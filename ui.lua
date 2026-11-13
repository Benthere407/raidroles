--[[
raidroles - the windows, in Vanacore's style (vcmenu).

    main window    My Jobs, My Assignment | Leader: Raid Board, Roll Call, Fights | Settings, Help
    raid check     a small window asking the member to send (or fix) their jobs
    assignment     a small window showing the member's party and job
--]]

require('common');
local imgui = require('imgui');
local vc    = require('vcmenu');
local data  = require('data');
local store = require('store');
local raid  = require('raid');
local solver = require('solver');

local C = vc.colors;
local ui = {};

local win  = vc.new_state('jobs');
local pwin = vc.new_state('main');   -- raid check prompt
local awin = vc.new_state('main');   -- assignment banner
ui.win = win;

local sel_fight = 1;                 -- the fight picked on the Fights page
local sel_roll  = nil;               -- the member picked on Roll Call
local buf_fight_name = { '' };
local buf_add_name, buf_add_jobs = { '' }, { '' };
local buf_notes = { '' };

local function z(n) return vc.z(n); end

local function save_scale(s)
    store.me.cfg.ui_scale = s;
    win.scale, pwin.scale, awin.scale = s, s, s;
    store.save();
end

local function input(id, buf, w, hint)
    pcall(imgui.PushItemWidth, w and z(w) or -1);
    local ok, edited;
    if hint then ok, edited = pcall(imgui.InputTextWithHint, id, hint, buf, 64); end
    if not ok then ok, edited = pcall(imgui.InputText, id, buf, 64); end
    pcall(imgui.PopItemWidth);
    return ok and edited;
end

local function tip(t) if imgui.IsItemHovered() then imgui.SetTooltip(t); end end

local function big(text, col, px)
    if vc.has_fonts() then
        vc.in_font('bi', px or 30, function() imgui.TextColored(col or C.text, text); end);
    else
        pcall(imgui.SetWindowFontScale, 1.8 * vc.scale());
        imgui.TextColored(col or C.text, text);
        pcall(imgui.SetWindowFontScale, vc.scale());
    end
end

local function chip(text, col)
    imgui.PushStyleColor(ImGuiCol_Button, col or C.seg);
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, col or C.seg);
    imgui.PushStyleColor(ImGuiCol_ButtonActive, col or C.seg);
    imgui.Button(text);
    imgui.PopStyleColor(3);
end

local function jobs_line(jobs)
    if jobs == nil or #jobs == 0 then return '-'; end
    return table.concat(jobs, ' ');
end

--- A fixed-height framed scrolling panel (vcmenu's list look), for lists that should not fill the page.
local function fixed_list(id, h, fn, always_scroll)
    imgui.PushStyleColor(ImGuiCol_ChildBg, C.side);
    imgui.PushStyleColor(ImGuiCol_Border, C.line);
    imgui.PushStyleColor(ImGuiCol_ScrollbarBg, always_scroll and C.field or { 0, 0, 0, 0 });
    imgui.PushStyleVar(ImGuiStyleVar_ChildRounding, z(6));
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { z(4), z(4) });
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { 0, 0 });
    local flags = always_scroll and (ImGuiWindowFlags_AlwaysVerticalScrollbar or 16384) or 0;
    if imgui.BeginChild(id, { 0, z(h) }, true, flags) then
        if not vc.has_fonts() then pcall(imgui.SetWindowFontScale, vc.scale()); end
        vc.safe(fn);
    end
    imgui.EndChild();
    imgui.PopStyleVar(3);
    imgui.PopStyleColor(3);
end

local function multiline(id, buf, h, size)
    local ok, edited = pcall(imgui.InputTextMultiline, id, buf, size or 1024, { -1, z(h) });
    return ok and edited;
end

--------------------------------------------------------------------------------
-- Pickers (popups)
--------------------------------------------------------------------------------
local SEL_KEEP = ImGuiSelectableFlags_DontClosePopups or 1;   -- a pick that leaves the popup open

--- The slot requirement picker: a job or role, then (optionally) a subjob. Returns the new requirement or nil.
local function req_picker(id, cur, w)
    local picked = nil;
    local main, sub = data.split_req(cur);
    local col = (cur == '' and C.mute) or ((data.ROLE[main] and not data.JOB_ID[main]) and C.teal) or C.gold;
    imgui.PushStyleColor(ImGuiCol_Text, col);
    if imgui.Button(data.req_label(cur) .. '##rq' .. id, { z(w or 84), 0 }) then imgui.OpenPopup('rqp' .. id); end
    imgui.PopStyleColor(1);
    tip('What this slot needs: a job or a role, and the subjob to bring');
    if imgui.BeginPopup('rqp' .. id) then
        local function with_sub(m) return data.norm_req(m .. (sub ~= '' and ('/' .. sub) or '')); end
        imgui.TextColored(C.teal, 'Main job');
        for i, j in ipairs(data.JOBS) do
            if (i - 1) % 6 ~= 0 then imgui.SameLine(); end
            if imgui.Selectable(j .. '##j' .. id, main == j, SEL_KEEP, { z(34), 0 }) then picked = with_sub(j); end
        end
        imgui.TextColored(C.teal, 'or a role');
        for i, r in ipairs(data.ROLES) do
            if i > 1 then imgui.SameLine(); end
            if imgui.Selectable(('%s##r%s%s'):format(r.label, r.id, id), main == r.id, SEL_KEEP, { z(58), 0 }) then picked = with_sub(r.id); end
            tip(r.jobs and table.concat(r.jobs, ' ') or 'every job');
        end
        imgui.Separator();
        imgui.TextColored(C.teal, 'Subjob');
        if main == '' then
            imgui.TextColored(C.mute, '  pick the main job first');
        else
            for i, j in ipairs(data.JOBS) do
                if (i - 1) % 6 ~= 0 then imgui.SameLine(); end
                if j ~= main and imgui.Selectable(j .. '##s' .. id, sub == j, 0, { z(34), 0 }) then picked = data.norm_req(main .. '/' .. j); end
                if j == main then imgui.Dummy({ z(34), 1 }); end
            end
            if imgui.Selectable('(their choice of subjob)##ns' .. id, sub == '') then picked = main; end
        end
        imgui.Separator();
        if imgui.Selectable('(unused slot)##u' .. id) then picked = ''; end
        imgui.EndPopup();
    end
    return picked;
end

--- The member picker for a slot. Returns a name ('' = clear) or nil.
local function member_picker(id, p, s, w, col)
    local r = raid.get();
    local cell = r.assign[p][s];
    local req = r.comp[p].slots[s];
    local _, want = data.split_req(req);
    local picked = nil;
    local label = cell.name ~= '' and cell.name or (req ~= '' and '(open)' or '');
    imgui.PushStyleColor(ImGuiCol_Text, cell.name ~= '' and (col or C.text) or C.mute);
    if imgui.Button(vc.fit_text(label, z((w or 140) - 10)) .. '##mb' .. id, { z(w or 140), 0 }) then imgui.OpenPopup('mbp' .. id); end
    imgui.PopStyleColor(1);
    if imgui.BeginPopup('mbp' .. id) then
        local fit, other = {}, {};
        for name, m in pairs(r.roster) do
            if not m.out then
                local cost, job = solver.cost(req, m);
                if job then fit[#fit + 1] = { name = name, job = job, cost = cost, m = m }; else other[#other + 1] = name; end
            end
        end
        table.sort(fit, function (a, b) if a.cost ~= b.cost then return a.cost < b.cost; end return a.name < b.name; end);
        table.sort(other);
        imgui.TextColored(C.teal, ('Can play %s  (best fit first)'):format(data.req_label(req)));
        if #fit == 0 then imgui.TextColored(C.mute, '  nobody registered'); end
        for _, f in ipairs(fit) do
            local wp = raid.slot_of(f.name);
            local where = (wp == data.SB and '  (standby)') or (wp == data.OH and '  (outside heal)') or (wp and ('  (in P%d)'):format(wp)) or '  (unassigned)';
            local g = data.gear_label(data.gear_of(f.m, f.job));
            local subs = data.subs_of(f.m, f.job);
            local txt = ('%s  -  %s%s%s%s'):format(f.name, f.job, g ~= '' and (' ' .. g) or '',
                #subs > 0 and ('  /' .. table.concat(subs, '/')) or '', where);
            local missing = want ~= '' and not data.has_sub(f.m, f.job, want);
            if missing then imgui.PushStyleColor(ImGuiCol_Text, C.bad); end
            if imgui.Selectable(txt .. '##f' .. id, cell.name == f.name) then picked = f.name; end
            if missing then imgui.PopStyleColor(1); tip('Did not list ' .. want .. ' as a subjob for ' .. f.job); end
        end
        if #other > 0 then
            imgui.Separator();
            imgui.TextColored(C.mute, 'Others (did not list this job)');
            for _, name in ipairs(other) do
                if imgui.Selectable(('%s  -  %s##o%s'):format(name, jobs_line(r.roster[name].jobs), id), false) then picked = name; end
            end
        end
        imgui.Separator();
        if imgui.Selectable('Clear slot##c' .. id) then picked = ''; end
        imgui.EndPopup();
    end
    return picked;
end

--------------------------------------------------------------------------------
-- Member pages
--------------------------------------------------------------------------------
local sel_job = nil;   -- the job whose subjobs are being picked on My Jobs

local function changed()
    if raid.get() then raid.add_self(); end
    store.save();
end

local function set_jobs(jobs)
    store.me.jobs = jobs;
    local keep = {};
    for _, j in ipairs(jobs) do keep[j] = true; end
    for j in pairs(store.me.subs) do if not keep[j] then store.me.subs[j] = nil; end end
    for j in pairs(store.me.gear) do if not keep[j] then store.me.gear[j] = nil; end end
    if sel_job and not keep[sel_job] then sel_job = nil; end
    changed();
end

--- A grid of job buttons; picked ones are lit and numbered in pick order. setter(new_list).
--- skip: a job not offered (shown dim); max: at most this many picked.
local function job_grid(id, list, setter, col, skip, max)
    local rank = {};
    for i, j in ipairs(list) do rank[j] = i; end
    for i, j in ipairs(data.JOBS) do
        if (i - 1) % 8 ~= 0 then imgui.SameLine(); end
        local on = rank[j] ~= nil;
        local off = (j == skip) or (not on and max and #list >= max);
        if on then
            imgui.PushStyleColor(ImGuiCol_Button, col or C.on);
            imgui.PushStyleColor(ImGuiCol_Text, { 1, 1, 1, 1 });
        else
            imgui.PushStyleColor(ImGuiCol_Button, C.field);
            imgui.PushStyleColor(ImGuiCol_Text, off and vc.alpha(C.mute, 0.5) or C.dim);
        end
        local label = on and ('%s  %d'):format(j, rank[j]) or j;
        if imgui.Button(label .. '##' .. id .. j, { z(62), z(26) }) and not off then
            local nl = store.copy(list);
            if on then table.remove(nl, rank[j]); else nl[#nl + 1] = j; end
            setter(nl);
        end
        imgui.PopStyleColor(2);
        if j == skip then tip('Your main job'); elseif off then tip(('Up to %d'):format(max)); end
    end
    return rank;
end

local GEAR_OPTS = { { 'B', 'BIS' }, { 'G', 'GOOD' }, { 'T', 'TEMU' } };

-- Your Order's columns (x at 100% scale, from the row's left edge)
local COL = { job = 22, gear = 84, sub = 246, up = 426, down = 486, x = 558 };
local gear_w = 140;   -- the gear switch's width at 100% (measured each frame)

--- A button with a small up or down arrow before its label. Returns clicked.
local function arrow_button(id, label, up, w)
    pcall(imgui.PushStyleVar, ImGuiStyleVar_ButtonTextAlign, { 0.8, 0.5 });
    local clicked = imgui.Button(label .. '##ar' .. id, { z(w), 0 });
    pcall(imgui.PopStyleVar, 1);
    pcall(function()
        local x0, y0 = vc.xy(imgui.GetItemRectMin());
        local _, y1 = vc.xy(imgui.GetItemRectMax());
        local cx, cy, s = x0 + z(12), (y0 + y1) / 2, z(4.5);
        local col = vc.u32(imgui.IsItemHovered() and C.text or C.acc);
        local dl = imgui.GetWindowDrawList();
        if up then dl:AddTriangleFilled({ cx, cy - s }, { cx + s, cy + s * 0.7 }, { cx - s, cy + s * 0.7 }, col);
        else dl:AddTriangleFilled({ cx - s, cy - s * 0.7 }, { cx + s, cy - s * 0.7 }, { cx, cy + s }, col); end
    end);
    return clicked;
end

local buf_set = { '' };   -- the job set name box

local function sets()
    store.me.sets = store.me.sets or {};
    return store.me.sets;
end

local function find_set(name)
    for i, st in ipairs(sets()) do if st.name:lower() == name:lower() then return i, st; end end
    return nil;
end

local function save_set(name)
    name = tostring(name or ''):gsub('^%s+', ''):gsub('%s+$', '');
    if name == '' then raid.warn('Type a name for the job set first.'); return; end
    local st = { name = name, jobs = store.copy(store.me.jobs), subs = store.copy(store.me.subs), gear = store.copy(store.me.gear) };
    local i = find_set(name);
    if i then sets()[i] = st; else sets()[#sets() + 1] = st; end
    store.me.set_name = name;
    store.save();
    raid.say(('Saved job set "%s".'):format(name));
end

local function load_set(st)
    store.me.jobs = store.copy(st.jobs or {});
    store.me.subs = store.copy(st.subs or {});
    store.me.gear = store.copy(st.gear or {});
    store.me.set_name = st.name;
    buf_set[1] = st.name;
    sel_job = nil;
    changed();
    raid.say(('Loaded job set "%s".'):format(st.name));
end

local function job_sets_bar()
    if buf_set.init == nil then buf_set[1] = store.me.set_name or ''; buf_set.init = true; end
    imgui.TextColored(C.dim, 'Job set');
    imgui.SameLine(z(70));
    input('##setname', buf_set, 180, 'name, e.g. Sortie or Dynamis');
    imgui.SameLine();
    if vc.button('Save##set', 'primary') then save_set(buf_set[1]); end
    tip('Saves your jobs, gear and subjobs under this name (same name = update it)');
    imgui.SameLine();
    local list = sets();
    local cur = store.me.set_name;
    if vc.button(((cur and cur ~= '') and ('Load: ' .. cur) or 'Load a saved set') .. '  v##setl') then imgui.OpenPopup('setp'); end
    if imgui.BeginPopup('setp') then
        imgui.TextColored(C.teal, 'Saved job sets');
        if #list == 0 then imgui.TextColored(C.mute, '  none yet: type a name and Save'); end
        for i, st in ipairs(list) do
            if imgui.Selectable(('%s   (%d jobs)##st%d'):format(st.name, #(st.jobs or {}), i), st.name == cur) then load_set(st); end
            tip(data.signup_pretty(st.jobs, st.subs, st.gear));
        end
        imgui.EndPopup();
    end
    local i = find_set(buf_set[1] or '');
    if i then
        imgui.SameLine();
        if vc.button('Delete##set', 'danger') then
            table.remove(list, i);
            if store.me.set_name == buf_set[1] then store.me.set_name = nil; end
            store.save();
        end
        tip('Deletes the saved set "' .. buf_set[1] .. '"');
    end
end

local buf_leader = { '' };   -- who "Send to leader" goes to

--- Send my jobs: by tell to the raid leader, or posted in party chat.
local function send_bar()
    local known, known_id = raid.known_leader();
    if buf_leader[1] == '' and known then buf_leader[1] = known; end
    imgui.TextColored(C.dim, 'Send jobs');
    imgui.SameLine(z(70));
    input('##leader', buf_leader, 180, 'raid leader\'s name');
    tip('The raid leader: filled in from the last raid check or assignment');
    imgui.SameLine();
    if vc.button('Send to raid leader##sendl', 'primary') then
        local id = (known and raid.cap(buf_leader[1]) == known) and known_id or nil;
        raid.send_jobs(buf_leader[1], id);
    end
    tip('Tells the leader your jobs, gear and subjobs. Their addon adds you to their raid.');
    imgui.SameLine();
    if vc.button('Post in party chat##sendp') then raid.post_jobs_party(); end
    tip('Posts your jobs in party chat for everyone to read (a leader in the party with the addon registers you too)');
end

local function page_jobs()
    vc.title('My Jobs', 'the jobs you are willing to play, best first');
    local jobs = store.me.jobs;
    job_sets_bar();
    send_bar();

    vc.section('1  PICK YOUR MAIN JOBS', ('%d picked'):format(#jobs));
    local rank = job_grid('jb', jobs, function (nl)
        if #nl > #jobs then sel_job = nl[#nl]; end   -- a job just added: pick its subjobs next
        set_jobs(nl);
    end);
    imgui.Dummy({ 1, z(4) });
    imgui.TextColored(C.dim, 'Add:');
    for _, g in ipairs(data.JOB_GROUPS) do
        imgui.SameLine();
        if vc.button(g[1] .. '##grp') then
            local nj = store.copy(jobs);
            for _, j in ipairs(g[2]) do if not rank[j] then nj[#nj + 1] = j; end end
            set_jobs(nj);
        end
        tip(table.concat(g[2], ' '));
    end
    imgui.SameLine();
    if vc.button('Clear##jobs', 'danger') then set_jobs({}); end

    vc.section('2  YOUR ORDER, GEAR AND SUBJOBS', 'first = most wanted');
    if #jobs == 0 then
        vc.note('Click jobs above. The order you pick them in is your preference: auto-assign tries your first job first.');
    end
    if #jobs > 0 then   -- column headings, lined up with the rows below
        local hx = imgui.GetCursorPosX();
        -- each heading centred over its column: x and width at 100% (the gear switch is measured)
        local function head(text, x, w, first)
            local tw = vc.xy(imgui.CalcTextSize(text));
            local at = hx + z(x) + math.max(0, (z(w) - tw) / 2);
            if first then imgui.SetCursorPosX(at); else imgui.SameLine(at); end
            imgui.TextColored(C.mute, text);
        end
        head('#', 0, 16, true);
        head('Job', COL.job, 52);
        head('Gear', COL.gear, gear_w);
        head('Sub Jobs', COL.sub, 170);
        head('Preference', COL.up, COL.down - COL.up + 66);
    end
    for i, j in ipairs(jobs) do
        local on = sel_job == j;
        local x0 = imgui.GetCursorPosX();
        imgui.TextColored(C.mute, ('%2d'):format(i));
        imgui.SameLine(x0 + z(COL.job));
        -- the job itself: a drop-down to change it (a job already in the list swaps places)
        imgui.PushStyleColor(ImGuiCol_Button, C.field);
        imgui.PushStyleColor(ImGuiCol_Text, on and C.acc or (i == 1 and C.gold or C.text));
        if imgui.Button(j .. '  v##jd' .. i, { z(52), 0 }) then imgui.OpenPopup('jdp' .. i); sel_job = j; end
        imgui.PopStyleColor(2);
        tip('Change this job (also opens its subjobs)');
        if imgui.BeginPopup('jdp' .. i) then
            imgui.TextColored(C.teal, ('Change %s to'):format(j));
            for k, nj in ipairs(data.JOBS) do
                if (k - 1) % 6 ~= 0 then imgui.SameLine(); end
                local at = rank[nj];
                local lbl = (at and nj ~= j) and ('%s %d'):format(nj, at) or nj;
                if imgui.Selectable(lbl .. '##jo' .. i .. nj, nj == j, 0, { z(44), 0 }) and nj ~= j then
                    local list = store.copy(jobs);
                    if at then
                        list[i], list[at] = list[at], list[i];   -- already listed: swap the two places
                    else
                        list[i] = nj;                            -- new job: takes this place, gear and subjobs
                        store.me.gear[nj] = store.me.gear[j];
                        local carried = {};
                        for _, sj in ipairs(store.me.subs[j] or {}) do if sj ~= nj then carried[#carried + 1] = sj; end end
                        store.me.subs[nj] = carried;
                        if sel_job == j then sel_job = nj; end
                    end
                    set_jobs(list);
                end
                if at and nj ~= j then tip(('Already #%d: swaps places'):format(at)); end
            end
            imgui.EndPopup();
        end
        imgui.SameLine(x0 + z(COL.gear));
        local gx = vc.screen_pos();
        local g = vc.seg('gear' .. j, GEAR_OPTS, store.me.gear[j]);
        if g then store.me.gear[j] = g; changed(); end
        gear_w = (vc.xy(imgui.GetItemRectMax()) - gx) / vc.scale();   -- for centring the Gear heading
        tip('How well geared you are on ' .. j);
        imgui.SameLine(x0 + z(COL.sub));
        local subs = store.me.subs[j] or {};
        if on then imgui.PushStyleColor(ImGuiCol_Button, C.seg); imgui.PushStyleColor(ImGuiCol_Text, C.acc); end
        if imgui.Button(((#subs > 0) and ('/' .. table.concat(subs, '/')) or 'pick subjobs') .. '##sb' .. i, { z(170), 0 }) then
            if on then sel_job = nil; else sel_job = j; end
        end
        if on then imgui.PopStyleColor(2); end
        tip(on and 'Close the subjob picker' or ('Pick the subjobs you can use on ' .. j .. ' (up to 5)'));
        imgui.SameLine(x0 + z(COL.up));
        if i > 1 then
            if arrow_button('u' .. i, 'Up', true, 54) then
                local nj = store.copy(jobs); nj[i], nj[i - 1] = nj[i - 1], nj[i]; set_jobs(nj);
            end
            tip('Move ' .. j .. ' up (more wanted)');
        else imgui.Dummy({ z(54), 1 }); end
        imgui.SameLine(x0 + z(COL.down));
        if i < #jobs then
            if arrow_button('d' .. i, 'Down', false, 66) then
                local nj = store.copy(jobs); nj[i], nj[i + 1] = nj[i + 1], nj[i]; set_jobs(nj);
            end
            tip('Move ' .. j .. ' down (less wanted)');
        else imgui.Dummy({ z(66), 1 }); end
        imgui.SameLine(x0 + z(COL.x));
        if imgui.Button('X##x' .. i, { z(26), 0 }) then
            local nj = store.copy(jobs); table.remove(nj, i); set_jobs(nj);
        end
        tip('Remove ' .. j);

        -- the subjob picker opens right under the job it is for
        if on then
            pcall(imgui.Indent, z(24));
            imgui.Dummy({ 1, z(2) });
            imgui.TextColored(C.teal, ('Subjobs for %s'):format(j));
            imgui.SameLine();
            imgui.TextColored(C.mute, ('%d / %d  -  best first'):format(#subs, data.MAX_SUBS));
            imgui.SameLine();
            if vc.button('Done##sjd') then sel_job = nil; end
            imgui.SameLine();
            if #subs > 0 and vc.button('Clear all##sjc', 'danger') then store.me.subs[j] = {}; changed(); end
            job_grid('sj' .. j, subs, function (nl) store.me.subs[j] = nl; changed(); end, C.teal, j, data.MAX_SUBS);
            imgui.Dummy({ 1, z(6) });
            pcall(imgui.Unindent, z(24));
        end
    end
    if #jobs > 0 then
        vc.note(('Rate your gear on each job, and click its subjob button to pick up to %d subjobs for it.'):format(data.MAX_SUBS));
    end

    vc.section('RAID CHECK');
    local p = raid.pending;
    if p and not p.join then
        imgui.TextColored(C.gold, ('%s is running a raid check for %s.'):format(p.leader, p.fight or 'a raid'));
        if vc.button('Send my jobs to ' .. p.leader, 'primary') then raid.reply(p); end
    else
        local lr = store.me.last_reply;
        if lr then imgui.TextColored(C.dim, ('Last sent to %s (raid %s).'):format(lr.leader, lr.id)); end
        vc.note('Your jobs are saved for this character. When a leader runs a raid check you will be asked to confirm them (Settings can make it automatic).');
    end
end

--- What the member's role is, for the headline: text, colour, whether a job check applies.
local function my_role(m)
    if m.standby then
        return ('STANDBY  #%d'):format(m.standby), true;
    elseif m.party == data.OH then
        return 'OUTSIDE HEAL', true;
    elseif m.party then
        return ('PARTY %d'):format(m.party), true;
    elseif m.unassigned_me then
        return 'UNASSIGNED', false;
    end
    return nil;
end

--- One list of members (a party, standby or outside heal) on My Assignment.
local function member_rows(members, first)
    if #members == 0 then imgui.TextColored(C.mute, '  nobody'); return; end
    for i, mem in ipairs(members) do
        local me = mem.name == raid.my_name();
        imgui.TextColored(C.mute, ('%2d'):format(i + (first or 1) - 1));
        if mem.name == '' then
            imgui.SameLine(z(30));
            imgui.TextColored(C.mute, ('(open)  %s'):format(mem.job or ''));
        else
            imgui.SameLine(z(30));
            imgui.TextColored(me and C.acc or C.text, mem.name);
            imgui.SameLine(z(170));
            imgui.TextColored(me and C.acc or C.dim, mem.job or '');
            if (mem.sub or '') ~= '' then
                imgui.SameLine(z(215));
                imgui.TextColored(me and C.acc or C.teal, '/ ' .. mem.sub);
            end
        end
    end
end

local zerg_card;   -- (defined with the Zerg page, below)
local function page_mine()
    vc.title('My Assignment');
    local m = raid.mine();
    if zerg_card then zerg_card(); end
    if m == nil or m.id == nil then
        vc.note('No assignment yet. When your leader posts assignments it shows up here (and pops up, if Settings allow).');
        return;
    end
    imgui.TextColored(C.dim, ('%s  -  leader %s'):format(m.fight or 'Raid', m.leader or '?'));
    local head, has_job = my_role(m);
    if head == nil then
        vc.note('Assignments are out, but you are not in them yet. Ask the leader, or /tell them !rr to check.');
    elseif not has_job then
        big(head, C.mute, 30);
        vc.note('You are registered but have no role in this raid yet. Stay close: the leader may still place you.');
    else
        big(('%s  -  %s'):format(head, data.job_sub(m.job or '?', m.sub)), C.gold, 30);
        if m.label and m.label ~= '' and not m.standby and m.party ~= data.OH then imgui.TextColored(C.teal, m.label); end
        if m.standby then vc.note('You are on standby: stay ready on that job. The leader will call you in if a slot opens.'); end
        if m.party == data.OH then vc.note('You heal from outside the alliance: do not join a party.'); end
        vc.stat('Main job', m.job or '?', C.gold, 90);
        vc.stat('Sub job', (m.sub or '') ~= '' and m.sub or 'your choice', (m.sub or '') ~= '' and C.teal or C.mute, 90);
        local cur, cur_sub = raid.my_job(), raid.my_sub();
        local ok = cur == m.job and ((m.sub or '') == '' or cur_sub == m.sub);
        local now = data.job_sub(cur or '?', cur_sub);
        if ok then imgui.TextColored(C.good, ('You are on %s.'):format(now));
        else imgui.TextColored(C.bad, ('You are on %s: change to %s.'):format(now, data.job_sub(m.job or '?', m.sub))); end
    end

    imgui.Dummy({ 1, z(4) });
    if head then
        if m.acked then imgui.TextColored(C.good, 'You told the leader you have seen it.');
        elseif vc.button('Got it - tell the leader', 'primary') then raid.ack(); end
    end

    -- the raid two sections to a row, as on the Raid Board:
    -- Party 1 | Party 2, Party 3 | Outside Heal, Standby 1-6 | Standby 7-12, then Unassigned
    local parties = m.parties or {};
    local gap = z(14);
    local colw = math.floor((vc.avail_w() - gap) / 2);
    local lh = z(20);
    pcall(function() lh = imgui.GetTextLineHeightWithSpacing(); end);
    local box_h = z(40) + data.SLOTS * lh;
    local function box(id, title, members, from)
        imgui.PushStyleColor(ImGuiCol_ChildBg, { 0, 0, 0, 0 });
        local open = imgui.BeginChild('##mbox' .. id, { colw, box_h }, false,
            bit.bor(ImGuiWindowFlags_NoScrollbar or 0, ImGuiWindowFlags_NoScrollWithMouse or 0));
        if open then
            if not vc.has_fonts() then pcall(imgui.SetWindowFontScale, vc.scale()); end
            vc.safe(function ()
                local list = {};
                for i = from, math.min(#members, from + data.SLOTS - 1) do list[#list + 1] = members[i]; end
                local named = 0;
                for _, mem in ipairs(list) do if mem.name ~= '' then named = named + 1; end end
                vc.section(title, ('%d'):format(named));
                member_rows(list, from);
            end);
        end
        imgui.EndChild();
        imgui.PopStyleColor(1);
    end
    local function party_box(p)
        local party = parties[tostring(p)];
        local members = party and party.members or {};
        if p == data.OH then return box('oh', 'OUTSIDE HEAL', members, 1); end
        return box('p' .. p, ('PARTY %d  %s'):format(p, ((party and party.label) or ''):upper()), members, 1);
    end
    local sb = parties[tostring(data.SB)];
    local sbm = sb and sb.members or {};
    party_box(1); imgui.SameLine(0, gap); party_box(2);
    party_box(3); imgui.SameLine(0, gap); party_box(data.OH);
    box('sb1', 'STANDBY  1-6', sbm, 1); imgui.SameLine(0, gap); box('sb2', 'STANDBY  7-12', sbm, 7);

    local un = m.unassigned or {};
    vc.section('UNASSIGNED', ('%d'):format(#un));
    if #un == 0 then imgui.TextColored(C.mute, '  nobody'); end
    for i, name in ipairs(un) do
        imgui.TextColored(C.mute, ('%2d'):format(i));
        imgui.SameLine(z(30));
        imgui.TextColored(name == raid.my_name() and C.acc or C.text, name);
    end
end

--------------------------------------------------------------------------------
-- Leader pages
--------------------------------------------------------------------------------
local function start_picker()
    vc.note('Pick a fight to start a raid. You can change the composition on the board, and save it on Fights.');
    for i, f in ipairs(store.fights) do
        if vc.button(('Start: %s##st%d'):format(f.name, i), i == 1 and 'primary' or nil) then
            raid.start(f, false);
            win.page = 'board';
        end
    end
end

local function status_of(name, job, sub, ally)
    local a = ally[name];
    if a == nil then return 'not in alliance', C.mute; end
    local now = 'on ' .. data.job_sub(a.job or '?', a.sub);
    if job ~= '' and a.job and a.job ~= job then return now, C.bad; end
    if (sub or '') ~= '' and a.sub and a.sub ~= sub then return now, C.bad; end
    return now .. (a.block and ('  pt ' .. a.block) or ''), C.good;
end

--- The subjob picker for an assigned slot: the member's own subjobs first. Returns a job, '' (none) or nil.
local function sub_picker(id, cell, m, w)
    local picked = nil;
    imgui.PushStyleColor(ImGuiCol_Text, (cell.sub or '') ~= '' and C.teal or C.mute);
    if imgui.Button(((cell.sub or '') ~= '' and ('/' .. cell.sub) or '/sub') .. '##sp' .. id, { z(w or 52), 0 }) then imgui.OpenPopup('spp' .. id); end
    imgui.PopStyleColor(1);
    tip('Subjob for this slot');
    if imgui.BeginPopup('spp' .. id) then
        local subs = data.subs_of(m, cell.job);
        imgui.TextColored(C.teal, ('Their subjobs for %s'):format(cell.job));
        if #subs == 0 then imgui.TextColored(C.mute, '  none registered'); end
        for _, j in ipairs(subs) do
            if j ~= cell.job and imgui.Selectable(j .. '##ms' .. id, cell.sub == j) then picked = j; end
        end
        imgui.Separator();
        imgui.TextColored(C.mute, 'Any job');
        for i, j in ipairs(data.JOBS) do
            if (i - 1) % 6 ~= 0 then imgui.SameLine(); end
            if imgui.Selectable(j .. '##as' .. id, cell.sub == j, 0, { z(34), 0 }) then picked = j; end
        end
        imgui.Separator();
        if imgui.Selectable('(their choice)##ns' .. id) then picked = ''; end
        imgui.EndPopup();
    end
    return picked;
end

--- One section of the Raid Board (a party, standby or outside heal), compact enough for two side by side.
--- Columns: slot | needs | member (coloured by status; hover for details) | job | /sub | lock | ready
local function draw_party(r, p, ally, from, to)
    local party = r.comp[p];
    from, to = from or 1, to or data.SLOTS;
    local blocks, n_in, nf = {}, 0, 0;
    for s = from, to do
        local c = r.assign[p][s];
        if c.name ~= '' then
            nf = nf + 1;
            local a = ally[c.name];
            if a then blocks[a.block] = true; n_in = n_in + 1; end
        end
    end
    local nb = 0; for _ in pairs(blocks) do nb = nb + 1; end
    if party.standby then
        vc.section(('STANDBY  %d-%d'):format(from, to), ('%d/%d  -  in this order'):format(nf, to - from + 1));
    elseif party.outside then
        vc.section('OUTSIDE HEAL', ('%d/%d  -  outside the alliance'):format(nf, data.SLOTS));
    else
        local right = ('%d/%d'):format(nf, data.SLOTS);
        if nb > 1 then right = right .. '  -  split up';
        elseif n_in > 0 and n_in == nf then right = right .. '  -  together';
        elseif n_in > 0 then right = right .. ('  -  %d in ally'):format(n_in); end
        vc.section(('PARTY %d  %s'):format(p, (party.label or ''):upper()), right);
    end

    local base = imgui.GetCursorPosX();
    local X = { req = 22, mem = 96, job = 198, sub = 232, lock = 280, ready = 318 };
    for s = from, to do
        local id = p .. '_' .. s;
        local c = r.assign[p][s];
        local mem = r.roster[c.name];
        imgui.TextColored(C.mute, tostring(s));
        imgui.SameLine(base + z(X.req));
        local nr = req_picker(id, party.slots[s], 70);
        if nr ~= nil then
            party.slots[s] = nr;
            if c.name ~= '' and not c.lock then c.name, c.job, c.sub = '', '', ''; end
            if r.mode == 'auto' then raid.auto(); end
            store.save();
        end
        imgui.SameLine(base + z(X.mem));
        -- the member's colour says where they stand: green ready to go, red wrong job, grey not in the alliance
        local st, col = nil, nil;
        if c.name ~= '' then st, col = status_of(c.name, c.job, c.sub, ally); end
        local pick = member_picker(id, p, s, 98, (col == C.mute) and C.text or col);
        if c.name ~= '' then
            local gl = data.gear_label(data.gear_of(mem, c.job));
            tip(('%s  -  %s%s\n%s%s'):format(c.name, data.job_sub(c.job, c.sub), gl ~= '' and ('  (' .. gl .. ')') or '', st,
                (mem and mem.ack) and '\nhas seen the assignment' or ''));
        end
        if pick ~= nil then raid.set_slot(p, s, pick); end
        imgui.SameLine(base + z(X.job));
        pcall(imgui.AlignTextToFramePadding);
        imgui.TextColored(c.job ~= '' and C.gold or C.mute, c.job ~= '' and c.job or '');
        if c.name ~= '' then
            imgui.SameLine(base + z(X.sub));
            local lacks = (c.sub or '') ~= '' and mem ~= nil and not data.has_sub(mem, c.job, c.sub);
            if lacks then imgui.PushStyleColor(ImGuiCol_Border, C.bad); imgui.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 1); end
            local ns = sub_picker(id, c, mem, 44);
            if lacks then imgui.PopStyleVar(1); imgui.PopStyleColor(1); tip(('%s did not list %s as a subjob for %s'):format(c.name, c.sub, c.job)); end
            if ns ~= nil then c.sub = ns; store.save(); end
            imgui.SameLine(base + z(X.lock));
            local v = vc.switch('lk' .. id, '', c.lock);
            if v ~= nil then c.lock = v; store.save(); end
            tip(c.lock and 'Locked: auto-fill keeps it' or 'Free: auto-fill may change it (click to lock)');
            -- confirmed: the member clicked Got it on their assignment
            imgui.SameLine(base + z(X.ready));
            local ok = mem and mem.ack;
            local missed = mem and mem.missed and not ok;
            vc.in_font('reg', 13, function ()
                pcall(imgui.AlignTextToFramePadding);
                imgui.TextColored(ok and C.good or (missed and C.gold or C.bad),
                    ok and 'Role Confirmed' or (missed and 'Tell not received' or 'Unconfirmed'));
            end);
            tip(ok and (c.name .. ' clicked Got it on their assignment')
                or (missed and (c.name .. ' was offline or zoning when you told them: Post again or tell them by hand'))
                or (c.name .. ' has not confirmed yet (they confirm with Got it after you post)'));
        end
    end
end

local function page_board()
    local r = raid.get();
    if r == nil then
        vc.title('Raid Board', 'no raid running');
        start_picker();
        return;
    end
    local ally = raid.alliance();
    vc.title(r.fight, ('raid %s'):format(r.id));
    if (r.notes or '') ~= '' then
        imgui.PushStyleColor(ImGuiCol_Text, C.dim);
        pcall(imgui.PushTextWrapPos, 0);
        imgui.Text(r.notes);
        pcall(imgui.PopTextWrapPos);
        imgui.PopStyleColor(1);
    end

    local nreg, filled, total = 0, 0, 0;
    for _ in pairs(r.roster) do nreg = nreg + 1; end
    for p = 1, data.MAX_PARTIES do
        for s = 1, data.SLOTS do
            if r.comp[p].slots[s] ~= '' then total = total + 1; end
            if r.assign[p][s].name ~= '' then filled = filled + 1; end
        end
    end
    local nsb, nun, noh = #raid.standby(), #raid.unassigned(), #raid.members_of(data.OH);
    imgui.TextColored(C.dim, ('%d registered  -  %d / %d slots filled  -  %d outside heal  -  %d standby  -  %d unassigned%s'):format(nreg, filled, total, noh, nsb, nun,
        raid.queue_size() > 0 and ('  -  sending %d line(s)...'):format(raid.queue_size()) or ''));

    local mode = vc.seg('mode', { { 'auto', 'Auto assign' }, { 'manual', 'Manual' } }, r.mode);
    if mode then r.mode = mode; if mode == 'auto' then raid.auto(); end store.save(); end
    tip('Auto: the board refills itself as people register. Manual: you place everyone (Auto-fill still works).');
    imgui.SameLine(); if vc.button('Auto-fill') then raid.auto(); end
    tip('Fills the open (unlocked) slots from the registrations');
    imgui.SameLine(); if vc.button('Clear') then raid.clear_assign(true); end
    tip('Empties the unlocked slots');
    imgui.SameLine(); if vc.button('Post assignments', 'primary') then raid.post(); end
    tip('Posts every party to the chat channel; tells members as Settings say');
    -- the session, at the right of the same row
    vc.right(176);
    if vc.button('Change fight') then win.page = 'fights'; end
    tip('Pick another fight for this raid (registrations are kept)');
    imgui.SameLine();
    if vc.button('End raid', 'danger') then imgui.OpenPopup('##endraid'); end
    tip('Forgets this raid: its registrations and assignments');
    if imgui.BeginPopup('##endraid') then
        imgui.TextColored(C.text, 'End this raid? Its registrations and assignments are forgotten.');
        if vc.button('End raid##yes', 'danger') then raid.end_session(); imgui.CloseCurrentPopup(); end
        imgui.SameLine();
        if vc.button('Keep it##no') then imgui.CloseCurrentPopup(); end
        imgui.EndPopup();
    end
    if raid.get() == nil then return; end

    -- raid checks: everyone, or only who is missing (jobs before the post, confirmations after it)
    if vc.button('Raid check ALL') then raid.poll(); end
    tip('Asks everyone (in the chat channel from Settings) to send their jobs');
    imgui.SameLine();
    local missing, what = raid.missing();
    if #missing > 0 then
        if vc.button(('Raid check: Not Received / Not Confirmed (%d)##missing'):format(#missing)) then raid.check_missing(); end
        tip(what == 'jobs'
            and ('Tells the raid check again to alliance members who have not sent their jobs:\n' .. table.concat(missing, ', '))
            or ('Tells their assignment again to everyone who did not receive it or has not confirmed:\n'
                .. table.concat(missing, ', ') .. '\n(Players without the addon cannot confirm: they are resent only when their tell bounced.)'));
    else
        pcall(imgui.AlignTextToFramePadding);
        imgui.TextColored(C.good, (r.posted and 'Everyone has received and confirmed their assignment.')
            or 'Everyone in the alliance has sent their jobs.');
    end

    -- the sections two to a row: Party 1 | Party 2, Party 3 | Outside Heal, Standby 1-6 | Standby 7-12
    local gap = z(14);
    local colw = math.floor((vc.avail_w() - gap) / 2);
    local fh = z(26);
    pcall(function() fh = imgui.GetFrameHeightWithSpacing(); end);
    local box_h = z(40) + data.SLOTS * fh;
    local function box(b)
        imgui.PushStyleColor(ImGuiCol_ChildBg, { 0, 0, 0, 0 });
        local open = imgui.BeginChild('##pbox' .. b[1] .. '_' .. b[2], { colw, box_h }, false,
            bit.bor(ImGuiWindowFlags_NoScrollbar or 0, ImGuiWindowFlags_NoScrollWithMouse or 0));
        if open then
            if not vc.has_fonts() then pcall(imgui.SetWindowFontScale, vc.scale()); end
            vc.safe(draw_party, r, b[1], ally, b[2], b[2] + data.SLOTS - 1);
        end
        imgui.EndChild();
        imgui.PopStyleColor(1);
    end
    for _, row in ipairs({ { { 1, 1 }, { 2, 1 } }, { { 3, 1 }, { data.OH, 1 } }, { { data.SB, 1 }, { data.SB, 7 } } }) do
        box(row[1]);
        if row[2] then imgui.SameLine(0, gap); box(row[2]); end
    end

    local un = raid.unassigned();
    vc.section('UNASSIGNED ROLE', ('%d registered without a slot'):format(#un));
    if #un == 0 then imgui.TextColored(C.mute, 'Everyone registered has a party, outside heal or standby slot.'); end
    for i, name in ipairs(un) do
        local m = r.roster[name];
        local x0 = imgui.GetCursorPosX();
        imgui.TextColored(C.mute, ('%2d'):format(i));
        imgui.SameLine(x0 + z(24));
        pcall(imgui.AlignTextToFramePadding);
        imgui.TextColored(C.text, name);
        imgui.SameLine(x0 + z(130));
        local full = data.signup_pretty(m.jobs, m.subs, m.gear);
        imgui.TextColored(C.dim, vc.fit_text(full, z(300)));
        tip(full);
        imgui.SameLine(x0 + z(440));
        if vc.button('To standby##un' .. i) then
            if not raid.to_standby(name) then raid.warn('Standby is full: clear a standby slot first.'); end
        end
        tip('Puts ' .. name .. ' in the first open standby slot');
        imgui.SameLine();
        if vc.button('Sit out##uo' .. i) then raid.set_out(name, true); end
        tip('Leaves them off the board (they stay registered: bring them back on Roll Call)');
    end
    vc.note('Put someone in a party or outside heal from that slot\'s member list, or on standby with To standby. Unassigned is posted too.');

end

local buf_saved_find = { '' };
local SRC_LABEL = { addon = 'addon', tell = 'by tell', manual = 'by hand', self = 'you', saved = 'from saved' };
local SEL_OVERLAP = ImGuiSelectableFlags_AllowOverlap or ImGuiSelectableFlags_AllowItemOverlap or 16;

local function add_by_hand()
    imgui.TextColored(C.dim, 'Add by hand:');
    imgui.SameLine(); input('##addn', buf_add_name, 120, 'Name');
    imgui.SameLine(); input('##addj', buf_add_jobs, 240, 'WHM.B/SCH/RDM BLM/WHM');
    imgui.SameLine();
    if vc.button('Add') then
        local jobs, subs, gear = data.parse_signup(buf_add_jobs[1]);
        if raid.get() == nil then
            raid.warn('Start a raid first (Raid Board).');
        elseif raid.cap(buf_add_name[1]) ~= '' and #jobs > 0 then
            raid.register(buf_add_name[1], jobs, 'manual', false, subs, gear);
            buf_add_name[1], buf_add_jobs[1] = '', '';
        else
            raid.warn('Give a name and at least one job.');
        end
    end
    tip('Adds them to this raid (and to the saved sign-ups)');
    -- how to type the jobs (the same format as the !rr tell, from Help)
    imgui.Dummy({ 1, z(2) });
    vc.note('Type each job as JOB.GEAR/SUB/SUB, best job first, with a space between jobs. For example:');
    pcall(imgui.Indent, z(20));
    imgui.TextColored(C.gold, 'WHM.B/SCH/RDM BLM.G/WHM/SCH COR.T/WHM/NIN');
    vc.stat('  WHM.B/SCH/RDM', '1st choice WHM, BIS gear, can sub SCH or RDM', C.text, 170);
    vc.stat('  BLM.G/WHM/SCH', '2nd choice BLM, GOOD gear, can sub WHM or SCH', C.text, 170);
    vc.stat('  COR.T/WHM/NIN', '3rd choice COR, TEMU gear, can sub WHM or NIN', C.text, 170);
    pcall(imgui.Unindent, z(20));
    vc.note('.B = BIS, .G = GOOD, .T = TEMU (leave it off if unsure). Up to 5 subjobs per job. Just jobs is fine too:  WHM BLM COR');
end

--- The saved sign-ups not in this raid: Add to raid (up) or Forget.
local function saved_section(r)
    local saved = raid.saved();
    local find = (buf_saved_find[1] or ''):lower();
    local names, total = {}, 0;
    for name, e in pairs(saved) do
        if not (r and r.roster[name]) then
            total = total + 1;
            local text = (name .. ' ' .. table.concat(e.jobs or {}, ' ')):lower();
            if find == '' or text:find(find, 1, true) then names[#names + 1] = name; end
        end
    end
    table.sort(names);
    vc.section('SAVED SIGN-UPS', ('%d not in this raid  -  kept from earlier sign-ups'):format(total));
    vc.search_box('##savedfind', buf_saved_find, 'Search name or job', 240);
    local x0 = imgui.GetCursorPosX();
    local COLS = { 0, 110, 420, 520, 590 };
    imgui.TextColored(C.mute, 'Name');
    imgui.SameLine(x0 + z(COLS[2])); imgui.TextColored(C.mute, 'Jobs (best first) / subjobs');
    imgui.SameLine(x0 + z(COLS[3])); imgui.TextColored(C.mute, 'Last sign-up');
    fixed_list('##saved', 210, function ()
        local lx = imgui.GetCursorPosX();
        for i, name in ipairs(names) do
            local e = saved[name];
            imgui.SetCursorPosX(lx + z(6));
            pcall(imgui.AlignTextToFramePadding);
            imgui.TextColored(C.text, name);
            imgui.SameLine(lx + z(COLS[2]));
            local full = data.signup_pretty(e.jobs, e.subs, e.gear);
            imgui.TextColored(C.dim, vc.fit_text(full, z(300)));
            tip(full);
            imgui.SameLine(lx + z(COLS[3]));
            imgui.TextColored(C.mute, os.date('%b %d', e.t or 0));
            tip(('Saved %s  (%s)'):format(os.date('%Y-%m-%d %H:%M', e.t or 0), SRC_LABEL[e.src] or e.src or '?'));
            imgui.SameLine(lx + z(COLS[4]));
            if r then
                if arrow_button('up' .. i, 'Add to raid', true, 104) then raid.move_up(name); end
                tip('Brings ' .. name .. ' into this raid with this sign-up');
            else
                imgui.TextColored(C.mute, 'no raid running');
            end
            imgui.SameLine();
            if vc.button('Forget##fg' .. i) then raid.forget(name); end
            tip('Deletes this saved sign-up');
            imgui.Dummy({ 1, z(2) });
        end
        if #names == 0 then
            imgui.TextColored(C.mute, total == 0 and '  Nothing saved yet: sign-ups you get are kept here.' or '  Nothing matches the search.');
        end
    end, true);
end

local function page_roll()
    local r = raid.get();
    vc.title('Roll Call', 'who is in this raid, and who you have heard from before');
    if r == nil then
        start_picker();
        saved_section(nil);
        return;
    end
    raid.save_roster();
    local roll = raid.roll();
    local saved = raid.saved();
    local nreg, nally, missing = 0, 0, 0;
    for _, e in ipairs(roll) do
        if e.reg then nreg = nreg + 1; end
        if e.ally then nally = nally + 1; if not e.reg then missing = missing + 1; end end
    end
    imgui.TextColored(C.dim, ('%d registered  -  %d in alliance  -  '):format(nreg, nally));
    imgui.SameLine(0, 0);
    imgui.TextColored(missing > 0 and C.bad or C.good, ('%d in alliance not registered'):format(missing));
    local older = 0;
    for _, e in ipairs(roll) do
        if e.reg and e.reg.addon and e.reg.ver and not data.ver_at_least(e.reg.ver, data.VERSION) then older = older + 1; end
    end
    if older > 0 then
        imgui.SameLine(0, 0);
        imgui.TextColored(C.gold, ('  -  %d on an older Raid Roles'):format(older));
        tip('They can still sign up, get assignments and confirm. Hover their Registered column for the version.');
    end

    if vc.button('Raid check', 'primary') then raid.poll(); end
    imgui.SameLine();
    if vc.button(('Nudge %d unregistered'):format(missing)) then raid.nudge(); end
    tip('Sends each alliance member who has not registered a tell with how to sign up');

    -- top: this raid (the alliance and everyone registered)
    vc.section('IN THIS RAID', ('%d'):format(#roll));
    local x0 = imgui.GetCursorPosX();
    local COLS = { 0, 110, 420, 510, 590 };
    imgui.TextColored(C.mute, 'Name');
    imgui.SameLine(x0 + z(COLS[2])); imgui.TextColored(C.mute, 'Jobs (best first) / subjobs');
    imgui.SameLine(x0 + z(COLS[3])); imgui.TextColored(C.mute, 'Registered');
    imgui.SameLine(x0 + z(COLS[4])); imgui.TextColored(C.mute, 'In alliance');

    fixed_list('##roll', 230, function ()
        local lx = imgui.GetCursorPosX();
        for i, e in ipairs(roll) do
            local name = e.name;
            local y = imgui.GetCursorPosY();
            if imgui.Selectable('##rc' .. name, sel_roll == name, SEL_OVERLAP, { 0, z(26) }) then sel_roll = name; end
            imgui.SetCursorPosY(y);
            imgui.SetCursorPosX(lx + z(6));
            pcall(imgui.AlignTextToFramePadding);
            local out = e.reg and e.reg.out;
            imgui.TextColored(out and C.mute or C.text, name);
            imgui.SameLine(lx + z(COLS[2]));
            local full = e.reg and data.signup_pretty(e.reg.jobs, e.reg.subs, e.reg.gear) or '-';
            imgui.TextColored(C.dim, vc.fit_text(full, z(300)));
            if e.reg then tip(full); end
            imgui.SameLine(lx + z(COLS[3]));
            if e.reg then
                local older = e.reg.addon and e.reg.ver and not data.ver_at_least(e.reg.ver, data.VERSION);
                local label = out and 'sitting out' or (SRC_LABEL[e.reg.src] or e.reg.src);
                if not out and e.reg.addon and e.reg.ver then label = label .. ' ' .. e.reg.ver; end
                imgui.TextColored(out and C.mute or (older and C.gold or C.good), label);
                if older then
                    tip(('%s runs Raid Roles %s (you have %s). It still works together; they can update when convenient.')
                        :format(name, e.reg.ver, data.VERSION));
                end
            else
                imgui.TextColored(C.bad, 'NOT registered');
            end
            imgui.SameLine(lx + z(COLS[4]));
            if e.ally then imgui.TextColored(C.text, ('%s  pt %d'):format(e.ally.job or '?', e.ally.block));
            else imgui.TextColored(C.mute, 'no'); end
            imgui.SameLine(lx + z(COLS[5]));
            if e.reg and e.reg.src ~= 'self' then
                if arrow_button('dn' .. i, 'Move down', false, 104) then raid.move_down(name); if sel_roll == name then sel_roll = nil; end end
                tip('Takes ' .. name .. ' out of this raid (and its slots). Their sign-up stays in Saved sign-ups.');
            elseif not e.reg and saved[name] then
                if arrow_button('us' .. i, 'Use saved', true, 104) then raid.move_up(name); end
                tip('Signs ' .. name .. ' up with their saved jobs: ' .. data.signup_pretty(saved[name].jobs, saved[name].subs, saved[name].gear));
            end
            imgui.SetCursorPosY(y + z(26));
        end
        if #roll == 0 then imgui.TextColored(C.mute, '  Nobody yet: run a raid check, or add people from Saved sign-ups.'); end
    end, true);

    -- the picked member
    if sel_roll and r.roster[sel_roll] then
        local m = r.roster[sel_roll];
        imgui.TextColored(C.acc, sel_roll);
        imgui.SameLine();
        if vc.button(m.out and 'Bring back' or 'Sit out') then raid.set_out(sel_roll, not m.out); end
        tip('Sitting out keeps them in the raid but off the board');
        imgui.SameLine();
        if vc.button('Tell assignment') then if not raid.tell_assignment(sel_roll) then raid.warn(sel_roll .. ' has no slot.'); end end
    elseif sel_roll then
        imgui.TextColored(C.acc, sel_roll);
        imgui.SameLine();
        if vc.button('Nudge') then raid.nudge({ sel_roll }); end
        imgui.SameLine();
        imgui.TextColored(C.dim, 'or add their jobs below');
        if buf_add_name[1] == '' then buf_add_name[1] = sel_roll; end
    end
    add_by_hand();

    -- bottom: everyone heard from before
    saved_section(r);
end

--------------------------------------------------------------------------------
-- Zerg (leader): 3 bards and 3 corsairs, two songs / two rolls each, rotating P1 > P2 > P3
--------------------------------------------------------------------------------
local buf_zname = { '' };

--- A drop-down list (songs, rolls). Returns the picked entry or nil.
local function pick_list(id, list, cur, w)
    local picked = nil;
    pcall(imgui.PushItemWidth, z(w));
    if imgui.BeginCombo('##' .. id, cur or '') then
        for _, item in ipairs(list) do
            if imgui.Selectable(item .. '##' .. id .. item, item == cur) then picked = item; end
        end
        imgui.EndCombo();
    end
    pcall(imgui.PopItemWidth);
    return picked;
end

--- Who plays a zerg part: people signed up with that job first, then anyone, or a typed name. '' clears.
local function zerg_name_picker(id, cur, job, w)
    local r = raid.get();
    local picked = nil;
    imgui.PushStyleColor(ImGuiCol_Text, cur ~= '' and C.text or C.mute);
    if imgui.Button((cur ~= '' and cur or '(pick)') .. '##zn' .. id, { z(w), 0 }) then
        buf_zname[1] = '';
        imgui.OpenPopup('znp' .. id);
    end
    imgui.PopStyleColor(1);
    tip('Who plays this part');
    if imgui.BeginPopup('znp' .. id) then
        local fit, other = {}, {};
        for name, m in pairs(r and r.roster or {}) do
            local has = false;
            for _, j in ipairs(m.jobs or {}) do if j == job then has = true; end end
            if has then fit[#fit + 1] = name; else other[#other + 1] = name; end
        end
        table.sort(fit); table.sort(other);
        imgui.TextColored(C.teal, ('Signed up with %s'):format(job));
        if #fit == 0 then imgui.TextColored(C.mute, '  nobody'); end
        for _, name in ipairs(fit) do
            local m = r.roster[name];
            local g = data.gear_label(data.gear_of(m, job));
            local subs = data.subs_of(m, job);
            if imgui.Selectable(('%s  -  %s%s%s##zf%s'):format(name, job, g ~= '' and (' ' .. g) or '',
                    #subs > 0 and ('  /' .. table.concat(subs, '/')) or '', id), cur == name) then picked = name; end
        end
        if #other > 0 then
            imgui.Separator();
            imgui.TextColored(C.mute, 'Others signed up');
            for _, name in ipairs(other) do
                if imgui.Selectable(name .. '##zo' .. id, cur == name) then picked = name; end
            end
        end
        imgui.Separator();
        imgui.TextColored(C.mute, 'Or type a name');
        input('##zt' .. id, buf_zname, 140, 'Name');
        imgui.SameLine();
        if vc.button('Set##zs' .. id) and raid.cap(buf_zname[1]) ~= '' then
            picked = raid.cap(buf_zname[1]);
            imgui.CloseCurrentPopup();
        end
        if imgui.Selectable('Clear##zc' .. id) then picked = ''; end
        imgui.EndPopup();
    end
    return picked;
end

local END_OPTS = { { true, 'Stay in P3' }, { false, 'Leave' } };

local function zerg_rows(kind, zg)
    local list = (kind == 'brd') and zg.brd or zg.cor;
    local job = (kind == 'brd') and 'BRD' or 'COR';
    local items = (kind == 'brd') and data.SONGS or data.ROLLS;
    for i, e in ipairs(list) do
        local id = kind .. i;
        local x0 = imgui.GetCursorPosX();
        pcall(imgui.AlignTextToFramePadding);
        imgui.TextColored(C.gold, ('%s %d'):format(job, i));
        imgui.SameLine(x0 + z(54));
        local nn = zerg_name_picker(id, e.name, job, 118);
        if nn ~= nil then e.name = nn; store.save(); end
        imgui.SameLine(x0 + z(180));
        local a = pick_list(id .. 'a', items, e.a, 170);
        if a then e.a = a; store.save(); end
        imgui.SameLine();
        local b = pick_list(id .. 'b', items, e.b, 170);
        if b then e.b = b; store.save(); end
        imgui.SameLine();
        local v = vc.seg('end' .. id, END_OPTS, e.stay);
        if v ~= nil then e.stay = v; store.save(); end
        tip('After party 3: stay in that party, or leave the alliance');
        imgui.SameLine();
        if vc.button('Tell##zt' .. id) then
            if not raid.zerg_tell(kind == 'brd' and 'B' or 'C', i) then raid.warn('Pick who plays it first (and not yourself).'); end
        end
        tip('Tells ' .. (e.name ~= '' and e.name or 'them') .. ' their part');
    end
end

local function team_text(zg, t)
    local b, c = zg.brd[t], zg.cor[t];
    return ('%s / %s'):format(b.name ~= '' and b.name or 'BRD ' .. t, c.name ~= '' and c.name or 'COR ' .. t);
end

local function page_zerg()
    vc.title('Zerg', 'bards and corsairs rotate through the parties');
    local r = raid.get();
    if r == nil then
        vc.note('Start a raid first (Raid Board), then plan the zerg here.');
        start_picker();
        return;
    end
    local zg = raid.zerg();
    if vc.button('Post zerg plan', 'primary') then raid.zerg_post(); end
    tip('Posts the plan to the chat channel (Settings) and tells each bard and corsair their part');
    imgui.SameLine();
    if vc.button('Reset songs and rolls') then raid.zerg_reset(); end
    tip('Back to Minuet x2, Madrigal x2, March x2 and the default rolls (names are kept)');
    vc.note('Bard n and corsair n are team n. Every team starts in party 1, does its 2 songs / 2 rolls, drops, '
        .. 'joins party 2, then party 3, and then stays or leaves. Party leaders keep 2 spots open and invite team 1, then 2, then 3.');

    vc.section('BARDS', '2 songs each');
    zerg_rows('brd', zg);
    vc.section('CORSAIRS', '2 rolls each');
    zerg_rows('cor', zg);

    -- the rotation: step s, team t is in party s - t + 1
    vc.section('ROTATION', 'a team moves on once it has sung / rolled');
    local x0 = imgui.GetCursorPosX();
    local CW = 220;
    imgui.TextColored(C.mute, 'Step');
    for p = 1, data.MAX_PARTIES do imgui.SameLine(x0 + z(60 + (p - 1) * CW)); imgui.TextColored(C.mute, 'Party ' .. p); end
    for s = 1, data.ZERG_STEPS do
        imgui.TextColored(C.dim, tostring(s));
        for p = 1, data.MAX_PARTIES do
            local t = s - p + 1;
            imgui.SameLine(x0 + z(60 + (p - 1) * CW));
            if t >= 1 and t <= data.ZERG_TEAMS then
                imgui.TextColored(C.text, vc.fit_text(('Team %d: %s'):format(t, team_text(zg, t)), z(CW - 12)));
            else
                imgui.TextColored(C.mute, '-');
            end
        end
    end

    vc.section('PARTY LEADERS', 'invite in this order');
    for p = 1, data.MAX_PARTIES do
        imgui.TextColored(C.teal, ('Party %d'):format(p));
        for t = 1, data.ZERG_TEAMS do
            imgui.SameLine();
            imgui.TextColored(t == 1 and C.text or C.dim, ('  %d) Team %d  (%s)'):format(t, t, team_text(zg, t)));
        end
    end
    vc.note('Invite the next team when the one before it drops. Every party ends up with all 6 songs and all 6 rolls.');
    local stays, leaves = {}, {};
    for _, k in ipairs({ 'brd', 'cor' }) do
        for _, e in ipairs(zg[k]) do
            if e.name ~= '' then if e.stay then stays[#stays + 1] = e.name; else leaves[#leaves + 1] = e.name; end end
        end
    end
    if #stays + #leaves > 0 then
        imgui.TextColored(C.dim, ('After party 3:  stay: %s   -   leave: %s'):format(
            #stays > 0 and table.concat(stays, ', ') or 'nobody', #leaves > 0 and table.concat(leaves, ', ') or 'nobody'));
    end
end

--- The zerg part of My Assignment (a member's own part, and the whole plan).
zerg_card = function ()
    local zm = store.me.zerg_mine;
    if zm == nil or #(zm.list or {}) == 0 then return; end
    vc.section('ZERG', 'from ' .. (zm.leader or '?'));
    local e = zm.me;
    if e then
        big(('%s %d  -  %s + %s'):format(e.role, e.n, e.a, e.b), C.gold, 24);
        vc.note(('Start in party 1. %s, then drop and join party 2, then party 3. After party 3: %s.'):format(
            e.role == 'BRD' and 'Sing your 2 songs' or 'Do your 2 rolls', e.stay and 'stay in that party' or 'leave the alliance'));
        local cur = raid.my_job();
        if cur == e.role then imgui.TextColored(C.good, 'You are on ' .. cur .. '.');
        else imgui.TextColored(C.bad, ('You are on %s: change to %s.'):format(cur or '?', e.role)); end
    end
    local by = {};
    for _, x in ipairs(zm.list) do by[x.role .. x.n] = x; end
    for t = 1, data.ZERG_TEAMS do
        local b, c = by['BRD' .. t], by['COR' .. t];
        imgui.TextColored(C.teal, ('Team %d'):format(t));
        imgui.SameLine(z(70));
        local me = raid.my_name();
        imgui.TextColored((b and b.name == me) and C.acc or C.text,
            b and ('BRD %s: %s + %s'):format(b.name, b.a, b.b) or 'BRD -');
        imgui.SameLine(z(420));
        imgui.TextColored((c and c.name == me) and C.acc or C.text,
            c and ('COR %s: %s + %s'):format(c.name, c.a, c.b) or 'COR -');
    end
    imgui.Dummy({ 1, z(6) });
end

local function page_fights()
    vc.title('Fights', 'saved compositions');
    local fights = store.fights;
    if sel_fight > #fights then sel_fight = #fights; end

    vc.section('SAVED FIGHTS', ('%d'):format(#fights));
    fixed_list('##fights', 200, function ()
        if #fights == 0 then imgui.TextColored(C.mute, '  No fights saved: click New.'); end
        for i, f in ipairs(fights) do
            local np = #(f.parties or {});
            if vc.row('##fr' .. i, { no_icon = true, name = f.name, right = ('%d part%s'):format(np, np == 1 and 'y' or 'ies'), selected = sel_fight == i }) then
                sel_fight = i;
            end
        end
    end);

    local f = fights[sel_fight];
    if f == nil then
        if vc.button('New fight') then
            fights[#fights + 1] = { name = 'New fight', notes = '', parties = { { label = 'Party 1', slots = { '', '', '', '', '', '' } } } };
            sel_fight = #fights; store.save_fights();
        end
        return;
    end

    local r = raid.get();
    if vc.button(r and 'Use on the board' or 'Start a raid with it', 'primary') then
        if r then raid.use_fight(f); else raid.start(f, false); end
        win.page = 'board';
    end
    tip('Puts this composition on the Raid Board (registrations are kept)');
    imgui.SameLine();
    if r and vc.button('Save board as this fight') then
        f.parties = {};
        for p = 1, data.MAX_PARTIES do local party = r.comp[p]; f.parties[p] = { label = party.label, slots = store.copy(party.slots) }; end
        if (r.notes or '') ~= '' and (f.notes or '') == '' then f.notes = r.notes; end
        store.save_fights();
        raid.say('Saved the board over ' .. f.name .. '.');
    end
    imgui.SameLine();
    if vc.button('New') then
        local src = r and r.comp or nil;
        local nf = { name = 'New fight', parties = {}, notes = '' };
        if src then for p = 1, data.MAX_PARTIES do local party = src[p]; nf.parties[p] = { label = party.label, slots = store.copy(party.slots) }; end
        else nf.parties[1] = { label = 'Party 1', slots = { '', '', '', '', '', '' } }; end
        fights[#fights + 1] = nf;
        sel_fight = #fights; store.save_fights();
    end
    tip('A new fight (a copy of the board, if a raid is running)');
    imgui.SameLine();
    if vc.button('Delete', 'danger') then
        table.remove(fights, sel_fight);
        sel_fight = math.max(1, sel_fight - 1);
        store.save_fights();
        return;
    end

    vc.section('EDIT  ' .. f.name:upper());
    if buf_fight_name.idx ~= sel_fight then buf_fight_name[1] = f.name; buf_fight_name.idx = sel_fight; end
    imgui.TextColored(C.dim, 'Name'); imgui.SameLine(z(70));
    if input('##fname', buf_fight_name, 260) then
        local n = raid.clean(buf_fight_name[1], 40);
        if n ~= '' then f.name = n; store.save_fights(); end
    end
    for p, party in ipairs(f.parties) do
        party.slots = party.slots or {};
        local lb = { party.label or '' };
        imgui.TextColored(C.mute, 'P' .. p); imgui.SameLine(z(30));
        if input('##pl' .. p, lb, 120) then party.label = raid.clean(lb[1], 20); store.save_fights(); end
        for s = 1, data.SLOTS do
            imgui.SameLine();
            local nr = req_picker('f' .. p .. '_' .. s, data.norm_req(party.slots[s]), 74);
            if nr ~= nil then party.slots[s] = nr; store.save_fights(); end
        end
    end
    if #f.parties < data.MAX_PARTIES and vc.button('Add party##f') then
        f.parties[#f.parties + 1] = { label = 'Party ' .. (#f.parties + 1), slots = { '', '', '', '', '', '' } };
        store.save_fights();
    end
    if #f.parties > 1 then
        if #f.parties < data.MAX_PARTIES then imgui.SameLine(); end
        if vc.button('Remove last party##f') then f.parties[#f.parties] = nil; store.save_fights(); end
    end

    vc.section('COMMENTS', 'saved with the fight');
    if buf_notes.idx ~= sel_fight then buf_notes[1] = f.notes or ''; buf_notes.idx = sel_fight; end
    if multiline('##fnotes', buf_notes, 120, 2048) then f.notes = buf_notes[1]; store.save_fights(); end
    vc.note('Strategy, gear, who pulls, what to bring. Shown on the Raid Board while this fight is used.');
end

--------------------------------------------------------------------------------
-- Settings and help
--------------------------------------------------------------------------------
local function page_settings()
    local cfg = store.me.cfg;
    vc.title('Settings');
    local changed = false;

    vc.section('LEADER');
    vc.label_row('Send raid checks and assignments to', 250);
    local v = vc.seg('chan', { { 'p', 'Party/Alliance' }, { 'l', 'Linkshell' }, { 'l2', 'Linkshell 2' } }, cfg.channel);
    if v then cfg.channel = v; changed = true; end
    vc.label_row('Also tell each member their assignment', 250);
    v = vc.seg('tells', { { 'off', 'Off' }, { 'nonaddon', 'No-addon only' }, { 'all', 'Everyone' } }, cfg.tells);
    if v then cfg.tells = v; changed = true; end
    vc.label_row('Seconds between lines sent', 200);
    v = vc.slider('delay', cfg.delay, 1.5, 6.0, 0.5, '%.1f s', 150);
    if v then cfg.delay = v; changed = true; end
    v = vc.switch_row('bot', 'Answer "!rr" tells (players without the addon)', cfg.bot);
    if v ~= nil then cfg.bot = v; changed = true; end
    vc.note('Party chat reaches the whole alliance once it is formed. Before that, use a linkshell the raid shares; members answer by tell either way.');

    vc.section('MEMBER');
    vc.label_row('When a leader runs a raid check', 250);
    v = vc.seg('reply', { { 'ask', 'Ask me' }, { 'auto', 'Send my jobs' }, { 'off', 'Ignore' } }, cfg.poll_reply);
    if v then cfg.poll_reply = v; changed = true; end
    v = vc.switch_row('popup', 'Pop up my assignment when it arrives', cfg.popup);
    if v ~= nil then cfg.popup = v; changed = true; end
    v = vc.switch_row('join', 'On joining an alliance, ask me to check my jobs', cfg.check_join);
    if v ~= nil then cfg.check_join = v; changed = true; end

    vc.section('CHAT');
    v = vc.switch_row('hide', "Hide the addon's own tells from the chat log", cfg.hide_proto);
    if v ~= nil then cfg.hide_proto = v; changed = true; end

    if changed then store.save(); end
end

local function page_help()
    vc.title('Raid Roles', 'help');
    vc.section('MEMBERS');
    vc.note('1. My Jobs: pick your main jobs, best first. For each one rate your gear (BIS, GOOD, TEMU) and pick up to 5 subjobs. Saved for this character.');
    vc.note('2. When your leader runs a raid check, confirm your jobs (or let Settings send them automatically).');
    vc.note('3. Your party and job arrive on My Assignment and in a pop-up. Click Got it so the leader sees you are ready.');
    vc.section('LEADERS');
    vc.note('1. Fights: pick or build a composition (up to 3 parties of 6; slots take a job or a role such as Tank).');
    vc.note('2. Raid Board: Raid check ALL asks everyone for their jobs. Raid check: Not Received / Not Confirmed asks only who is missing: before the post, alliance members who have not sent their jobs; after it, whoever did not get their assignment (offline, zoning) or has not confirmed it.');
    vc.note('3. Auto assign fills the board as answers come in (best gear, then their preference, then the slot\'s subjob); Manual lets you place each member. Lock a slot to keep it. Everyone left over is on Standby.');
    vc.note('4. Post assignments puts every party in chat and tells the members (Settings).');
    vc.section('WITHOUT THE ADDON');
    vc.note('Players without the addon sign up by sending the leader a tell. Each job is written JOB.GEAR/SUB/SUB, best job first, with a space between jobs. For example they would type:');
    local leader = (raid.get() and raid.my_name()) or 'Leadername';
    local example = { ('/tell %s !rr WHM.B/SCH/RDM BLM.G/WHM/SCH COR.T/WHM/NIN'):format(leader) };
    imgui.Dummy({ 1, z(2) });
    imgui.PushStyleColor(ImGuiCol_Text, C.gold);
    local ok = pcall(imgui.InputText, '##example', example, 128, ImGuiInputTextFlags_ReadOnly or 16384);
    if not ok then imgui.Text(example[1]); end
    imgui.PopStyleColor(1);
    tip('Select and Ctrl+C to copy it for someone');
    imgui.Dummy({ 1, z(2) });
    imgui.TextColored(C.dim, 'Which means:');
    vc.stat('  WHM.B/SCH/RDM', '1st choice WHM, BIS gear, can sub SCH or RDM', C.text, 170);
    vc.stat('  BLM.G/WHM/SCH', '2nd choice BLM, GOOD gear, can sub WHM or SCH', C.text, 170);
    vc.stat('  COR.T/WHM/NIN', '3rd choice COR, TEMU gear, can sub WHM or NIN', C.text, 170);
    imgui.Dummy({ 1, z(2) });
    vc.note('.B = BIS, .G = GOOD, .T = TEMU (leave it off if unsure). Up to 5 subjobs per job. Leaving out the subjobs is fine too:  !rr WHM BLM COR');
    vc.stat('  !rr', 'what is my assignment? (party, job and subjob, or standby number)', C.text, 170);
    vc.stat('  !rr help', 'the leader replies with how to sign up', C.text, 170);
    vc.note('Sending a new !rr sign-up replaces the old one. The leader\'s addon answers automatically, by tell. '
        .. 'All of these also work typed in party chat (e.g. "!rr help"), and !RR in capitals works too.');
    vc.section('COMMANDS');
    for _, c in ipairs({
        { '/roles', 'open or close this window' },
        { '/roles jobs WHM.B/SCH BLM/WHM', 'set your jobs, gear and subjobs' },
        { '/roles reply', 'send your jobs for the last raid check' },
        { '/roles me', 'show your assignment' },
        { '/roles fight <name>', 'leader: start a raid with a saved fight' },
        { '/roles check | auto | post | nudge', 'leader: raid check, auto-fill, post, nudge' },
        { '/roles add <name> <jobs>', 'leader: register someone by hand' },
    }) do vc.stat(c[1], c[2], C.dim, 230); end
end

--------------------------------------------------------------------------------
-- The pop-ups
--------------------------------------------------------------------------------
local function page_prompt()
    local p = raid.pending;
    if p == nil then pwin.open[1] = false; return; end
    if p.join then
        vc.title('You joined an alliance');
        imgui.TextColored(C.dim, 'Are these still the jobs you can play?');
    else
        vc.title('Raid check');
        imgui.TextColored(C.text, ('%s is gathering jobs for %s.'):format(p.leader or '?', p.fight or 'a raid'));
    end
    imgui.Dummy({ 1, z(4) });
    local jobs = store.me.jobs;
    if #jobs == 0 then
        imgui.TextColored(C.bad, 'You have no jobs saved yet.');
    else
        for i, j in ipairs(jobs) do
            chip(('%d  %s'):format(i, j), i == 1 and C.on or C.seg);
            local g = data.gear_label(store.me.gear[j]);
            if g ~= '' then imgui.SameLine(); imgui.TextColored(C.gold, g); end
            local subs = store.me.subs[j] or {};
            for _, sj in ipairs(subs) do imgui.SameLine(); chip('/' .. sj, vc.alpha(C.teal, 0.45)); end
            if #subs == 0 then imgui.SameLine(); imgui.TextColored(C.mute, 'no subjobs picked'); end
        end
    end
    imgui.Dummy({ 1, z(8) });
    local can_send = #jobs > 0 and p.leader ~= nil and p.id ~= nil;
    if can_send then
        if vc.button(p.join and 'Looks good - send to ' .. p.leader or 'Send these', 'primary') then raid.reply(p); pwin.open[1] = false; end
        imgui.SameLine();
    elseif p.join and #jobs > 0 then
        if vc.button('Looks good', 'primary') then raid.pending = nil; pwin.open[1] = false; end
        imgui.SameLine();
    end
    if vc.button('Edit my jobs') then win.open[1] = true; win.page = 'jobs'; pwin.open[1] = false; end
    imgui.SameLine();
    if vc.button('Not now') then raid.pending = nil; pwin.open[1] = false; end
end

local function page_banner()
    local m = raid.mine();
    local head, has_job = nil, false;
    if m then head, has_job = my_role(m); end
    if head == nil then awin.open[1] = false; return; end
    imgui.TextColored(C.dim, ('%s  -  from %s'):format(m.fight or 'Raid', m.leader or '?'));
    big(head:sub(1, 1) .. head:sub(2):lower(), has_job and C.text or C.mute, 26);
    if has_job then
        imgui.SameLine();
        big(m.job or '?', C.gold, 26);
        if (m.sub or '') ~= '' then imgui.SameLine(); big('/ ' .. m.sub, C.teal, 26); end
        if m.standby then imgui.TextColored(C.dim, 'Stay ready: the leader will call you in if a slot opens.');
        elseif m.party == data.OH then imgui.TextColored(C.dim, 'Heal from outside the alliance: do not join a party.');
        elseif m.label and m.label ~= '' then imgui.TextColored(C.teal, m.label); end
        local cur, cur_sub = raid.my_job(), raid.my_sub();
        local now = data.job_sub(cur or '?', cur_sub);
        if cur == m.job and ((m.sub or '') == '' or cur_sub == m.sub) then imgui.TextColored(C.good, 'You are already on ' .. now .. '.');
        else imgui.TextColored(C.bad, ('Change job: you are on %s.'):format(now)); end
    else
        imgui.TextColored(C.dim, 'You are registered but have no role yet.');
    end
    imgui.Dummy({ 1, z(6) });
    if not m.acked then
        if vc.button('Got it', 'primary') then raid.ack(); awin.open[1] = false; end
        imgui.SameLine();
    end
    if vc.button('Whole raid') then win.open[1] = true; win.page = 'mine'; awin.open[1] = false; end
    imgui.SameLine();
    if vc.button('Close') then awin.open[1] = false; end
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------
local PAGES = {
    jobs = page_jobs, mine = page_mine,
    board = page_board, roll = page_roll, fights = page_fights, zerg = page_zerg,
    settings = page_settings, help = page_help,
};
local SUB = {
    jobs = 'My Jobs', mine = 'My Assignment', board = 'Raid Board', roll = 'Roll Call',
    fights = 'Fights', zerg = 'Zerg', settings = 'Settings', help = 'Help',
};

local function sidebar(nav)
    nav.caption('MEMBER');
    if nav.head('star', 'My Jobs', win.page == 'jobs') then win.page = 'jobs'; end
    nav.tip('Pick the jobs you can play');
    if nav.head('equip', 'My Assignment', win.page == 'mine') then win.page = 'mine'; end
    nav.caption('LEADER');
    if nav.head('widget', 'Raid Board', win.page == 'board') then win.page = 'board'; end
    if nav.head('list', 'Roll Call', win.page == 'roll') then win.page = 'roll'; end
    if nav.head('files', 'Fights', win.page == 'fights') then win.page = 'fights'; end
    if nav.head('spark', 'Zerg', win.page == 'zerg') then win.page = 'zerg'; end
    nav.tip('Bard and corsair rotation through the parties');
    nav.gap(8);
    if nav.head('gear', 'Settings', win.page == 'settings') then win.page = 'settings'; end
    if nav.head('about', 'Help', win.page == 'help') then win.page = 'help'; end
end

function ui.init()
    local s = tonumber(store.me.cfg.ui_scale) or 1;
    win.scale, pwin.scale, awin.scale = s, s, s;
    raid.events.on_poll = function () pwin.open[1] = true; end
    raid.events.on_assigned = function ()
        if store.me.cfg.popup then awin.open[1] = true; end
    end
    raid.events.on_zerg = function ()
        if store.me.cfg.popup then win.open[1] = true; win.page = 'mine'; end
    end
end

function ui.toggle(page)
    if page then win.page = page; win.open[1] = true; return; end
    win.open[1] = not win.open[1];
end

function ui.show_banner() awin.open[1] = true; end
function ui.show_prompt() pwin.open[1] = true; end

function ui.render()
    if store.me == nil then return; end
    vc.window(win, {
        id = 'raidroles', title = 'Raid Roles', size = { 1060, 680 }, min = { 900, 460 },
        pages = PAGES, scaler = true, on_scale = save_scale,
        subtitle = function (page) return SUB[page]; end,
        header_right = function ()
            local r = raid.get();
            if r then return ('Raid %s  -  %s'):format(r.id, r.fight), C.gold; end
            return '', nil;
        end,
        sidebar = sidebar,
    });
    vc.window(pwin, {
        id = 'raidroles_prompt', title = 'Raid Roles', size = { 520, 320 }, min = { 420, 220 },
        pages = { main = page_prompt }, subtitle = function () return 'Raid check'; end,
    });
    vc.window(awin, {
        id = 'raidroles_assign', title = 'Raid Roles', size = { 400, 230 }, min = { 340, 200 },
        pages = { main = page_banner }, subtitle = function () return 'Your assignment'; end,
    });
end

return ui;
