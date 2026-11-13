--[[
raidroles - saving and loading.

    config/addons/raidroles/fights.json        the leader's saved fights (shared by every character)
    config/addons/raidroles/<Character>.json   that character's jobs, settings, raid session and assignment
--]]

require('common');
local json = require('json');
local data = require('data');

local store = {};

local function dir()
    return ('%s\\config\\addons\\raidroles\\'):format(AshitaCore:GetInstallPath());
end

local function read_json(path)
    local f = io.open(path, 'rb');
    if f == nil then return nil; end
    local s = f:read('*a');
    f:close();
    local ok, v = pcall(json.decode, s);
    if ok and type(v) == 'table' then return v; end
    print(('[raidroles] Could not read %s - starting fresh.'):format(path));
    return nil;
end

local function write_json(path, v)
    local ok, s = pcall(json.encode, v);
    if not ok then
        print('[raidroles] Could not save: ' .. tostring(s));
        return false;
    end
    local f = io.open(path, 'wb');
    if f == nil then return false; end
    f:write(s);
    f:close();
    return true;
end

local function deep_copy(t)
    if type(t) ~= 'table' then return t; end
    local o = {};
    for k, v in pairs(t) do o[k] = deep_copy(v); end
    return o;
end
store.copy = deep_copy;

-- Fills missing keys of `t` from `defaults` (recursively for tables).
local function merge(t, defaults)
    for k, v in pairs(defaults) do
        if t[k] == nil then
            t[k] = deep_copy(v);
        elseif type(v) == 'table' and type(t[k]) == 'table' and #v == 0 and next(v) ~= nil then
            merge(t[k], v);
        end
    end
    return t;
end

store.DEFAULT_CFG = {
    channel     = 'p',          -- where raid checks and assignments go: 'p' party/alliance, 'l' linkshell, 'l2' linkshell 2
    tells       = 'nonaddon',   -- also tell each member their assignment: 'off', 'nonaddon', 'all'
    delay       = 2.5,          -- seconds between lines the addon sends (chat spam filter)
    poll_reply  = 'ask',        -- on a raid check: 'ask' (show a confirm window), 'auto' (reply), 'off'
    popup       = true,         -- show the assignment window when an assignment arrives
    check_join  = true,         -- on joining an alliance, ask to check your jobs
    hide_proto  = true,         -- hide the addon's own tells ([RR:REG], [RR:ACK]) from the chat log
    bot         = true,         -- leader: answer '!rr' tells from players without the addon
    ui_scale    = 1,
};

store.char = nil;      -- the character this was loaded for
store.fights = nil;    -- { { name, parties = { { label, slots = { 6 reqs } } } } }
store.me = nil;        -- per character: { cfg, jobs, subs = { job = { subjobs } }, gear = { job = 'B'|'G'|'T' }, raid, mine }

function store.ensure_dir()
    local d = dir();
    if not ashita.fs.exists(d) then ashita.fs.create_dir(d); end
end

function store.load_fights()
    store.ensure_dir();
    local f = read_json(dir() .. 'fights.json');
    if type(f) ~= 'table' then f = {}; end
    store.fights = f;
    -- the fights that ship: added once per DEFAULTS_VERSION (by name), so deleting one sticks
    local meta = read_json(dir() .. 'meta.json') or {};
    if (tonumber(meta.defaults) or 0) < data.DEFAULTS_VERSION or #f == 0 then
        local have = {};
        for _, x in ipairs(f) do have[x.name or ''] = true; end
        for _, d in ipairs(data.DEFAULT_FIGHTS) do
            if not have[d.name] then f[#f + 1] = deep_copy(d); end
        end
        meta.defaults = data.DEFAULTS_VERSION;
        write_json(dir() .. 'meta.json', meta);
        store.save_fights();
    end
end

function store.save_fights()
    store.ensure_dir();
    write_json(dir() .. 'fights.json', store.fights);
end

--- Loads the per-character file. Returns true once a character is known.
function store.load_char(name)
    if name == nil or name == '' then return false; end
    store.ensure_dir();
    local me = read_json(dir() .. name .. '.json') or {};
    me.cfg  = merge(type(me.cfg) == 'table' and me.cfg or {}, store.DEFAULT_CFG);
    me.jobs = type(me.jobs) == 'table' and me.jobs or {};
    me.subs = type(me.subs) == 'table' and me.subs or {};
    me.gear = type(me.gear) == 'table' and me.gear or {};
    if me.subs[1] ~= nil then        -- older files: one subjob list for every job -> a list per job
        local old, map = me.subs, {};
        for _, j in ipairs(me.jobs) do
            local l = {};
            for _, sj in ipairs(old) do if sj ~= j and #l < data.MAX_SUBS then l[#l + 1] = sj; end end
            map[j] = l;
        end
        me.subs = map;
    end
    me.note = type(me.note) == 'string' and me.note or '';
    store.char = name;
    store.me = me;
    return true;
end

function store.save()
    if store.char == nil or store.me == nil then return; end
    store.ensure_dir();
    write_json(dir() .. store.char .. '.json', store.me);
end

return store;
