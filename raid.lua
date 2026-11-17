--[[
raidroles - the raid: the leader's session, the member's side, and the chat protocol between them.

Everything travels in ordinary chat, so it needs no server support and players without the
addon can still read it. Lines carry a tag the addon reads: [RR:KIND:field:field...] text.

    channel (party/alliance, linkshell or linkshell 2) - from the leader
      [RR:POLL:<id>:<leader>]  Raid check ...                     everyone: send me your jobs
      [RR:POST:<id>:<leader>]  Assignments: ...                a fresh set of assignments follows
      [RR:ASG:<id>:<p>] Label: Name JOB/SUB, Name JOB, ...        party p (continued as <p>+)
      [RR:ASG:<id>:4] Standby: Name JOB/SUB, ...                   the standby party (party 4), in order
      [RR:ASG:<id>:5] Outside Heal: Name JOB/SUB, ...              healers outside the alliance (party 5)
      [RR:UNA:<id>] Unassigned: Name, Name, ...                    registered, no role (continued as :+)
      [RR:ZRG:<id>:<leader>:H] Zerg: ...                           a zerg plan follows (bards and corsairs rotate)
      [RR:ZRG:<id>:<leader>:B1] Name sings A + B; P1>P2>P3; then stays|leaves      bard 1 (B2, B3; C1-C3 roll)
    tells - member to leader
      [RR:REG:<id>:<name>:<i>/<n>] WHM.B/SCH/RDM BLM/WHM           my jobs, best first: .B/.G/.T gear (BIS, GOOD,
                                                                   TEMU), then up to 5 subjobs; part i of n
      [RR:ACK:<id>:<name>] Ready ...                               I have seen my assignment
    tells - leader to member
      [RR:POLL:...] (a nudge: the same as the channel's)
      [RR:YOU:<id>:<p>:<job>:<sub>] ...                            your assignment
      [RR:STB:<id>:<n>:<job>:<sub>] ...                            you are on standby, number n, on job/sub
    tells - players without the addon, to the leader (the chat bot)
      !rr WHM/SCH BLM/WHM register        !rr      what is my assignment?        !rr help

Compatibility: people in one raid run different copies of the addon, so every change must keep
older copies working, both ways (an old leader with new members, a new leader with old members):
  1. Never rename or remove a KIND, and never change what an existing field means or where it is.
  2. Add information only as new fields at the END of a tag (older copies ignore extra fields),
     e.g. the version: [RR:REG:<id>:<name>:<i>/<n>:v<version>] and [RR:ACK:<id>:<name>:v<version>].
  3. A new feature gets a new KIND (older copies ignore KINDs they do not know: they see plain chat).
  4. Read every field as optional (a default when it is missing); ignore anything not understood.
     The bodies the addon reads (REG jobs, ASG/UNA lists, ZRG parts) keep their format: only add to them
     in ways the old patterns still read.
  5. Members send their version, so the leader knows who is older (Roll Call shows it) and can fall back
     for them - e.g. a tell, which every copy and players without the addon understand.
  6. Saved files only gain keys (store.lua fills in defaults for missing ones); never rename a key.
  7. A broken or unexpected line must never stop the addon: raid.on_text runs inside pcall.
--]]

require('common');
local chat   = require('chat');
local data   = require('data');
local store  = require('store');
local solver = require('solver');

local raid = {};

raid.pending = nil;     -- member: a raid check waiting for the player's answer { id, leader, fight, join }
raid.events  = {};      -- callbacks set by the UI: on_assigned(), on_poll()

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
local function say(msg)   print(chat.header('raidroles'):append(chat.message(msg))); end

--- A line in the chat log in the game's tell colours, so tell traffic looks like tells:
--- incoming (12: 'Name>> ...') or outgoing (4: '>>Name : ...'). Only this player sees it.
local function tell_note(incoming, name, text)
    local line = incoming and ('%s>> %s'):format(name, text) or ('>>%s : %s'):format(name, text);
    local ok = pcall(function() AshitaCore:GetChatManager():AddChatMessage(incoming and 12 or 4, false, line); end);
    if not ok then say(line); end
end
raid.tell_note = tell_note;
local function warn(msg)  print(chat.header('raidroles'):append(chat.error(msg))); end
raid.say, raid.warn = say, warn;

local function cap(name)
    name = tostring(name or ''):gsub('[^%a]', '');
    if name == '' then return ''; end
    return name:sub(1, 1):upper() .. name:sub(2):lower();
end
raid.cap = cap;

-- Text that goes inside a tag: no ':', '[', ']', ',' and short.
local function clean(s, n)
    s = tostring(s or ''):gsub('[%[%]:,|]', ' '):gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '');
    return s:sub(1, n or 36);
end
raid.clean = clean;

local function new_id()
    local a = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    local s = '';
    for _ = 1, 3 do
        local i = math.random(1, #a);
        s = s .. a:sub(i, i);
    end
    return s;
end

function raid.my_name()
    local ok, n = pcall(function()
        return AshitaCore:GetMemoryManager():GetParty():GetMemberName(0);
    end);
    if ok and n and n ~= '' then return cap(n); end
    return nil;
end

function raid.my_job()
    local ok, j = pcall(function()
        return AshitaCore:GetMemoryManager():GetPlayer():GetMainJob();
    end);
    return ok and data.JOBS[j or 0] or nil;
end

function raid.my_sub()
    local ok, j = pcall(function()
        return AshitaCore:GetMemoryManager():GetPlayer():GetSubJob();
    end);
    return ok and data.JOBS[j or 0] or nil;
end

--- The alliance as the client sees it: { [name] = { job, block, idx } } and the count.
--- block: 1 = your own party, 2 and 3 the other parties of the alliance.
function raid.alliance()
    local out, n = {}, 0;
    pcall(function()
        local party = AshitaCore:GetMemoryManager():GetParty();
        for i = 0, 17 do
            -- players only: Trusts (and other NPCs) have server ids from 0x01000000 up
            if party:GetMemberIsActive(i) == 1 and (party:GetMemberServerId(i) or 0) < 0x01000000 then
                local name = cap(party:GetMemberName(i));
                if name ~= '' then
                    out[name] = { job = data.JOBS[party:GetMemberMainJob(i) or 0], sub = data.JOBS[party:GetMemberSubJob(i) or 0], block = math.floor(i / 6) + 1, idx = i };
                    n = n + 1;
                end
            end
        end
    end);
    return out, n;
end

function raid.in_alliance()
    local a = raid.alliance();
    for _, m in pairs(a) do if m.block > 1 then return true; end end
    return false;
end

--------------------------------------------------------------------------------
-- Sending: a queue, one line every cfg.delay seconds (the game drops chat sent too fast)
--------------------------------------------------------------------------------
local queue, next_send = {}, 0;

local function send(line)
    queue[#queue + 1] = line;
end

function raid.queue_size() return #queue; end
function raid.clear_queue() queue = {}; end
function raid.queued() return queue; end
--- Queues one chat command (e.g. '/p hello') to go out through the same queue (pops.lua uses it).
function raid.send_line(line) send(line); end

local CHANNEL_CMD = { p = '/p', l = '/l', l2 = '/l2' };
local CHANNEL_NAME = { p = 'party / alliance chat', l = 'linkshell', l2 = 'linkshell 2' };
raid.CHANNEL_NAME = CHANNEL_NAME;

local function to_channel(text)
    local cfg = store.me.cfg;
    send((CHANNEL_CMD[cfg.channel] or '/p') .. ' ' .. text);
end

local function tell(name, text)
    send(('/tell %s %s'):format(name, text));
end

-- The game refuses chat sent less than ~1.5s apart ("...A command error occurred.") and the line
-- is lost (tested live: 1.0s lost 8 of 20). So the gap is at least MIN_GAP, and a refused line is
-- put back at the front of the queue and sent again after a longer pause.
local MIN_GAP = 1.5;
local last_line, last_at, retries = nil, -100, 0;
local last_tell = nil;   -- { name, at }: the last tell the queue sent
raid.MIN_GAP = MIN_GAP;

function raid.tick()
    if #queue == 0 then return; end
    local now = os.clock();
    if now < next_send then return; end
    if last_line ~= nil then retries = 0; end   -- the previous line went through
    local line = table.remove(queue, 1);
    pcall(function() AshitaCore:GetChatManager():QueueCommand(1, line); end);
    last_line, last_at = line, now;
    local to = line:match('^/tell (%S+) ');
    if to then last_tell = { name = cap(to), at = now }; end
    next_send = now + math.max(MIN_GAP, tonumber(store.me and store.me.cfg.delay) or 2.5);
end

--- The game said our last tell was not received (offline or zoning): flag that member for the leader.
local function tell_missed()
    local t = last_tell;
    if t == nil or os.clock() - t.at > 5 then return; end
    last_tell = nil;
    local r = raid.get();
    local m = r and r.roster[t.name];
    if m then m.missed = true; store.save(); end
    warn(('%s did not get your tell (offline or zoning).%s'):format(t.name,
        m and ' They show "Tell not received" on the Raid Board.' or ''));
end

--- The game said our last line was refused: send it again (up to 3 times), after a pause.
local function resend_refused()
    local now = os.clock();
    if last_line == nil or now - last_at > 3 then return; end
    retries = retries + 1;
    if retries > 3 then warn('A line was refused 3 times and dropped: ' .. last_line:sub(1, 60)); retries = 0; last_line = nil; return; end
    table.insert(queue, 1, last_line);
    last_line = nil;
    next_send = now + 3;
end

--------------------------------------------------------------------------------
-- Leader: the session
--------------------------------------------------------------------------------
local SB = data.SB;   -- the standby "party": always the one after the last real party
local OH = data.OH;   -- the outside heal "party": after standby

local function blank_party(label) return { label = label, slots = { '', '', '', '', '', '' } }; end
local function standby_party()
    local slots = {};
    for s = 1, data.SB_SLOTS do slots[s] = 'ANY'; end
    return { label = 'Standby', standby = true, slots = slots };
end
local function outside_party()
    return { label = 'Outside Heal', outside = true, slots = { 'HEALER', 'HEALER', '', '', '', '' } };
end

--- The board's shape: always 3 parties (blank ones added) and the standby party after them.
local function comp_from_fight(f)
    local comp = {};
    for p = 1, data.MAX_PARTIES do
        local src = f.parties and f.parties[p];
        if src then
            local slots = {};
            for s = 1, data.SLOTS do slots[s] = data.norm_req(src.slots and src.slots[s]); end
            comp[p] = { label = src.label or ('Party ' .. p), slots = slots };
        else
            comp[p] = blank_party('Party ' .. p);
        end
    end
    comp[SB] = standby_party();
    comp[OH] = outside_party();
    return comp;
end
raid.comp_from_fight = comp_from_fight;

local function blank_cell() return { name = '', job = '', sub = '', lock = false }; end

--- Brings a raid (also one saved by an older version) to the current shape.
local function shape(r)
    local parties, cells = {}, {};
    for p, party in ipairs(r.comp or {}) do
        if party.standby then
            cells[SB] = r.assign and r.assign[p] or nil;
            parties.sb = party;
        elseif party.outside then
            cells[OH] = r.assign and r.assign[p] or nil;
            parties.oh = party;
        elseif #parties < data.MAX_PARTIES then
            parties[#parties + 1] = party;
            cells[#parties] = r.assign and r.assign[p] or nil;
        end
    end
    local comp, assign = {}, {};
    for p = 1, data.MAX_PARTIES do
        comp[p] = parties[p] or blank_party('Party ' .. p);
        assign[p] = cells[p] or {};
    end
    comp[SB] = parties.sb or standby_party();
    assign[SB] = cells[SB] or {};
    comp[OH] = parties.oh or outside_party();
    assign[OH] = cells[OH] or {};
    for s = #comp[SB].slots + 1, data.SB_SLOTS do comp[SB].slots[s] = 'ANY'; end   -- older standby: 6 slots
    for p = 1, data.LAST do
        for s = 1, data.nslots(p) do assign[p][s] = assign[p][s] or blank_cell(); end
    end
    r.comp, r.assign, r.standby, r.v = comp, assign, nil, 4;
end

local function empty_grid()
    local g = {};
    for p = 1, data.LAST do
        g[p] = {};
        for s = 1, data.nslots(p) do g[p][s] = blank_cell(); end
    end
    return g;
end

function raid.get()
    local r = store.me and store.me.raid or nil;
    if r and r.v ~= 4 then shape(r); end
    return r;
end

--- Starts (or restarts) a leader session for a fight. Keeps registrations when keep_roster.
function raid.start(fight, keep_roster)
    local old = raid.get();
    local r = {
        id      = new_id(),
        fight   = fight.name or 'Raid',
        comp    = comp_from_fight(fight),
        notes   = fight.notes or '',
        roster  = (keep_roster and old and old.roster) or {},
        mode    = (old and old.mode) or 'auto',
        posted  = false,
        v       = 4,
    };
    r.assign = empty_grid();
    store.me.raid = r;
    raid.add_self();
    store.save();
    return r;
end

--- Puts another fight's composition on the board, keeping the session and its registrations.
function raid.use_fight(fight)
    local r = raid.get();
    if r == nil then return raid.start(fight, false); end
    local sb, oh = r.comp[SB], r.comp[OH];
    r.fight  = fight.name or r.fight;
    r.comp   = comp_from_fight(fight);
    r.comp[SB] = sb or r.comp[SB];      -- the standby and outside heal slots stay as the leader set them
    r.comp[OH] = oh or r.comp[OH];
    r.notes  = fight.notes or '';
    r.assign = empty_grid();
    r.posted = false;
    if r.mode == 'auto' then raid.auto(); end
    store.save();
    return r;
end

function raid.end_session()
    store.me.raid = nil;
    store.save();
end

--- The leader counts as a member too, with their own saved jobs.
function raid.add_self()
    local r, me = raid.get(), raid.my_name();
    if r == nil or me == nil or #store.me.jobs == 0 then return; end
    local cur = r.roster[me];
    r.roster[me] = { jobs = store.copy(store.me.jobs), subs = store.copy(store.me.subs or {}), gear = store.copy(store.me.gear or {}), src = 'self', addon = true, t = os.time(), ack = cur and cur.ack or false, out = cur and cur.out };
end

--------------------------------------------------------------------------------
-- Saved sign-ups: every sign-up the leader gets (or types) is kept here, across raids, so
-- people can be brought into a later raid without signing up again.
--------------------------------------------------------------------------------
function raid.saved()
    store.me.repo = store.me.repo or {};
    return store.me.repo;
end

local function remember(name, e)
    if name == '' or name == raid.my_name() then return; end
    raid.saved()[name] = { jobs = store.copy(e.jobs or {}), subs = store.copy(e.subs or {}), gear = store.copy(e.gear or {}),
                           src = e.src, addon = e.addon, t = os.time() };
end

--- Sign-ups made before saving existed (or by an older version) get saved too.
function raid.save_roster()
    local r = raid.get();
    if r == nil then return; end
    local saved = raid.saved();
    for name, m in pairs(r.roster) do
        if saved[name] == nil and m.src ~= 'self' then remember(name, m); end
    end
end

--- Brings a saved sign-up into the running raid.
function raid.move_up(name)
    local e = raid.saved()[name];
    if e == nil or raid.get() == nil then return false; end
    return raid.register(name, store.copy(e.jobs), 'saved', e.addon, store.copy(e.subs), store.copy(e.gear));
end

--- Takes a member out of the running raid (and its slots); their sign-up stays saved.
function raid.move_down(name)
    local r = raid.get();
    if r == nil or r.roster[name] == nil then return; end
    remember(name, r.roster[name]);
    raid.remove(name);
end

function raid.forget(name)
    raid.saved()[name] = nil;
    store.save();
end

function raid.register(name, jobs, src, addon, subs, gear)
    local r = raid.get();
    name = cap(name);
    if r == nil or name == '' then return false; end
    local cur = r.roster[name] or {};
    r.roster[name] = { jobs = jobs, subs = subs or cur.subs or {}, gear = gear or cur.gear or {}, src = src,
                       addon = addon or cur.addon or false, t = os.time(), ack = false, out = cur.out, ver = cur.ver };
    if src ~= 'self' then remember(name, r.roster[name]); end
    if r.mode == 'auto' and r.posted == false then raid.auto(); end
    store.save();
    return true;
end

--- Takes a member out of every slot.
local function unplace(r, name)
    for _, party in ipairs(r.assign) do
        for _, c in ipairs(party) do
            if c.name == name and name ~= '' then c.name, c.job, c.sub, c.lock = '', '', '', false; end
        end
    end
end

function raid.remove(name)
    local r = raid.get();
    if r == nil then return; end
    r.roster[name] = nil;
    unplace(r, name);
    store.save();
end

--- Sits a member out (or brings them back): out of every slot, but still registered.
function raid.set_out(name, out)
    local r = raid.get();
    if r == nil or r.roster[name] == nil then return; end
    r.roster[name].out = out;
    if out then unplace(r, name); end
    if r.mode == 'auto' then raid.auto(); end
    store.save();
end

function raid.fit_grid()
    local r = raid.get();
    if r then shape(r); end
end

--- Auto-fill, in turn: the 3 parties, then outside heal, then standby, each from whoever is left.
function raid.auto()
    local r = raid.get();
    if r == nil then return; end
    shape(r);
    local locked = {};      -- names locked in a later stage stay out of the earlier ones
    for _, p in ipairs({ SB, OH }) do
        for _, c in ipairs(r.assign[p]) do if c.lock and c.name ~= '' then locked[c.name] = p; end end
    end
    local taken, out = {}, {};
    local function stage(ps, own)
        local comp, cells, roster = {}, {}, {};
        for i, p in ipairs(ps) do comp[i], cells[i] = r.comp[p], r.assign[p]; end
        for n, m in pairs(r.roster) do
            if not taken[n] and (locked[n] == nil or locked[n] == own) then roster[n] = m; end
        end
        local res = solver.solve(comp, cells, roster);
        for i, p in ipairs(ps) do
            out[p] = res[i];
            for _, c in ipairs(res[i]) do if c.name ~= '' then taken[c.name] = true; end end
        end
    end
    stage({ 1, 2, 3 }, nil);
    stage({ OH }, OH);
    stage({ SB }, SB);
    r.assign = out;
    store.save();
end

function raid.clear_assign(keep_locks)
    local r = raid.get();
    if r == nil then return; end
    for _, party in ipairs(r.assign) do
        for _, c in ipairs(party) do
            if not (keep_locks and c.lock) then c.name, c.job, c.sub, c.lock = '', '', '', false; end
        end
    end
    store.save();
end

--- Puts a member in a slot (manual). Moves them out of any other slot. Locks it.
function raid.set_slot(p, s, name)
    local r = raid.get();
    if r == nil then return; end
    unplace(r, name);
    local cell = r.assign[p][s];
    if name == '' then
        cell.name, cell.job, cell.sub, cell.lock = '', '', '', false;
    else
        local m = r.roster[name];
        if m then m.out = nil; end
        local req = r.comp[p].slots[s];
        local _, job = solver.cost(req ~= '' and req or 'ANY', m or {});
        local _, want = data.split_req(req);
        cell.name, cell.job, cell.lock = name, job or (m and m.jobs[1]) or '', true;
        cell.sub = data.pick_sub(m, cell.job, want);
    end
    store.save();
end

--- Puts a member in the first open standby slot. Returns false when standby is full.
function raid.to_standby(name)
    local r = raid.get();
    if r == nil then return false; end
    for s, c in ipairs(r.assign[SB]) do
        if c.name == '' then raid.set_slot(SB, s, name); return true; end
    end
    return false;
end

--- Where a member is assigned: p, s, cell (or nil). p == data.SB is the standby party.
function raid.slot_of(name)
    local r = raid.get();
    if r == nil then return nil; end
    for p, party in ipairs(r.assign) do
        for s, c in ipairs(party) do
            if c.name == name then return p, s, c; end
        end
    end
    return nil;
end

--- Registered, not sitting out, and in no slot (not even standby): the Unassigned Role list.
function raid.unassigned()
    local r = raid.get();
    local out = {};
    if r == nil then return out; end
    for name, m in pairs(r.roster) do
        if not raid.slot_of(name) and not m.out then out[#out + 1] = name; end
    end
    table.sort(out);
    return out;
end

--- A party's members in slot order (SB = standby, OH = outside heal).
function raid.members_of(p)
    local r = raid.get();
    local out = {};
    if r == nil then return out; end
    for _, c in ipairs(r.assign[p]) do if c.name ~= '' then out[#out + 1] = c.name; end end
    return out;
end

function raid.standby() return raid.members_of(SB); end

--- Everyone the leader knows of: registered or in the alliance. { name, reg, ally }
function raid.roll()
    local r = raid.get();
    local ally = raid.alliance();
    local names, seen = {}, {};
    for name in pairs(r and r.roster or {}) do names[#names + 1] = name; seen[name] = true; end
    for name in pairs(ally) do if not seen[name] then names[#names + 1] = name; end end
    table.sort(names);
    local out = {};
    for _, name in ipairs(names) do
        out[#out + 1] = { name = name, reg = r and r.roster[name] or nil, ally = ally[name] };
    end
    return out;
end

--------------------------------------------------------------------------------
-- Leader: talking to the raid
--------------------------------------------------------------------------------
local function poll_tag(r)
    return ('[RR:POLL:%s:%s]'):format(r.id, raid.my_name() or '?');
end

--- Before sending to party chat: warns when it would reach nobody, or only your own party.
local function check_reach()
    if (store.me.cfg.channel or 'p') ~= 'p' then return; end
    local ally, n = raid.alliance();
    if n <= 1 then
        warn('You are not in a party: party chat reaches nobody. Form the party/alliance first, or pick a linkshell in Settings.');
    elseif not raid.in_alliance() then
        warn(('Not in an alliance yet: party chat only reaches your own party (%d). Form the alliance first, or use a linkshell (Settings).'):format(n));
    end
end
raid.check_reach = check_reach;

function raid.poll()
    local r = raid.get();
    if r == nil then warn('Start a raid first (pick a fight).'); return; end
    check_reach();
    raid.add_self();
    local me = raid.my_name() or '?';
    to_channel(('%s Raid check! No addon? /tell %s !rr WHM/SCH BLM/WHM  (or !rr help)'):format(poll_tag(r), me));
    say(('Raid check sent to %s.'):format(CHANNEL_NAME[store.me.cfg.channel] or 'chat'));
end

--- Alliance members who have not sent their jobs (not yourself).
function raid.unregistered()
    local r = raid.get();
    local out = {};
    if r == nil then return out; end
    local me = raid.my_name();
    for name in pairs(raid.alliance()) do
        if r.roster[name] == nil and name ~= me then out[#out + 1] = name; end
    end
    table.sort(out);
    return out;
end

--- The second raid check: only to who is missing. Before the post: alliance members who have not sent
--- their jobs. After it: whoever did not receive their assignment or has not confirmed it.
--- Returns the names and what it does ('jobs' or 'assignments').
function raid.missing()
    local r = raid.get();
    if r and r.posted then return raid.unconfirmed(), 'assignments'; end
    return raid.unregistered(), 'jobs';
end

function raid.check_missing()
    local names, what = raid.missing();
    if #names == 0 then say(what == 'jobs' and 'Everyone in the alliance has sent their jobs.' or 'Everyone has confirmed: nothing to send.'); return 0; end
    if what == 'jobs' then raid.nudge(names); return #names; end
    return raid.resend();
end

--- Tells everyone in the alliance who has not registered (or `names`, if given).
function raid.nudge(names)
    local r = raid.get();
    if r == nil then return; end
    local me = raid.my_name() or '?';
    if names == nil then
        names = {};
        for name in pairs(raid.alliance()) do
            if r.roster[name] == nil and name ~= me then names[#names + 1] = name; end
        end
    end
    for _, name in ipairs(names) do
        tell(name, ('%s Please send your jobs: /tell %s !rr WHM/SCH BLM/WHM ...'):format(poll_tag(r), me));
    end
    say(('Nudged %d member(s).'):format(#names));
end

local function party_lines(r, p)
    local party = r.comp[p];
    local items = {};
    for s = 1, data.nslots(p) do
        local req = party.slots[s];
        local c = r.assign[p][s];
        if (req ~= '' and p <= data.MAX_PARTIES) or c.name ~= '' then
            if c.name ~= '' then items[#items + 1] = ('%s %s'):format(c.name, c.job ~= '' and data.job_sub(c.job, c.sub) or '?');
            else items[#items + 1] = ('?%s'):format(data.req_label(req):upper()); end
        end
    end
    local lines, cur = {}, ('[RR:ASG:%s:%d] %s:'):format(r.id, p, clean(party.label, 20));
    local first = true;
    for _, it in ipairs(items) do
        local add = (first and ' ' or ', ') .. it;
        if #cur + #add > 100 then
            lines[#lines + 1] = cur;
            cur = ('[RR:ASG:%s:%d+]'):format(r.id, p);
            add = ' ' .. it;
        end
        cur = cur .. add;
        first = false;
    end
    lines[#lines + 1] = cur;
    return lines;
end

--- Does this member also need a tell? Settings 'all'; players without the addon; and, when the
--- assignments go to party chat, anyone not in the alliance (standby, outside heal, people who
--- signed up by tell): party chat never reaches them.
local function needs_tell(r, name, mode, ally)
    if mode == 'off' then return false; end
    if mode == 'all' then return true; end
    local m = r.roster[name];
    if not (m and m.addon) then return true; end
    return (store.me.cfg.channel or 'p') == 'p' and ally[name] == nil;
end

--- Posts the assignments to the channel, and tells members as the settings say.
function raid.post()
    local r = raid.get();
    if r == nil then return; end
    check_reach();
    local me = raid.my_name() or '?';
    for _, m in pairs(r.roster) do m.missed = nil; end
    local count, used = 0, {};
    for p = 1, data.MAX_PARTIES do
        for s = 1, data.SLOTS do
            if r.assign[p][s].name ~= '' then count = count + 1; used[p] = true; end
            if r.comp[p].slots[s] ~= '' then used[p] = true; end
        end
    end
    local np = 0; for _ in pairs(used) do np = np + 1; end
    local sb = raid.standby();
    local oh = raid.members_of(OH);
    local un = raid.unassigned();
    to_channel(('[RR:POST:%s:%s] Assignments: %d in %d parties, %d outside heal, %d standby. No addon? /tell %s !rr')
        :format(r.id, me, count, np, #oh, #sb, me));
    for p = 1, data.MAX_PARTIES do
        if used[p] then
            for _, line in ipairs(party_lines(r, p)) do to_channel(line); end
        end
    end
    if #sb > 0 then
        for _, line in ipairs(party_lines(r, SB)) do to_channel(line); end
    end
    if #oh > 0 then
        for _, line in ipairs(party_lines(r, OH)) do to_channel(line); end
    end
    if #un > 0 then
        local cur = ('[RR:UNA:%s] Unassigned:'):format(r.id);
        for i, name in ipairs(un) do
            local add = (i == 1 and ' ' or ', ') .. name;
            if #cur + #add > 100 then
                to_channel(cur);
                cur = ('[RR:UNA:%s:+]'):format(r.id);
                add = ' ' .. name;
            end
            cur = cur .. add;
        end
        to_channel(cur);
    end
    local mode = store.me.cfg.tells;
    if mode ~= 'off' then
        local ally = raid.alliance();
        for p, party in ipairs(r.assign) do
            for _, c in ipairs(party) do
                if c.name ~= '' and c.name ~= me and needs_tell(r, c.name, mode, ally) then
                    raid.tell_assignment(c.name);
                end
            end
        end
    end
    for _, m in pairs(r.roster) do m.ack = false; end
    r.posted = true;
    store.save();
    say('Assignments posted.');
end

--- Who still needs their assignment after a post: their tell bounced (offline or zoning), or they have
--- the addon and have not confirmed. Players without the addon cannot confirm, so they only count when
--- their tell bounced. Everyone with a slot (parties, standby, outside heal), never yourself.
function raid.unconfirmed()
    local r = raid.get();
    local out = {};
    if r == nil or not r.posted then return out; end
    local me = raid.my_name();
    for _, party in ipairs(r.assign) do
        for _, c in ipairs(party) do
            local m = c.name ~= '' and r.roster[c.name];
            if m and c.name ~= me and not m.ack and (m.missed or m.addon) then out[#out + 1] = c.name; end
        end
    end
    table.sort(out);
    return out;
end

--- Tells their assignment again to everyone raid.unconfirmed() lists. Returns how many.
function raid.resend()
    local r = raid.get();
    if r == nil then return 0; end
    local n = 0;
    for _, name in ipairs(raid.unconfirmed()) do
        r.roster[name].missed = nil;      -- set again if this tell bounces too
        if raid.tell_assignment(name) then n = n + 1; end
    end
    store.save();
    if n > 0 then say(('Sending %d assignment%s again (one every %.1f s).'):format(n, n == 1 and '' or 's',
        math.max(MIN_GAP, tonumber(store.me.cfg.delay) or 2.5)));
    else say('Everyone has confirmed: nothing to send.'); end
    return n;
end

function raid.tell_assignment(name)
    local r = raid.get();
    if r == nil or name == raid.my_name() then return false; end
    local p, _, c = raid.slot_of(name);
    if p == nil then return false; end
    if p == SB then
        for i, n in ipairs(raid.standby()) do
            if n == name then
                local js = data.job_sub(c.job, c.sub);
                tell(name, ('[RR:STB:%s:%d:%s:%s] You are standby number %d on %s. Stay ready to fill in.')
                    :format(r.id, i, c.job, c.sub or '', i, js));
                return true;
            end
        end
        return false;
    end
    local js = data.job_sub(c.job, c.sub);
    if p == OH then
        tell(name, ('[RR:YOU:%s:%d:%s:%s] You are Outside Heal on %s. Stay out of the alliance.')
            :format(r.id, p, c.job, c.sub or '', js));
        return true;
    end
    tell(name, ('[RR:YOU:%s:%d:%s:%s] You are Party %d (%s) on %s.')
        :format(r.id, p, c.job, c.sub or '', p, clean(r.comp[p].label, 20), js));
    return true;
end

--------------------------------------------------------------------------------
-- Leader: the zerg plan. Bard n and corsair n are team n: each team starts in party 1, does its
-- two songs / two rolls, drops, and joins party 2, then party 3; then stays there or leaves.
-- Step s: team t is in party s - t + 1, so each party sees all three teams, one after another.
--------------------------------------------------------------------------------
function raid.zerg()
    local r = raid.get();
    if r == nil then return nil; end
    if r.zerg == nil then
        local z = { brd = {}, cor = {} };
        for i = 1, data.ZERG_TEAMS do
            local b, c = data.ZERG_DEFAULT.brd[i], data.ZERG_DEFAULT.cor[i];
            z.brd[i] = { name = '', a = b[1], b = b[2], stay = true };
            z.cor[i] = { name = '', a = c[1], b = c[2], stay = true };
        end
        r.zerg = z;
    end
    return r.zerg;
end

function raid.zerg_reset()
    local r = raid.get();
    if r == nil then return; end
    local names = {};
    if r.zerg then
        for _, k in ipairs({ 'brd', 'cor' }) do
            names[k] = {};
            for i, e in ipairs(r.zerg[k]) do names[k][i] = e.name; end
        end
    end
    r.zerg = nil;
    local z = raid.zerg();
    for _, k in ipairs({ 'brd', 'cor' }) do
        for i, e in ipairs(z[k]) do e.name = (names[k] and names[k][i]) or ''; end
    end
    store.save();
end

local function zerg_line(r, role, i)
    local z = raid.zerg();
    local e = (role == 'B') and z.brd[i] or z.cor[i];
    if e == nil or e.name == '' then return nil; end
    return ('[RR:ZRG:%s:%s:%s%d] %s %s %s + %s; P1>P2>P3; then %s'):format(r.id, raid.my_name() or '?', role, i, e.name,
        role == 'B' and 'sings' or 'rolls', e.a, e.b, e.stay and 'stays' or 'leaves');
end

local function zerg_header(r)
    return ('[RR:ZRG:%s:%s:H] Zerg: teams rotate P1>P2>P3. Party leaders: keep 2 spots, invite Team 1, 2, then 3.')
        :format(r.id, raid.my_name() or '?');
end

--- Posts the zerg plan to the chat channel; tells each bard and corsair their part (as Settings say).
function raid.zerg_post()
    local r = raid.get();
    if r == nil then return; end
    local me = raid.my_name();
    check_reach();
    to_channel(zerg_header(r));
    for i = 1, data.ZERG_TEAMS do
        for _, role in ipairs({ 'B', 'C' }) do
            local line = zerg_line(r, role, i);
            if line then to_channel(line); end
        end
    end
    local mode = store.me.cfg.tells;
    if mode ~= 'off' then
        local z = raid.zerg();
        local ally = raid.alliance();
        for i = 1, data.ZERG_TEAMS do
            for _, role in ipairs({ 'B', 'C' }) do
                local e = (role == 'B') and z.brd[i] or z.cor[i];
                if e.name ~= '' and e.name ~= me and needs_tell(r, e.name, mode, ally) then raid.zerg_tell(role, i); end
            end
        end
    end
    say('Zerg plan posted.');
end

--- Tells one bard (role 'B') or corsair ('C') their part.
function raid.zerg_tell(role, i)
    local r = raid.get();
    if r == nil then return false; end
    local line = zerg_line(r, role, i);
    if line == nil then return false; end
    local z = raid.zerg();
    local e = (role == 'B') and z.brd[i] or z.cor[i];
    if e.name == raid.my_name() then return false; end
    tell(e.name, line);
    return true;
end

--------------------------------------------------------------------------------
-- Member side
--------------------------------------------------------------------------------
function raid.mine()
    return store.me and store.me.mine or nil;
end

--- Answers a raid check with the saved jobs.
function raid.reply(p)
    p = p or raid.pending;
    if p == nil then return; end
    raid.pending = nil;
    local jobs = store.me.jobs;
    if #jobs == 0 then warn('You have no jobs saved yet: open /roles and pick them on My Jobs.'); return; end
    local me = raid.my_name() or '?';
    if p.leader == me then
        raid.add_self();
        store.save();
        return;
    end
    raid.send_jobs(p.leader, p.id);
end

-- The sign-up lines: [RR:REG:<id>:<me>:i/n] WHM.B/SCH/RDM ... ('*' = whatever raid the leader is running)
local function reg_lines(id)
    local me = raid.my_name() or '?';
    local parts = data.signup_chunks(store.me.jobs, store.me.subs, store.me.gear, 64);
    local out = {};
    for i, part in ipairs(parts) do out[i] = ('[RR:REG:%s:%s:%d/%d:v%s] %s'):format(id or '*', me, i, #parts, data.VERSION, part); end
    return out;
end

--- Sends the saved jobs to a leader by tell (no raid check needed: their running raid takes it).
function raid.send_jobs(leader, id)
    leader = cap(leader);
    if #store.me.jobs == 0 then warn('You have no jobs saved yet: pick them on My Jobs.'); return false; end
    if leader == '' then warn('Type the raid leader\'s name first.'); return false; end
    if leader == raid.my_name() then raid.add_self(); store.save(); say('You are the leader: your own jobs are on your board.'); return true; end
    for _, line in ipairs(reg_lines(id)) do tell(leader, line); end
    store.me.last_reply = { id = id or '*', leader = leader, t = os.time() };
    store.save();
    local n = #reg_lines(id);
    tell_note(false, leader, ('[Raid Roles] my %d job%s, gear and subjobs%s'):format(#store.me.jobs,
        #store.me.jobs == 1 and '' or 's', n > 1 and (' (' .. n .. ' tells)') or ''));
    return true;
end

--- Posts the saved jobs in party chat: everyone reads them, and a leader's addon in the party registers them.
function raid.post_jobs_party()
    if #store.me.jobs == 0 then warn('You have no jobs saved yet: pick them on My Jobs.'); return false; end
    local m, p = raid.mine(), raid.pending;
    local id = (p and p.id) or (m and m.id) or '*';
    for _, line in ipairs(reg_lines(id)) do send('/p ' .. line); end
    say(('Posting your %d job%s in party chat.'):format(#store.me.jobs, #store.me.jobs == 1 and '' or 's'));
    return true;
end

--- The leader we last heard from: a raid check waiting, the last assignment, or the last one we answered.
function raid.known_leader()
    local p, m, lr = raid.pending, raid.mine(), store.me and store.me.last_reply;
    if p and p.leader then return p.leader, p.id; end
    if m and m.leader then return m.leader, m.id; end
    if lr and lr.leader then return lr.leader, lr.id; end
    return nil;
end

function raid.ack()
    local m = raid.mine();
    if m == nil or m.leader == nil then return; end
    if m.leader ~= raid.my_name() then
        tell(m.leader, ('[RR:ACK:%s:%s:v%s] Ready: %s on %s'):format(m.id, raid.my_name() or '?', data.VERSION,m.standby and ('standby #' .. m.standby) or (m.party == OH and 'outside heal') or ('party ' .. tostring(m.party or '?')), data.job_sub(m.job or '?', m.sub)));
    end
    if m.leader ~= raid.my_name() then tell_note(false, m.leader, '[Raid Roles] role confirmed'); end
    m.acked = true;
    store.save();
end

local function on_poll(id, leader, fight, nudge)
    leader = cap(leader);
    if leader == raid.my_name() then return; end
    local cfg = store.me.cfg;
    local p = { id = id, leader = leader, fight = fight, nudge = nudge };
    if cfg.poll_reply == 'off' then
        say(('%s started a raid check (replies are off).'):format(leader));
        return;
    end
    if cfg.poll_reply == 'auto' and #store.me.jobs > 0 then
        raid.reply(p);
        return;
    end
    raid.pending = p;
    say(('%s started a raid check.'):format(leader));
    if raid.events.on_poll then raid.events.on_poll(p); end
end

local function on_post(id, leader, fight)
    store.me.mine = { id = id, leader = cap(leader), fight = fight, parties = {}, unassigned = {}, t = os.time(), acked = false };
    store.save();
end

local function on_asg(id, pnum, cont, body)
    local m = raid.mine();
    if m == nil or m.id ~= id then return; end
    local me = raid.my_name();
    local key = tostring(pnum);
    local party = m.parties[key];
    if party == nil or not cont then
        party = { label = '', members = {} };
        m.parties[key] = party;
    end
    local rest = body;
    if not cont then
        local label, after = body:match('^%s*([^:]*):(.*)$');
        if label then party.label, rest = label, after; end
    end
    for item in rest:gmatch('[^,]+') do
        item = item:gsub('^%s+', ''):gsub('%s+$', '');
        local open = item:match('^%?(%S+)$');
        if open then
            party.members[#party.members + 1] = { name = '', job = open };
        else
            local name, js = item:match('^(%a+)%s+(%S+)$');
            if name then
                name = cap(name);
                local job, sub = js:match('^(%a+)/(%a+)$');
                job, sub = job or js, sub or '';
                party.members[#party.members + 1] = { name = name, job = job, sub = sub };
                if name == me and pnum == SB then
                    m.party, m.job, m.sub, m.label, m.standby, m.unassigned_me = nil, job, sub, party.label, #party.members, nil;
                    if raid.events.on_assigned then raid.events.on_assigned(m); end
                elseif name == me then
                    m.party, m.job, m.sub, m.label, m.standby, m.unassigned_me = pnum, job, sub, party.label, nil, nil;
                    if raid.events.on_assigned then raid.events.on_assigned(m); end
                end
            end
        end
    end
    store.save();
end

local function on_sby(id, cont, body)
    local m = raid.mine();
    if m == nil or m.id ~= id then return; end
    if not cont then m.standby_list = {}; end
    m.standby_list = m.standby_list or {};
    local rest = body:gsub('^%s*Standby:', '');
    local me = raid.my_name();
    for item in rest:gmatch('[^,]+') do
        local name = cap(item);
        if name ~= '' then
            m.standby_list[#m.standby_list + 1] = name;
            if name == me then
                m.standby, m.party, m.job, m.sub = #m.standby_list, nil, nil, nil;
                if raid.events.on_assigned then raid.events.on_assigned(m); end
            end
        end
    end
    store.save();
end

local function on_una(id, cont, body)
    local m = raid.mine();
    if m == nil or m.id ~= id then return; end
    if not cont or m.unassigned == nil then m.unassigned = {}; end
    local rest = body:gsub('^%s*Unassigned:', '');
    local me = raid.my_name();
    for item in rest:gmatch('[^,]+') do
        local name = cap(item);
        if name ~= '' then
            m.unassigned[#m.unassigned + 1] = name;
            if name == me and m.party == nil and m.standby == nil then
                m.unassigned_me = true;
                if raid.events.on_assigned then raid.events.on_assigned(m); end
            end
        end
    end
    store.save();
end

local function on_stb(id, leader, n, job, sub, body)
    local m = raid.mine();
    if m == nil or m.id ~= id then
        m = { id = id, leader = cap(leader), fight = body:match('^%s*(.-):') or 'Raid', parties = {}, t = os.time(), acked = false };
        store.me.mine = m;
    end
    m.standby, m.party, m.unassigned_me = tonumber(n) or 1, nil, nil;
    m.job, m.sub = (job ~= '' and job or nil), sub or '';
    store.save();
    if raid.events.on_assigned then raid.events.on_assigned(m); end
end

local function on_you(id, leader, pnum, job, sub, body)
    local m = raid.mine();
    if m == nil or m.id ~= id then
        m = { id = id, leader = cap(leader), fight = body:match('^%s*(.-):') or 'Raid', parties = {}, t = os.time(), acked = false };
        store.me.mine = m;
    end
    m.party, m.job, m.sub, m.standby, m.unassigned_me = pnum, job, sub or '', nil, nil;
    if pnum == OH then m.label = 'Outside Heal'; end
    m.label = body:match('%((.-)%)') or m.label;
    store.save();
    if raid.events.on_assigned then raid.events.on_assigned(m); end
end

--------------------------------------------------------------------------------
-- Leader: answers from members (tags) and players without the addon (the bot)
--------------------------------------------------------------------------------
local bot_last = {};

local function bot(sender, text)
    local r = raid.get();
    if r == nil or not store.me.cfg.bot then return; end
    local now = os.clock();
    if bot_last[sender] and now - bot_last[sender] < 4 then return; end
    bot_last[sender] = now;
    local arg = text:gsub('^%s*!rr%s*', '');
    local low = arg:lower();
    if low == 'help' or low == '?' or low == 'format' then
        -- two tells: one tell is cut off after 128 characters
        tell(sender, ('[RR] Sign up: /tell %s !rr WHM.B/SCH/RDM BLM.G/WHM  (jobs you can play, best first)'):format(raid.my_name() or 'me'));
        tell(sender, '[RR] After each job: .B .G .T = BIS GOOD TEMU gear, then /subjobs. Send "!rr" alone to see your assignment.');
        return;
    end
    local jobs, subs, gear = data.parse_signup(arg);
    if #jobs > 0 then
        raid.register(sender, jobs, 'tell', false, subs, gear);
        tell_note(true, sender, ('[Raid Roles] signed up with %d job%s (see Roll Call)'):format(#jobs, #jobs == 1 and '' or 's'));
        tell(sender, ('[RR] Got it: %s. Thanks!'):format(data.signup_text(jobs, subs, gear)):sub(1, 120));
        return;
    end
    if r.posted and raid.tell_assignment(sender) then
        return;
    elseif r.roster[sender] then
        tell(sender, ('[RR] You are signed up with %s. Assignments are not out yet.'):format(data.signup_text(r.roster[sender].jobs, r.roster[sender].subs, r.roster[sender].gear)):sub(1, 120));
    else
        tell(sender, '[RR] Not signed up yet: /tell me "!rr WHM/SCH BLM/WHM" (jobs you can play, best first, /subjobs after each).');
    end
end

local reg_parts = {};   -- a sign-up arriving in several tells: name -> { jobs, subs, gear }

--- A version field ('v1.1.0') -> '1.1.0'; nil for copies that did not send one (before 1.1.0).
local function ver_of(field)
    return field and field:match('^v(%d+[%.%d]*)$') or nil;
end

--- The leader remembers each member's version (shown in Roll Call).
local function note_ver(name, ver)
    local r = raid.get();
    local m = r and r.roster[name];
    if m and ver then m.ver = ver; end
end

local function on_reg(id, name, part, body, ver)
    local r = raid.get();
    if r == nil or (r.id ~= id and id ~= '*') then return; end
    name = cap(name);
    if name == raid.my_name() then return; end
    local i, n = (part or ''):match('^(%d+)/(%d+)$');
    i, n = tonumber(i) or 1, tonumber(n) or 1;
    local jobs, subs, gear = data.parse_signup(body);
    local acc = reg_parts[name];
    if i == 1 or acc == nil then acc = { jobs = {}, subs = {}, gear = {} }; reg_parts[name] = acc; end
    for _, j in ipairs(jobs) do
        acc.jobs[#acc.jobs + 1] = j;
        acc.subs[j] = subs[j];
        acc.gear[j] = gear[j];
    end
    if #acc.jobs == 0 then return; end
    raid.register(name, store.copy(acc.jobs), 'addon', true, store.copy(acc.subs), store.copy(acc.gear));
    local m = r.roster[name];
    if m then m.ver = ver or '1.0.0'; store.save(); end   -- no version field: a copy from before 1.1.0
    if i >= n then
        tell_note(true, name, ('[Raid Roles] signed up with %d job%s (see Roll Call)'):format(#acc.jobs, #acc.jobs == 1 and '' or 's'));
        reg_parts[name] = nil;
    end
end

local function on_ack(id, name, ver)
    local r = raid.get();
    if r == nil or r.id ~= id then return; end
    local m = r.roster[cap(name)];
    if m then
        m.ack = true;
        note_ver(cap(name), ver);
        store.save();
        tell_note(true, cap(name), '[Raid Roles] role confirmed');
    end
end

--- Zerg lines: the whole plan is kept (store.me.zerg_mine.list), and the player's own part (.me).
local function on_zrg(id, leader, kind, body)
    local z = store.me.zerg_mine;
    if kind == 'H' or z == nil or z.id ~= id then
        z = { id = id, leader = cap(leader), list = {}, t = os.time() };
        store.me.zerg_mine = z;
        if kind == 'H' then store.save(); return; end
    end
    local role, n = kind:match('^([BC])(%d)$');
    if role == nil then return; end
    local name, what, ends = body:match('^%s*(%a+) %a+ (.-); P1>P2>P3; then (%a+)');
    if name == nil then return; end
    local a, b = what:match('^(.-) %+ (.*)$');
    local e = { role = (role == 'B') and 'BRD' or 'COR', n = tonumber(n), name = cap(name), a = a or what, b = b or '', stay = ends == 'stays' };
    for i = #z.list, 1, -1 do
        if z.list[i].role == e.role and z.list[i].n == e.n then table.remove(z.list, i); end
    end
    z.list[#z.list + 1] = e;
    if e.name == raid.my_name() then
        z.me = e;
        say(('Zerg: you are %s %d: %s + %s, party 1 > 2 > 3, then %s.'):format(e.role, e.n, e.a, e.b,
            e.stay and 'stay in party 3' or 'leave the alliance'));
        if raid.events.on_zerg then raid.events.on_zerg(z); end
    end
    store.save();
end

--------------------------------------------------------------------------------
-- Incoming chat. Returns true when the line should be hidden.
--------------------------------------------------------------------------------
local handle_text;
local err_at = -100;

--- Incoming chat, protected: a line the addon cannot handle (from a newer or older copy, or just
--- garbled) is skipped, never stops the addon. Returns true when the line should be hidden.
function raid.on_text(message)
    local ok, res = pcall(handle_text, message);
    if ok then return res; end
    if os.clock() - err_at > 30 then   -- say so at most every 30 s
        err_at = os.clock();
        warn('Skipped a chat line it could not read (a different addon version?): ' .. tostring(res):sub(1, 120));
    end
    return false;
end

handle_text = function (message)
    if store.me == nil then return false; end
    local line = tostring(message or ''):gsub('\253[^\253]*\253', ''):gsub('[\30\31\127].', '');
    local hide = store.me.cfg.hide_proto;

    -- the game refused a line (sent too soon after another): send it again
    if line:find('A command error occurred', 1, true) then resend_refused(); return false; end
    if line:find('Your tell was not received', 1, true) then tell_missed(); return false; end

    -- the bot: "Name>> !rr ..." (an incoming tell)
    local sender, rest = line:match('(%a+)>>%s*(![Rr][Rr].*)$');
    if sender then
        bot(cap(sender), '!rr' .. rest:sub(4));
        return hide and raid.get() ~= nil;
    end
    -- the bot in party chat too: "(Name) !rr help" / "(Name) !rr WHM/SCH" (answered by tell, not in chat)
    sender, rest = line:match('^%s*%((%a+)%)%s*(![Rr][Rr].*)$');
    if sender and cap(sender) ~= raid.my_name() then
        bot(cap(sender), '!rr' .. rest:sub(4));
        return false;
    end
    if line:find('[RR] ', 1, true) then
        return hide and line:find('^%s*>>') ~= nil;   -- our own bot replies, echoed back
    end

    local s, e, kind, fields = line:find('%[RR:(%u+):([^%]]*)%]');
    if not s then return false; end
    local body = line:sub(e + 1);
    local f = {};
    for v in (fields .. ':'):gmatch('([^:]*):') do f[#f + 1] = v; end

    if kind == 'POLL' then
        on_poll(f[1], f[2], f[3], line:find('>>', 1, true) ~= nil);
    elseif kind == 'POST' then
        on_post(f[1], f[2], f[3]);
    elseif kind == 'ASG' then
        local pn, plus = (f[2] or ''):match('^(%d)(%+?)$');
        if pn then on_asg(f[1], tonumber(pn), plus == '+', body); end
    elseif kind == 'YOU' then
        local lead = line:match('(%a+)>>');
        if lead then on_you(f[1], lead, tonumber(f[2]), f[3], f[4] or '', body); end
    elseif kind == 'ZRG' then
        on_zrg(f[1], f[2], f[3] or '', body);
    elseif kind == 'UNA' then
        on_una(f[1], f[2] == '+', body);
    elseif kind == 'SBY' then
        on_sby(f[1], f[2] == '+', body);
    elseif kind == 'STB' then
        local lead = line:match('(%a+)>>');
        if lead then on_stb(f[1], lead, f[2], f[3] or '', f[4] or '', body); end
    elseif kind == 'REG' then
        -- from a tell ("Name>> ...") or party chat ("(Name) ..."), and only for the sender themself
        local from = line:match('(%a+)>>') or line:match('%((%a+)%)');
        if from and cap(from) == cap(f[2]) then on_reg(f[1], f[2], f[3], body, ver_of(f[4])); end
        return hide;
    elseif kind == 'ACK' then
        if line:match('(%a+)>>') then on_ack(f[1], f[2], ver_of(f[3])); end
        return hide;
    end
    return false;
end

--------------------------------------------------------------------------------
-- Once a second: noticing an alliance being joined
--------------------------------------------------------------------------------
local was_ally = nil;
function raid.watch()
    if store.me == nil then return; end
    local now = raid.in_alliance();
    if was_ally == false and now and store.me.cfg.check_join and raid.pending == nil then
        local m = raid.mine();
        raid.pending = { join = true, id = m and m.id, leader = m and m.leader, fight = m and m.fight };
        if raid.events.on_poll then raid.events.on_poll(raid.pending); end
    end
    was_ally = now;
end

return raid;
