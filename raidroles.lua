addon.name    = 'raidroles';
addon.author  = 'Benthere';
addon.version = '1.0.0';
addon.desc    = 'Raid / alliance job sign-up and party assignment: members register the jobs they can play, leaders build the parties and post them.';

require('common');
local chat  = require('chat');
local data  = require('data');
local store = require('store');
local raid  = require('raid');
local ui    = require('ui');

local ready = false;      -- the character's file is loaded
local next_second = 0;

local function try_ready()
    if ready then return true; end
    local name = raid.my_name();
    if name == nil then return false; end
    if store.fights == nil then store.load_fights(); end
    if store.load_char(name) then
        ui.init();
        ready = true;
    end
    return ready;
end

ashita.events.register('load', 'raidroles_load', function ()
    math.randomseed(os.time());
    store.load_fights();
    try_ready();
end);

ashita.events.register('unload', 'raidroles_unload', function ()
    if ready then store.save(); end
end);

ashita.events.register('d3d_present', 'raidroles_present', function ()
    if not try_ready() then return; end
    raid.tick();
    local now = os.clock();
    if now >= next_second then
        next_second = now + 1;
        pcall(raid.watch);
    end
    ui.render();
end);

ashita.events.register('text_in', 'raidroles_text_in', function (e)
    if not ready or e.injected then return; end
    local ok, hide = pcall(raid.on_text, e.message);
    if ok and hide then e.blocked = true; end
    if not ok then print(chat.header('raidroles'):append(chat.error(tostring(hide)))); end
end);

local function help()
    raid.say('/roles (or /raid, /raidroles)  - open the window.   /roles jobs WHM.B/SCH/RDM BLM/WHM  - jobs best first, .B/.G/.T gear, /subjobs.   /roles reply  - answer the raid check.   /roles me  - your assignment.');
    raid.say('Leader: /roles fight <name>, /roles check, /roles auto, /roles post, /roles nudge, /roles add <name> <jobs>, /roles board, /roles roll.');
end

ashita.events.register('command', 'raidroles_command', function (e)
    local args = e.command:args();
    if #args == 0 then return; end
    local c = args[1]:lower();
    if c ~= '/roles' and c ~= '/raidroles' and c ~= '/raid' then return; end   -- (/rr is the Reraise alias)
    e.blocked = true;
    if not try_ready() then raid.warn('Not logged in yet.'); return; end

    local sub = (args[2] or ''):lower();
    local rest = table.concat(args, ' ', 3);
    if sub == '' then
        ui.toggle();
    elseif sub == 'help' then
        help();
    elseif sub == 'jobs' then
        local jobs, subs, gear = data.parse_signup(rest);
        if #jobs == 0 then
            raid.say('Your jobs: ' .. (#store.me.jobs > 0 and data.signup_pretty(store.me.jobs, store.me.subs, store.me.gear) or '(none)'));
        else
            store.me.jobs, store.me.subs, store.me.gear = jobs, subs, gear;
            if raid.get() then raid.add_self(); end
            store.save();
            raid.say('Saved your jobs: ' .. data.signup_pretty(store.me.jobs, store.me.subs, store.me.gear));
        end
    elseif sub == 'reply' then
        if raid.pending then raid.reply(); else raid.warn('No raid check to answer.'); end
    elseif sub == 'me' then
        local m = raid.mine();
        if m and m.party then
            raid.say(('%s: Party %d (%s) as %s - leader %s'):format(m.fight or 'Raid', m.party, m.label or '', m.job or '?', m.leader or '?'));
            ui.show_banner();
        else
            raid.say('No assignment yet.');
        end
    elseif sub == 'fight' or sub == 'start' then
        local want = rest:lower();
        local pick = nil;
        for _, f in ipairs(store.fights) do
            if want == '' or f.name:lower() == want then pick = f; break; end
        end
        if pick == nil then
            for _, f in ipairs(store.fights) do if f.name:lower():find(want, 1, true) then pick = f; break; end end
        end
        if pick == nil then raid.warn('No fight called ' .. rest); return; end
        if raid.get() then raid.use_fight(pick); else raid.start(pick, false); end
        raid.say('Raid board: ' .. pick.name);
        ui.toggle('board');
    elseif sub == 'check' or sub == 'poll' then
        raid.poll();
    elseif sub == 'auto' then
        raid.auto(); raid.say('Auto-filled the board.');
    elseif sub == 'post' then
        raid.post();
    elseif sub == 'nudge' then
        raid.nudge();
    elseif sub == 'add' then
        local name = args[3];
        local jobs, subs, gear = data.parse_signup(table.concat(args, ' ', 4));
        if name == nil or #jobs == 0 then raid.warn('/roles add <name> WHM.B/SCH/RDM BLM/WHM ...'); return; end
        if raid.register(name, jobs, 'manual', false, subs, gear) then raid.say(('Added %s: %s'):format(raid.cap(name), data.signup_pretty(jobs, subs, gear))); end
    elseif sub == 'board' then
        ui.toggle('board');
    elseif sub == 'roll' then
        ui.toggle('roll');
    elseif sub == 'end' then
        raid.end_session(); raid.say('Raid ended.');
    else
        help();
    end
end);
