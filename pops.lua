--[[
raidroles - Pop Rolls: a timed /random roll call that builds a pop order.

    the roll window   "Start your rolls", a timer, every "Dice roll! Name rolls ###!" recorded
    the pop order     highest roll first; edited by hand (add, move, remove)
    pops              a count per person; the order goes round until everyone has `pops_each`
    chat              through raid's queue (raid.send_line), so it shares the delay and the resend

Saved in the character's file under `pops` (store.me.pops): cfg, order, order_time, pop_log, history.
Local only: nothing here is part of the [RR:...] protocol.
--]]

require('common');
local store = require('store');
local raid  = require('raid');

local pops = {};
pops.session = nil;     -- while rolls are open: { length, ends, started, list, seen, n, warned }
pops.events  = {};      -- on_start()
pops.HISTORY_MAX = 25;

local cap = raid.cap;
local say, warn = raid.say, raid.warn;

local DEFAULTS = {
    channel    = 'p',       -- p party/alliance, l linkshell, l2 linkshell 2, s say, sh shout
    duration   = 60,        -- seconds the roll window stays open
    start_msg  = 'Start your rolls! You have %d seconds.',   -- %d = the seconds
    end_msg    = 'Rolls are closed!',
    countdown  = true,      -- post 30 / 10 seconds left
    first_only = true,      -- ignore rerolls (the first roll counts)
    auto_post  = false,     -- post the pop order when the rolls close
    call_next  = true,      -- Next also posts who is up
    pops_each  = 1,         -- pops each person gets
};

--- The saved Pop Rolls data (made, and missing keys filled in, on first use).
local function D()
    local me = store.me;
    if type(me.pops) ~= 'table' then me.pops = {}; end
    local p = me.pops;
    if type(p.cfg) ~= 'table' then p.cfg = {}; end
    for k, v in pairs(DEFAULTS) do if p.cfg[k] == nil then p.cfg[k] = v; end end
    if type(p.order) ~= 'table' then p.order = {}; end
    if type(p.history) ~= 'table' then p.history = {}; end
    if type(p.pop_log) ~= 'table' then p.pop_log = {}; end
    p.order_time = tonumber(p.order_time) or 0;
    return p;
end
pops.data = D;
function pops.cfg() return D().cfg; end

--------------------------------------------------------------------------------
-- Chat
--------------------------------------------------------------------------------
pops.CHANNELS = { { 'p', 'Party/Alliance' }, { 'l', 'Linkshell' }, { 'l2', 'Linkshell 2' }, { 's', 'Say' }, { 'sh', 'Shout' } };
local CHANNEL_CMD = { p = '/p', l = '/l', l2 = '/l2', s = '/s', sh = '/sh' };

function pops.channel_name(ch)
    for _, c in ipairs(pops.CHANNELS) do if c[1] == ch then return c[2]; end end
    return '/' .. tostring(ch);
end

--- Queues a line for the Pop Rolls channel, or `channel` when given.
function pops.post(text, channel)
    local ch = channel or D().cfg.channel;
    text = (tostring(text):gsub('<', '('):gsub('>', ')'));   -- (no <t> style substitutions)
    raid.send_line((CHANNEL_CMD[ch] or '/p') .. ' ' .. text);
end

--------------------------------------------------------------------------------
-- Sorting: highest roll first; a tie goes to whoever rolled first; no roll goes last
--------------------------------------------------------------------------------
local function sorted(list)
    local pos = {};
    for i, e in ipairs(list) do pos[e] = i; end
    table.sort(list, function (a, b)
        local ra, rb = a.roll or -1, b.roll or -1;
        if ra ~= rb then return ra > rb; end
        return (a.n or pos[a]) < (b.n or pos[b]);
    end);
    return list;
end

local function append_log(time, list)
    pcall(function()
        store.ensure_dir();
        local f = io.open(('%s\\config\\addons\\raidroles\\pop_history.txt'):format(AshitaCore:GetInstallPath()), 'a');
        if f == nil then return; end
        f:write(('=== %s  (%d rolls) ===\n'):format(os.date('%Y-%m-%d %H:%M:%S', time), #list));
        for i, e in ipairs(list) do
            f:write(('%2d. %-16s %s\n'):format(i, e.name, e.roll and tostring(e.roll) or '-'));
        end
        f:write('\n');
        f:close();
    end);
end

--------------------------------------------------------------------------------
-- The roll window
--------------------------------------------------------------------------------
function pops.left()
    if pops.session == nil then return 0; end
    return math.max(0, pops.session.ends - os.clock());
end

--- The rolls so far, sorted.
function pops.live()
    local c = {};
    for i, e in ipairs(pops.session and pops.session.list or {}) do c[i] = e; end
    return sorted(c);
end

--- What the page shows: the live rolls while the window is open, else the pop order.
function pops.list()
    if pops.session then return pops.live(); end
    return D().order;
end

function pops.start(sec)
    if pops.session then warn('Rolls are already open.'); return false; end
    local cfg = D().cfg;
    sec = math.floor(tonumber(sec) or tonumber(cfg.duration) or 60);
    sec = math.max(5, math.min(600, sec));
    pops.session = { length = sec, ends = os.clock() + sec, started = os.time(), list = {}, seen = {}, n = 0, warned = {} };
    local m = tostring(cfg.start_msg or ''):gsub('%%d', tostring(sec));
    if m ~= '' then pops.post(m); end
    say(('Pop Rolls: recording /random for %d seconds.'):format(sec));
    if pops.events.on_start then pcall(pops.events.on_start); end
    return true;
end

function pops.close(silent)
    local s = pops.session;
    if s == nil then return; end
    pops.session = nil;
    local d = D();
    if not silent and (d.cfg.end_msg or '') ~= '' then pops.post(d.cfg.end_msg); end

    if #s.list == 0 then
        say('Pop Rolls: nobody rolled, so the pop order is unchanged.');
        return;
    end
    local order = {};
    for _, e in ipairs(sorted(s.list)) do order[#order + 1] = { name = e.name, roll = e.roll, pops = 0 }; end
    d.order, d.order_time, d.pop_log = order, s.started, {};
    table.insert(d.history, 1, { time = s.started, list = store.copy(order) });
    while #d.history > pops.HISTORY_MAX do table.remove(d.history); end
    store.save();
    append_log(s.started, order);
    say(('Pop Rolls: %d in the pop order.'):format(#order));
    if not silent and d.cfg.auto_post then pops.post_order(); end
end

function pops.cancel()
    if pops.session == nil then return; end
    pops.session = nil;
    pops.post('Roll call cancelled.');
    say('Pop Rolls cancelled; the pop order is unchanged.');
end

local function record(name, n)
    local s = pops.session;
    name = cap(name);
    if s == nil or name == '' then return; end
    local e = s.seen[name];
    if e then
        if D().cfg.first_only then
            say(('Ignored a reroll from %s (%d); their first roll was %d.'):format(name, n, e.roll));
        else
            e.roll = n;
        end
        return;
    end
    s.n = s.n + 1;
    e = { name = name, roll = n, n = s.n };
    s.list[#s.list + 1] = e;
    s.seen[name] = e;
end

--- Incoming chat: FFXI prints "Dice roll! Name rolls 523!"
function pops.on_text(msg)
    if pops.session == nil then return; end
    local t = tostring(msg or ''):gsub('\x1E.', ''):gsub('\x1F.', ''):gsub('\x7F.', ''):gsub('%c', ' ');
    local name, n = t:match('Dice roll!%s*(%a+) rolls (%d+)');
    if name then record(name, tonumber(n)); end
end

--- Every frame: runs the timer (the chat queue is raid.tick's).
function pops.tick()
    local s = pops.session;
    if s == nil then return; end
    local left = s.ends - os.clock();
    if left <= 0 then
        pops.close(false);
    elseif D().cfg.countdown then
        for _, mark in ipairs({ 30, 10 }) do
            if left <= mark and s.length > mark + 2 and not s.warned[mark] then
                s.warned[mark] = true;
                pops.post(('%d seconds left to roll!'):format(mark));
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Pops: each person has a count; the order goes round and round until everyone
-- has popped `pops_each` times.
--------------------------------------------------------------------------------
function pops.goal()
    return math.max(1, math.floor(tonumber(D().cfg.pops_each) or 1));
end

function pops.set_goal(n)
    D().cfg.pops_each = math.max(1, math.min(99, math.floor(tonumber(n) or 1)));
    store.save();
end

function pops.count(e) return math.max(0, math.floor(tonumber(e and e.pops) or 0)); end

--- Who is up: the fewest pops so far (under the goal), the highest in the order first.
function pops.current()
    local best, low = nil, pops.goal();
    for i, e in ipairs(D().order) do
        local p = pops.count(e);
        if p < low then best, low = i, p; end
    end
    return best;
end

--- Who comes after `i` (counting `i` as having popped once more).
function pops.on_deck(i)
    local o = D().order;
    if i == nil or o[i] == nil then return nil; end
    o[i].pops = pops.count(o[i]) + 1;
    local n = pops.current();
    o[i].pops = o[i].pops - 1;
    if n == i then return nil; end
    return n;
end

function pops.set_count(i, n)
    local e = D().order[i];
    if e == nil then return; end
    e.pops = math.max(0, math.floor(tonumber(n) or 0));
    store.save();
end

--------------------------------------------------------------------------------
-- Editing the order
--------------------------------------------------------------------------------
function pops.find(name)
    name = cap(name);
    for i, e in ipairs(pops.list()) do
        if e.name == name then return i, e; end
    end
    return nil;
end

--- Adds someone. While rolls are open a roll is needed; else roll and spot are optional.
function pops.add(name, n, spot)
    name = cap(name);
    if name == '' then warn('Type a name first.'); return false; end
    n = tonumber(n);
    if n then n = math.floor(n); if n < 0 then n = nil; end end

    local s = pops.session;
    if s then
        if n == nil then warn('While rolls are open, add someone with their roll.'); return false; end
        local e = s.seen[name];
        if e then
            e.roll = n;
        else
            s.n = s.n + 1;
            e = { name = name, roll = n, n = s.n };
            s.list[#s.list + 1] = e;
            s.seen[name] = e;
        end
        say(('Added %s (%d) to the rolls.'):format(name, n));
        return true;
    end

    local d = D();
    if pops.find(name) then warn(name .. ' is already in the pop order.'); return false; end
    local e = { name = name, roll = n, pops = 0 };
    spot = tonumber(spot);
    if spot and spot >= 1 and spot <= #d.order then
        spot = math.floor(spot);
        table.insert(d.order, spot, e);
    else
        d.order[#d.order + 1] = e;
        spot = #d.order;
    end
    if d.order_time == 0 then d.order_time = os.time(); end
    store.save();
    say(('Added %s at #%d.'):format(name, spot));
    return true;
end

function pops.remove(i)
    local s = pops.session;
    if s then
        local e = pops.live()[i];
        if e == nil then return; end
        for k = #s.list, 1, -1 do if s.list[k] == e then table.remove(s.list, k); end end
        s.seen[e.name] = nil;
        return;
    end
    local o = D().order;
    if o[i] then
        table.remove(o, i);
        store.save();
    end
end

--- Moves the person at spot i to spot `to` (the pop order only).
function pops.move(i, to)
    local o = D().order;
    if pops.session or o[i] == nil then return; end
    to = math.max(1, math.min(#o, math.floor(tonumber(to) or i)));
    if to == i then return; end
    local e = table.remove(o, i);
    table.insert(o, to, e);
    store.save();
end

--------------------------------------------------------------------------------
-- Calling people up
--------------------------------------------------------------------------------
function pops.all_done_text()
    local g = pops.goal();
    if g == 1 then return 'Everyone in the pop order has popped!'; end
    return ('Everyone in the pop order has popped %d times!'):format(g);
end

--- Posts who is up (and who is on deck).
function pops.call()
    local o = D().order;
    if #o == 0 then warn('The pop order is empty.'); return; end
    local i = pops.current();
    if i == nil then pops.post(pops.all_done_text()); return; end
    local m = ('Up to pop (#%d of %d): %s'):format(i, #o, o[i].name);
    if pops.goal() > 1 then m = m .. (' - pop %d of %d'):format(pops.count(o[i]) + 1, pops.goal()); end
    local dk = pops.on_deck(i);
    if dk then m = m .. '  -  on deck: ' .. o[dk].name; end
    pops.post(m);
end

--- Gives the person up one more pop, then (Settings) posts the next one.
function pops.next()
    local i = pops.current();
    if i == nil then warn(pops.all_done_text()); return; end
    local d = D();
    d.order[i].pops = pops.count(d.order[i]) + 1;
    table.insert(d.pop_log, d.order[i].name);
    store.save();
    if d.cfg.call_next then pops.call(); end
end

--- Takes back the last pop given with Next.
function pops.back()
    local d = D();
    while #d.pop_log > 0 do
        local name = table.remove(d.pop_log);
        for i, e in ipairs(d.order) do
            if e.name == name and pops.count(e) > 0 then
                pops.set_count(i, pops.count(e) - 1);
                say(('Took back a pop from %s (now %d).'):format(name, pops.count(e)));
                return;
            end
        end
    end
    store.save();
    warn('Nothing to take back.');
end

--- Posts the whole order (or `list`), packed a few names to a line.
function pops.post_order(channel, list)
    list = list or pops.list();
    if #list == 0 then warn('The pop order is empty.'); return; end
    pops.post(('Pop order (%d):'):format(#list), channel);
    local line = '';
    for i, e in ipairs(list) do
        local piece = e.roll and ('%d.%s(%d)'):format(i, e.name, e.roll) or ('%d.%s'):format(i, e.name);
        if line ~= '' and #line + #piece + 1 > 95 then
            pops.post(line, channel);
            line = piece;
        else
            line = (line == '') and piece or (line .. ' ' .. piece);
        end
    end
    if line ~= '' then pops.post(line, channel); end
end

function pops.sort()
    if pops.session then return; end
    sorted(D().order);
    store.save();
end

function pops.reset()
    local d = D();
    for _, e in ipairs(d.order) do e.pops = 0; end
    d.pop_log = {};
    store.save();
end

function pops.clear()
    local d = D();
    d.order, d.order_time, d.pop_log = {}, 0, {};
    store.save();
end

--- Makes a past roll call the pop order again (every count back to 0).
function pops.use_history(h)
    local d = D();
    local o = {};
    for _, e in ipairs(h.list or {}) do o[#o + 1] = { name = e.name, roll = e.roll, pops = 0 }; end
    d.order, d.order_time, d.pop_log = o, tonumber(h.time) or os.time(), {};
    store.save();
end

return pops;
