--[[
  IRC client - entry + UI. The protocol engine (core.lua) lives in the
  background record and keeps running while other Lua apps are open; this
  file only renders it.

  Layout follows the Messenger: a fixed header (title left, status right)
  over a body holding a row of control buttons and a scroll list.
  Views: networks (home) -> network page (its buffers + Menu) -> chat ->
  members / channel info / whois card; plus network editor, certificate
  trust, settings and raw console. Row lists use nav.list (a tap/click on the list arms trackball
  row-select, 'q' leaves it) and nav.scroll_aware (a tap opens a row, a
  drag scrolls). Actions live in popups (dim layer + nav.push, pop before
  delete); view refreshes are held while a popup is open.

  Chat lines are Spangroups (time, nick, then the text wrapping under the
  full width); holding a line opens its action menu (line_menu). The
  chat's third button shows the topic (tap: full topic) or, while scrolled
  up with newer lines below, "N new - jump". Scrolling to the top of a
  chat asks the server for older lines (CHATHISTORY, engine side).
]]

local lvgl = require("lvgl")
local apps = require("lib/apps")
local nav = require("lib/nav")
local utils = require("lib/utils")
local clipboard = require("lib/clipboard")

local app_dir = ...

local function loadmod(name)
    local f = io.open(app_dir .. "/" .. name .. ".lua", "r")
    if not f then error("IRC: missing " .. name .. ".lua") end
    local src = f:read("*a")
    f:close()
    local chunk, err = load(src, "@" .. name .. ".lua")
    if not chunk then error(err) end
    return chunk()
end

-- ── engine rendezvous ────────────────────────────────────────────────────────

local rec = apps.background_of("irc")
local R = rec and rec.state or nil
if not (R and R.engine and R.mods) then
    local cfg0 = loadmod("cfg")
    local parse0 = loadmod("parse")
    local cmds0 = loadmod("cmds")
    local corelib = loadmod("core")
    local E0 = corelib.new { cfg = cfg0, parse = parse0, cmds = cmds0 }
    R = { engine = E0, mods = { cfg = cfg0, parse = parse0, cmds = cmds0 } }
end
local E = R.engine
local cfg = R.mods.cfg
local parse = R.mods.parse

apps.register_background {
    key = "irc",
    app_name = "IRC",
    state = R,
    period = 250,
    tick = E.tick,
    on_close = E.quit_all,
    -- The engine outlives this UI, and E.ui_* are closures over `root`, which
    -- the manager deletes on the way out. Neutralise them until a relaunch
    -- reinstalls them (main.lua assigns all three at load). They stay
    -- FUNCTIONS, not nil: cmds.lua calls E.ui_open unguarded.
    on_background = function()
        local function ignore() end
        E.ui_open, E.ui_whois, E.ui_list = ignore, ignore, ignore
    end,
    status = E.status,
}

-- ── palette ──────────────────────────────────────────────────────────────────
-- Every UI color comes from the theme palette. text/grey/accent_text are
-- calibrated for the scr/card grounds; button labels use the theme's
-- btn_text, with highlight as the one emphasis color guaranteed readable on
-- a button fill. A nil (palette unavailable) leaves the property unset, so
-- the theme's defaults apply. The one exception is the chat message area in
-- true-IRC-color mode (Settings), which uses the IRC palette below.

local pal
do
    local ok, p = pcall(function() return require("lib/theme").palette() end)
    pal = ok and p or {}
end
local COL_TEXT = pal.text
local COL_ACC  = pal.accent_text
local COL_HI   = pal.highlight
local COL_BTN  = pal.btn_text
local COL_SCR  = pal.scr
local COL_CARD = pal.card
local COL_BORD = pal.grey

-- Theme nick colors: five blends from the theme's text color toward its
-- accent_text.
local NICKCOLS = {}
do
    local function rgb(hex)
        if type(hex) ~= "string" then return nil end
        local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
        if not r then return nil end
        return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
    end
    local r1, g1, b1 = rgb(pal.text)
    local r2, g2, b2 = rgb(pal.accent_text)
    if r1 and r2 then
        for k = 1, 5 do
            local t = k / 5
            NICKCOLS[k] = string.format("#%02X%02X%02X",
                math.floor(r1 + (r2 - r1) * t + 0.5),
                math.floor(g1 + (g2 - g1) * t + 0.5),
                math.floor(b1 + (b2 - b1) * t + 0.5))
        end
    end
end

-- IRC color codes 00-98. 00-15: mIRC's default palette
-- (mirc.com/colors.html); 16-98: modern.ircdocs.horse/formatting.html.
-- 99 = default color (not in the table).
local IRC_COLORS = {
    [0] = "#FFFFFF",
    -- 01-15
    "#000000", "#00007F", "#009300", "#FF0000", "#7F0000", "#9C009C",
    "#FC7F00", "#FFFF00", "#00FC00", "#009393", "#00FFFF", "#0000FC",
    "#FF00FF", "#7F7F7F", "#D2D2D2",
    -- 16-27
    "#470000", "#472100", "#474700", "#324700", "#004700", "#00472C",
    "#004747", "#002747", "#000047", "#2E0047", "#470047", "#47002A",
    -- 28-39
    "#740000", "#743A00", "#747400", "#517400", "#007400", "#007449",
    "#007474", "#004074", "#000074", "#4B0074", "#740074", "#740045",
    -- 40-51
    "#B50000", "#B56300", "#B5B500", "#7DB500", "#00B500", "#00B571",
    "#00B5B5", "#0063B5", "#0000B5", "#7500B5", "#B500B5", "#B5006B",
    -- 52-63
    "#FF0000", "#FF8C00", "#FFFF00", "#B2FF00", "#00FF00", "#00FFA0",
    "#00FFFF", "#008CFF", "#0000FF", "#A500FF", "#FF00FF", "#FF0098",
    -- 64-75
    "#FF5959", "#FFB459", "#FFFF71", "#CFFF60", "#6FFF6F", "#65FFC9",
    "#6DFFFF", "#59B4FF", "#5959FF", "#C459FF", "#FF66FF", "#FF59BC",
    -- 76-87
    "#FF9C9C", "#FFD39C", "#FFFF9C", "#E2FF9C", "#9CFF9C", "#9CFFDB",
    "#9CFFFF", "#9CD3FF", "#9C9CFF", "#DC9CFF", "#FF9CFF", "#FF94D3",
    -- 88-98
    "#000000", "#131313", "#282828", "#363636", "#4D4D4D", "#656565",
    "#818181", "#9F9F9F", "#BCBCBC", "#E2E2E2", "#FFFFFF",
}

-- True-IRC-color grounds: pure black for dark themes, pure white for light
-- ones; every color below is an IRC palette entry.
local TRUE_DARK = {
    bg = "#000000", border = "#7F7F7F", text = "#FFFFFF",
    me = "#00FFFF", hl = "#FFFF00",
    nicks = { "#00FC00", "#FC7F00", "#FF00FF", "#D2D2D2", "#FF0000", "#9C9CFF" },
}
local TRUE_LIGHT = {
    bg = "#FFFFFF", border = "#7F7F7F", text = "#000000",
    me = "#0000FC", hl = "#FF0000",
    nicks = { "#00007F", "#009300", "#7F0000", "#9C009C", "#009393", "#FC7F00" },
}

local function nick_color(nick, set, fallback)
    if not set or #set == 0 then return fallback end
    local h = 0
    for i = 1, #nick do h = (h + nick:byte(i)) % #set end
    return set[h + 1]
end

-- ── root + header ────────────────────────────────────────────────────────────

local W, H = lvgl.HOR_RES(), lvgl.VER_RES()
local HEADER_H = 24
local BODY_H = H - HEADER_H
local INNER_W = W - 6   -- body width minus its pad_all = 3 on both sides

local root = apps.new_root {
    w = W, h = H,
    bg_color = COL_SCR, border_width = 0, radius = 0, pad_all = 0,
}
-- Home chord = clean QUIT (go_home runs this; go_background does not).
apps.set_on_close(function() apps.close_background("irc") end)

local header = root:Object {
    w = W, h = HEADER_H, x = 0, y = 0,
    bg_opa = 0, border_width = 0, radius = 0,
    pad_top = 0, pad_bottom = 0, pad_left = 4, pad_right = 4,
}
header:clear_flag(lvgl.FLAG.SCROLLABLE)
header:clear_flag(lvgl.FLAG.CLICKABLE)
local hdr_title = header:Label { text = "IRC", align = lvgl.ALIGN.LEFT_MID,
                                 text_color = COL_TEXT }
local hdr_right = header:Label { text = "", align = lvgl.ALIGN.RIGHT_MID,
                                 text_color = COL_TEXT }

-- ── shared helpers ───────────────────────────────────────────────────────────

-- Every UI callback runs through this: errors always reach the serial log.
local function safe(fn)
    return function()
        local ok, err = pcall(fn)
        if not ok then print("[irc:ui] error: " .. tostring(err)) end
    end
end

-- Character-count truncation (UTF-8 aware, ".." marks a cut).
local function trunc(s, max)
    s = parse.utf8_clean(s or "")
    local count, i, cut = 0, 1, 1
    while i <= #s do
        count = count + 1
        if count == max - 1 then cut = i end
        local b = s:byte(i)
        if b >= 0xF0 then i = i + 4
        elseif b >= 0xE0 then i = i + 3
        elseif b >= 0xC0 then i = i + 2
        else i = i + 1 end
    end
    if count <= max then return s end
    return s:sub(1, cut - 1) .. ".."
end

-- Formatting codes removed, invalid UTF-8 replaced. Row previews call this
-- on every refresh, so it takes parse's no-runs path.
local function plain(s)
    return parse.plain(parse.utf8_clean(s or ""))
end

local hdr_t_cache, hdr_r_cache = nil, nil
local function set_header(title, right)
    local t = utils.emojiText(trunc(title or "IRC", 22))
    local r = utils.emojiText(trunc(right or "", 18))
    if t ~= hdr_t_cache then
        hdr_t_cache = t
        hdr_title:set { text = t }
    end
    if r ~= hdr_r_cache then
        hdr_r_cache = r
        hdr_right:set { text = r }
    end
end

-- Returns the button and its label.
local function btn(parent, label, w, cb, h)
    local b = parent:Button { w = w, h = h or 24 }
    local l = b:Label { text = label, align = lvgl.ALIGN.CENTER }
    b:onClicked(safe(cb))
    return b, l
end

-- On-screen feedback for actions that would otherwise fail invisibly.
local function toast(msg)
    pcall(function()
        utils.createNotification(lvgl.disp.get_scr_act(), msg, 3000)
    end)
end

local function net_label(c)
    return c.net.name ~= "" and c.net.name or c.net.host
end

local function state_short(c)
    local st = c.st
    if st == "up" then return "up" end
    if st == "backoff" then
        return "retry " .. math.max(0, math.floor(c.recon_at - E.mono)) .. "s"
    end
    if st == "connecting" or st == "registering" then return "connecting" end
    if st == "waiting_wifi" then return "no wifi" end
    if st == "untrusted" then return "cert?" end
    return "off"
end

local function quit_app()
    apps.close_background("irc")
    apps.go_home()
end

-- ── view plumbing ────────────────────────────────────────────────────────────

local cur_view = nil
local cur_cont = nil
local shown_gen = -1
local popup_depth = 0
local ch = nil   -- live chat-view state, nil outside the chat view
local mem_c, mem_key, mem_filter, mem_sig   -- live members-view state

local show_nets, show_net, show_chat, show_members, show_editor
local show_console, show_cert, show_settings, show_whois, show_chaninfo
local show_chanlist
local refresh_nets, refresh_net, refresh_chat, refresh_console
local refresh_whois, refresh_chaninfo, refresh_chanlist, refresh_members

local function swap_view(name, builder)
    local old = cur_cont
    ch = nil
    cur_view = name
    nav.reset()
    cur_cont = root:Object {
        w = W, h = BODY_H, x = 0, y = HEADER_H,
        bg_opa = 0, border_width = 0, radius = 0,
        pad_all = 3, pad_row = 4, pad_column = 4,
        flex = { flex_direction = "row", flex_wrap = "wrap" },
    }
    builder(cur_cont)
    nav.replace(cur_cont, { flags = nav.ROLLOVER + nav.SCROLL_FIRST })
    if old then apps.delete_view(old) end
    shown_gen = -1
end

-- A scroll list for rows; returns the list and its tap binder.
local function make_list(v, h)
    local list = v:Object {
        w = lvgl.PCT(100), h = h,
        bg_opa = 0, border_width = 0, radius = 0,
        pad_all = 0, pad_row = 4,
        flex = { flex_direction = "column", flex_wrap = "nowrap" },
    }
    nav.list(list)
    return list, nav.scroll_aware(list)
end

-- A full-width row button with a left and a right label. Texts and color
-- are applied by row_update, which skips unchanged values.
local function make_row(list, bind, activate)
    local row = list:Button { w = lvgl.PCT(100), h = 28 }
    local r = {
        row = row,
        lb_l = row:Label { text = "", align = lvgl.ALIGN.LEFT_MID },
        lb_r = row:Label { text = "", align = lvgl.ALIGN.RIGHT_MID },
    }
    bind(row, safe(activate))
    return r
end

local function row_update(r, left, right, emph)
    if left ~= r.l then
        r.l = left
        r.lb_l:set { text = utils.emojiText(left) }
    end
    if right ~= r.r then
        r.r = right
        r.lb_r:set { text = right }
    end
    if emph ~= r.e then
        r.e = emph
        local col = emph and COL_HI or COL_BTN
        r.lb_l:set { text_color = col }
        r.lb_r:set { text_color = col }
    end
end

-- /query and /close land here from cmds.
E.ui_open = function(c, key)
    if key then show_chat(c, key) else show_net(c) end
end

-- ── popups ───────────────────────────────────────────────────────────────────

local function popup_layer()
    popup_depth = popup_depth + 1
    local ov = root:Object {
        w = W, h = H, x = 0, y = 0,
        bg_color = COL_SCR, bg_opa = 170, border_width = 0, pad_all = 0,
    }
    ov:add_flag(lvgl.FLAG.CLICKABLE)   -- modal: swallow taps behind the box
    local closed = false
    local function close()
        if closed then return end
        closed = true
        nav.pop()
        ov:delete()
        popup_depth = popup_depth - 1
    end
    return ov, close
end

local function prompt(title, initial, cb)
    local ov, close = popup_layer()
    local box = ov:Object {
        w = 280, h = 116, x = (W - 280) // 2, y = 36,
        bg_color = COL_CARD, border_width = 1, border_color = COL_BORD,
        pad_all = 6, pad_row = 4, pad_column = 4,
        flex = { flex_direction = "row", flex_wrap = "wrap" },
    }
    box:Label { text = title, w = lvgl.PCT(100), text_color = COL_ACC }
    local ta = box:Textarea { one_line = true, text = initial or "",
                              w = lvgl.PCT(100), h = 32 }
    local function ok_go()
        local text = ta:get("text"):match("^%s*(.-)%s*$")
        close()
        if text ~= "" then cb(text) end
    end
    local okb = box:Button { w = 128, h = 28 }
    okb:Label { text = "OK", align = lvgl.ALIGN.CENTER }
    okb:onClicked(safe(ok_go))
    local cb2 = box:Button { w = 128, h = 28 }
    cb2:Label { text = "Cancel", align = lvgl.ALIGN.CENTER }
    cb2:onClicked(safe(close))
    ta:onevent(lvgl.EVENT.KEY, safe(function()
        local indev = lvgl.indev.get_act()
        if indev and indev:get_key() == lvgl.KEY.ENTER then ok_go() end
    end))
    nav.push(box)
end

-- items = array of { label, cb }. A Cancel row is added automatically; each
-- item closes the menu before its cb runs, so a cb may open views or another
-- popup freely.
local function menu(title, items)
    local ov, close = popup_layer()
    local want_h = 12 + 24 + (#items + 1) * 34
    local bh = math.min(H - 16, want_h)
    local box = ov:Object {
        w = 240, h = bh, x = (W - 240) // 2, y = (H - bh) // 2,
        bg_color = COL_CARD, border_width = 1, border_color = COL_BORD,
        pad_all = 6, pad_row = 4,
        flex = { flex_direction = "column", flex_wrap = "nowrap" },
    }
    box:Label { text = utils.emojiText(trunc(title, 26)), w = lvgl.PCT(100),
                text_color = COL_ACC }
    for i = 1, #items do
        local it = items[i]
        local b = box:Button { w = lvgl.PCT(100), h = 30 }
        b:Label { text = it[1], align = lvgl.ALIGN.CENTER }
        b:onClicked(safe(function()
            close()
            if it[2] then it[2]() end
        end))
    end
    local cb2 = box:Button { w = lvgl.PCT(100), h = 30 }
    cb2:Label { text = "Cancel", align = lvgl.ALIGN.CENTER }
    cb2:onClicked(safe(close))
    nav.push(box)
end

-- Read-only text: Close button first, then the text in its own focusable
-- scrollable child (the trackball scrolls it).
local function text_popup(title, body)
    local ov, close = popup_layer()
    local bh = H - 40
    local box = ov:Object {
        w = 280, h = bh, x = (W - 280) // 2, y = 20,
        bg_color = COL_CARD, border_width = 1, border_color = COL_BORD,
        pad_all = 6, pad_row = 4,
        flex = { flex_direction = "column", flex_wrap = "nowrap" },
    }
    box:Label { text = utils.emojiText(trunc(title, 26)), w = lvgl.PCT(100),
                text_color = COL_ACC }
    local cb = box:Button { w = lvgl.PCT(100), h = 28 }
    cb:Label { text = "Close", align = lvgl.ALIGN.CENTER }
    cb:onClicked(safe(close))
    local sc = box:Object {
        w = lvgl.PCT(100), h = bh - 12 - 22 - 28 - 8 - 2,
        bg_opa = 0, border_width = 0, pad_all = 2,
    }
    sc:Label { text = utils.emojiText(body), w = lvgl.PCT(100),
               text_color = COL_TEXT }
    nav.push(box, { flags = nav.ROLLOVER + nav.SCROLL_FIRST })
end

-- ── menus ────────────────────────────────────────────────────────────────────

local function app_menu()
    menu("IRC", {
        { "Add network", function()
            show_editor(cfg.new_network(E.nets), true, show_nets)
        end },
        { "Settings", function() show_settings() end },
        { "Run in background", function() apps.go_background("irc") end },
        { "Quit", quit_app },
    })
end

local function net_menu(c)
    local id = c.id
    local items = {}
    items[#items + 1] = { "Join channel...", function()
        prompt("Join channel on " .. net_label(c), "#", function(text)
            if c.st ~= "up" then
                toast("Not connected - use Connect first")
                return
            end
            E.join(c, text)
        end)
    end }
    items[#items + 1] = { "Query nick...", function()
        prompt("Query nick on " .. net_label(c), "", function(text)
            local nick = text:match("^(%S+)") or text
            local key = E.open_query(c, nick)
            if key then show_chat(c, key)
            else toast("Private chat limit reached") end
        end)
    end }
    items[#items + 1] = { "Channel list", function() show_chanlist(c) end }
    items[#items + 1] = { "Raw log", function() show_console(c) end }
    if c.st == "untrusted" then
        items[#items + 1] = { "Approve certificate", function() show_cert(c) end }
    elseif c.st == "off" and c.last_reason
        and c.last_reason:sub(1, 4) == "tls:" then
        items[#items + 1] = { "Trust this server...", function()
            E.recapture(id)
        end }
    end
    items[#items + 1] = { "Edit", function()
        show_editor(c.net, false, function() show_net(c) end)
    end }
    items[#items + 1] = { "Remove", function()
        menu("Remove " .. net_label(c) .. "?", {
            { "Remove", function()
                print("[irc:ui] delete network " .. id)
                E.delete_net(id)
                show_nets()
            end },
        })
    end }
    menu(net_label(c), items)
end

local function member_count(b)
    local n = 0
    for _ in pairs(b.members) do n = n + 1 end
    return n
end

local function chat_menu()
    if not ch then return end
    local c, key, b = ch.c, ch.key, ch.b
    local items = {}
    if b.type == "channel" then
        items[#items + 1] = { "Members (" .. member_count(b) .. ")", function()
            show_members(c, key)
        end }
        items[#items + 1] = { "Channel info", function()
            show_chaninfo(c, key)
        end }
    end
    if clipboard.has() then
        local mine = ch
        items[#items + 1] = { "Paste", function()
            if ch ~= mine then return end
            -- An IRC line cannot carry CR/LF.
            local t = clipboard.paste():gsub("[\r\n]+", " ")
            ch.ta:set { text = ch.ta:get("text") .. t }
            nav.set_focused(ch.ta)
        end }
    end
    items[#items + 1] = { "Notifications: " .. E.get_notify_mode(c, key),
        function()
            local order = { off = "mentions", mentions = "all", all = "off" }
            local nm = order[E.get_notify_mode(c, key)]
            E.set_notify_mode(c, key, nm)
            toast("Notifications: " .. nm)
        end }
    items[#items + 1] = { "Clear", function() E.clear_buffer(c, key) end }
    if key ~= c.skey then
        items[#items + 1] = { "Close buffer", function()
            E.close_buffer(c, key)
            show_net(c)
        end }
    end
    items[#items + 1] = { "Raw log", function() show_console(c) end }
    menu(b.name, items)
end

local function query_nick(c, nick)
    local key = E.open_query(c, nick)
    if key then show_chat(c, key)
    else toast("Private chat limit reached") end
end

-- Where the whois card's Back goes; set by whoever asks, read once by the
-- E.ui_whois hook (a /whois typed into a chat sets none and lands there).
local whois_back = nil

local function whois_nick(c, nick, back)
    whois_back = back
    if not E.whois(c, nick) then   -- opens the card through E.ui_whois
        whois_back = nil
        toast("Not connected")
    end
end

-- A member's rank letters in a channel, from ISUPPORT PREFIX ("o" for @).
local function ranks_of(c, pfx)
    local syms = c.isupport.prefix_syms or "@+"
    local modes = c.isupport.prefix_modes or "ov"
    local out = {}
    for i = 1, #(pfx or "") do
        local at = syms:find(pfx:sub(i, i), 1, true)
        if at and at <= #modes then out[#out + 1] = modes:sub(at, at) end
    end
    return table.concat(out)
end

local function member_pfx(c, b, nick)
    local mem = b.members and b.members[E.buffer_key(c, nick)]
    return (mem and mem.pfx) or ""
end

-- The ops actions are offered to ranks above voice.
local function can_op(c, b)
    return ranks_of(c, member_pfx(c, b, c.nick)):find("[qaoh]") ~= nil
end

local function member_ops_menu(c, key, nick)
    local b = c.buffers[key]
    if not b then return end
    local chan = b.name
    local held = ranks_of(c, member_pfx(c, b, nick))
    local function mode(sign, letter)
        E.sendline(c, "MODE " .. chan .. " " .. sign .. letter .. " " .. nick)
    end
    local is_op = held:find("o", 1, true) ~= nil
    local is_voiced = held:find("v", 1, true) ~= nil
    local mask = nick .. "!*@*"
    menu(nick .. " on " .. chan, {
        { is_op and "Take ops" or "Give ops",
          function() mode(is_op and "-" or "+", "o") end },
        { is_voiced and "Take voice" or "Give voice",
          function() mode(is_voiced and "-" or "+", "v") end },
        { "Kick", function()
            E.sendline(c, "KICK " .. chan .. " " .. nick)
            mem_sig = nil   -- the roster shrinks: rebuild the members view
        end },
        { "Ban", function()
            E.sendline(c, "MODE " .. chan .. " +b " .. mask)
        end },
        { "Kick + ban", function()
            E.sendline(c, "MODE " .. chan .. " +b " .. mask)
            E.sendline(c, "KICK " .. chan .. " " .. nick)
            mem_sig = nil
        end },
    })
end

local function member_menu(c, key, nick)
    local items = {
        { "Mention", function() show_chat(c, key, nick .. ": ") end },
        { "Query", function() query_nick(c, nick) end },
        { "Whois", function()
            whois_nick(c, nick, function() show_members(c, key) end)
        end },
    }
    local b = c.buffers[key]
    if b and b.type == "channel" and can_op(c, b) then
        items[#items + 1] = { "Channel ops...", function()
            member_ops_menu(c, key, nick)
        end }
    end
    menu(nick, items)
end

-- A source that names a user: server names contain '.', nicks cannot.
local function user_nick(s)
    return s ~= nil and s ~= "" and not s:find(".", 1, true)
end

-- Held a chat line. Lines from another user get Reply (channels),
-- Query (outside that user's own query) and Whois; every line gets Copy
-- text (the message text, to lib/clipboard).
local function line_menu(L)
    if not ch then return end
    local c, b = ch.c, ch.b
    local text = plain(L.fmt or L.text)
    local nick = nil
    if L.kind ~= "info" and user_nick(L.src) and L.src ~= c.nick then
        nick = L.src
    end
    local items = {}
    if nick and b.type == "channel" then
        local mine = ch
        items[#items + 1] = { "Reply", function()
            if ch ~= mine then return end
            local pre = nick .. ": "
            local cur = ch.ta:get("text")
            if cur:sub(1, #pre) ~= pre then ch.ta:set { text = pre .. cur } end
            nav.set_focused(ch.ta)
        end }
    end
    items[#items + 1] = { "Copy text", function()
        clipboard.copy(utils.emojiText(text))
        toast("Copied")
    end }
    if nick then
        if b.type ~= "query" then
            items[#items + 1] = { "Query", function() query_nick(c, nick) end }
        end
        items[#items + 1] = { "Whois", function() whois_nick(c, nick) end }
    end
    menu((L.src and (L.src .. ": ") or "") .. text, items)
end

-- ── networks (home) ──────────────────────────────────────────────────────────

local nets_rows = {}
local nets_sig = ""

local function nets_signature()
    return table.concat(E.order, ";")
end

local function net_row_texts(c)
    local unread, hl = 0, 0
    for k = 1, #c.buforder do
        local b = c.buffers[c.buforder[k]]
        if b then
            unread = unread + b.unread
            hl = hl + b.hl
        end
    end
    local nick = c.st == "up" and c.nick or c.net.nick
    local left = trunc(net_label(c) .. "  " .. nick, 24)
    local right = state_short(c)
    if hl > 0 then
        right = "(" .. hl .. "!) " .. right
    elseif unread > 0 then
        right = "(" .. unread .. ") " .. right
    end
    return left, right, (hl > 0 or unread > 0 or c.st == "untrusted")
end

refresh_nets = function()
    local up = 0
    for i = 1, #E.order do
        if E.conns[E.order[i]].st == "up" then up = up + 1 end
    end
    set_header("IRC", #E.order > 0 and (up .. "/" .. #E.order .. " connected") or "")
    if nets_signature() ~= nets_sig then
        show_nets()
        return
    end
    for i = 1, #E.order do
        local id = E.order[i]
        local r = nets_rows[id]
        if r then row_update(r, net_row_texts(E.conns[id])) end
    end
end

show_nets = function()
    E.ui.conn, E.ui.buf = nil, nil
    swap_view("nets", function(v)
        nets_rows = {}
        nets_sig = nets_signature()
        btn(v, "Menu", 64, app_menu)
        local list, bind = make_list(v, BODY_H - 38)
        if #E.order == 0 then
            list:Label { text = "No networks yet.\nMenu > Add network to start.",
                         w = lvgl.PCT(100), text_color = COL_TEXT }
        end
        for i = 1, #E.order do
            local id = E.order[i]
            nets_rows[id] = make_row(list, bind, function()
                show_net(E.conns[id])
            end)
        end
    end)
    refresh_nets()
end

-- ── network page ─────────────────────────────────────────────────────────────

local net_c = nil
local net_rows = {}
local net_order = {}       -- buffer keys in displayed row order
local net_sig = ""
local net_conn_lbl = nil   -- the page's Connect/Disconnect button label
local net_conn_txt = nil

local function net_signature(c)
    return table.concat(c.buforder, ";")
end

-- Buffer keys, most recent activity first (b.act, engine-maintained); the
-- server log stays last.
local function sorted_keys(c)
    local keys = {}
    for k = 1, #c.buforder do
        local bkey = c.buforder[k]
        if bkey ~= c.skey and c.buffers[bkey] then keys[#keys + 1] = bkey end
    end
    table.sort(keys, function(a, b)
        return (c.buffers[a].act or 0) > (c.buffers[b].act or 0)
    end)
    if c.buffers[c.skey] then keys[#keys + 1] = c.skey end
    return keys
end

-- A connection the user asked for (up, connecting, retrying or waiting for
-- WiFi) offers Disconnect; anything else offers Connect.
local function conn_wanted(c)
    return c.want and c.st ~= "off"
end

local function conn_label(c)
    return conn_wanted(c) and "Disconnect" or "Connect"
end

local function buf_row_texts(b)
    local name = b.type == "server" and "server log" or b.name
    local last = b.lines[#b.lines]
    local left = name
    if last then
        local pv = plain(last.text)
        if last.src and last.kind ~= "info" then pv = last.src .. ": " .. pv end
        if pv ~= "" then left = name .. "  " .. pv end
    end
    left = trunc(left, 26)
    local right = last and utils.relTime(last.t) or ""
    if b.hl > 0 then
        right = "(" .. b.hl .. "!) " .. right
    elseif b.unread > 0 then
        right = "(" .. b.unread .. ") " .. right
    end
    return left, right, (b.hl > 0 or b.unread > 0)
end

local function net_header(c)
    set_header(net_label(c),
        c.st == "up" and ("up as " .. c.nick) or state_short(c))
end

local function update_conn_btn(c)
    if not net_conn_lbl then return end
    local t = conn_label(c)
    if t ~= net_conn_txt then
        net_conn_txt = t
        net_conn_lbl:set { text = t }
    end
end

refresh_net = function()
    local c = net_c
    if not (c and E.conns[c.id]) then
        show_nets()
        return
    end
    net_header(c)
    if net_signature(c) ~= net_sig then
        show_net(c)
        return
    end
    update_conn_btn(c)
    -- Re-order rows in place when activity changed the ranking.
    local order = sorted_keys(c)
    local changed = #order ~= #net_order
    if not changed then
        for k = 1, #order do
            if order[k] ~= net_order[k] then
                changed = true
                break
            end
        end
    end
    if changed then
        for k = 1, #order do
            local r = net_rows[order[k]]
            if r then r.row:move_to_index(k - 1) end
        end
        net_order = order
    end
    for k = 1, #c.buforder do
        local bkey = c.buforder[k]
        local b = c.buffers[bkey]
        local r = net_rows[bkey]
        if r and b then row_update(r, buf_row_texts(b)) end
    end
end

show_net = function(c)
    if not (c and E.conns[c.id]) then
        show_nets()
        return
    end
    net_c = c
    E.ui.conn, E.ui.buf = nil, nil
    swap_view("net", function(v)
        net_rows = {}
        net_sig = net_signature(c)
        btn(v, "Back", 64, function() show_nets() end)
        btn(v, "Menu", 64, function() net_menu(c) end)
        net_conn_txt = conn_label(c)
        -- Label + header only here: row re-ordering stays on the heartbeat,
        -- never inside an event handler.
        local _, lbl = btn(v, net_conn_txt, 100, function()
            if conn_wanted(c) then
                E.disconnect_net(c.id)
            else
                E.connect_net(c.id)
            end
            update_conn_btn(c)
            net_header(c)
        end)
        net_conn_lbl = lbl
        local list, bind = make_list(v, BODY_H - 38)
        net_order = sorted_keys(c)
        for k = 1, #net_order do
            local bkey = net_order[k]
            net_rows[bkey] = make_row(list, bind, function()
                show_chat(c, bkey)
            end)
        end
    end)
    refresh_net()
end

-- ── chat view: windowed rows ─────────────────────────────────────────────────

local CH_WIN, CH_PAGE, CH_EDGE = 30, 10, 40
local CH_ROW_W = INNER_W - 6          -- list width minus border (1+1) and pad (2+2)
local TOPIC_BTN_W = INNER_W - 56 - 56 - 8 - 2

-- Message-area colors. Theme mode: palette slots on the card ground, IRC
-- color codes not drawn, bold drawn in accent_text. True-IRC-color mode:
-- pure black (dark theme) or white (light theme) ground with the IRC
-- palette as sent; a code color equal to the ground draws in the default
-- text color; bold has no font face and draws plain.
local function chat_colors()
    if E.settings.true_colors then
        local T = (pal.dark == false) and TRUE_LIGHT or TRUE_DARK
        return { irc = true, bg = T.bg, border = T.border, text = T.text,
                 me = T.me, hl = T.hl, nicks = T.nicks }
    end
    return { irc = false, bg = COL_CARD, border = COL_BORD, text = COL_TEXT,
             me = COL_ACC, hl = COL_HI, nicks = NICKCOLS, bold = COL_ACC }
end

local function run_color(cc, run)
    if not cc.irc then return nil end
    local fg = run.fg
    local hex = nil
    if type(fg) == "string" then
        hex = fg:upper()
    elseif type(fg) == "number" and fg >= 0 and fg <= 98 then
        hex = IRC_COLORS[fg]
    end
    if hex == cc.bg then return nil end
    return hex
end

-- Span style for one formatted run; base = the line's default text color.
local function span_style(cc, run, base)
    local st = { text_color = base }
    local col = run_color(cc, run)
    if col then
        st.text_color = col
    elseif run.bold and cc.bold and base == cc.text then
        st.text_color = cc.bold
    end
    if run.underline then st.underline = true end
    if run.strike then st.strike = true end
    return st
end

local function ch_row_build(L, at_top)
    local cc = ch.cc
    local sg = ch.list:Spangroup { w = CH_ROW_W, h = lvgl.SIZE_CONTENT }
    sg:set_mode("break")
    -- Hold a line to open its menu. CLICKABLE makes the line the pressed
    -- object (LONG_PRESSED goes only there); LVGL stops sending it once a
    -- drag has started scrolling, so a scroll never opens the menu.
    sg:add_flag(lvgl.FLAG.CLICKABLE)
    sg:onevent(lvgl.EVENT.LONG_PRESSED, safe(function() line_menu(L) end))
    sg:add_span(utils.clockHM(L.t) .. " ", { text_color = cc.text })
    local base = L.hl and cc.hl or cc.text
    local src = utils.emojiText(L.src or "")
    if L.kind == "msg" then
        local ncol
        if L.src == ch.c.nick then
            ncol = cc.me
        elseif L.hl then
            ncol = cc.hl
        else
            ncol = nick_color(L.src or "", cc.nicks, cc.text)
        end
        sg:add_span(src .. ": ", { text_color = ncol })
    elseif L.kind == "action" then
        sg:add_span("* " .. src .. " ", { text_color = base })
    elseif L.kind == "notice" then
        sg:add_span("-" .. src .. "- ",
            { text_color = nick_color(L.src or "", cc.nicks, cc.text) })
    end
    local _, runs = parse.strip(parse.utf8_clean(L.fmt or L.text or ""))
    for i = 1, #runs do
        local r = runs[i]
        sg:add_span(utils.emojiText(r.text), span_style(cc, r, base))
    end
    if at_top then sg:move_to_index(0) end
    return sg
end

local function ch_scroll_bottom()
    local st = ch.list:get_scroll_top()
    local sb = ch.list:get_scroll_bottom()
    pcall(function() ch.list:scroll_to { y = st + sb, anim = false } end)
end

local function ch_build_tail()
    for i = 1, #ch.rows do
        pcall(function() ch.rows[i]:delete() end)
    end
    ch.rows = {}
    local b = ch.b
    local lines = b.lines
    ch.lines_ref = lines
    ch.trim_n = b.trim_n or 0
    ch.clear_n = b.clear_n or 0
    ch.win_lo = math.max(1, #lines - (CH_WIN - 1))
    for i = ch.win_lo, #lines do
        ch.rows[#ch.rows + 1] = ch_row_build(lines[i])
    end
    ch.following = true
    ch.seen_n = #lines
    ch.list:update_layout()
    ch_scroll_bottom()
end

local function ch_page(dir)
    local lines = ch.b.lines
    if dir < 0 then
        local n = math.min(CH_PAGE, ch.win_lo - 1)
        local anchor = ch.rows[1]
        if n <= 0 or not anchor then return end
        local y0 = anchor:get_coords().y1
        local st0 = ch.list:get_scroll_top()
        for i = ch.win_lo - 1, ch.win_lo - n, -1 do
            table.insert(ch.rows, 1, ch_row_build(lines[i], true))
        end
        ch.win_lo = ch.win_lo - n
        while #ch.rows > CH_WIN do
            local last = table.remove(ch.rows)
            pcall(function() last:delete() end)
        end
        ch.list:update_layout()
        local shift = anchor:get_coords().y1 - y0
        pcall(function() ch.list:scroll_to { y = st0 + shift, anim = false } end)
        ch.following = false
    else
        local win_hi = ch.win_lo + #ch.rows - 1
        local n = math.min(CH_PAGE, #lines - win_hi)
        if n <= 0 then return end
        local prune = math.max(0, (#ch.rows + n) - CH_WIN)
        local anchor = ch.rows[prune + 1]
        local y0 = anchor and anchor:get_coords().y1
        local st0 = ch.list:get_scroll_top()
        for i = 1, prune do
            local first = table.remove(ch.rows, 1)
            pcall(function() first:delete() end)
        end
        ch.win_lo = ch.win_lo + prune
        for i = win_hi + 1, win_hi + n do
            ch.rows[#ch.rows + 1] = ch_row_build(lines[i])
        end
        ch.list:update_layout()
        if anchor and y0 then
            local shift = anchor:get_coords().y1 - y0
            pcall(function() ch.list:scroll_to { y = st0 + shift, anim = false } end)
        end
    end
end

-- Runs from a one-shot timer, never inside the scroll callback; deferred
-- while a touch is still down (mutating mid-drag turns the press into a
-- spurious click). `mine` is the chat state that scheduled it: a timer that
-- outlives its view does nothing.
local function ch_run_page(mine)
    if not ch or ch ~= mine then return end
    local okp, pressed = pcall(_touch_pressed)
    if okp and pressed then
        apps.add_timer { period = 30, cb = function(t)
            t:delete()
            ch_run_page(mine)
        end }
        return
    end
    ch.sched = false
    local st = ch.list:get_scroll_top()
    local sb = ch.list:get_scroll_bottom()
    if st <= CH_EDGE and ch.win_lo > 1 then
        ch_page(-1)
    elseif sb <= CH_EDGE then
        local win_hi = ch.win_lo + #ch.rows - 1
        if win_hi < #ch.b.lines then ch_page(1) end
        ch.following = (ch.win_lo + #ch.rows - 1) >= #ch.b.lines
    else
        ch.following = false
    end
    -- At the top with nothing older held: ask the server for more.
    if st <= CH_EDGE and ch.win_lo == 1 then
        E.history_before(ch.c, ch.key)
    end
    refresh_chat()
end

-- Idle text of the chat's third button.
local function chat_btn_text(b)
    if b.type == "channel" then
        local t = plain(b.topic)
        return t ~= "" and trunc(t, 22) or "no topic"
    elseif b.type == "query" then
        return "private chat"
    end
    return "connection"
end

refresh_chat = function()
    if not ch then return end
    local c = ch.c
    local b = c.buffers[ch.key]
    if not b then
        show_net(c)   -- buffer was closed under us
        return
    end
    ch.b = b
    set_header(b.type == "server" and "server log" or b.name, net_label(c))
    -- A trim dropped lines from the front: shift the window's indices. The
    -- steady-state trim reuses the same table, so b.trim_n - not the table's
    -- identity - is what says lines went away. A Clear, or a trim that
    -- reached the window's own top, rebuilds instead.
    local shift = (b.trim_n or 0) - ch.trim_n
    if shift ~= 0 or b.lines ~= ch.lines_ref
        or (b.clear_n or 0) ~= ch.clear_n then
        if (b.clear_n or 0) ~= ch.clear_n or ch.win_lo - shift < 1 then
            ch_build_tail()
        else
            ch.win_lo = ch.win_lo - shift
            ch.seen_n = ch.seen_n - shift
            ch.lines_ref = b.lines
            ch.trim_n = b.trim_n or 0
        end
    end
    local win_hi = ch.win_lo + #ch.rows - 1
    if #b.lines > win_hi and ch.following then
        local n = #b.lines - win_hi
        local prune = math.max(0, (#ch.rows + n) - CH_WIN)
        for i = 1, prune do
            local first = table.remove(ch.rows, 1)
            pcall(function() first:delete() end)
        end
        ch.win_lo = ch.win_lo + prune
        for i = win_hi + 1, #b.lines do
            ch.rows[#ch.rows + 1] = ch_row_build(b.lines[i])
        end
        ch.list:update_layout()
        ch_scroll_bottom()
        E.mark_seen(c, ch.key)
    end
    if ch.following then ch.seen_n = #b.lines end
    ch.newc = ch.following and 0 or math.max(0, #b.lines - ch.seen_n)
    local txt, emph
    if ch.newc > 0 then
        txt, emph = ch.newc .. " new - jump", true
    else
        txt, emph = utils.emojiText(chat_btn_text(b)), false
    end
    if txt ~= ch.tb_txt then
        ch.tb_txt = txt
        ch.tb_lbl:set { text = txt }
    end
    if emph ~= ch.tb_emph then
        ch.tb_emph = emph
        ch.tb_lbl:set { text_color = emph and COL_HI or COL_BTN }
    end
end

local function topic_tap()
    if not ch then return end
    local c, b = ch.c, ch.b
    if ch.newc > 0 then
        -- Jump to the newest lines; the window rebuild runs off the event
        -- stack.
        local mine = ch
        apps.add_timer { period = 1, cb = function(t)
            t:delete()
            if ch == mine then
                ch_build_tail()
                refresh_chat()
            end
        end }
        return
    end
    if b.type == "channel" then
        local t = plain(b.topic)
        local body = t ~= "" and t or "(no topic set)"
        if b.topic_by then body = body .. "\n\nset by " .. b.topic_by end
        text_popup(b.name, body)
    elseif b.type == "query" then
        text_popup(b.name, "Private conversation with " .. b.name .. ".")
    else
        local out = {
            "state: " .. state_short(c),
            "server: " .. c.net.host .. ":" .. c.net.port
                .. (c.net.tls and " (tls)" or ""),
            "nick: " .. (c.st == "up" and c.nick or c.net.nick),
        }
        if c.lag then out[#out + 1] = "lag: " .. c.lag .. "s" end
        if c.isupport.NETWORK then
            out[#out + 1] = "network: " .. tostring(c.isupport.NETWORK)
        end
        text_popup(net_label(c), table.concat(out, "\n"))
    end
end

-- prefill (optional) is placed in the input, which takes focus.
show_chat = function(c, key, prefill)
    local b = c.buffers[key]
    if not b then
        show_net(c)
        return
    end
    E.ui.conn, E.ui.buf = c.id, key
    E.mark_seen(c, key)
    swap_view("chat", function(v)
        ch = { c = c, key = key, b = b, rows = {}, win_lo = 1,
               lines_ref = b.lines, trim_n = 0, clear_n = 0, seen_n = 0,
               following = true, sched = false, newc = 0,
               cc = chat_colors() }
        local cc = ch.cc
        btn(v, "Back", 56, function() show_net(c) end)
        btn(v, "Menu", 56, chat_menu)
        local _, tl = btn(v, "", TOPIC_BTN_W, topic_tap)
        ch.tb_lbl = tl
        ch.list = v:Object {
            w = lvgl.PCT(100), h = BODY_H - 74,
            bg_color = cc.bg, bg_opa = cc.irc and 255 or nil,
            border_width = 1, border_color = cc.border,
            pad_all = 2, pad_row = 1, pad_column = 0,
            flex = { flex_direction = "column", flex_wrap = "nowrap" },
        }
        local mine = ch
        ch.list:onevent(lvgl.EVENT.SCROLL_END, function()
            if ch == mine and not ch.sched then
                ch.sched = true
                apps.add_timer { period = 1, cb = function(t)
                    t:delete()
                    ch_run_page(mine)
                end }
            end
        end)
        ch.ta = v:Textarea { one_line = true, text = "",
                             w = INNER_W - 70 - 4 - 2, h = 32 }
        local function send()
            if ch ~= mine then return end
            local text = ch.ta:get("text")
            if text == "" then return end
            if c.st ~= "up" and text:sub(1, 1) ~= "/" then
                toast("Not connected")
            end
            local tgt = (key ~= c.skey) and b.name or nil
            local ok, err = pcall(E.handle_input, c, text, tgt)
            if not ok then print("[irc] input error: " .. tostring(err)) end
            if ch == mine then
                ch.ta:set { text = "" }
                ch.following = true
                refresh_chat()
            end
        end
        ch.ta:onevent(lvgl.EVENT.KEY, safe(function()
            local indev = lvgl.indev.get_act()
            if indev and indev:get_key() == lvgl.KEY.ENTER then send() end
        end))
        btn(v, "Send", 70, send, 32)
        ch_build_tail()
        -- Nothing held for this buffer: ask the server for its history.
        if #b.lines == 0 then E.history_latest(c, key) end
    end)
    if prefill and ch then
        ch.ta:set { text = prefill }
        nav.set_focused(ch.ta)
    end
    refresh_chat()
end

-- ── members ──────────────────────────────────────────────────────────────────

local MEMBERS_MAX = 100

-- Ranked members only: the view rebuilds when someone is opped or voiced,
-- and plain joins and parts leave the reader's scroll position alone.
local function members_sig(b)
    local syms = {}
    for _, mem in pairs(b.members) do
        if mem.pfx ~= "" then syms[#syms + 1] = mem.pfx .. mem.nick end
    end
    table.sort(syms)
    return table.concat(syms, ",")
end

refresh_members = function()
    if not mem_c then return end
    local b = mem_c.buffers[mem_key]
    if not b then return end
    if members_sig(b) ~= mem_sig then show_members(mem_c, mem_key, mem_filter) end
end

local function member_rank(c, pfx)
    local syms = c.isupport.prefix_syms or "@+"
    if pfx == "" then return #syms + 1 end
    return syms:find(pfx:sub(1, 1), 1, true) or (#syms + 1)
end

-- Ops/voiced first, then by nick; at most MEMBERS_MAX rows (Filter narrows).
show_members = function(c, key, filter)
    local b = c.buffers[key]
    if not b then
        show_net(c)
        return
    end
    mem_c, mem_key, mem_filter = c, key, filter
    mem_sig = members_sig(b)
    E.ui.conn, E.ui.buf = nil, nil
    swap_view("members", function(v)
        local total = 0
        local shown = {}
        local f = filter and filter:lower() or nil
        for _, mem in pairs(b.members) do
            total = total + 1
            if not f or mem.nick:lower():find(f, 1, true) then
                shown[#shown + 1] = mem
            end
        end
        table.sort(shown, function(x, y)
            local rx, ry = member_rank(c, x.pfx), member_rank(c, y.pfx)
            if rx ~= ry then return rx < ry end
            return x.nick:lower() < y.nick:lower()
        end)
        set_header(b.name, total .. " members")
        btn(v, "Back", 64, function() show_chat(c, key) end)
        btn(v, "Filter", 64, function()
            prompt("Filter members", filter or "", function(text)
                show_members(c, key, text)
            end)
        end)
        if filter then
            btn(v, "All", 64, function() show_members(c, key, nil) end)
        end
        local list, bind = make_list(v, BODY_H - 38)
        local n = math.min(#shown, MEMBERS_MAX)
        for i = 1, n do
            local nick = shown[i].nick
            local r = make_row(list, bind, function()
                member_menu(c, key, nick)
            end)
            row_update(r, trunc(shown[i].pfx .. nick, 30), "", false)
        end
        if #shown > n then
            list:Label { text = (#shown - n) .. " more - use Filter",
                         w = lvgl.PCT(100), text_color = COL_TEXT }
        elseif #shown == 0 then
            list:Label { text = filter and "No member matches." or "No members known.",
                         w = lvgl.PCT(100), text_color = COL_TEXT }
        end
    end)
end

-- ── whois card ───────────────────────────────────────────────────────────────
-- The engine collects the WHOIS/WHOWAS numerics into c.whois; this card
-- renders that record and fills in as the replies arrive.

local wh_conn, wh_nick, wh_label

local function dur(s)
    if not s or s < 0 then return "?" end
    if s < 60 then return s .. "s" end
    if s < 3600 then return math.floor(s / 60) .. "m" end
    if s < 86400 then
        return math.floor(s / 3600) .. "h " .. math.floor((s % 3600) / 60) .. "m"
    end
    return math.floor(s / 86400) .. "d " .. math.floor((s % 86400) / 3600) .. "h"
end

local function whois_text(c, nick)
    local w = E.whois_get(c, nick)
    if not w then return "No answer." end
    local out = {}
    local function add(s) out[#out + 1] = s end
    if w.user or w.host then
        add((w.nick or nick) .. "!" .. (w.user or "?") .. "@" .. (w.host or "?"))
    else
        add(w.nick or nick)
    end
    if w.whowas then add("(whowas - last known)") end
    if w.real and w.real ~= "" then add(plain(w.real)) end
    if w.account then add("account: " .. w.account) end
    if w.away then add("away: " .. plain(w.away)) end
    if w.server then
        add("server: " .. w.server
            .. (w.server_info and (" (" .. plain(w.server_info) .. ")") or ""))
    end
    if w.idle then
        add("idle: " .. dur(w.idle)
            .. (w.signon and ("   on since " .. utils.clockDateTime(w.signon))
                or ""))
    end
    if w.channels and w.channels ~= "" then add("channels: " .. w.channels) end
    for i = 1, #w.extra do add(plain(w.extra[i])) end
    if w.error then add(w.error) end
    if not w.done then add("...") end
    return utils.emojiText(table.concat(out, "\n"))
end

refresh_whois = function()
    if not (wh_conn and wh_label) then return end
    local w = E.whois_get(wh_conn, wh_nick)
    set_header("whois " .. trunc(wh_nick, 14),
        (w and w.done) and net_label(wh_conn) or "waiting")
    wh_label:set { text = whois_text(wh_conn, wh_nick) }
end

show_whois = function(c, nick, back)
    wh_conn, wh_nick = c, nick
    E.ui.conn, E.ui.buf = nil, nil
    swap_view("whois", function(v)
        btn(v, "Back", 64, function()
            wh_conn = nil
            if back then back() else show_net(c) end
        end)
        btn(v, "Query", 64, function() query_nick(c, nick) end)
        btn(v, "Again", 64, function()
            if not E.whois(c, nick) then toast("Not connected") end
        end)
        local sc = v:Object {
            w = lvgl.PCT(100), h = BODY_H - 38,
            bg_color = COL_CARD, border_width = 1, border_color = COL_BORD,
            pad_all = 4,
        }
        wh_label = sc:Label { text = "", w = lvgl.PCT(100),
                              text_color = COL_TEXT }
    end)
    refresh_whois()
end

-- /whois, /whowas and every Whois menu item land here.
E.ui_whois = function(c, nick)
    local back = whois_back
    whois_back = nil
    if not back then
        if cur_view == "chat" and ch and ch.c == c then
            local key = ch.key
            back = function() show_chat(c, key) end
        elseif cur_view == "console" then
            back = function() show_console(c) end
        end
    end
    show_whois(c, nick, back)
end

-- ── channel info ─────────────────────────────────────────────────────────────
-- Topic, modes, creation time and, on demand, the +b/+e/+I mask lists.

local ci_conn, ci_key, ci_mode, ci_label
local LIST_NAMES = { b = "Bans", e = "Exceptions", I = "Invites" }

local function chaninfo_text()
    local c = ci_conn
    local b = c and c.buffers[ci_key]
    if not b then return "" end
    local out = {}
    local function add(s) out[#out + 1] = s end
    local topic = plain(b.topic or "")
    add("topic: " .. (topic ~= "" and topic or "(none)"))
    if b.topic_by then add("set by " .. b.topic_by) end
    local modes = E.modes_text(b)
    add("modes: " .. (modes ~= "" and modes or "(none known)"))
    if b.created then add("created " .. utils.clockDateTime(b.created)) end
    if b.url then add("url: " .. b.url) end
    add(member_count(b) .. " members" .. (b.joined and "" or " - not joined"))
    local hs = E.history_state(c, ci_key)
    if hs == "off" then hs = "not offered by this server"
    elseif hs == "full" then hs = "buffer full - Clear to fetch more"
    elseif hs == "done" then hs = "all the server had" end
    add("history: " .. hs)
    if ci_mode then
        local rec = (b.lists or {})[ci_mode] or { items = {} }
        add("")
        add(LIST_NAMES[ci_mode] .. ":")
        for i = 1, #rec.items do
            local it = rec.items[i]
            local by = it.by and (it.by:match("^([^!]+)") or it.by) or nil
            add("  " .. (it.mask or "?") .. (by and ("  by " .. by) or ""))
        end
        if #rec.items == 0 then
            add(rec.done and "  (none)" or "  ...")
        elseif rec.over then
            add("  (only the first " .. #rec.items .. " shown)")
        end
    end
    return utils.emojiText(table.concat(out, "\n"))
end

refresh_chaninfo = function()
    if not (ci_conn and ci_label) then return end
    ci_label:set { text = chaninfo_text() }
end

show_chaninfo = function(c, key)
    local b = c.buffers[key]
    if not b then
        show_net(c)
        return
    end
    ci_conn, ci_key, ci_mode = c, key, nil
    E.ui.conn, E.ui.buf = nil, nil
    E.chan_info_req(c, key)   -- MODE <chan>: current modes + creation time
    swap_view("chaninfo", function(v)
        set_header(b.name, net_label(c))
        btn(v, "Back", 56, function()
            ci_conn = nil
            show_chat(c, key)
        end)
        -- CHANMODES type A = the mask lists this server actually has.
        local amodes = (c.isupport.chanmodes and c.isupport.chanmodes.a) or "beI"
        local function lbtn(mode, label, w)
            if not amodes:find(mode, 1, true) then return end
            btn(v, label, w, function()
                if ci_mode == mode then
                    ci_mode = nil
                elseif E.chan_list_req(c, key, mode) then
                    ci_mode = mode
                else
                    toast("Not connected")
                end
                refresh_chaninfo()
            end)
        end
        lbtn("b", "Bans", 56)
        lbtn("e", "Excepts", 76)
        lbtn("I", "Invites", 72)
        local sc = v:Object {
            w = lvgl.PCT(100), h = BODY_H - 38,
            bg_color = COL_CARD, border_width = 1, border_color = COL_BORD,
            pad_all = 4,
        }
        ci_label = sc:Label { text = "", w = lvgl.PCT(100),
                              text_color = COL_TEXT }
    end)
    refresh_chaninfo()
end

-- ── channel list (/LIST) ─────────────────────────────────────────────────────
-- The engine keeps the largest 500 channels of the reply; this browser shows
-- the top CL_ROWS of them (filter narrows), and joining is a tap away. The
-- rows are a fixed pool: the list streams in, so they are re-texted rather
-- than rebuilt, which keeps the scroll position.

local CL_ROWS = 60
local CL_MINS = { 1, 5, 20, 100 }
local cl_conn, cl_filter, cl_rows, cl_items
local cl_min_i = 2

local function chanlist_shown()
    local out = {}
    local L = cl_conn and E.list_get(cl_conn)
    if not L then return out end
    local f = cl_filter and cl_filter:lower() or nil
    for i = 1, #L.items do
        local it = L.items[i]
        if not f or it.name:lower():find(f, 1, true)
            or (it.topic or ""):lower():find(f, 1, true) then
            out[#out + 1] = it
        end
    end
    table.sort(out, function(a, b)
        if a.users ~= b.users then return a.users > b.users end
        return a.name:lower() < b.name:lower()
    end)
    return out
end

local function chanlist_menu(c, it)
    menu(it.name .. "  (" .. it.users .. ")", {
        { "Join", function()
            if c.st ~= "up" then
                toast("Not connected")
                return
            end
            E.join(c, it.name)
            toast("Joining " .. it.name)
        end },
        { "Topic", function()
            local t = plain(it.topic or "")
            text_popup(it.name, t ~= "" and t or "(no topic)")
        end },
    })
end

local function chanlist_menu_open()
    local c = cl_conn
    if not c then return end
    local function request()
        if not E.list_req(c, CL_MINS[cl_min_i]) then toast("Not connected") end
        refresh_chanlist()
    end
    local items = {}
    items[#items + 1] = { "Filter...", function()
        prompt("Filter channels", cl_filter or "", function(text)
            cl_filter = text
            refresh_chanlist()
        end)
    end }
    if cl_filter then
        items[#items + 1] = { "Show all", function()
            cl_filter = nil
            refresh_chanlist()
        end }
    end
    items[#items + 1] = { "Refresh", request }
    items[#items + 1] = { "Minimum users: " .. CL_MINS[cl_min_i], function()
        cl_min_i = (cl_min_i % #CL_MINS) + 1
        request()
    end }
    menu("Channels", items)
end

refresh_chanlist = function()
    if not (cl_conn and cl_rows) then return end
    local L = E.list_get(cl_conn)
    cl_items = chanlist_shown()
    set_header("Channels", #cl_items .. "/" .. ((L and L.seen) or 0)
        .. ((L and L.done) and "" or " ..."))
    local n = math.min(#cl_items, CL_ROWS)
    for i = 1, CL_ROWS do
        local r = cl_rows[i]
        local it = cl_items[i]
        if i <= n then
            row_update(r, trunc(it.name .. "  " .. plain(it.topic or ""), 28),
                tostring(it.users), false)
            r.row:clear_flag(lvgl.FLAG.HIDDEN)
        else
            r.row:add_flag(lvgl.FLAG.HIDDEN)
        end
    end
end

show_chanlist = function(c)
    cl_conn, cl_filter, cl_items = c, nil, {}
    E.ui.conn, E.ui.buf = nil, nil
    swap_view("chanlist", function(v)
        set_header("Channels", net_label(c))
        btn(v, "Back", 56, function()
            cl_conn = nil
            show_net(c)
        end)
        btn(v, "Menu", 64, chanlist_menu_open)
        local list, bind = make_list(v, BODY_H - 38)
        cl_rows = {}
        for i = 1, CL_ROWS do
            local r = make_row(list, bind, function()
                local it = cl_items[i]
                if it then chanlist_menu(c, it) end
            end)
            r.row:add_flag(lvgl.FLAG.HIDDEN)
            cl_rows[i] = r
        end
    end)
    -- The first visit asks; Menu > Refresh asks again.
    if not E.list_get(c) and not E.list_req(c, CL_MINS[cl_min_i]) then
        toast("Not connected")
    end
    refresh_chanlist()
end

-- /list opens the browser too (it is already open when the request came
-- from inside it).
E.ui_list = function(c)
    if cur_view == "chanlist" and cl_conn == c then return end
    show_chanlist(c)
end

-- ── certificate trust ────────────────────────────────────────────────────────

show_cert = function(c)
    swap_view("cert", function(v)
        set_header("Certificate", net_label(c))
        btn(v, "Trust", 150, function()
            E.trust(c.id)
            show_net(c)
        end, 28)
        btn(v, "Cancel", 150, function()
            E.reject(c.id)
            show_net(c)
        end, 28)
        local cert = c.cert or {}
        local function fline(k, val)
            v:Label { text = k .. ": " .. tostring(val or "?"),
                      w = lvgl.PCT(100), text_color = COL_TEXT }
        end
        fline("host", c.net.host .. ":" .. c.net.port)
        fline("subject", cert.cert_subject)
        fline("issuer", cert.cert_issuer)
        fline("valid to", cert.cert_valid_to)
        fline("sha256", cert.cert_sha256)
        v:Label { text = "Trust pins this certificate; the network then "
                  .. "refuses any other. A later 'certificate changed' error "
                  .. "means the server's certificate really changed.",
                  w = lvgl.PCT(100), text_color = COL_TEXT }
    end)
end

-- ── settings ─────────────────────────────────────────────────────────────────

show_settings = function()
    E.ui.conn, E.ui.buf = nil, nil
    swap_view("settings", function(v)
        set_header("Settings", "")
        btn(v, "Back", 64, function() show_nets() end)
        local S = E.settings
        local function trow(label, skey, on_txt, off_txt)
            local function lbl()
                return label .. ": "
                    .. (S[skey] and (on_txt or "on") or (off_txt or "off"))
            end
            local b = btn(v, lbl(), lvgl.PCT(100), function() end, 28)
            b:onClicked(safe(function()
                S[skey] = not S[skey]
                cfg.save_settings(S)
                b:get_child(0):set { text = lbl() }
            end))
        end
        trow("Message colors", "true_colors", "true IRC", "theme")
        trow("Connection notifications", "notify_conn")
        trow("Login failure notifications", "notify_login")
        trow("Certificate notifications", "notify_cert")
        trow("Answer CTCP (version/time)", "ctcp_replies")
        trow("Background memory", "bg_low_mem", "low", "full")

        -- ── memory ──
        -- Everything the app keeps lives in the Lua heap, which it shares
        -- with every other app, so these are its budget. Measured on device:
        -- a stored line holding a short message costs 220 bytes, one holding
        -- a long message 304, and one carrying formatting, a server
        -- timestamp and a message id 357. An empty buffer is 247 bytes and a
        -- channel member 92.
        local LINE_BYTES = 220
        local est_lbl
        local function est_text()
            local per_net = S.max_chans * S.cap_chat + S.max_pms * S.cap_pm
            local kb = math.floor((per_net * LINE_BYTES) / 1024)
            local nets = math.max(1, #E.nets)
            local chans, pms = E.buffer_counts()
            return "At these limits one network can hold about " .. kb
                .. "KB of messages, " .. (kb * nets) .. "KB across " .. nets
                .. ". Measured on this device: 220 bytes a line for a short "
                .. "message, up to about 360 for a long or formatted one. "
                .. "Holding now: " .. chans .. " channels, " .. pms
                .. " private chats, " .. math.floor(collectgarbage("count"))
                .. "KB of Lua heap, shared with every other app."
        end
        local function crow(label, skey, vals, zero_txt)
            local function lbl()
                local vv = S[skey]
                return label .. ": "
                    .. ((vv == 0 and zero_txt) and zero_txt or tostring(vv))
            end
            local b, l = btn(v, lbl(), lvgl.PCT(100), function() end, 28)
            b:onClicked(safe(function()
                local cur, idx = S[skey], 1
                for i = 1, #vals do
                    if vals[i] == cur then
                        idx = i
                        break
                    end
                end
                S[skey] = vals[(idx % #vals) + 1]
                cfg.save_settings(S)
                l:set { text = lbl() }
                E.apply_caps()
                if est_lbl then est_lbl:set { text = est_text() } end
            end))
        end
        crow("Channel lines kept", "cap_chat", { 50, 100, 200, 300, 500 })
        crow("Private chat lines kept", "cap_pm", { 25, 50, 100, 200 })
        crow("Raw log lines kept", "cap_log", { 0, 100, 250, 500 }, "off")
        crow("Max channels", "max_chans", { 5, 10, 20, 50 })
        crow("Max private chats", "max_pms", { 5, 10, 20, 50 })
        est_lbl = v:Label { text = est_text(), w = lvgl.PCT(100),
                            text_color = COL_TEXT }

        v:Label { text = "Message colors apply the next time a chat opens. "
            .. "Per-channel notification modes (Off / Mentions / All) are "
            .. "set from each chat's Menu. Lowering a cap drops the oldest "
            .. "lines at once. At a limit, new channels and new private "
            .. "chats are refused until one is closed. Background memory "
            .. "'low' shrinks every buffer while another app is in front.",
            w = lvgl.PCT(100), text_color = COL_TEXT }
    end)
end

-- ── network editor ───────────────────────────────────────────────────────────
-- back() runs after Save or Cancel.

show_editor = function(net, is_new, back)
    E.ui.conn, E.ui.buf = nil, nil
    swap_view("edit", function(v)
        set_header(is_new and "Add network" or "Edit network",
            is_new and "" or (net.name ~= "" and net.name or net.host))

        local save_btn = btn(v, "Save", 150, function() end, 28)
        btn(v, "Cancel", 150, function() back() end, 28)
        local err_lbl = v:Label { text = "", w = lvgl.PCT(100), text_color = COL_HI }

        local function field(label, value)
            v:Label { text = label, w = 90, text_color = COL_TEXT }
            return v:Textarea { one_line = true, text = tostring(value),
                                w = INNER_W - 90 - 4 - 2, h = 30 }
        end
        local f_name  = field("name", net.name)
        local f_host  = field("host", net.host)
        local f_port  = field("port", net.port)
        local f_nick  = field("nick", net.nick)
        local f_alts  = field("alt nicks", net.alt_nicks)
        local f_real  = field("realname", net.realname)
        local f_user  = field("account", net.user)
        local f_pass  = field("password", net.password)
        local f_spass = field("server pw", net.server_password)
        local f_perf  = field("perform", net.perform)
        local f_hl    = field("highlights", net.highlight_words)
        local f_pin   = field("pin", net.pin)

        local function toggle(label_of, get, flip)
            local b = btn(v, label_of(get()), 150, function() end, 28)
            b:onClicked(safe(function()
                flip()
                b:get_child(0):set { text = label_of(get()) }
            end))
            return b
        end
        local tls_on = net.tls
        toggle(function(x) return "TLS: " .. (x and "on" or "off") end,
            function() return tls_on end, function() tls_on = not tls_on end)
        local AUTHS = { "none", "sasl_plain", "pass" }
        local auth_i = 1
        for i = 1, #AUTHS do if AUTHS[i] == net.auth then auth_i = i end end
        toggle(function() return "Auth: " .. AUTHS[auth_i] end,
            function() return auth_i end,
            function() auth_i = auth_i % #AUTHS + 1 end)
        local verify_pin = net.verify == "pin"
        toggle(function(x) return "Verify: " .. (x and "pin" or "ca") end,
            function() return verify_pin end,
            function() verify_pin = not verify_pin end)
        local autoconn = net.autoconnect
        toggle(function(x) return "Autoconnect: " .. (x and "on" or "off") end,
            function() return autoconn end, function() autoconn = not autoconn end)
        local joins = net.show_joins
        toggle(function(x) return "Joins/parts: " .. (x and "on" or "off") end,
            function() return joins end, function() joins = not joins end)

        save_btn:onClicked(safe(function()
            local host = f_host:get("text"):gsub("%s+", "")
            if host == "" then
                err_lbl:set { text = "host is required" }
                return
            end
            local pin = f_pin:get("text"):gsub("%s+", ""):lower()
            if verify_pin and pin ~= "" and not pin:match("^%x+$") then
                err_lbl:set { text = "pin must be hex (or empty to capture)" }
                return
            end
            net.name = f_name:get("text")
            net.host = host
            net.port = tonumber(f_port:get("text")) or (tls_on and 6697 or 6667)
            net.nick = f_nick:get("text"):gsub("%s+", "")
            net.alt_nicks = f_alts:get("text")
            net.realname = f_real:get("text")
            net.user = f_user:get("text"):gsub("%s+", "")
            net.password = f_pass:get("text")
            net.server_password = f_spass:get("text")
            net.perform = f_perf:get("text")
            net.highlight_words = f_hl:get("text")
            net.pin = pin
            net.tls = tls_on
            net.auth = AUTHS[auth_i]
            net.verify = verify_pin and "pin" or "ca"
            net.autoconnect = autoconn
            net.show_joins = joins
            if net.nick == "" then net.nick = "meshpunk" end
            if is_new then E.add_net(net) else E.save_nets() end
            back()
        end))
    end)
end

-- ── raw console ──────────────────────────────────────────────────────────────

local con_scroll, con_label, con_conn

local function render_raw(c)
    local r = c.raw
    if (E.settings.cap_log or 0) <= 0 then
        return "The raw log is off.\n\nSettings > Raw log lines kept turns "
            .. "it on; it also puts every line on the serial console."
    end
    local first = #r > 44 and (#r - 43) or 1
    local out = {}
    for i = first, #r do
        out[#out + 1] = plain(r[i])
    end
    return utils.emojiText(table.concat(out, "\n"))
end

refresh_console = function()
    if not (con_conn and con_label) then return end
    set_header("Raw log", net_label(con_conn)
        .. (con_conn.lag and (" " .. con_conn.lag .. "s") or ""))
    con_label:set { text = render_raw(con_conn) }
    pcall(function() con_scroll:scroll_to { y = 1000000, anim = false } end)
end

show_console = function(c)
    con_conn = c
    E.ui.conn, E.ui.buf = c.id, nil
    swap_view("console", function(v)
        btn(v, "Back", 64, function()
            con_conn = nil
            show_net(c)
        end)
        con_scroll = v:Object {
            w = lvgl.PCT(100), h = BODY_H - 74,
            bg_color = COL_CARD, border_width = 1, border_color = COL_BORD,
            pad_all = 4,
        }
        con_label = con_scroll:Label { text = "", w = lvgl.PCT(100),
                                       text_color = COL_TEXT }
        local ta = v:Textarea { one_line = true, text = "",
                                w = INNER_W - 70 - 4 - 2, h = 32 }
        local function send()
            local text = ta:get("text")
            if text ~= "" then
                local ok, err = pcall(E.handle_input, c, text, nil)
                if not ok then print("[irc] input error: " .. tostring(err)) end
                ta:set { text = "" }
            end
        end
        ta:onevent(lvgl.EVENT.KEY, safe(function()
            local indev = lvgl.indev.get_act()
            if indev and indev:get_key() == lvgl.KEY.ENTER then send() end
        end))
        btn(v, "Send", 70, send, 32)
    end)
    refresh_console()
end

-- ── foreground heartbeat ─────────────────────────────────────────────────────
-- Row texts carry relative times and retry countdowns that age without any
-- engine change, so the list views also refresh every 5s.

local last_forced = 0

apps.add_timer { period = 250, cb = function()
    local ok, err = pcall(E.tick)
    if not ok then print("[irc] tick error: " .. tostring(err)) end
    E.ui.seen = E.mono
    if popup_depth > 0 then return end
    if (cur_view == "nets" or cur_view == "net")
        and E.mono - last_forced >= 5 then
        last_forced = E.mono
        shown_gen = -1
    end
    if E.gen ~= shown_gen then
        shown_gen = E.gen
        local ok2, err2 = pcall(function()
            if cur_view == "chat" then refresh_chat()
            elseif cur_view == "net" then refresh_net()
            elseif cur_view == "nets" then refresh_nets()
            elseif cur_view == "console" then refresh_console()
            elseif cur_view == "whois" then refresh_whois()
            elseif cur_view == "chaninfo" then refresh_chaninfo()
            elseif cur_view == "chanlist" then refresh_chanlist()
            elseif cur_view == "members" then refresh_members() end
        end)
        if not ok2 then print("[irc:ui] refresh error: " .. tostring(err2)) end
    end
end }

show_nets()

return root
