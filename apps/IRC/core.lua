--[[
  IRC app - UI-free engine. Lives in the background record's state and is
  driven by tick() from the foreground timer and the background manager
  alike; nothing here touches LVGL.

  corelib.new{cfg=, parse=, cmds=} -> E:
    E.tick()                    advance every connection (recv/parse/send/
                                keepalive/reconnect/WiFi kick)
    E.status()                  launcher background-row line
    E.quit_all()                background contract on_close: QUIT + close all
    E.connect_net(id) / E.disconnect_net(id)
    E.add_net(net) / E.delete_net(id) / E.save_nets()
    E.privmsg(c, target, text, kind)   split + flood-queue + echo
    E.sendline(c, line)         flood-queued raw line
    E.direct(c, line)           immediate raw line (registration, PONG)
    E.conninfo(c, text)         info line into the connection's server buffer
    E.handle_input(c, text)     slash-command entry from the UI
    E.join(c, "#chan [key]")    JOIN + add it to the network's channel list
    E.whois(c, nick)            WHOIS + collect its numerics into c.whois
    E.chan_info_req/chan_list_req   MODE <chan> / MODE <chan> +b|+e|+I
    E.history_latest/history_before  CHATHISTORY, replayed into the buffer

  Timebase: E.mono, seconds, advanced from utils.now() deltas clamped to
  [0,10] so a GPS clock sync cannot fire timeouts or refill the flood
  bucket. Reconnect backoff 5/15/60 then 300s; stopped by server ERROR,
  465, registration/SASL failure and user disconnect. After 90s of RX
  silence a PING goes out; 60s without an answer closes the connection.
]]

local utils = require("lib/utils")
local wifi = require("lib/wifi")

local M = {}

local WANTED_CAPS = {
    "sasl", "server-time", "message-tags", "batch", "multi-prefix",
    "userhost-in-names", "extended-join", "away-notify", "account-notify",
    "account-tag", "chghost", "setname", "invite-notify", "echo-message",
    "labeled-response", "cap-notify", "draft/chathistory", "chathistory",
    "draft/multiline",
}
local RECON_DELAYS = { 5, 15, 60 }
-- How far past its cap a buffer runs before a trim: trimming in batches
-- keeps the shift (and the chat view's index shift) off the hot path.
local BUF_SLACK = 30
local BG_DIVISOR = 4       -- background diet: a quarter of the caps
local BG_FLOOR = 25        -- ...but never fewer lines than this
local HIST_N = 50          -- lines per CHATHISTORY request
local WHOIS_CAP = 8        -- whois records kept per connection
local LIST_CAP = 100       -- +b/+e/+I entries kept per channel
local LIST_KEEP = 500      -- channels kept from a /LIST
local LIST_SLACK = 100     -- how far past LIST_KEEP it grows before a compact

-- WHOIS/WHOWAS numerics whose params[2] is the nick and whose last param is
-- a ready-made sentence ("is an IRC operator", "is using a secure
-- connection", ...). The structured ones (311/312/317/319/330/301) are read
-- field by field instead.
local WHOIS_TEXT = {
    ["276"] = true, ["307"] = true, ["310"] = true, ["313"] = true,
    ["320"] = true, ["335"] = true, ["338"] = true, ["378"] = true,
    ["379"] = true, ["671"] = true,
}

-- Numerics that answer something the user did to one channel or nick:
-- they belong in that buffer, where the attempt was made, instead of the
-- server log. The value is the parameter holding the target (params[1] is
-- always our own nick); 3 means params[2] names a nick the text is about.
-- 401 no such nick, 403 no such channel, 404 cannot send, 405 too many
-- channels, 407 too many targets, 437 unavailable, 441 not in channel,
-- 442 not on channel, 443 already on channel, 470 forwarding, 471 +l full,
-- 473 +i, 474 +b, 475 +k, 476 bad mask, 477 needs a registered nick,
-- 478 ban list full, 479 bad name, 480 cannot knock, 482 not operator,
-- 485 unique op needed, 489 secure only, 341 invite sent, 301 the nick you
-- messaged is away (during a WHOIS it is part of the card instead).
local TARGET_NUM = {
    ["301"] = 2,
    ["401"] = 2, ["403"] = 2, ["404"] = 2, ["405"] = 2, ["407"] = 2,
    ["437"] = 2, ["442"] = 2, ["470"] = 2, ["471"] = 2, ["473"] = 2,
    ["474"] = 2, ["475"] = 2, ["476"] = 2, ["477"] = 2, ["478"] = 2,
    ["479"] = 2, ["480"] = 2, ["482"] = 2, ["485"] = 2, ["489"] = 2,
    ["441"] = 3, ["443"] = 3, ["341"] = 3,
}

local B64C = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64(s)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        out[#out + 1] = B64C:sub((n >> 18) + 1, (n >> 18) + 1)
            .. B64C:sub(((n >> 12) & 63) + 1, ((n >> 12) & 63) + 1)
            .. (b and B64C:sub(((n >> 6) & 63) + 1, ((n >> 6) & 63) + 1) or "=")
            .. (c and B64C:sub((n & 63) + 1, (n & 63) + 1) or "=")
    end
    return table.concat(out)
end

-- Characters legal in nicks: a word-boundary check for highlight matching.
local NICKSET = "[%w%[%]`_^{|}\\%-]"

function M.new(deps)
    local parse = deps.parse
    local cmds = deps.cmds

    local E = {
        nets = deps.cfg.load_networks(),
        settings = deps.cfg.load_settings(),
        conns = {}, order = {},
        gen = 0, mono = 0, _wall = nil,
        act_seq = 0,   -- bumped per buffer creation and per line; b.act = recency
        ui = { conn = nil, seen = -999 },
        _last_kick = -999, _wifi_notified = false, _wifi_off_notified = false,
    }

    local function dirty() E.gen = E.gen + 1 end

    -- ── logging into a connection ────────────────────────────────────────

    -- The raw wire log, and the serial trace with it: both are off unless
    -- the user gives the log a line budget (Settings). The prefix stays a
    -- separate argument so nothing is built while it is off.
    local function rawlog(c, pfx, s)
        local cap = E.settings.cap_log or 0
        if cap <= 0 then return end
        local line = pfx .. s
        print("[irc:" .. c.id .. "] " .. line)
        local r = c.raw
        r[#r + 1] = line
        if #r > cap + 20 then
            local drop = #r - cap
            table.move(r, drop + 1, #r, 1, r)
            for i = #r, cap + 1, -1 do r[i] = nil end
        end
        dirty()
    end

    local function buf_get(c, key, name, btype)
        local b = c.buffers[key]
        if not b then
            b = { key = key, name = name or key, type = btype or "query",
                  lines = {}, unread = 0, hl = 0, members = {}, topic = "" }
            c.buffers[key] = b
            c.buforder[#c.buforder + 1] = key
            E.act_seq = E.act_seq + 1
            b.act = E.act_seq
        end
        return b
    end

    -- Buffers ARE the app's memory, so the user's per-network limits cap how
    -- many of each kind may exist.
    local function count_type(c, t)
        local n = 0
        for i = 1, #c.buforder do
            local b = c.buffers[c.buforder[i]]
            if b and b.type == t then n = n + 1 end
        end
        return n
    end

    local function room_for(c, t)
        local max = (t == "query") and E.settings.max_pms or E.settings.max_chans
        if not max or max <= 0 then return true end
        return count_type(c, t) < max
    end

    -- Lines a buffer may keep: the user's cap for its kind, cut to the
    -- background share while another app is in front.
    local function buf_cap(c, b)
        local s = E.settings
        local n = (b.type == "query" and s.cap_pm or s.cap_chat) or 100
        if E.low_mem then
            n = n // BG_DIVISOR
            if n < BG_FLOOR then n = BG_FLOOR end
        end
        if n < 10 then n = 10 end
        return n
    end

    -- Drop the oldest lines down to the cap. `shrink` builds a smaller array
    -- (the diet and a settings change want the memory back now); the
    -- steady-state trim shifts inside the array it already has, so a busy
    -- channel stops allocating a new one every few dozen messages.
    -- b.trim_n = total lines dropped from the front; a view holding line
    -- indices shifts them by the difference.
    local function trim_buf(c, b, shrink)
        local keep = buf_cap(c, b)
        local ls = b.lines
        local drop = #ls - keep
        if drop <= 0 then return end
        b.trim_n = (b.trim_n or 0) + drop
        if shrink then
            local out = {}
            table.move(ls, drop + 1, #ls, 1, out)
            b.lines = out
        else
            table.move(ls, drop + 1, #ls, 1, ls)
            for i = #ls, keep + 1, -1 do ls[i] = nil end
        end
    end

    -- Hand memory back while another app is in front: the raw ring and any
    -- channel-list result go, and every buffer shrinks into a fresh, smaller
    -- array - releasing the old one is the whole point.
    local function diet()
        for i = 1, #E.order do
            local c = E.conns[E.order[i]]
            c.raw = {}
            c.list = nil
            for k = 1, #c.buforder do
                trim_buf(c, c.buffers[c.buforder[k]], true)
            end
        end
        collectgarbage("collect")
        dirty()
        print("[irc] background diet done, lua heap "
            .. math.floor(collectgarbage("count")) .. "KB")
    end

    -- text = display text without formatting codes; fmt = the same text WITH
    -- its codes (only set when it had any). Returns the stored line.
    local function bufline(c, key, src, text, kind, srvtime, hl, fmt)
        local b = c.buffers[key] or buf_get(c, key)
        local ls = b.lines
        local L = { t = utils.now(), src = src, text = text, kind = kind,
                    srvtime = srvtime, hl = hl, fmt = fmt }
        ls[#ls + 1] = L
        E.act_seq = E.act_seq + 1
        b.act = E.act_seq
        if #ls > buf_cap(c, b) + BUF_SLACK then trim_buf(c, b, false) end
        dirty()
        return L
    end

    local function info(c, text)
        rawlog(c, "-- ", text)
        bufline(c, c.skey, nil, text, "info")
    end

    -- ── send paths ───────────────────────────────────────────────────────

    -- Immediate: registration and PONG must not sit behind the flood bucket.
    local function tx(c, line)
        if not c.sock then return end
        local n = c.sock:send(line .. "\r\n")
        if n then rawlog(c, ">> ", line) end
    end

    -- Flood-queued (token bucket: burst 5, then 1 line per 2s).
    local function q(c, line)
        if #c.sendq >= 100 then
            info(c, "send queue full - dropped: " .. line:sub(1, 40))
            return
        end
        c.sendq[#c.sendq + 1] = line
    end

    local function pump_send(c, dt)
        c.tokens = math.min(5, c.tokens + dt * 0.5)
        while c.sendq[1] and c.tokens >= 1 do
            local line = c.sendq[1]
            local n = c.sock and c.sock:send(line .. "\r\n") or nil
            if not n then break end
            table.remove(c.sendq, 1)
            c.tokens = c.tokens - 1
            rawlog(c, ">> ", line)
        end
    end

    -- ── the persistent channel list ──────────────────────────────────────
    -- net.channels ("#a,#b key,#c") is every channel the engine is in. It
    -- is rejoined on every connect and survives the app closing, so joining
    -- and parting rewrite it in networks.cfg.

    local function chan_entries(net)
        local out = {}
        for entry in (net.channels or ""):gmatch("[^,]+") do
            local name, k = entry:match("^%s*(%S+)%s*(%S*)")
            if name and name ~= "" then
                out[#out + 1] = { name = name, key = (k ~= "" and k) or nil }
            end
        end
        return out
    end

    local function chan_save(c, list)
        local out = {}
        for i = 1, #list do
            out[#out + 1] = list[i].name
                .. (list[i].key and (" " .. list[i].key) or "")
        end
        c.net.channels = table.concat(out, ",")
        deps.cfg.save_networks(E.nets)
        dirty()
    end

    local function chan_remember(c, name, key)
        local cm = c.isupport.CASEMAPPING
        local want = parse.casemap(name, cm)
        local list = chan_entries(c.net)
        for i = 1, #list do
            if parse.casemap(list[i].name, cm) == want then
                if key and list[i].key ~= key then
                    list[i].key = key
                    chan_save(c, list)
                end
                return
            end
        end
        list[#list + 1] = { name = name, key = key }
        print("[irc:" .. c.id .. "] channels + " .. name)
        chan_save(c, list)
    end

    local function chan_forget(c, name)
        local cm = c.isupport.CASEMAPPING
        local want = parse.casemap(name, cm)
        local list = chan_entries(c.net)
        for i = #list, 1, -1 do
            if parse.casemap(list[i].name, cm) == want then
                table.remove(list, i)
                print("[irc:" .. c.id .. "] channels - " .. name)
                chan_save(c, list)
                return
            end
        end
    end

    -- ── connection lifecycle ─────────────────────────────────────────────

    local function conn_new(net)
        local c = {
            id = net.id, net = net,
            st = "off", want = false,
            sock = nil, rbuf = "", pending = {}, pend_i = 1,
            raw = {},
            buffers = {}, buforder = {},
            caps = {}, offered = {},
            whois = {}, batches = {}, join_keys = {},
            sasl_wait = false, sasl_done = false, cap_ending = false,
            isupport = {},
            nick = net.nick, alt_idx = 0,
            prefixlen = 96,
            sendq = {}, tokens = 5,
            lastrx = 0, ping_at = nil, lag = nil,
            conn_started = 0, reg_start = 0,
            recon_n = 0, recon_at = 0,
            no_reconnect = false,
            skey = "*server*",
        }
        buf_get(c, c.skey, net.name ~= "" and net.name or net.host, "server")
        -- The saved channels get their buffers straight away, so they are
        -- on the network page before the connection is even up.
        local maxc = E.settings.max_chans or 0
        local n = 0
        for _, e in ipairs(chan_entries(net)) do
            n = n + 1
            if maxc > 0 and n > maxc then break end
            buf_get(c, parse.casemap(e.name, nil), e.name, "channel")
        end
        return c
    end

    local function conn_close_sock(c)
        if c.sock then
            pcall(function() c.sock:close() end)
            c.sock = nil
        end
    end

    -- Membership is the server's, not ours: it ends with the connection.
    -- The next connect rejoins everything in net.channels.
    local function drop_membership(c)
        for _, bkey in ipairs(c.buforder) do
            local b = c.buffers[bkey]
            if b.type == "channel" then
                b.joined = false
                b.members = {}
            end
        end
    end

    local function lost(c, reason)
        conn_close_sock(c)
        c.rbuf, c.pending, c.pend_i = "", {}, 1
        c.batches = {}   -- an unfinished batch never completes
        if c.list then c.list.done = true end
        drop_membership(c)
        c.sendq, c.tokens = {}, 5
        c.ping_at = nil
        c.st = "off"
        c.last_reason = reason
        c.capture = nil   -- a capture connect is one-shot, never auto-retried
        info(c, "disconnected: " .. reason)
        print("[irc] " .. c.id .. " lost: " .. reason)
        if c.no_reconnect or not c.want then
            c.want = false
            return
        end
        c.recon_n = c.recon_n + 1
        local delay = RECON_DELAYS[c.recon_n] or 300
        c.st = "backoff"
        c.recon_at = E.mono + delay
        info(c, "reconnecting in " .. delay .. "s")
    end

    local function start(c)
        if _wifi_status() ~= "connected" then
            c.st = "waiting_wifi"
            return
        end
        local net = c.net
        local opts = { tls = net.tls, timeout_ms = 15000 }
        if net.tls then
            if c.capture then
                opts.verify = "pin"   -- no pin: handshake lands in "untrusted"
                                      -- so the trust screen can read the cert
            elseif net.verify == "pin" then
                opts.verify = "pin"
                if net.pin ~= "" then opts.pin = net.pin end
            else
                opts.verify = "ca"
            end
        end
        local s, err = _tcp_open(net.host, net.port, opts)
        if not s then
            info(c, "open failed: " .. tostring(err))
            lost(c, tostring(err))
            return
        end
        c.sock = s
        c.st = "connecting"
        c.conn_started = E.mono
        info(c, "connecting to " .. net.host .. ":" .. net.port
            .. (net.tls and " (tls)" or ""))
        print("[irc] " .. c.id .. " connecting " .. net.host .. ":" .. net.port)
    end

    local function register(c)
        print("[irc] " .. c.id .. " registering as " .. c.net.nick)
        c.st = "registering"
        c.reg_start = E.mono
        c.offered, c.caps = {}, {}
        c.sasl_wait, c.sasl_done, c.cap_ending = false, false, false
        c.alt_idx = 0
        c.nick = c.net.nick
        tx(c, "CAP LS 302")
        if c.net.server_password ~= "" then
            tx(c, "PASS :" .. c.net.server_password)
        elseif c.net.auth == "pass" and c.net.password ~= "" then
            tx(c, "PASS :" .. c.net.password)
        end
        tx(c, "NICK " .. c.nick)
        local user = c.net.user ~= "" and c.net.user or c.nick
        local real = c.net.realname ~= "" and c.net.realname or c.nick
        tx(c, "USER " .. user .. " 0 * :" .. real)
    end

    local function cap_finish(c)
        if not c.cap_ending then
            c.cap_ending = true
            tx(c, "CAP END")
        end
    end

    -- A failed login never continues unauthenticated.
    local function login_fail(c, why)
        info(c, "login failed: " .. why)
        if E.settings.notify_login then
            pcall(_notify_post, "IRC "
                .. (c.net.name ~= "" and c.net.name or c.net.host)
                .. ": login failed - " .. why)
        end
        c.no_reconnect = true
        c.want = false
        lost(c, "login failed")
    end

    -- ── highlights + notifications ───────────────────────────────────────

    local function word_hit(hay, needle)
        if needle == "" then return false end
        local from = 1
        while true do
            local s, e = hay:find(needle, from, true)
            if not s then return false end
            local before = s > 1 and hay:sub(s - 1, s - 1) or ""
            local after = e < #hay and hay:sub(e + 1, e + 1) or ""
            if not (before ~= "" and before:match(NICKSET))
                and not (after ~= "" and after:match(NICKSET)) then
                return true
            end
            from = e + 1
        end
    end

    -- The folded nick and highlight words are the same for every message:
    -- fold them once and rebuild only when one of their sources changes.
    local function is_highlight(c, plain)
        local cm = c.isupport.CASEMAPPING
        local words = c.net.highlight_words
        if c.hl_nick_src ~= c.nick or c.hl_words_src ~= words
            or c.hl_cm ~= cm then
            c.hl_nick_src, c.hl_words_src, c.hl_cm = c.nick, words, cm
            c.hl_nick = parse.casemap(c.nick, cm)
            c.hl_words = {}
            for w in words:gmatch("[^,%s]+") do
                c.hl_words[#c.hl_words + 1] = parse.casemap(w, cm)
            end
        end
        local hay = parse.casemap(plain, cm)
        if word_hit(hay, c.hl_nick) then return true end
        for i = 1, #c.hl_words do
            if word_hit(hay, c.hl_words[i]) then return true end
        end
        return false
    end

    -- Is the UI live on this buffer right now? The foreground timer stamps
    -- ui.seen every pass, so a backgrounded app stops matching within 2s
    -- with no lifecycle hook. ui.buf == nil (the raw console) counts as
    -- viewing every buffer of that connection.
    local function viewing(c, key)
        if E.ui.conn ~= c.id then return false end
        if (E.mono - E.ui.seen) >= 2 then return false end
        return E.ui.buf == nil or E.ui.buf == key
    end

    local function maybe_notify(c, b, from, text)
        if viewing(c, b.key) then return end
        print("[irc:" .. c.id .. "] notify " .. b.name .. " <" .. from .. ">")
        local netname = c.net.name ~= "" and c.net.name or c.net.host
        local t = text
        if #t > 100 then t = (parse.cut(t, 100)) end
        pcall(_notify_post,
            "IRC " .. netname .. " " .. b.name .. " " .. from .. ": " .. t)
    end

    -- ── message routing ──────────────────────────────────────────────────

    local function me_nick(c, nick)
        local cm = c.isupport.CASEMAPPING
        return parse.casemap(nick or "", cm) == parse.casemap(c.nick, cm)
    end

    local function is_chan_name(c, name)
        local first = name:sub(1, 1)
        if first == "" then return false end
        local chant = tostring(c.isupport.CHANTYPES or "#&")
        return chant:find(first, 1, true) ~= nil
    end

    local function handle_msg(c, m, is_notice)
        local from = m.nick or m.prefix or "?"
        local target = m.params[1] or ""
        local text = m.params[2] or ""
        local cm = c.isupport.CASEMAPPING
        local me = me_nick(c, from)
        if me and m.prefix and m.prefix:find("!", 1, true) then
            c.prefixlen = #m.prefix   -- our real nick!user@host, for the 512 split
        end

        local ctcp, arg = parse.ctcp(text)
        if ctcp and ctcp ~= "ACTION" then
            if is_notice then
                info(c, "ctcp reply from " .. from .. ": " .. ctcp .. " " .. (arg or ""))
            elseif not me then
                if E.settings.ctcp_replies then
                    if ctcp == "VERSION" then
                        tx(c, "NOTICE " .. from .. " :\1VERSION meshpunk-irc\1")
                    elseif ctcp == "PING" then
                        tx(c, "NOTICE " .. from .. " :\1PING " .. (arg or "") .. "\1")
                    elseif ctcp == "TIME" then
                        tx(c, "NOTICE " .. from .. " :\1TIME "
                            .. utils.clockDateTime(utils.now()) .. "\1")
                    elseif ctcp == "CLIENTINFO" then
                        tx(c, "NOTICE " .. from
                            .. " :\1CLIENTINFO ACTION CLIENTINFO PING TIME VERSION\1")
                    end
                end
                info(c, "ctcp " .. ctcp .. " from " .. from)
            end
            return
        end
        if ctcp == "ACTION" then text = arg or "" end

        local plain = parse.utf8_clean(parse.plain(text))
        local fmt = nil
        if plain ~= text then fmt = parse.utf8_clean(text) end

        -- STATUSMSG prefixes (@#chan) route to the channel's buffer.
        local disp = target
        local statusmsg = tostring(c.isupport.STATUSMSG or "")
        while statusmsg ~= "" and #disp > 1
            and statusmsg:find(disp:sub(1, 1), 1, true) do
            disp = disp:sub(2)
        end

        local key, b
        if is_chan_name(c, disp) then
            key = parse.casemap(disp, cm)
            b = buf_get(c, key, disp, "channel")
        elseif me then
            key = parse.casemap(target, cm)   -- echo of our own query line
            b = buf_get(c, key, target, "query")
        else
            key = parse.casemap(from, cm)
            b = c.buffers[key]
            if not b then
                if not room_for(c, "query") then
                    -- The limit is a memory limit: no new buffer, and the
                    -- refusal is named in the server log so nothing is silent.
                    info(c, "private chat from " .. from .. " refused (limit "
                        .. tostring(E.settings.max_pms) .. ")")
                    return
                end
                b = buf_get(c, key, from, "query")
            end
        end

        local kind = ctcp == "ACTION" and "action" or (is_notice and "notice" or "msg")
        local hl = false
        if not me then
            hl = b.type == "query" or is_highlight(c, plain)
        end
        -- One history anchor per line is enough, and each costs ~48 bytes of
        -- the ~220 a line takes: the msgid when the server sends one, its
        -- timestamp otherwise. CHATHISTORY BEFORE reads whichever is there.
        local mid = m.tags.msgid
        if mid == "" then mid = nil end
        local L = bufline(c, key, from, plain, kind,
            (not mid) and m.tags.time or nil, hl, fmt)
        if mid then L.msgid = mid end
        if not me and not viewing(c, b.key) then
            b.unread = b.unread + 1
            if hl then b.hl = b.hl + 1 end
        end
        if not me then
            local mode = c.net.notify_modes and c.net.notify_modes[b.key]
            if not mode then mode = b.type == "query" and "all" or "mentions" end
            if mode == "all" or (mode == "mentions" and hl) then
                maybe_notify(c, b, from, plain)
            end
        end
    end

    -- ── the protocol dispatcher ──────────────────────────────────────────

    -- A member's rank symbols in PREFIX order (highest first).
    local function order_pfx(c, set)
        local syms = c.isupport.prefix_syms or "@+"
        local out = {}
        for i = 1, #syms do
            local s = syms:sub(i, i)
            if set[s] then out[#out + 1] = s end
        end
        return table.concat(out)
    end

    -- Applies a channel MODE line (params p) to b: prefix modes (+o, -v, ...)
    -- move member ranks, the rest becomes b.cmodes (mode -> argument or
    -- true). Argument use per ISUPPORT: PREFIX modes and CHANMODES types A/B
    -- always take one, type C only when set, type D never (defaults when
    -- CHANMODES is absent: beI,k,l,imnpst). Type A is a mask list, not
    -- channel state, so it never lands in b.cmodes.
    local function apply_chan_modes(c, b, p)
        local cm = c.isupport.CASEMAPPING
        local pmodes = c.isupport.prefix_modes or "ov"
        local psyms = c.isupport.prefix_syms or "@+"
        local cmodes = c.isupport.chanmodes
            or { a = "beI", b = "k", c = "l", d = "imnpst" }
        local modes = p[2] or ""
        local ai = 3
        local sign = "+"
        b.cmodes = b.cmodes or {}
        for i = 1, #modes do
            local mch = modes:sub(i, i)
            if mch == "+" or mch == "-" then
                sign = mch
            else
                local pi = pmodes:find(mch, 1, true)
                if pi then
                    local nick = p[ai]
                    ai = ai + 1
                    local mem = nick and b.members[parse.casemap(nick, cm)]
                    if mem then
                        local set = {}
                        for k = 1, #mem.pfx do set[mem.pfx:sub(k, k)] = true end
                        set[psyms:sub(pi, pi)] = (sign == "+") or nil
                        mem.pfx = order_pfx(c, set)
                    end
                elseif cmodes.a:find(mch, 1, true) then
                    ai = ai + 1
                elseif cmodes.b:find(mch, 1, true) then
                    local arg = p[ai]
                    ai = ai + 1
                    b.cmodes[mch] = (sign == "+") and (arg or true) or nil
                elseif cmodes.c:find(mch, 1, true) then
                    if sign == "+" then
                        b.cmodes[mch] = p[ai] or true
                        ai = ai + 1
                    else
                        b.cmodes[mch] = nil
                    end
                else
                    b.cmodes[mch] = (sign == "+") or nil
                end
            end
        end
    end

    -- ── whois records ────────────────────────────────────────────────────

    -- One record per nick; WHOIS_CAP kept, the least recent dropped.
    local function whois_get(c, nick)
        local key = parse.casemap(nick, c.isupport.CASEMAPPING)
        local w = c.whois[key]
        if not w then
            local n, oldest, okey = 0, nil, nil
            for k, rec in pairs(c.whois) do
                n = n + 1
                if not oldest or rec.at < oldest then oldest, okey = rec.at, k end
            end
            if n >= WHOIS_CAP and okey then c.whois[okey] = nil end
            w = { extra = {} }
            c.whois[key] = w
        end
        w.nick = nick
        w.at = E.mono
        return w
    end

    -- The record a whois numeric belongs to, if any (311/314 open one for a
    -- reply we never asked for).
    local function whois_open(c, nick)
        if not nick or nick == "" then return nil end
        return c.whois[parse.casemap(nick, c.isupport.CASEMAPPING)]
    end

    -- ── channel mask lists (+b / +e / +I) ────────────────────────────────

    local function list_rec(b, mode)
        b.lists = b.lists or {}
        local rec = b.lists[mode]
        if not rec then
            rec = { items = {}, done = false }
            b.lists[mode] = rec
        end
        return rec
    end

    -- ── the channel list (/LIST) ─────────────────────────────────────────
    -- A big network answers with tens of thousands of 322s. They are kept
    -- out of the raw log, and only the LIST_KEEP largest channels are kept:
    -- once the list is full, list.floor rejects the rest with one compare.

    local function list_new(min)
        return { items = {}, seen = 0, floor = 0, done = false, min = min or 0 }
    end

    local function list_compact(L)
        table.sort(L.items, function(a, b)
            if a.users ~= b.users then return a.users > b.users end
            return a.name < b.name
        end)
        if #L.items > LIST_KEEP then
            for i = #L.items, LIST_KEEP + 1, -1 do L.items[i] = nil end
            L.floor = L.items[#L.items].users
        end
    end

    local function list_add(c, name, users, topic)
        local L = c.list
        if not L or L.done or name == "" then return end
        L.seen = L.seen + 1
        if users >= L.floor then
            -- 500 kept entries hold the topics too: bound what one costs.
            if #topic > 160 then topic = (parse.cut(topic, 160)) end
            L.items[#L.items + 1] = { name = name, users = users, topic = topic }
            if #L.items >= LIST_KEEP + LIST_SLACK then list_compact(L) end
        end
        if L.seen % 100 == 0 then dirty() end   -- the browser's progress
    end

    -- ── server history (CHATHISTORY) ─────────────────────────────────────

    local function hist_cap(c)
        return c.caps["draft/chathistory"] or c.caps["chathistory"]
    end

    -- Lines per request: the server's advertised maximum, capped at HIST_N.
    -- CHATHISTORY absent or 0 means the server sets no limit.
    local function hist_n(c)
        local adv = tonumber(c.isupport.CHATHISTORY) or 0
        if adv <= 0 or adv > HIST_N then return HIST_N end
        return adv
    end

    -- One request in flight per buffer; the 15s cutoff covers a server that
    -- answers a request with no batch at all.
    local function hist_send(c, b, sel, anchor)
        if c.st ~= "up" or not hist_cap(c) then return end
        if b.type == "server" or not b.name or b.name == "" then return end
        if #b.lines >= buf_cap(c, b) then
            print("[irc:" .. c.id .. "] history " .. b.name .. ": buffer full")
            return
        end
        if b.hist_busy and (E.mono - (b.hist_at or 0)) < 15 then return end
        b.hist_busy, b.hist_at = true, E.mono
        b.hist_want = hist_n(c)
        print("[irc:" .. c.id .. "] history " .. sel .. " " .. b.name
            .. " " .. anchor)
        q(c, "CHATHISTORY " .. sel .. " " .. b.name .. " " .. anchor
            .. " " .. b.hist_want)
    end

    -- A replay is the same line as one we hold when the msgid matches, or -
    -- on a server that sends no msgids - when time, sender and text do.
    local function line_id(L)
        return L.msgid
            or ((L.srvtime or "") .. "\0" .. (L.src or "") .. "\0" .. L.text)
    end

    -- New replayed lines, oldest first, capped to the room left in the
    -- buffer (the newest of the batch win).
    local function hist_new(c, b, got)
        local have = {}
        for i = 1, #b.lines do have[line_id(b.lines[i])] = true end
        local add = {}
        for i = 1, #got do
            local L = got[i]
            local id = line_id(L)
            if not have[id] then
                add[#add + 1] = L
                have[id] = true
            end
        end
        local room = buf_cap(c, b) - #b.lines
        if #add > room then
            local keep = {}
            if room > 0 then table.move(add, #add - room + 1, #add, 1, keep) end
            add = keep
        end
        return add
    end

    -- Older than everything we hold (paging up): the lines go in FRONT.
    -- b.trim_n counts lines dropped from the front, so a prepend subtracts
    -- from it and a chat view shifts its window indices by the difference.
    -- A replay that overlaps or follows what we hold (a rejoin after being
    -- away) is merged by time instead, and b.clear_n tells the view to
    -- rebuild - its held indices no longer mean anything.
    local function hist_insert(c, b, got)
        local add = hist_new(c, b, got)
        if #add == 0 then return 0 end
        local out = {}
        if #b.lines == 0 or add[#add].t <= b.lines[1].t then
            table.move(add, 1, #add, 1, out)
            table.move(b.lines, 1, #b.lines, #add + 1, out)
            b.trim_n = (b.trim_n or 0) - #add
        else
            local i, j = 1, 1
            while i <= #b.lines or j <= #add do
                local A, B = b.lines[i], add[j]
                if A and (not B or A.t <= B.t) then
                    out[#out + 1] = A
                    i = i + 1
                else
                    out[#out + 1] = B
                    j = j + 1
                end
            end
            b.clear_n = (b.clear_n or 0) + 1
        end
        b.lines = out
        dirty()
        return #add
    end

    -- One replayed message: shaped like a live line but stamped with the
    -- server's own time, and held until the batch ends.
    local function hist_line(c, ba, m, is_notice)
        local from = m.nick or m.prefix or "?"
        local text = m.params[2] or ""
        local ctcp, arg = parse.ctcp(text)
        if ctcp and ctcp ~= "ACTION" then return end
        if ctcp == "ACTION" then text = arg or "" end
        local plain = parse.utf8_clean(parse.plain(text))
        local fmt = nil
        if plain ~= text then fmt = parse.utf8_clean(text) end
        if not ba.key then
            local cm = c.isupport.CASEMAPPING
            local target = m.params[1] or ""
            if is_chan_name(c, target) or me_nick(c, from) then
                ba.key = parse.casemap(target, cm)
            else
                ba.key = parse.casemap(from, cm)
            end
        end
        -- Eight keys at most: the constructor's count rounds up to a power of
        -- two, and a ninth would double the table's hash part.
        local mid = m.tags.msgid
        if mid == "" then mid = nil end
        ba.lines[#ba.lines + 1] = {
            t = parse.tstamp(m.tags.time) or utils.now(),
            src = from, text = plain,
            kind = ctcp == "ACTION" and "action"
                or (is_notice and "notice" or "msg"),
            srvtime = (not mid) and m.tags.time or nil,
            msgid = mid,
            hl = false, fmt = fmt,
        }
    end

    local function handle(c, m)
        local cmd = m.cmd
        local p = m.params
        local cm = c.isupport.CASEMAPPING

        -- Lines inside an open chathistory batch are replays: collected for
        -- the front of the buffer, never rendered as live traffic. Other
        -- batch types fall through to the normal path.
        local ba = m.tags.batch and c.batches[m.tags.batch]
        if ba and ba.btype == "chathistory" then
            if cmd == "PRIVMSG" or cmd == "NOTICE" then
                hist_line(c, ba, m, cmd == "NOTICE")
            end
            return
        end

        if cmd == "PING" then
            tx(c, "PONG :" .. (p[1] or ""))

        elseif cmd == "PONG" then
            if c.ping_at then
                c.lag = E.mono - c.ping_at
                c.ping_at = nil
            end

        elseif cmd == "PRIVMSG" or cmd == "NOTICE" then
            handle_msg(c, m, cmd == "NOTICE")

        elseif cmd == "CAP" then
            local sub = (p[2] or ""):upper()
            if sub == "LS" then
                local last = p[3] ~= "*"
                local list = last and p[3] or p[4]
                for cap in (list or ""):gmatch("%S+") do
                    c.offered[cap:match("^([^=]+)")] = true
                end
                if last then
                    if c.net.auth == "sasl_plain" and not c.offered["sasl"] then
                        login_fail(c, "server does not offer SASL")
                        return
                    end
                    local req = {}
                    for i = 1, #WANTED_CAPS do
                        if c.offered[WANTED_CAPS[i]] then
                            req[#req + 1] = WANTED_CAPS[i]
                        end
                    end
                    if #req > 0 then
                        tx(c, "CAP REQ :" .. table.concat(req, " "))
                    else
                        cap_finish(c)
                    end
                end
            elseif sub == "ACK" then
                for cap in (p[3] or ""):gmatch("%S+") do c.caps[cap] = true end
                if c.net.auth == "sasl_plain" and c.caps["sasl"] and not c.sasl_done then
                    c.sasl_wait = true
                    tx(c, "AUTHENTICATE PLAIN")
                else
                    cap_finish(c)
                end
            elseif sub == "NAK" then
                if c.net.auth == "sasl_plain"
                    and (p[3] or ""):find("sasl", 1, true) then
                    login_fail(c, "server refused SASL")
                else
                    cap_finish(c)
                end
            elseif sub == "NEW" then
                for cap in (p[3] or ""):gmatch("%S+") do
                    c.offered[cap:match("^([^=]+)")] = true
                end
            elseif sub == "DEL" then
                for cap in (p[3] or ""):gmatch("%S+") do
                    c.offered[cap] = nil
                    c.caps[cap] = nil
                end
            end

        elseif cmd == "AUTHENTICATE" then
            if p[1] == "+" and c.sasl_wait then
                local acct = c.net.user ~= "" and c.net.user or c.net.nick
                local payload = b64("\0" .. acct .. "\0" .. c.net.password)
                local i = 1
                repeat
                    tx(c, "AUTHENTICATE " .. payload:sub(i, i + 399))
                    i = i + 400
                until i > #payload
                if #payload % 400 == 0 then tx(c, "AUTHENTICATE +") end
            end

        elseif cmd == "903" then
            info(c, "login OK")
            c.sasl_wait, c.sasl_done = false, true
            cap_finish(c)

        elseif cmd == "902" or cmd == "904" or cmd == "905" or cmd == "906"
            or cmd == "908" then
            login_fail(c, p[#p] or ("SASL error " .. cmd))

        elseif cmd == "001" then
            c.st = "up"
            c.nick = p[1] or c.nick
            c.recon_n = 0
            info(c, "connected as " .. c.nick)
            print("[irc] " .. c.id .. " up as " .. c.nick)
            local maxc = E.settings.max_chans or 0
            local nch = 0
            for _, e in ipairs(chan_entries(c.net)) do
                nch = nch + 1
                if maxc > 0 and nch > maxc then
                    info(c, "channel limit " .. maxc .. ": " .. e.name
                        .. " not rejoined")
                else
                    q(c, e.key and ("JOIN " .. e.name .. " " .. e.key)
                        or ("JOIN " .. e.name))
                end
            end
            for line in c.net.perform:gmatch("[^;]+") do
                local t = line:match("^%s*(.-)%s*$")
                if t ~= "" then q(c, t) end
            end

        elseif cmd == "005" then
            parse.isupport(p, c.isupport)

        elseif cmd == "375" or cmd == "372" or cmd == "376" or cmd == "422" then
            bufline(c, c.skey, nil, p[#p] or "", "info")

        elseif (cmd == "431" or cmd == "432" or cmd == "433" or cmd == "436")
            and c.st == "registering" then
            local alts = {}
            for a in c.net.alt_nicks:gmatch("[^,%s]+") do alts[#alts + 1] = a end
            c.alt_idx = c.alt_idx + 1
            if alts[c.alt_idx] then
                c.nick = alts[c.alt_idx]
                info(c, "nick in use - trying " .. c.nick)
                tx(c, "NICK " .. c.nick)
            else
                login_fail(c, "nickname in use")
            end

        elseif cmd == "465" then
            info(c, "banned from server: " .. (p[#p] or ""))
            c.no_reconnect = true

        elseif cmd == "ERROR" then
            info(c, "server error: " .. (p[1] or ""))
            c.no_reconnect = true

        elseif cmd == "JOIN" then
            local chan = p[1] or ""
            local key = parse.casemap(chan, cm)
            if me_nick(c, m.nick) then
                local b = buf_get(c, key, chan, "channel")
                b.joined = true
                b.members = {}
                bufline(c, key, nil, "joined " .. chan, "info")
                if m.prefix and m.prefix:find("!", 1, true) then
                    c.prefixlen = #m.prefix
                end
                b.hist_busy, b.hist_done = false, false
                E.history_latest(c, key)
                chan_remember(c, chan, c.join_keys[key])
                c.join_keys[key] = nil
            else
                local b = c.buffers[key]
                if b then
                    b.members[parse.casemap(m.nick or "", cm)] =
                        { nick = m.nick, pfx = "" }
                    if c.net.show_joins then
                        bufline(c, key, nil, (m.nick or "?") .. " joined", "info")
                    end
                end
            end

        elseif cmd == "PART" then
            local chan = p[1] or ""
            local key = parse.casemap(chan, cm)
            local b = c.buffers[key]
            if b then
                if me_nick(c, m.nick) then
                    b.joined = false
                    b.members = {}
                    chan_forget(c, chan)
                    bufline(c, key, nil, "left " .. chan, "info")
                else
                    b.members[parse.casemap(m.nick or "", cm)] = nil
                    if c.net.show_joins then
                        bufline(c, key, nil, (m.nick or "?") .. " left", "info")
                    end
                end
            end

        elseif cmd == "KICK" then
            local chan, victim = p[1] or "", p[2] or ""
            local key = parse.casemap(chan, cm)
            local b = c.buffers[key]
            if b then
                bufline(c, key, nil, victim .. " kicked by " .. (m.nick or "?")
                    .. (p[3] and (" (" .. p[3] .. ")") or ""), "info")
                if me_nick(c, victim) then
                    b.joined = false
                    b.members = {}
                    chan_forget(c, chan)   -- a kick ends the membership
                else
                    b.members[parse.casemap(victim, cm)] = nil
                end
            end

        elseif cmd == "QUIT" then
            local who = parse.casemap(m.nick or "", cm)
            for _, bkey in ipairs(c.buforder) do
                local b = c.buffers[bkey]
                if b.type == "channel" and b.members[who] then
                    b.members[who] = nil
                    if c.net.show_joins then
                        bufline(c, bkey, nil, (m.nick or "?") .. " quit"
                            .. (p[1] and (" (" .. p[1] .. ")") or ""), "info")
                    end
                end
            end

        elseif cmd == "NICK" then
            local newn = p[1] or ""
            local oldkey = parse.casemap(m.nick or "", cm)
            if me_nick(c, m.nick) then
                c.nick = newn
                info(c, "you are now " .. newn)
            end
            for _, bkey in ipairs(c.buforder) do
                local b = c.buffers[bkey]
                local old = b.members and b.members[oldkey]
                if old then
                    b.members[oldkey] = nil
                    b.members[parse.casemap(newn, cm)] =
                        { nick = newn, pfx = old.pfx }
                end
            end

        elseif cmd == "TOPIC" then
            local key = parse.casemap(p[1] or "", cm)
            local b = c.buffers[key]
            if b then
                b.topic = p[2] or ""
                b.topic_by = m.nick
                bufline(c, key, nil, "topic: " .. b.topic, "info")
            end

        elseif cmd == "333" then
            -- RPL_TOPICWHOTIME: <client> <channel> <setter> <setat>
            local b = c.buffers[parse.casemap(p[2] or "", cm)]
            if b then
                b.topic_by = (p[3] or ""):match("^([^!]+)")
                dirty()
            end

        elseif cmd == "331" or cmd == "332" then
            local key = parse.casemap(p[2] or "", cm)
            local b = c.buffers[key]
            if b then
                b.topic = cmd == "332" and (p[3] or "") or ""
                bufline(c, key, nil, "topic: "
                    .. (b.topic ~= "" and b.topic or "(none)"), "info")
            end

        elseif cmd == "353" then
            local chan = p[3] or ""
            local b = c.buffers[parse.casemap(chan, cm)]
            if b then
                if not b.names_acc then
                    b.names_acc = true
                    b.members = {}
                end
                local syms = c.isupport.prefix_syms or "@+"
                for tokn in (p[4] or ""):gmatch("%S+") do
                    local i = 1
                    local pfx = ""
                    while i <= #tokn and syms:find(tokn:sub(i, i), 1, true) do
                        pfx = pfx .. tokn:sub(i, i)
                        i = i + 1
                    end
                    local nick = tokn:sub(i):match("^([^!]+)") or tokn:sub(i)
                    if nick ~= "" then
                        b.members[parse.casemap(nick, cm)] =
                            { nick = nick, pfx = pfx }
                    end
                end
            end

        elseif cmd == "366" then
            local b = c.buffers[parse.casemap(p[2] or "", cm)]
            if b then
                b.names_acc = nil
                local n = 0
                for _ in pairs(b.members) do n = n + 1 end
                bufline(c, b.key, nil, n .. " members", "info")
            end

        elseif cmd == "MODE" then
            local tgt = p[1] or ""
            local rest = table.concat(p, " ", 2)
            if is_chan_name(c, tgt) then
                local key = parse.casemap(tgt, cm)
                local b = c.buffers[key]
                if b then
                    apply_chan_modes(c, b, p)
                    bufline(c, key, nil, "mode " .. rest
                        .. " by " .. (m.nick or "?"), "info")
                end
            else
                bufline(c, c.skey, nil, "mode " .. tgt .. " " .. rest, "info")
            end

        elseif cmd == "BATCH" then
            local ref = p[1] or ""
            local name = ref:sub(2)
            if ref:sub(1, 1) == "+" then
                local nb = { btype = (p[2] or ""):lower(), lines = {} }
                if nb.btype == "chathistory" and p[3] then
                    nb.key = parse.casemap(p[3], cm)
                end
                c.batches[name] = nb
            else
                local eb = c.batches[name]
                c.batches[name] = nil
                if eb and eb.btype == "chathistory" then
                    local b = eb.key and c.buffers[eb.key]
                    if b then
                        local n = hist_insert(c, b, eb.lines)
                        b.hist_busy = false
                        if #eb.lines < (b.hist_want or HIST_N) then
                            b.hist_done = true   -- the server had no more
                        end
                        print("[irc:" .. c.id .. "] history " .. b.name .. ": "
                            .. #eb.lines .. " replayed, " .. n .. " new")
                    end
                end
            end

        elseif cmd == "321" then
            if not c.list then c.list = list_new(0) end

        elseif cmd == "322" then
            -- RPL_LIST: <me> <channel> <#users> :<topic>
            list_add(c, p[2] or "", tonumber(p[3]) or 0, p[#p] or "")

        elseif cmd == "323" then
            if c.list and not c.list.done then
                list_compact(c.list)
                c.list.done = true
                print("[irc:" .. c.id .. "] list done: " .. c.list.seen
                    .. " seen, " .. #c.list.items .. " kept")
                dirty()
            end

        elseif cmd == "311" or cmd == "314" then
            -- RPL_WHOISUSER / RPL_WHOWASUSER:
            -- <me> <nick> <user> <host> * :<real name>
            local w = whois_get(c, p[2] or "?")
            w.user, w.host, w.real = p[3], p[4], p[#p]
            w.whowas = (cmd == "314") or nil
            w.done = false
            dirty()

        elseif cmd == "312" and whois_open(c, p[2]) then
            local w = whois_open(c, p[2])
            w.server, w.server_info = p[3], p[#p]
            dirty()

        elseif cmd == "317" and whois_open(c, p[2]) then
            -- RPL_WHOISIDLE: <me> <nick> <idle secs> [<signon>] :text
            local w = whois_open(c, p[2])
            w.idle, w.signon = tonumber(p[3]), tonumber(p[4])
            dirty()

        elseif cmd == "319" and whois_open(c, p[2]) then
            local w = whois_open(c, p[2])
            w.channels = (w.channels and (w.channels .. " ") or "")
                .. (p[#p] or "")
            dirty()

        elseif cmd == "330" and whois_open(c, p[2]) then
            whois_open(c, p[2]).account = p[3]
            dirty()

        elseif cmd == "301" and whois_open(c, p[2]) then
            whois_open(c, p[2]).away = p[#p]
            dirty()

        elseif WHOIS_TEXT[cmd] and whois_open(c, p[2]) then
            local w = whois_open(c, p[2])
            w.extra[#w.extra + 1] = p[#p]
            dirty()

        elseif (cmd == "318" or cmd == "369") and whois_open(c, p[2]) then
            whois_open(c, p[2]).done = true
            dirty()

        elseif (cmd == "401" or cmd == "406") and whois_open(c, p[2])
            and not whois_open(c, p[2]).done then
            local w = whois_open(c, p[2])
            w.error = p[#p] or "no such nick"
            w.done = true
            dirty()

        elseif cmd == "324" then
            -- RPL_CHANNELMODEIS: <me> <chan> <modes> [args]
            local b = c.buffers[parse.casemap(p[2] or "", cm)]
            if b then
                b.cmodes = {}
                apply_chan_modes(c, b, { p[2], p[3], table.unpack(p, 4) })
                dirty()
            end

        elseif cmd == "329" then
            local b = c.buffers[parse.casemap(p[2] or "", cm)]
            if b then
                b.created = tonumber(p[3])
                dirty()
            end

        elseif cmd == "328" then
            local b = c.buffers[parse.casemap(p[2] or "", cm)]
            if b then
                b.url = p[3]
                dirty()
            end

        elseif cmd == "367" or cmd == "348" or cmd == "346" then
            -- ban / exception / invite entry: <me> <chan> <mask> [<by> <at>]
            local mode = (cmd == "367" and "b") or (cmd == "348" and "e") or "I"
            local b = c.buffers[parse.casemap(p[2] or "", cm)]
            if b then
                local rec = list_rec(b, mode)
                if #rec.items < LIST_CAP then
                    rec.items[#rec.items + 1] =
                        { mask = p[3], by = p[4], at = tonumber(p[5]) }
                else
                    rec.over = true
                end
                dirty()
            end

        elseif cmd == "368" or cmd == "349" or cmd == "347" then
            local mode = (cmd == "368" and "b") or (cmd == "349" and "e") or "I"
            local b = c.buffers[parse.casemap(p[2] or "", cm)]
            if b then
                list_rec(b, mode).done = true
                dirty()
            end

        elseif cmd == "TAGMSG" or cmd == "AWAY"
            or cmd == "ACCOUNT" or cmd == "CHGHOST" or cmd == "SETNAME" then
            -- Tracked caps whose events need no buffer line; the raw log
            -- already shows them.

        elseif TARGET_NUM[cmd]
            and c.buffers[parse.casemap(p[TARGET_NUM[cmd]] or "", cm)] then
            local at = TARGET_NUM[cmd]
            local key = parse.casemap(p[at], cm)
            local text = p[#p] or cmd
            if cmd == "341" then text = "invited " .. (p[2] or "?")
            elseif at == 3 then text = (p[2] or "?") .. ": " .. text
            elseif cmd == "301" then text = "away: " .. text end
            bufline(c, key, nil, text, "info")

        elseif cmd:match("^%d%d%d$") then
            -- Any other numeric: text into the server buffer (params minus
            -- our own nick).
            bufline(c, c.skey, nil, cmd .. " " .. table.concat(p, " ", 2), "info")

        else
            bufline(c, c.skey, nil, cmd .. " " .. table.concat(p, " "), "info")
        end
    end

    -- ── per-tick socket pumping ──────────────────────────────────────────

    local function pump_recv(c)
        local data, why = c.sock:recv(4096)
        if data == nil then
            lost(c, why or "closed")
            return false
        end
        if #data > 0 then
            c.lastrx = E.mono
            c.ping_at = nil
            -- Scan by index and slice the tail ONCE: re-cutting the buffer
            -- per line copied the whole remainder every time, which on a
            -- busy server was this app's largest source of garbage.
            local buf = c.rbuf .. data
            local pos = 1
            while true do
                local nl = buf:find("\n", pos, true)
                if not nl then break end
                local stop = nl - 1
                if stop >= pos and buf:byte(stop) == 13 then stop = stop - 1 end
                if stop >= pos then
                    c.pending[#c.pending + 1] = buf:sub(pos, stop)
                end
                pos = nl + 1
            end
            c.rbuf = (pos > 1) and buf:sub(pos) or buf
            if #c.rbuf > 16384 then
                lost(c, "protocol error (oversized line)")
                return false
            end
        end
        local nproc = 0
        -- A streaming channel list gets a bigger slice: its lines are cheap
        -- and tens of thousands of them arrive at once.
        local budget = (c.list and not c.list.done and 200) or 40
        -- A read cursor, not table.remove: shifting a 200-entry queue per
        -- line is work and churn for nothing.
        local i = c.pend_i
        while nproc < budget do
            local line = c.pending[i]
            if not line then break end
            c.pending[i] = false   -- release the string, keep the array dense
            i = i + 1
            nproc = nproc + 1
            local m = parse.line(line)
            -- 322s would flush everything else out of the raw ring.
            if not (m and m.cmd == "322") then rawlog(c, "<< ", line) end
            if m then
                local ok, err = pcall(handle, c, m)
                if not ok then
                    info(c, "handler error: " .. tostring(err))
                    print("[irc] handler error: " .. tostring(err)
                        .. " line=" .. line)
                end
            end
        end
        if c.pending[i] == nil then
            c.pending, c.pend_i = {}, 1   -- drained
        else
            c.pend_i = i
        end
        return true
    end

    local function conn_tick(c, dt)
        if c.st == "off" then
            if c.want then start(c) end
            return
        end
        if c.st == "waiting_wifi" then
            if not c.want then c.st = "off" return end
            start(c)
            return
        end
        if c.st == "backoff" then
            if not c.want then c.st = "off" return end
            if E.mono >= c.recon_at then start(c) end
            return
        end
        if not c.sock then
            c.st = "off"
            return
        end
        local sst, sreason = c.sock:state()
        if sst == "closed" then
            lost(c, sreason or "closed")
            return
        end
        if sst == "untrusted" then
            -- Held open (no reads, no writes) so the trust screen can show
            -- the certificate; E.trust / E.reject end it.
            if c.st ~= "untrusted" then
                c.st = "untrusted"
                c.cert = c.sock:info()
                info(c, "server certificate needs approval (network menu)")
                if E.settings.notify_cert then
                    pcall(_notify_post, "IRC "
                        .. (c.net.name ~= "" and c.net.name or c.net.host)
                        .. ": server certificate needs approval")
                end
                dirty()
            end
            return
        end
        if c.st == "connecting" then
            if sst == "open" then
                register(c)
            elseif E.mono - c.conn_started > 45 then
                lost(c, "connect timeout")
            end
            return
        end
        if not pump_recv(c) then return end
        if c.st == "registering" and E.mono - c.reg_start > 60 then
            lost(c, "registration timeout")
            return
        end
        if c.st == "up" then
            if c.ping_at then
                if E.mono - c.ping_at > 60 then
                    lost(c, "ping timeout")
                    return
                end
            elseif E.mono - c.lastrx > 90 then
                c.ping_at = E.mono
                tx(c, "PING :mp" .. math.floor(E.mono))
            end
        end
        pump_send(c, dt)
    end

    -- ── engine API ───────────────────────────────────────────────────────

    function E.tick()
        local before = E.gen
        local now = utils.now()
        local dt = 0
        if E._wall then
            dt = now - E._wall
            if dt < 0 or dt > 10 then dt = 1 end   -- clock jump (GPS sync)
        end
        E._wall = now
        E.mono = E.mono + dt

        -- The foreground stamps ui.seen every pass, so 5s without one means
        -- another app is in front. With the low-memory setting on, that is
        -- when the buffers give their memory back.
        local bg = E.settings.bg_low_mem and (E.mono - E.ui.seen) >= 5
        if (bg and true or false) ~= (E.low_mem or false) then
            E.low_mem = bg and true or false
            print("[irc] memory mode: "
                .. (E.low_mem and "background (low)" or "full"))
            if E.low_mem then diet() end
        end

        local wanting = false
        for _, id in ipairs(E.order) do
            if E.conns[id].want then wanting = true end
        end
        local wifi_up = _wifi_status() == "connected"
        if not wanting or wifi_up then E._wifi_down_since = nil end
        if wifi_up then
            E._wifi_notified, E._wifi_off_notified = false, false
        end
        if wanting and not wifi_up then
            if not E._wifi_down_since then E._wifi_down_since = E.mono end
            local ok_en, en = pcall(wifi.isEnabled)
            if ok_en and en then
                -- Bring-up takes seconds; the bell only rings for a SUSTAINED
                -- outage, never during a connect that is still coming up.
                if not E._wifi_notified
                    and (E.mono - E._wifi_down_since) >= 90 then
                    E._wifi_notified = true
                    print("[irc] wifi outage past 90s")
                    if E.settings.notify_conn then
                        pcall(_notify_post, "IRC: no WiFi for 90s - still retrying")
                    end
                end
                if E.mono - E._last_kick >= 60 then
                    E._last_kick = E.mono
                    pcall(_wifi_auto_connect)
                    print("[irc] wifi down - kicking auto-connect")
                end
            elseif not E._wifi_off_notified then
                E._wifi_off_notified = true
                print("[irc] wifi is disabled - no kicks")
                if E.settings.notify_conn then
                    pcall(_notify_post, "IRC offline: WiFi is disabled")
                end
            end
        end

        for _, id in ipairs(E.order) do
            conn_tick(E.conns[id], dt)
        end
        return E.gen ~= before
    end

    function E.status()
        local up, unread, hl = 0, 0, 0
        for _, id in ipairs(E.order) do
            local c = E.conns[id]
            if c.st == "up" then up = up + 1 end
            for _, bkey in ipairs(c.buforder) do
                local b = c.buffers[bkey]
                unread = unread + b.unread
                hl = hl + b.hl
            end
        end
        if up == 0 then return "IRC: disconnected" end
        local s = "IRC: " .. up .. " connected"
        if hl > 0 then s = s .. " - " .. hl .. " mentions"
        elseif unread > 0 then s = s .. " - " .. unread .. " unread" end
        return s
    end

    function E.quit_all()
        for _, id in ipairs(E.order) do
            local c = E.conns[id]
            c.want = false
            c.no_reconnect = true
            if c.sock then
                if c.st == "up" or c.st == "registering" then
                    pcall(function() c.sock:send("QUIT :leaving\r\n") end)
                end
                pcall(function() c.sock:close() end)
                c.sock = nil
            end
            drop_membership(c)
            c.st = "off"
        end
        print("[irc] quit_all")
    end

    function E.connect_net(id)
        local c = E.conns[id]
        if not c then return end
        print("[irc] " .. id .. " connect requested")
        c.want = true
        c.no_reconnect = false
        c.recon_n = 0
        if c.st == "off" or c.st == "backoff" or c.st == "waiting_wifi" then
            start(c)
        end
    end

    function E.disconnect_net(id)
        local c = E.conns[id]
        if not c then return end
        print("[irc] " .. id .. " disconnect requested")
        c.want = false
        c.no_reconnect = true
        if c.sock and (c.st == "up" or c.st == "registering") then
            pcall(function() c.sock:send("QUIT :leaving\r\n") end)
        end
        conn_close_sock(c)
        drop_membership(c)
        c.st = "off"
        info(c, "disconnected")
    end

    function E.add_net(net)
        E.nets[#E.nets + 1] = net
        local c = conn_new(net)
        E.conns[c.id] = c
        E.order[#E.order + 1] = c.id
        deps.cfg.save_networks(E.nets)
        dirty()
    end

    function E.delete_net(id)
        E.disconnect_net(id)
        E.conns[id] = nil
        for i = #E.order, 1, -1 do
            if E.order[i] == id then table.remove(E.order, i) end
        end
        for i = #E.nets, 1, -1 do
            if E.nets[i].id == id then table.remove(E.nets, i) end
        end
        deps.cfg.save_networks(E.nets)
        dirty()
    end

    function E.save_nets()
        deps.cfg.save_networks(E.nets)
        dirty()
    end

    -- Settings changed the caps: apply them to what is already stored.
    function E.apply_caps()
        local cap = E.settings.cap_log or 0
        for i = 1, #E.order do
            local c = E.conns[E.order[i]]
            for k = 1, #c.buforder do
                trim_buf(c, c.buffers[c.buforder[k]], true)
            end
            if cap <= 0 then
                c.raw = {}
            elseif #c.raw > cap then
                local keep = {}
                table.move(c.raw, #c.raw - cap + 1, #c.raw, 1, keep)
                c.raw = keep
            end
        end
        collectgarbage("collect")
        dirty()
        print("[irc] caps applied, lua heap "
            .. math.floor(collectgarbage("count")) .. "KB")
    end

    -- Buffers held, for the Settings estimate.
    function E.buffer_counts()
        local chans, pms = 0, 0
        for i = 1, #E.order do
            local c = E.conns[E.order[i]]
            chans = chans + count_type(c, "channel")
            pms = pms + count_type(c, "query")
        end
        return chans, pms
    end

    -- ── whois / channel info / history (the UI's read side) ──────────────

    -- Asks, dropping any earlier answer for that nick. E.ui_whois (set by
    -- the UI) opens the card that fills in as the numerics arrive.
    local function whois_ask(c, nick, verb)
        nick = (nick or ""):match("^(%S*)") or ""
        if nick == "" then return false end
        if c.st ~= "up" then
            info(c, "not connected")
            return false
        end
        c.whois[parse.casemap(nick, c.isupport.CASEMAPPING)] = nil
        whois_get(c, nick)
        E.sendline(c, verb .. " " .. nick)
        if E.ui_whois then E.ui_whois(c, nick) end
        return true
    end

    function E.whois(c, nick) return whois_ask(c, nick, "WHOIS") end

    -- WHOWAS fills the same record (314/369 instead of 311/318).
    function E.whowas(c, nick) return whois_ask(c, nick, "WHOWAS") end

    function E.whois_get(c, nick)
        return c.whois[parse.casemap(nick or "", c.isupport.CASEMAPPING)]
    end

    -- LIST into c.list, which the browser reads. A mask goes to the server
    -- as given; otherwise ELIST's ">N" trims the flood where the server
    -- offers it. E.ui_list (set by the UI) opens the browser.
    function E.list_req(c, min_users, mask)
        if c.st ~= "up" then
            info(c, "not connected")
            return false
        end
        local minu = min_users or 5
        local elist = c.isupport.ELIST
        c.list = list_new(minu)
        if mask and mask ~= "" then
            c.list.min = 0
            E.sendline(c, "LIST " .. mask)
        elseif minu > 1 and type(elist) == "string"
            and elist:upper():find("U", 1, true) then
            -- ELIST's U = "LIST >N" (more than N users) is understood here.
            E.sendline(c, "LIST >" .. (minu - 1))
        else
            c.list.min = 0
            E.sendline(c, "LIST")
        end
        if E.ui_list then E.ui_list(c) end
        return true
    end

    function E.list_get(c) return c.list end

    -- MODE <chan>: the current modes (324) and creation time (329).
    function E.chan_info_req(c, key)
        local b = c.buffers[key]
        if not b or b.type ~= "channel" or c.st ~= "up" then return false end
        E.sendline(c, "MODE " .. b.name)
        return true
    end

    -- MODE <chan> +b|+e|+I: the mask list, collected into b.lists[mode].
    function E.chan_list_req(c, key, mode)
        local b = c.buffers[key]
        if not b or b.type ~= "channel" or c.st ~= "up" then return false end
        b.lists = b.lists or {}
        b.lists[mode] = { items = {}, done = false }
        E.sendline(c, "MODE " .. b.name .. " +" .. mode)
        return true
    end

    -- "+mnt  k secret" from the tracked channel modes.
    function E.modes_text(b)
        if not b.cmodes or not next(b.cmodes) then return "" end
        local flags, args = {}, {}
        for mch, v in pairs(b.cmodes) do
            flags[#flags + 1] = mch
            if type(v) == "string" then args[#args + 1] = mch .. " " .. v end
        end
        table.sort(flags)
        table.sort(args)
        local s = "+" .. table.concat(flags)
        if #args > 0 then s = s .. "  " .. table.concat(args, "  ") end
        return s
    end

    -- "off" (the server replays nothing), "busy", "full" (no room until the
    -- buffer is cleared), "done" (the server had no more) or "ready".
    function E.history_state(c, key)
        local b = c.buffers[key]
        if not b or not hist_cap(c) then return "off" end
        if b.hist_busy and (E.mono - (b.hist_at or 0)) < 15 then return "busy" end
        if #b.lines >= buf_cap(c, b) then return "full" end
        if b.hist_done then return "done" end
        return "ready"
    end

    function E.history_latest(c, key)
        local b = c.buffers[key]
        if b then hist_send(c, b, "LATEST", "*") end
    end

    -- Older than the oldest line we hold, anchored on its msgid (server-time
    -- when the server sends no msgids).
    function E.history_before(c, key)
        local b = c.buffers[key]
        if not b or b.hist_done then return end
        local anchor = nil
        for i = 1, #b.lines do
            local L = b.lines[i]
            if L.msgid then
                anchor = "msgid=" .. L.msgid
                break
            elseif L.srvtime and L.srvtime ~= "" then
                anchor = "timestamp=" .. L.srvtime
                break
            end
        end
        if anchor then hist_send(c, b, "BEFORE", anchor) end
    end

    function E.privmsg(c, target, text, kind)
        if c.st ~= "up" then
            info(c, "not connected")
            return
        end
        if not is_chan_name(c, target) then
            local bk = parse.casemap(target, c.isupport.CASEMAPPING)
            if not c.buffers[bk] and not room_for(c, "query") then
                info(c, "private chat limit reached ("
                    .. tostring(E.settings.max_pms) .. ") - close one first")
                return
            end
        end
        local wire = text
        local okd, dec = pcall(_emoji_decompose, wire)
        if okd and dec then wire = dec end
        local verb = kind == "notice" and "NOTICE" or "PRIVMSG"
        local overhead = 1 + c.prefixlen + 1 + #verb + 1 + #target + 2
        local budget = 510 - overhead
        if kind == "action" then budget = budget - 9 end
        if budget < 32 then budget = 32 end
        local rest = wire
        while #rest > 0 do
            local chunk
            chunk, rest = parse.cut(rest, budget)
            local payload = chunk
            if kind == "action" then payload = "\1ACTION " .. chunk .. "\1" end
            q(c, verb .. " " .. target .. " :" .. payload)
            if not c.caps["echo-message"] then
                local cm = c.isupport.CASEMAPPING
                local key = parse.casemap(target, cm)
                local b = buf_get(c, key, target,
                    is_chan_name(c, target) and "channel" or "query")
                bufline(c, b.key, c.nick, parse.utf8_clean(chunk),
                    kind == "action" and "action" or "msg")
            end
        end
    end

    -- Raw lines are refused while the connection is down: a silently queued
    -- command that fires on a later connect is never what the user meant.
    function E.sendline(c, line)
        if c.st ~= "up" and c.st ~= "registering" then
            info(c, "not connected - dropped: " .. line:sub(1, 40))
            return
        end
        q(c, line)
    end
    function E.direct(c, line) tx(c, line) end
    function E.conninfo(c, text) info(c, text) end
    function E.clear_raw(c)
        c.raw = {}
        dirty()
    end

    function E.handle_input(c, text, target)
        cmds.run(E, c, text, target)
    end

    function E.mark_seen(c, key)
        local b = c.buffers[key]
        if b then
            b.unread, b.hl = 0, 0
            dirty()
        end
    end

    function E.clear_buffer(c, key)
        local b = c.buffers[key]
        if b then
            b.lines = {}
            b.clear_n = (b.clear_n or 0) + 1
            b.hist_busy, b.hist_done = false, false   -- history can come back
            dirty()
        end
    end

    function E.close_buffer(c, key)
        if key == c.skey then return end
        local b = c.buffers[key]
        if not b then return end
        if b.type == "channel" then
            if b.joined and c.st == "up" then q(c, "PART " .. b.name) end
            chan_forget(c, b.name)   -- closing a channel leaves it for good
        end
        c.buffers[key] = nil
        for i = #c.buforder, 1, -1 do
            if c.buforder[i] == key then table.remove(c.buforder, i) end
        end
        dirty()
    end

    -- JOIN, remembering the key so the rejoin after a reconnect can use it
    -- (the server's JOIN echo carries none).
    function E.join(c, text)
        local chan, key = (text or ""):match("^%s*(%S+)%s*(%S*)")
        if not chan or chan == "" then return false end
        local bk = parse.casemap(chan, c.isupport.CASEMAPPING)
        if not c.buffers[bk] and not room_for(c, "channel") then
            info(c, "channel limit reached ("
                .. tostring(E.settings.max_chans) .. ") - close one first")
            return false
        end
        c.join_keys[parse.casemap(chan, c.isupport.CASEMAPPING)] =
            (key ~= "" and key) or nil
        E.sendline(c, (key ~= "" and ("JOIN " .. chan .. " " .. key))
            or ("JOIN " .. chan))
        return true
    end

    -- PART + JOIN with the channel's saved key (the PART drops it from the
    -- saved list, the JOIN puts it back).
    function E.cycle(c, name)
        name = (name or ""):match("^(%S*)") or ""
        if name == "" then return false end
        local cm = c.isupport.CASEMAPPING
        local want = parse.casemap(name, cm)
        local key = nil
        for _, e in ipairs(chan_entries(c.net)) do
            if parse.casemap(e.name, cm) == want then key = e.key end
        end
        E.sendline(c, "PART " .. name)
        return E.join(c, key and (name .. " " .. key) or name)
    end

    -- nil when the private-chat limit is reached (the UI says so).
    function E.open_query(c, nick)
        local key = parse.casemap(nick, c.isupport.CASEMAPPING)
        if not c.buffers[key] then
            if not room_for(c, "query") then
                info(c, "private chat limit reached ("
                    .. tostring(E.settings.max_pms) .. ") - close one first")
                return nil
            end
            buf_get(c, key, nick, "query")
        end
        dirty()
        return key
    end

    function E.buffer_key(c, name)
        return parse.casemap(name, c.isupport.CASEMAPPING)
    end

    function E.get_notify_mode(c, key)
        local m = c.net.notify_modes and c.net.notify_modes[key]
        if m then return m end
        local b = c.buffers[key]
        return (b and b.type == "query") and "all" or "mentions"
    end

    function E.set_notify_mode(c, key, mode)
        c.net.notify_modes = c.net.notify_modes or {}
        local b = c.buffers[key]
        local def = (b and b.type == "query") and "all" or "mentions"
        c.net.notify_modes[key] = (mode ~= def) and mode or nil
        deps.cfg.save_networks(E.nets)
        dirty()
    end

    -- Trust screen actions. trust() pins the certificate the held
    -- "untrusted" handshake presented, persists it, and reconnects pinned.
    function E.trust(id)
        local c = E.conns[id]
        if not (c and c.st == "untrusted" and c.cert and c.cert.cert_sha256) then
            return
        end
        print("[irc] " .. id .. " trust: pinning " .. c.cert.cert_sha256)
        c.net.pin = c.cert.cert_sha256
        c.net.verify = "pin"
        c.capture = nil
        deps.cfg.save_networks(E.nets)
        info(c, "certificate pinned")
        conn_close_sock(c)
        c.st = "off"
        c.want = true
        c.no_reconnect = false
        c.recon_n = 0
        start(c)
    end

    function E.reject(id)
        local c = E.conns[id]
        if not c then return end
        c.capture = nil
        c.want = false
        c.no_reconnect = true
        conn_close_sock(c)
        c.st = "off"
        info(c, "certificate rejected")
        dirty()
    end

    -- After a CA refusal: reconnect once in capture mode so the certificate
    -- can be inspected and pinned.
    function E.recapture(id)
        local c = E.conns[id]
        if not c then return end
        print("[irc] " .. id .. " capture connect (certificate inspection)")
        c.capture = true
        c.want = true
        c.no_reconnect = false
        c.recon_n = 0
        if c.st == "off" or c.st == "backoff" or c.st == "waiting_wifi" then
            start(c)
        end
    end

    function E.ui_open(c, key) end   -- reassigned by the UI (/query, /close)

    -- ── boot: one connection object per configured network ──────────────

    for i = 1, #E.nets do
        local c = conn_new(E.nets[i])
        E.conns[c.id] = c
        E.order[#E.order + 1] = c.id
        if E.nets[i].autoconnect then c.want = true end
    end
    print("[irc] engine created (" .. #E.nets .. " networks)")

    return E
end

return M
