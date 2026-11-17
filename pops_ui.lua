--[[
raidroles - the Pop Rolls pages (vcmenu), drawn inside the main window.

    Pop Rolls     the roll window (60 s countdown, Stop / Cancel, live rolls) and the pop order:
                  call up, next, back, pops each, a pop count per person, add / move / remove
    Pop History   past roll calls: use one again, or post it
    settings()    the POP ROLLS section of the Settings page
    help()        the POP ROLLS section of the Help page
--]]

require('common');
local imgui = require('imgui');
local vc    = require('vcmenu');
local store = require('store');
local pops  = require('pops');

local C = vc.colors;
local pui = {};

local win = nil;   -- the main window's state (pui.init)
local buf_name, buf_roll, buf_spot = { '' }, { '' }, { '' };
local buf_start, buf_end = { '' }, { '' };

local SEL_OVERLAP = ImGuiSelectableFlags_AllowOverlap or ImGuiSelectableFlags_AllowItemOverlap or 16;

local function z(n) return vc.z(n); end
local function tip(t) if imgui.IsItemHovered() then imgui.SetTooltip(t); end end

local function input(id, buf, w, hint, size)
    pcall(imgui.PushItemWidth, w and z(w) or -1);
    local ok, edited;
    if hint then ok, edited = pcall(imgui.InputTextWithHint, id, hint, buf, size or 64); end
    if not ok then ok, edited = pcall(imgui.InputText, id, buf, size or 64); end
    pcall(imgui.PopItemWidth);
    return ok and edited;
end

local function big(text, col, px)
    if vc.has_fonts() then
        vc.in_font('bi', px or 30, function() imgui.TextColored(col or C.text, text); end);
    else
        pcall(imgui.SetWindowFontScale, 1.8 * vc.scale());
        imgui.TextColored(col or C.text, text);
        pcall(imgui.SetWindowFontScale, vc.scale());
    end
end

--- A small icon button: 'up', 'down', 'minus', 'plus' or 'x'. Returns clicked (never while disabled).
local function glyph_button(id, kind, enabled, tiptext)
    local s = z(22);
    local x, y = vc.screen_pos();
    local hit = imgui.InvisibleButton('##pgb' .. id, { s, s });
    local hov = imgui.IsItemHovered();
    pcall(function()
        local dl = imgui.GetWindowDrawList();
        if hov and enabled then dl:AddRectFilled({ x, y }, { x + s, y + s }, vc.u32({ 1, 1, 1, 0.08 }), z(4)); end
        local c;
        if not enabled then c = vc.alpha(C.mute, 0.35);
        elseif kind == 'x' then c = hov and C.bad or C.dim;
        else c = hov and C.text or C.acc; end
        c = vc.u32(c);
        local cx, cy, e = x + s / 2, y + s / 2, z(4.5);
        if kind == 'up' then
            dl:AddTriangleFilled({ cx, cy - e }, { cx + e, cy + e * 0.7 }, { cx - e, cy + e * 0.7 }, c);
        elseif kind == 'down' then
            dl:AddTriangleFilled({ cx - e, cy - e * 0.7 }, { cx + e, cy - e * 0.7 }, { cx, cy + e }, c);
        elseif kind == 'minus' or kind == 'plus' then   -- in a round frame, as a stepper
            dl:AddCircle({ cx, cy }, s / 2 - z(2), c, 16, 1.2);
            dl:AddLine({ cx - e * 0.8, cy }, { cx + e * 0.8, cy }, c, 1.6);
            if kind == 'plus' then dl:AddLine({ cx, cy - e * 0.8 }, { cx, cy + e * 0.8 }, c, 1.6); end
        else
            dl:AddLine({ cx - e, cy - e }, { cx + e, cy + e }, c, 1.5);
            dl:AddLine({ cx - e, cy + e }, { cx + e, cy - e }, c, 1.5);
        end
    end);
    if hov and enabled and tiptext then imgui.SetTooltip(tiptext); end
    return hit and enabled;
end

--------------------------------------------------------------------------------
-- Pop Rolls
--------------------------------------------------------------------------------
local function status_block()
    local cfg = pops.cfg();
    local s = pops.session;
    if s then
        local left = pops.left();
        -- the countdown: 60, 59, 58 ... with Stop right beside it
        big(tostring(math.ceil(left)), left <= 10 and C.bad or C.gold, 34);
        imgui.SameLine(0, z(6));
        imgui.TextColored(C.dim, 'sec');
        imgui.SameLine(0, z(18));
        if vc.button('Stop', 'primary', 90) then pops.close(false); end
        tip('Stop the timer now and make these rolls the pop order');
        imgui.SameLine();
        if vc.button('Cancel', 'danger') then pops.cancel(); end
        tip('Stop without saving: the pop order stays as it was');
        imgui.SameLine(0, z(18));
        imgui.TextColored(C.dim, ('%d roll%s in'):format(#s.list, #s.list == 1 and '' or 's'));
        vc.progress(left / s.length);
        return;
    end

    local o = pops.data().order;
    local i = pops.current();
    local goal = pops.goal();
    if #o == 0 then
        imgui.TextColored(C.dim, 'No pop order yet. Start rolls, or add people by hand below.');
    elseif i then
        local head = ('UP NEXT  -  #%d of %d'):format(i, #o);
        if goal > 1 then head = head .. ('  -  pop %d of %d'):format(pops.count(o[i]) + 1, goal); end
        imgui.TextColored(C.mute, head);
        big(o[i].name, C.gold, 28);
        local d = pops.on_deck(i);
        if d then
            imgui.SameLine(0, z(16));
            imgui.TextColored(C.dim, 'on deck:');
            imgui.SameLine();
            imgui.TextColored(C.text, o[d].name);
        end
    else
        big(goal == 1 and 'Everyone has popped' or ('Everyone has popped %d times'):format(goal), C.good, 24);
    end
    imgui.Dummy({ 1, z(2) });

    if vc.button(('Start rolls (%ds)'):format(cfg.duration), 'primary') then pops.start(); end
    tip(('Posts "%s" in %s and records every /random for %d seconds'):format(
        tostring(cfg.start_msg):gsub('%%d', tostring(cfg.duration)), pops.channel_name(cfg.channel), cfg.duration));
    if #o > 0 then
        imgui.SameLine();
        if vc.button('Call up') then pops.call(); end
        tip('Posts who is up to pop, and who is on deck');
        imgui.SameLine();
        if vc.button('Next') then pops.next(); end
        tip(cfg.call_next and 'Gives the person up one pop and posts who is up next' or 'Gives the person up one pop');
        imgui.SameLine();
        if vc.button('Back') then pops.back(); end
        tip('Takes back the last pop given with Next');
    end

    -- pops each: the order goes round until everyone has this many
    imgui.SameLine(0, z(24));
    pcall(imgui.AlignTextToFramePadding);
    imgui.TextColored(C.dim, 'Pops each');
    imgui.SameLine(0, z(8));
    if glyph_button('goal-', 'minus', goal > 1, 'One less pop each') then pops.set_goal(goal - 1); end
    imgui.SameLine(0, z(6));
    imgui.TextColored(C.text, tostring(goal));
    imgui.SameLine(0, z(6));
    if glyph_button('goal+', 'plus', goal < 99, 'One more pop each') then pops.set_goal(goal + 1); end
end

local function add_row()
    local s = pops.session;
    vc.section('ADD SOMEONE');
    input('##pop_name', buf_name, 150, 'Name');
    imgui.SameLine();
    input('##pop_roll', buf_roll, 70, 'Roll');
    tip(s and 'Their roll (needed while rolls are open)' or 'Their roll (optional)');
    if not s then
        imgui.SameLine();
        input('##pop_spot', buf_spot, 60, 'Spot');
        tip('Where in the order: 1 is the top (blank = the bottom)');
    end
    imgui.SameLine();
    if vc.button('Add##pop_add', 'primary') then
        if pops.add(buf_name[1], buf_roll[1], buf_spot[1]) then buf_name[1], buf_roll[1], buf_spot[1] = '', '', ''; end
    end
end

local COL = { num = 10, name = 42, roll = 196, pop = 250 };

local function order_list()
    local s = pops.session;
    local list = pops.list();
    local cur = (s == nil) and pops.current() or nil;
    local goal = pops.goal();
    vc.section(s and 'LIVE ROLLS' or 'POP ORDER', tostring(#list));

    local x0 = imgui.GetCursorPosX();
    imgui.SetCursorPosX(x0 + z(COL.num + 4)); imgui.TextColored(C.mute, '#');
    imgui.SameLine(x0 + z(COL.name + 4));     imgui.TextColored(C.mute, 'Name');
    imgui.SameLine(x0 + z(COL.roll + 4));     imgui.TextColored(C.mute, 'Roll');
    if s == nil then imgui.SameLine(x0 + z(COL.pop + 4)); imgui.TextColored(C.mute, 'Pops'); end

    local act = nil;   -- one edit per frame, applied after the list is drawn
    vc.list('##pop_order', 44, function ()
        local lx = imgui.GetCursorPosX();
        local w  = vc.avail_w();
        local rh = z(30);
        local fh = imgui.GetFontSize();
        local dl = imgui.GetWindowDrawList();
        for i, e in ipairs(list) do
            local y = imgui.GetCursorPosY();
            local sx, sy = vc.screen_pos();
            imgui.Selectable('##prow' .. i, false, SEL_OVERLAP, { 0, rh });
            if i == cur then   -- the person up next: the accent row, as vc.row's selected
                pcall(function()
                    dl:AddRectFilled({ sx, sy + 1 }, { sx + w, sy + rh - 1 }, vc.u32(vc.alpha(C.acc, 0.13)), z(5), 0);
                    dl:AddRectFilled({ sx + 1, sy + z(6) }, { sx + z(4), sy + rh - z(6) }, vc.u32(C.acc), 1, 0);
                end);
            end
            local n = (s == nil) and pops.count(e) or 0;
            local done = (s == nil) and n >= goal;
            local col = C.text;
            if done then col = C.mute; elseif i == cur or (s and i == 1) then col = C.gold; end
            local ty = y + (rh - fh) / 2;
            local function at(cx, t, c) imgui.SetCursorPos({ lx + z(cx), ty }); imgui.TextColored(c, t); end
            at(COL.num, tostring(i), done and C.mute or C.dim);
            at(COL.name, vc.fit_text(e.name, z(COL.roll - COL.name - 8)), col);
            at(COL.roll, e.roll and tostring(e.roll) or '-', done and C.mute or C.text);
            if s == nil then   -- the pop count: - n / goal +
                local by0 = y + (rh - z(22)) / 2;
                imgui.SetCursorPos({ lx + z(COL.pop), by0 });
                if glyph_button('pm' .. i, 'minus', n > 0, 'One less pop for ' .. e.name) then act = { 'count', i, n - 1 }; end
                local txt = (goal > 1) and ('%d/%d'):format(n, goal) or tostring(n);
                local tw = vc.xy(imgui.CalcTextSize(txt));
                imgui.SetCursorPos({ lx + z(COL.pop + 44) - tw / 2, ty });
                imgui.TextColored(done and C.good or (n > 0 and C.text or C.mute), txt);
                imgui.SetCursorPos({ lx + z(COL.pop + 66), by0 });
                if glyph_button('pp' .. i, 'plus', n < 99, 'One more pop for ' .. e.name) then act = { 'count', i, n + 1 }; end
            end

            local by = y + (rh - z(22)) / 2;
            local bx = lx + w - z(s and 30 or 82);
            if s == nil then
                imgui.SetCursorPos({ bx, by });
                if glyph_button('u' .. i, 'up', i > 1, 'Move up') then act = { 'move', i, i - 1 }; end
                imgui.SetCursorPos({ bx + z(26), by });
                if glyph_button('d' .. i, 'down', i < #list, 'Move down') then act = { 'move', i, i + 1 }; end
                bx = bx + z(52);
            end
            imgui.SetCursorPos({ bx, by });
            if glyph_button('x' .. i, 'x', true, 'Remove ' .. e.name) then act = { 'remove', i }; end
            imgui.SetCursorPos({ lx, y + rh });
        end
        if #list == 0 then
            imgui.SetCursorPos({ lx + z(10), imgui.GetCursorPosY() + z(8) });
            imgui.TextColored(C.mute, s and 'Waiting for rolls...' or 'Nobody in the pop order yet.');
        end
        imgui.Dummy({ 0, 0 });
    end);

    if act then
        if act[1] == 'move' then pops.move(act[2], act[3]);
        elseif act[1] == 'count' then pops.set_count(act[2], act[3]);
        elseif act[1] == 'remove' then pops.remove(act[2]); end
    end

    -- under the list
    imgui.Dummy({ 1, z(2) });
    if vc.button(s and 'Post rolls so far' or 'Post order') then pops.post_order(); end
    tip('Posts the whole list in ' .. pops.channel_name(pops.cfg().channel));
    if s == nil and #list > 0 then
        imgui.SameLine();
        if vc.button('Sort by roll') then pops.sort(); end
        tip('Puts everyone back in roll order (highest first; no roll last)');
        imgui.SameLine();
        if vc.button('Reset pops') then pops.reset(); end
        tip('Puts everyone back to 0 pops, to run the order again');
        imgui.SameLine();
        if vc.button('Clear##pop_clear', 'danger') then imgui.OpenPopup('##pop_clear_q'); end
        tip('Empties the pop order');
    end
    if imgui.BeginPopup('##pop_clear_q') then
        imgui.Text('Empty the whole pop order?');
        if vc.button('Clear it', 'danger') then pops.clear(); imgui.CloseCurrentPopup(); end
        imgui.SameLine();
        if vc.button('Keep it') then imgui.CloseCurrentPopup(); end
        imgui.EndPopup();
    end
end

function pui.page_pops()
    local d = pops.data();
    local sub;
    if pops.session then sub = 'rolls are open';
    elseif d.order_time > 0 then sub = 'rolled ' .. os.date('%m/%d  %H:%M', d.order_time);
    else sub = 'a /random roll call for the pop order'; end
    vc.title('Pop Rolls', sub);
    status_block();
    add_row();
    order_list();
end

--------------------------------------------------------------------------------
-- Pop History
--------------------------------------------------------------------------------
function pui.page_history()
    local h = pops.data().history;
    vc.title('Pop History', ('the last %d roll calls'):format(pops.HISTORY_MAX));
    if #h == 0 then
        vc.note('Every Pop Rolls roll call you close is kept here. Use one to make it the pop order again.');
        return;
    end
    local del = nil;
    for k, rec in ipairs(h) do
        vc.section(os.date('%a %m/%d  %H:%M', tonumber(rec.time) or 0), ('%d rolls'):format(#(rec.list or {})));
        local parts = {};
        for i, e in ipairs(rec.list or {}) do
            parts[#parts + 1] = e.roll and ('%d. %s (%d)'):format(i, e.name, e.roll) or ('%d. %s'):format(i, e.name);
        end
        imgui.PushStyleColor(ImGuiCol_Text, C.dim);
        pcall(imgui.PushTextWrapPos, 0);
        imgui.Text(table.concat(parts, '     '));
        pcall(imgui.PopTextWrapPos);
        imgui.PopStyleColor(1);
        if vc.button('Use this order##phu' .. k) then pops.use_history(rec); if win then win.page = 'pops'; end end
        tip('Makes this the pop order again (everyone at 0 pops)');
        imgui.SameLine();
        if vc.button('Post it##php' .. k) then pops.post_order(nil, rec.list or {}); end
        tip('Posts this order in ' .. pops.channel_name(pops.cfg().channel));
        imgui.SameLine();
        if vc.button('Delete##phd' .. k, 'danger') then del = k; end
    end
    if del then table.remove(h, del); store.save(); end
    imgui.Dummy({ 1, z(6) });
    vc.note('Every roll call is also written to config/addons/raidroles/pop_history.txt.');
end

--------------------------------------------------------------------------------
-- Settings and Help sections
--------------------------------------------------------------------------------
--- The POP ROLLS section of the Settings page. Saves on its own.
function pui.settings()
    local cfg = pops.cfg();
    local changed = false;
    vc.section('POP ROLLS');
    vc.label_row('Post roll calls and pop calls to', 420);
    local v = vc.seg('popchan', pops.CHANNELS, cfg.channel);
    if v then cfg.channel = v; changed = true; end
    vc.label_row('Rolls stay open for', 200);
    v = vc.slider('popdur', cfg.duration, 15, 180, 5, '%d s', 150);
    if v then cfg.duration = math.floor(v); changed = true; end
    vc.label_row('Pops each person gets', 200);
    v = vc.slider('popseach', pops.goal(), 1, 10, 1, '%d', 150);
    if v then cfg.pops_each = math.floor(v); changed = true; end
    v = vc.switch_row('popcount', 'Post "30 / 10 seconds left"', cfg.countdown);
    if v ~= nil then cfg.countdown = v; changed = true; end
    v = vc.switch_row('popfirst', 'First roll only (rerolls are ignored)', cfg.first_only);
    if v ~= nil then cfg.first_only = v; changed = true; end
    v = vc.switch_row('popauto', 'Post the pop order when the rolls close', cfg.auto_post);
    if v ~= nil then cfg.auto_post = v; changed = true; end
    v = vc.switch_row('popnext', 'Next also posts who is up', cfg.call_next);
    if v ~= nil then cfg.call_next = v; changed = true; end
    vc.label_row('When rolls open', 330);
    if input('##pop_start_msg', buf_start, 330, 'Start your rolls!', 120) then cfg.start_msg = buf_start[1]; changed = true; end
    vc.label_row('When rolls close', 330);
    if input('##pop_end_msg', buf_end, 330, 'Rolls are closed!', 120) then cfg.end_msg = buf_end[1]; changed = true; end
    vc.note('%d in the opening message becomes the number of seconds. Leave a message empty to post nothing. Lines go out with the delay above.');
    if changed then store.save(); end
end

--- The POP ROLLS section of the Help page.
function pui.help()
    vc.section('POP ROLLS');
    vc.note('1. Start rolls posts "Start your rolls!" (Settings: channel and message) and records every /random while the 60 second countdown runs. Stop ends it early; Cancel ends it without changing the order.');
    vc.note('2. The rolls become the pop order, highest first. A tie goes to whoever rolled first.');
    vc.note('3. Call up posts who is up and who is on deck. Next gives them a pop and posts the next person. Back takes that pop back.');
    vc.note('4. Pops each (- / +) is how many pops everyone gets: the order goes round (fewest pops is up next, top of the order first) until everyone has that many. The - / + in the Pops column change anyone\'s count.');
    vc.note('5. Add someone (roll and spot optional), the arrows move people, x removes them. Pop History keeps the last 25 roll calls.');
end

pui.COMMANDS = {
    { '/pops  (/roles pops)', 'open Pop Rolls' },
    { '/pops start [sec] | stop | cancel', 'open rolls, stop the timer, cancel' },
    { '/pops call | next | back', 'who is up | give a pop, call next | undo' },
    { '/pops post [p|l|l2|s|sh]', 'post the pop order' },
    { '/pops each <n>  |  count <name> <n>', 'pops each person gets | set a count' },
    { '/pops add <name> [roll] [spot]', 'add someone' },
    { '/pops remove <name> | move <name> <spot>', 'take out | move' },
    { '/pops sort | reset | clear | history', 'by roll | 0 pops | empty | past roll calls' },
};

--------------------------------------------------------------------------------
function pui.init(main_win)
    win = main_win;
    local cfg = pops.cfg();
    buf_start[1] = tostring(cfg.start_msg or '');
    buf_end[1]   = tostring(cfg.end_msg or '');
    pops.events.on_start = function () if win then win.open[1] = true; win.page = 'pops'; end end
end

--- Header text while rolls are open (else nil).
function pui.header()
    if pops.session then return ('Pop rolls open  %d s'):format(math.ceil(pops.left())), C.gold; end
    return nil;
end

return pui;
