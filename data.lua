--[[
raidroles - static data and the small rules shared by everything else:
jobs, roles, slot requirements (PLD/WAR), sign-ups (jobs, subjobs, gear) and the fights that ship.
--]]

local data = {};

-- This copy's version (also addon.version). Members send it with their sign-up and confirmation,
-- so the leader can see who runs an older copy and fall back for them (see raid.lua: compatibility).
data.VERSION = '1.2.0';

--- Is version string `v` ('1.2.0') at least `want`? A missing version (copies before 1.1.0 did
--- not send one) counts as '1.0.0'.
function data.ver_at_least(v, want)
    local a = { tostring(v or '1.0.0'):match('^(%d+)%.?(%d*)%.?(%d*)') };
    local b = { tostring(want):match('^(%d+)%.?(%d*)%.?(%d*)') };
    for i = 1, 3 do
        local x, y = tonumber(a[i]) or 0, tonumber(b[i]) or 0;
        if x ~= y then return x > y; end
    end
    return true;
end

-- Job abbreviations in the game's id order (index = job id).
data.JOBS = {
    'WAR', 'MNK', 'WHM', 'BLM', 'RDM', 'THF', 'PLD', 'DRK', 'BST', 'BRD', 'RNG',
    'SAM', 'NIN', 'DRG', 'SMN', 'BLU', 'COR', 'PUP', 'DNC', 'SCH', 'GEO', 'RUN',
};

data.JOB_ID = {};
for i, j in ipairs(data.JOBS) do data.JOB_ID[j] = i; end

-- Role groups: a composition slot can ask for a role instead of one job.
data.ROLES = {
    { id = 'TANK',    label = 'Tank',     jobs = { 'PLD', 'RUN', 'NIN' } },
    { id = 'HEALER',  label = 'Healer',   jobs = { 'WHM', 'SCH', 'RDM' } },
    { id = 'SUPPORT', label = 'Support',  jobs = { 'BRD', 'COR', 'GEO', 'RDM' } },
    { id = 'MELEE',   label = 'Melee',    jobs = { 'WAR', 'MNK', 'THF', 'DRK', 'BST', 'SAM', 'DRG', 'DNC', 'BLU', 'PUP', 'NIN', 'RUN' } },
    { id = 'RANGED',  label = 'Ranged',   jobs = { 'RNG', 'COR' } },
    { id = 'NUKER',   label = 'Nuker',    jobs = { 'BLM', 'SCH', 'GEO', 'RDM', 'SMN' } },
    { id = 'ANY',     label = 'Any job',  jobs = nil },   -- nil = every job
};
data.ROLE = {};
for _, r in ipairs(data.ROLES) do data.ROLE[r.id] = r; end

-- Groups for the member page's quick-select buttons.
data.JOB_GROUPS = {
    { 'Tanks',   { 'PLD', 'RUN', 'NIN' } },
    { 'Healers', { 'WHM', 'SCH' } },
    { 'Support', { 'BRD', 'COR', 'GEO', 'RDM' } },
    { 'Melee',   { 'WAR', 'MNK', 'THF', 'DRK', 'SAM', 'DRG', 'DNC', 'BLU', 'PUP', 'BST' } },
    { 'Magic',   { 'BLM', 'SCH', 'GEO', 'SMN', 'RDM' } },
};

-- Gear ratings a member gives each job: the letter travels in chat, the label is shown.
data.GEAR = {
    { id = 'B', label = 'BIS',  cost = 0 },
    { id = 'G', label = 'GOOD', cost = 1 },
    { id = 'T', label = 'TEMU', cost = 2 },
};
data.GEAR_BY = {};
for _, g in ipairs(data.GEAR) do data.GEAR_BY[g.id] = g; end
function data.gear_label(id) local g = data.GEAR_BY[id or '']; return g and g.label or ''; end
function data.gear_cost(id) local g = data.GEAR_BY[id or '']; return g and g.cost or 1; end   -- unrated = GOOD

data.MAX_PARTIES = 3;
data.SB = data.MAX_PARTIES + 1;   -- the standby party's number on the board
data.OH = data.MAX_PARTIES + 2;   -- the outside heal party's number (healers outside the alliance)
data.LAST = data.OH;
data.SB_SLOTS = 12;               -- standby holds two lists of 6 (1-6 and 7-12)

--- How many slots a board section has.
function data.nslots(p) return (p == data.SB) and data.SB_SLOTS or data.SLOTS; end
data.SLOTS = 6;
data.MAX_SUBS = 5;

--------------------------------------------------------------------------------
-- Slot requirements: 'MAIN' or 'MAIN/SUB'; MAIN a job or role id, SUB a job.
--------------------------------------------------------------------------------
function data.split_req(req)
    req = tostring(req or '');
    local main, sub = req:match('^([^/]*)/?(.*)$');
    return main or '', sub or '';
end

--- Normalises a requirement ('pld/war' -> 'PLD/WAR', 'tank' -> 'TANK', '' for an unused slot).
function data.norm_req(s)
    s = tostring(s or ''):upper():gsub('%s', '');
    if s == '' or s == '-' then return ''; end
    local main, sub = data.split_req(s);
    if not (data.JOB_ID[main] or data.ROLE[main]) then return ''; end
    if data.JOB_ID[sub] and sub ~= main then return main .. '/' .. sub; end
    return main;
end

--- The requirement's display label ('PLD/WAR', 'Tank', 'Tank/WAR').
function data.req_label(req)
    if req == nil or req == '' then return '-'; end
    local main, sub = data.split_req(req);
    local r = data.ROLE[main];
    local label = (r and not data.JOB_ID[main]) and r.label or main;
    if sub ~= '' then label = label .. '/' .. sub; end
    return label;
end

--- True when `job` satisfies the requirement's main job / role.
function data.job_fits(req, job)
    if req == nil or req == '' or job == nil then return false; end
    local main = data.split_req(req);
    if main == job then return true; end
    local r = data.ROLE[main];
    if r == nil then return false; end
    if r.jobs == nil then return data.JOB_ID[job] ~= nil; end
    for _, j in ipairs(r.jobs) do if j == job then return true; end end
    return false;
end

--- A member's best job for a requirement: job, rank (1 = first choice), or nil.
function data.best_job(req, jobs)
    for rank, j in ipairs(jobs or {}) do
        if data.job_fits(req, j) then return j, rank; end
    end
    return nil;
end

--- Parses a list of jobs out of free text ('whm, blm rdm brd') -> { 'WHM', 'BLM', ... } (no duplicates).
function data.parse_jobs(text)
    local out, seen = {}, {};
    for w in tostring(text or ''):upper():gmatch('%a+') do
        if data.JOB_ID[w] and not seen[w] then
            seen[w] = true;
            out[#out + 1] = w;
        end
    end
    return out;
end

--------------------------------------------------------------------------------
-- Members: jobs (best first), subs (job -> up to 5 subjobs), gear (job -> 'B' | 'G' | 'T')
--------------------------------------------------------------------------------
--- The subjobs a member listed for `job`. An older list (the same subjobs for every job) still works.
function data.subs_of(m, job)
    local subs = m and m.subs;
    if type(subs) ~= 'table' then return {}; end
    if subs[1] ~= nil then return subs; end
    return subs[job] or {};
end

function data.has_sub(m, job, sub)
    for _, s in ipairs(data.subs_of(m, job)) do if s == sub then return true; end end
    return false;
end

function data.gear_of(m, job)
    return (m and type(m.gear) == 'table' and m.gear[job]) or '';
end

--- The subjob to use on `job` in a slot: the slot's own subjob if it names one, else the member's
--- first subjob for that job, else ''.
function data.pick_sub(m, job, want)
    if want and want ~= '' then return want; end
    for _, s in ipairs(data.subs_of(m, job)) do if s ~= job then return s; end end
    return '';
end

--- Parses a sign-up -> jobs, subs, gear.
---   'WHM.B/SCH/RDM BLM/WHM PLD.T'   each job (.B .G .T = BIS, GOOD, TEMU), then its subjobs after slashes
---   'WHM BLM RDM sub SCH RDM'       the older form: the same subjobs for every job
function data.parse_signup(text)
    text = tostring(text or '');
    local jobs, subs, gear, seen = {}, {}, {}, {};
    local s, e = text:lower():find('%f[%a]subs?%f[%A]');
    if s then
        local common = data.parse_jobs(text:sub(e + 1));
        for _, j in ipairs(data.parse_jobs(text:sub(1, s - 1))) do
            jobs[#jobs + 1] = j;
            local l = {};
            for _, sj in ipairs(common) do if sj ~= j and #l < data.MAX_SUBS then l[#l + 1] = sj; end end
            subs[j] = l;
        end
        return jobs, subs, gear;
    end
    for tok in text:upper():gmatch('[%a/%.]+') do
        local parts = {};
        for w in tok:gmatch('[%a%.]+') do parts[#parts + 1] = w; end
        local main, g = (parts[1] or ''):match('^(%a+)%.?(%a?)$');
        if main and data.JOB_ID[main] and not seen[main] then
            seen[main] = true;
            jobs[#jobs + 1] = main;
            if data.GEAR_BY[g] then gear[main] = g; end
            local l, ls = {}, {};
            for i = 2, #parts do
                local sj = parts[i]:gsub('%.', '');
                if data.JOB_ID[sj] and sj ~= main and not ls[sj] and #l < data.MAX_SUBS then ls[sj] = true; l[#l + 1] = sj; end
            end
            subs[main] = l;
        end
    end
    return jobs, subs, gear;
end

local function token(job, subs, gear)
    local t = job;
    local g = gear and gear[job];
    if g and g ~= '' then t = t .. '.' .. g; end
    local l = (subs and subs[1] == nil and subs[job]) or {};
    if #l > 0 then t = t .. '/' .. table.concat(l, '/'); end
    return t;
end

--- 'WHM.B/SCH/RDM BLM/WHM PLD.T' (what goes in chat)
function data.signup_text(jobs, subs, gear)
    local t = {};
    for i, j in ipairs(jobs or {}) do t[i] = token(j, subs, gear); end
    return table.concat(t, ' ');
end

--- The sign-up cut into pieces of at most `max` characters (for chat lines).
function data.signup_chunks(jobs, subs, gear, max)
    local out, cur = {}, '';
    for _, j in ipairs(jobs or {}) do
        local tk = token(j, subs, gear);
        if cur ~= '' and #cur + 1 + #tk > (max or 90) then out[#out + 1] = cur; cur = ''; end
        cur = (cur == '') and tk or (cur .. ' ' .. tk);
    end
    if cur ~= '' or #out == 0 then out[#out + 1] = cur; end
    return out;
end

--- A sign-up for people to read: 'WHM (BIS) /SCH/RDM, BLM /WHM'
function data.signup_pretty(jobs, subs, gear)
    local t = {};
    for i, j in ipairs(jobs or {}) do
        local s = j;
        local g = gear and gear[j];
        if g and g ~= '' then s = s .. ' ' .. data.gear_label(g); end
        local l = (subs and (subs[1] ~= nil and subs or subs[j])) or {};
        if #l > 0 then s = s .. ' /' .. table.concat(l, '/'); end
        t[i] = s;
    end
    return table.concat(t, ',  ');
end

--- 'WHM/SCH' or 'WHM'.
function data.job_sub(job, sub)
    if job == nil or job == '' then return ''; end
    if sub == nil or sub == '' then return job; end
    return job .. '/' .. sub;
end

--------------------------------------------------------------------------------
-- The fights that ship with the addon. They are added to the saved fights once (the leader can
-- change or delete them after); raising DEFAULTS_VERSION adds any new ones (by name).
--------------------------------------------------------------------------------
local function TANK()   return { label = 'Tank Party', slots = { 'PLD/WAR', 'WHM/SCH', 'COR/WHM', 'RDM/WHM', 'BRD/WHM', 'GEO/WHM' } }; end
local function BLM_PT() return { label = 'BLM DPS',    slots = { 'BLM/WHM', 'BLM/WHM', 'BLM/WHM', 'SCH/WHM', 'COR/WHM', 'BRD/WHM' } }; end
local function RNG_PT() return { label = 'Ranged DPS', slots = { 'RNG/DRG', 'RNG/DRG', 'BLM/WHM', 'WHM/SCH', 'COR/NIN', 'BRD/WHM' } }; end

data.DEFAULTS_VERSION = 2;
data.DEFAULT_FIGHTS = {
    {
        name = 'Standard Melee Alliance', notes = '',
        parties = {
            TANK(),
            { label = 'Melee DPS', slots = { 'BLU/WAR', 'BLU/WAR', 'COR/WHM', 'BRD/WHM', 'SAM/WAR', 'WHM/SCH' } },
            { label = 'Melee DPS', slots = { 'WAR/SAM', 'THF/WAR', 'DNC/WAR', 'COR/WHM', 'BRD/WHM', 'WHM/SCH' } },
        },
    },
    { name = 'Standard Magic MB Alliance',  notes = '', parties = { TANK(), BLM_PT(), BLM_PT() } },
    { name = 'Standard Ranged MB Alliance', notes = '', parties = { TANK(), RNG_PT(), RNG_PT() } },
    { name = 'Standard Hybrid Ranged/MB Alliance', notes = '', parties = { TANK(), RNG_PT(), BLM_PT() } },
};

--------------------------------------------------------------------------------
-- Zerg: 3 bards and 3 corsairs rotate through the parties, two songs / two rolls each.
--------------------------------------------------------------------------------
data.SONGS = {
    'Valor Minuet V', 'Valor Minuet IV', 'Valor Minuet III', 'Valor Minuet II', 'Valor Minuet',
    'Blade Madrigal', 'Sword Madrigal',
    'Honor March', 'Victory March', 'Advancing March',
    "Mage's Ballad III", "Mage's Ballad II", "Mage's Ballad",
    "Army's Paeon VI", "Army's Paeon V", "Army's Paeon IV",
    "Knight's Minne V", "Knight's Minne IV", "Knight's Minne III",
    "Archer's Prelude", "Hunter's Prelude",
    'Sinewy Etude', 'Dextrous Etude', 'Vivacious Etude', 'Quick Etude', 'Learned Etude', 'Spirited Etude', 'Enchanting Etude',
    'Herculean Etude', 'Uncanny Etude', 'Vital Etude', 'Swift Etude', 'Sage Etude', 'Logical Etude', 'Bewitching Etude',
    'Fire Carol', 'Ice Carol', 'Wind Carol', 'Earth Carol', 'Lightning Carol', 'Water Carol', 'Light Carol', 'Dark Carol',
    'Sheepfoe Mambo', 'Dragonfoe Mambo', 'Chocobo Mazurka', 'Raptor Mazurka', "Goddess's Hymnus", 'Fowl Aubade',
    'Herb Pastoral', 'Shining Fantasia', 'Gold Capriccio', 'Warding Round', "Scop's Operetta", "Puppet's Operetta",
    'Sentinel\'s Scherzo', 'Foe Sirvente', "Adventurer's Dirge",
};

data.ROLLS = {
    "Chaos Roll", "Samurai Roll", "Fighter's Roll", "Hunter's Roll", "Rogue's Roll", "Wizard's Roll", "Warlock's Roll",
    "Evoker's Roll", "Healer's Roll", "Monk's Roll", "Gallant's Roll", "Beast Roll", "Choral Roll", "Ninja Roll",
    "Drachen Roll", "Magus's Roll", "Corsair's Roll", "Puppet Roll", "Dancer's Roll", "Scholar's Roll", "Bolter's Roll",
    "Caster's Roll", "Courser's Roll", "Blitzer's Roll", "Tactician's Roll", "Allies' Roll", "Miser's Roll",
    "Companion's Roll", "Avenger's Roll", "Naturalist's Roll", "Runeist's Roll",
};

-- The usual plan: bard 1 Minuet x2, bard 2 Madrigal x2, bard 3 March x2.
data.ZERG_DEFAULT = {
    brd = {
        { 'Valor Minuet IV', 'Valor Minuet III' },
        { 'Blade Madrigal',  'Sword Madrigal' },
        { 'Victory March',   'Advancing March' },
    },
    cor = {
        { 'Chaos Roll',    'Samurai Roll' },
        { "Fighter's Roll", "Hunter's Roll" },
        { "Rogue's Roll",  "Wizard's Roll" },
    },
};
data.ZERG_TEAMS = 3;        -- bard n and corsair n move together as team n
data.ZERG_STEPS = 5;        -- team t is in party (step - t + 1): step 1 = team 1 in P1 ... step 5 = team 3 in P3

--- Where team t is at step s: the party number, or nil (not started / done).
function data.zerg_party(s, t)
    local p = s - t + 1;
    if p >= 1 and p <= data.MAX_PARTIES then return p; end
    return nil;
end

return data;
