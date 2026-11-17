addon.name    = 'raidroles';
addon.author  = 'Benthere';
addon.version = '1.2.0';   -- keep in step with data.VERSION
addon.desc    = 'Raid / alliance job sign-up and party assignment: members register the jobs they can play, leaders build the parties and post them.';

require('common');
local chat  = require('chat');
local data  = require('data');
local store = require('store');
local raid  = require('raid');
local pops  = require('pops');
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
    if ready then
        if pops.session then pcall(pops.close, true); end
        store.save();
    end
end);

ashita.events.register('d3d_present', 'raidroles_present', function ()
    if not try_ready() then return; end
    raid.tick();
    pcall(pops.tick);
    local now = os.clock();
    if now >= next_second then
        next_second = now + 1;
        pcall(raid.watch);
    end
    ui.render();
end);

ashita.events.register('text_in', 'raidroles_text_in', function (e)
    if not ready or e.injected then return; end
    pcall(pops.on_text, e.message);
    local ok, hide = pcall(raid.on_text, e.message);
    if ok and hide then e.blocked = true; end
    if not ok then print(chat.header('raidroles'):append(chat.error(tostring(hide)))); end
end);

local function help()
    raid.say('/roles (or /raid, /raidroles)  - open the window.   /roles jobs WHM.B/SCH/RDM BLM/WHM  - jobs best first, .B/.G/.T gear, /subjobs.   /roles reply  - answer the raid check.   /roles me  - your assignment.');
    raid.say('Leader: /roles fight <name>, /roles check, /roles auto, /roles post, /roles nudge, /roles add <name> <jobs>, /roles board, /roles roll.');
    raid.say('Pop Rolls: /pops (or /roles pops)  - open.   /pops start [sec] | stop | cancel | call | next | back | post [p|l|l2|s|sh] | each <n> | count <name> <n> | add <name> [roll] [spot] | remove <name> | move <name> <spot> | sort | reset | clear | history');
end

--- /pops ... (also /roles pops ...): the Pop Rolls commands. args = the words after 'pops'.
local function pops_command(args)
    local sub = (args[1] or ''):lower();
    if sub == '' then
        ui.toggle('pops');
    elseif sub == 'start' or sub == 'go' then
        pops.start(args[2]);
    elseif sub == 'stop' or sub == 'close' then
        if pops.session then pops.close(false); else raid.warn('Pop rolls are not open.'); end
    elseif sub == 'cancel' then
        pops.cancel();
    elseif sub == 'post' or sub == 'say' then
        pops.post_order(args[2] and (args[2]:lower():gsub('^/', '')) or nil);
    elseif sub == 'call' then
        pops.call();
    elseif sub == 'next' then
        pops.next();
    elseif sub == 'back' then
        pops.back();
    elseif sub == 'each' or sub == 'goal' then
        if args[2] then pops.set_goal(args[2]); end
        raid.say(('Pops each: %d'):format(pops.goal()));
    elseif sub == 'count' then
        local i, e = pops.find(args[2] or '');
        local n = tonumber(args[3]);
        if pops.session then raid.warn('Set pop counts once the rolls close.');
        elseif i and n then pops.set_count(i, n); raid.say(('%s: %d pop(s).'):format(e.name, pops.count(e)));
        else raid.warn('/pops count <name> <number>'); end
    elseif sub == 'add' then
        if args[2] == nil then raid.warn('/pops add <name> [roll] [spot]'); return; end
        pops.add(args[2], args[3], args[4]);
    elseif sub == 'remove' or sub == 'del' then
        local i, e = pops.find(args[2] or '');
        if i then pops.remove(i); raid.say('Removed ' .. e.name .. '.'); else raid.warn('Not in the list: ' .. tostring(args[2])); end
    elseif sub == 'move' then
        local i, e = pops.find(args[2] or '');
        local to = tonumber(args[3]);
        if pops.session then raid.warn('Move people once the rolls close.');
        elseif i and to then pops.move(i, to); raid.say(('Moved %s to #%d.'):format(e.name, math.max(1, math.min(#pops.data().order, to))));
        else raid.warn('/pops move <name> <spot>'); end
    elseif sub == 'sort' then
        pops.sort();
    elseif sub == 'reset' then
        pops.reset(); raid.say('Everyone is back to 0 pops.');
    elseif sub == 'clear' then
        pops.clear(); raid.say('Pop order cleared.');
    elseif sub == 'history' then
        ui.toggle('pophist');
    else
        help();
    end
end

ashita.events.register('command', 'raidroles_command', function (e)
    local args = e.command:args();
    if #args == 0 then return; end
    local c = args[1]:lower();
    if c ~= '/roles' and c ~= '/raidroles' and c ~= '/raid' and c ~= '/pops' then return; end   -- (/rr is the Reraise alias)
    e.blocked = true;
    if not try_ready() then raid.warn('Not logged in yet.'); return; end

    if c == '/pops' then pops_command({ select(2, unpack(args)) }); return; end
    local sub = (args[2] or ''):lower();
    local rest = table.concat(args, ' ', 3);
    if sub == 'pops' then pops_command({ select(3, unpack(args)) }); return; end
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
