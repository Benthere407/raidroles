--[[
raidroles - auto assignment.

Fills the composition's open slots from the registered members with the Hungarian algorithm
(minimum cost matching): the most slots filled first, then each member on the job they ranked
highest. Locked slots are kept as they are and their members take no other slot.
--]]

local data = require('data');

local solver = {};

local INF_PAIR = 1000000;   -- member can't play the slot
local LEAVE    = 1000;      -- a slot left open / a member left on the bench (each side)
local NO_SUB   = 60;        -- the slot names a subjob the member did not list for that job

--[[
What it costs to put member m in a slot asking for req, and the job they would play. Lower is better:
  gear on that job      BIS 0, GOOD (or unrated) 10, TEMU 20
  their preference      2 per place down their list
  a role, not a job     1 (a slot asking for exactly this job is the better fit)
  missing subjob        60 (still possible, but only when nobody better fits)
--]]
function solver.cost(req, m)
    local main, want = data.split_req(req);
    local best, best_job = nil, nil;
    for rank, j in ipairs(m.jobs or {}) do
        if data.job_fits(req, j) then
            local c = data.gear_cost(data.gear_of(m, j)) * 10 + (rank - 1) * 2 + (data.JOB_ID[main] and 0 or 1);
            if want ~= '' and not data.has_sub(m, j, want) then c = c + NO_SUB; end
            if best == nil or c < best then best, best_job = c, j; end
        end
    end
    return best, best_job;
end

-- Hungarian algorithm on a square cost matrix a[1..n][1..n]. Returns match[row] = col.
local function hungarian(a, n)
    local INF = math.huge;
    local u, v, p, way = {}, {}, {}, {};
    for i = 0, n do u[i] = 0; v[i] = 0; p[i] = 0; way[i] = 0; end
    for i = 1, n do
        p[0] = i;
        local j0 = 0;
        local minv, used = {}, {};
        for j = 0, n do minv[j] = INF; used[j] = false; end
        repeat
            used[j0] = true;
            local i0, delta, j1 = p[j0], INF, 0;
            for j = 1, n do
                if not used[j] then
                    local cur = a[i0][j] - u[i0] - v[j];
                    if cur < minv[j] then minv[j] = cur; way[j] = j0; end
                    if minv[j] < delta then delta = minv[j]; j1 = j; end
                end
            end
            for j = 0, n do
                if used[j] then u[p[j]] = u[p[j]] + delta; v[j] = v[j] - delta;
                else minv[j] = minv[j] - delta; end
            end
            j0 = j1;
        until p[j0] == 0;
        repeat
            local j1 = way[j0];
            p[j0] = p[j1];
            j0 = j1;
        until j0 == 0;
    end
    local match = {};
    for j = 1, n do if p[j] ~= 0 then match[p[j]] = j; end end
    return match;
end

--[[
comp:    { { label, slots = { req x6 } }, ... }
assign:  { { { name, job, lock }, x6 }, ... }  (current grid; locked cells are kept)
roster:  { [name] = { jobs = { 'WHM', ... }, ... } }
Returns a new assign grid and the list of members left on the bench.
--]]
function solver.solve(comp, assign, roster)
    local out = {};
    local taken = {};
    local slots = {};
    for p, party in ipairs(comp) do
        out[p] = {};
        for s = 1, #party.slots do
            local req = party.slots[s] or '';
            local cur = assign[p] and assign[p][s] or nil;
            if cur and cur.lock and cur.name ~= '' then
                out[p][s] = { name = cur.name, job = cur.job, sub = cur.sub or '', lock = true };
                taken[cur.name] = true;
            else
                out[p][s] = { name = '', job = '', sub = '', lock = false };
                if req ~= '' then slots[#slots + 1] = { p = p, s = s, req = req }; end
            end
        end
    end

    local members = {};
    for name, r in pairs(roster) do
        if not taken[name] and r.jobs and #r.jobs > 0 and not r.out then members[#members + 1] = name; end
    end
    table.sort(members);

    local n = math.max(#members, #slots);
    if n > 0 and #slots > 0 then
        local a = {};
        for i = 1, n do
            a[i] = {};
            for j = 1, n do
                local cost;
                if i > #members or j > #slots then
                    cost = LEAVE;
                else
                    cost = solver.cost(slots[j].req, roster[members[i]]) or INF_PAIR;
                end
                a[i][j] = cost;
            end
        end
        local match = hungarian(a, n);
        for i = 1, #members do
            local j = match[i];
            if j and j <= #slots and a[i][j] < INF_PAIR then
                local sl = slots[j];
                local m = roster[members[i]];
                local _, job = solver.cost(sl.req, m);
                local _, want = data.split_req(sl.req);
                out[sl.p][sl.s] = { name = members[i], job = job, sub = data.pick_sub(m, job, want), lock = false };
                taken[members[i]] = true;
            end
        end
    end

    local bench = {};
    for name, r in pairs(roster) do if not taken[name] and not r.out then bench[#bench + 1] = name; end end
    table.sort(bench);
    return out, bench;
end

return solver;
