--[[
  IRC app - slash-command layer. cmds.run(E, c, input, target) turns a typed
  line into engine calls. `target` is the open buffer's name (nil in the raw
  console and the server buffer): bare text goes there, and channel-ish
  commands default to it.
]]

local M = {}

local function split1(s)
    local a, b = s:match("^(%S+)%s*(.*)$")
    return a or "", b or ""
end

local C = {}

C.join = function(E, c, rest, target)
    if rest == "" then return E.conninfo(c, "usage: /join <channel> [key]") end
    E.join(c, rest)
end
C.j = C.join

C.part = function(E, c, rest, target)
    local chan, reason = split1(rest)
    if chan == "" then chan = target or "" end
    if chan == "" then return E.conninfo(c, "usage: /part <channel> [reason]") end
    E.sendline(c, reason ~= "" and ("PART " .. chan .. " :" .. reason)
        or ("PART " .. chan))
end

C.msg = function(E, c, rest, target)
    local to, text = split1(rest)
    if to == "" or text == "" then
        return E.conninfo(c, "usage: /msg <target> <text>")
    end
    E.privmsg(c, to, text, "msg")
end

C.notice = function(E, c, rest, target)
    local to, text = split1(rest)
    if to == "" or text == "" then
        return E.conninfo(c, "usage: /notice <target> <text>")
    end
    E.privmsg(c, to, text, "notice")
end

C.me = function(E, c, rest, target)
    if target then
        if rest == "" then return E.conninfo(c, "usage: /me <action text>") end
        E.privmsg(c, target, rest, "action")
        return
    end
    local to, text = split1(rest)
    if to == "" or text == "" then
        return E.conninfo(c, "usage: /me <target> <action text>")
    end
    E.privmsg(c, to, text, "action")
end

C.query = function(E, c, rest, target)
    local nick = rest:match("^(%S+)")
    if not nick then return E.conninfo(c, "usage: /query <nick>") end
    local key = E.open_query(c, nick)
    E.ui_open(c, key)
end

C.close = function(E, c, rest, target)
    if not target then return E.conninfo(c, "nothing to close here") end
    E.close_buffer(c, E.buffer_key(c, target))
    E.ui_open(c, nil)
end

C.clear = function(E, c, rest, target)
    if target then
        E.clear_buffer(c, E.buffer_key(c, target))
    else
        E.clear_raw(c)
    end
end

C.ctcp = function(E, c, rest, target)
    local to, body = split1(rest)
    if to == "" or body == "" then
        return E.conninfo(c, "usage: /ctcp <target> <CMD> [args]")
    end
    E.sendline(c, "PRIVMSG " .. to .. " :\1" .. body:upper() .. "\1")
end

C.nick = function(E, c, rest, target)
    if rest == "" then return E.conninfo(c, "usage: /nick <newnick>") end
    E.sendline(c, "NICK " .. rest)
end

C.topic = function(E, c, rest, target)
    local first = rest:match("^(%S+)") or ""
    local named = first:sub(1, 1) == "#" or first:sub(1, 1) == "&"
    if named then
        local chan, text = split1(rest)
        E.sendline(c, text ~= "" and ("TOPIC " .. chan .. " :" .. text)
            or ("TOPIC " .. chan))
    elseif target then
        E.sendline(c, rest ~= "" and ("TOPIC " .. target .. " :" .. rest)
            or ("TOPIC " .. target))
    else
        E.conninfo(c, "usage: /topic <channel> [text]")
    end
end

-- Both answer into the whois card, not the server log.
C.whois = function(E, c, rest, target)
    if rest == "" then return E.conninfo(c, "usage: /whois <nick>") end
    E.whois(c, rest)
end

C.whowas = function(E, c, rest, target)
    if rest == "" then return E.conninfo(c, "usage: /whowas <nick>") end
    E.whowas(c, rest)
end

C.who = function(E, c, rest, target)
    local mask = rest ~= "" and rest or target
    if not mask or mask == "" then return E.conninfo(c, "usage: /who <mask>") end
    E.sendline(c, "WHO " .. mask)
end

C.names = function(E, c, rest, target)
    local chan = rest ~= "" and rest or target
    if not chan or chan == "" then return E.conninfo(c, "usage: /names <channel>") end
    E.sendline(c, "NAMES " .. chan)
end

C.mode = function(E, c, rest, target)
    if rest == "" then
        if not target then return E.conninfo(c, "usage: /mode <target> [modes]") end
        E.sendline(c, "MODE " .. target)
        return
    end
    E.sendline(c, "MODE " .. rest)
end

C.kick = function(E, c, rest, target)
    local a, r2 = split1(rest)
    local chan, nick, reason
    if a:sub(1, 1) == "#" or a:sub(1, 1) == "&" or not target then
        chan = a
        nick, reason = split1(r2)
    else
        chan = target
        nick, reason = a, r2
    end
    if chan == "" or nick == "" then
        return E.conninfo(c, "usage: /kick [channel] <nick> [reason]")
    end
    E.sendline(c, reason ~= "" and ("KICK " .. chan .. " " .. nick .. " :" .. reason)
        or ("KICK " .. chan .. " " .. nick))
end

-- ── operator helpers ────────────────────────────────────────────────────────
-- Each takes an optional leading channel; without one they act on the open
-- channel buffer. A bare nick becomes the mask nick!*@*; anything carrying
-- ! @ or * is used as typed.

local function chan_args(c, rest, target)
    local first, more = split1(rest)
    local chant = tostring(c.isupport.CHANTYPES or "#&")
    if first ~= "" and chant:find(first:sub(1, 1), 1, true) then
        return first, more
    end
    return target or "", rest
end

local function words(s)
    local out = {}
    for w in s:gmatch("%S+") do out[#out + 1] = w end
    return out
end

local function ban_mask(s)
    if s:find("[!@*]") then return s end
    return s .. "!*@*"
end

-- MODE <chan> +ooo a b c, split to ISUPPORT MODES per line (3 when absent).
local function mode_run(E, c, chan, sign, letter, list)
    local max = tonumber(c.isupport.MODES) or 3
    if max < 1 then max = 1 end
    local i = 1
    while i <= #list do
        local n = math.min(max, #list - i + 1)
        E.sendline(c, "MODE " .. chan .. " " .. sign .. string.rep(letter, n)
            .. " " .. table.concat(list, " ", i, i + n - 1))
        i = i + n
    end
end

local function rank_cmd(name, sign, letter, mask)
    return function(E, c, rest, target)
        local chan, args = chan_args(c, rest, target)
        local list = words(args)
        if chan == "" or #list == 0 then
            return E.conninfo(c,
                "usage: /" .. name .. " [#channel] <nick> [nick...]")
        end
        if mask then
            for i = 1, #list do list[i] = ban_mask(list[i]) end
        end
        mode_run(E, c, chan, sign, letter, list)
    end
end

C.op      = rank_cmd("op", "+", "o")
C.deop    = rank_cmd("deop", "-", "o")
C.voice   = rank_cmd("voice", "+", "v")
C.devoice = rank_cmd("devoice", "-", "v")
C.ban     = rank_cmd("ban", "+", "b", true)
C.unban   = rank_cmd("unban", "-", "b", true)

C.kickban = function(E, c, rest, target)
    local chan, args = chan_args(c, rest, target)
    local nick, reason = split1(args)
    if chan == "" or nick == "" then
        return E.conninfo(c, "usage: /kickban [#channel] <nick> [reason]")
    end
    mode_run(E, c, chan, "+", "b", { ban_mask(nick) })
    E.sendline(c, reason ~= ""
        and ("KICK " .. chan .. " " .. nick .. " :" .. reason)
        or ("KICK " .. chan .. " " .. nick))
end
C.kb = C.kickban

-- PART + JOIN, keeping the channel's key.
C.cycle = function(E, c, rest, target)
    local chan = rest ~= "" and rest or (target or "")
    if chan == "" then return E.conninfo(c, "usage: /cycle [#channel]") end
    E.cycle(c, chan)
end

C.invite = function(E, c, rest, target)
    local nick, chan = split1(rest)
    if chan == "" then chan = target or "" end
    if nick == "" or chan == "" then
        return E.conninfo(c, "usage: /invite <nick> [channel]")
    end
    E.sendline(c, "INVITE " .. nick .. " " .. chan)
end

C.away = function(E, c, rest, target)
    E.sendline(c, rest ~= "" and ("AWAY :" .. rest) or "AWAY :away")
end

C.back = function(E, c, rest, target)
    E.sendline(c, "AWAY")
end

C.list = function(E, c, rest, target)
    E.list_req(c, nil, rest ~= "" and rest or nil)   -- answers in the browser
end

C.monitor = function(E, c, rest, target)
    if rest == "" then return E.conninfo(c, "usage: /monitor +nick|-nick|C|L|S") end
    E.sendline(c, "MONITOR " .. rest)
end

C.quote = function(E, c, rest, target)
    if rest == "" then return E.conninfo(c, "usage: /quote <raw line>") end
    E.sendline(c, rest)
end
C.raw = C.quote

C.connect = function(E, c, rest, target)
    E.connect_net(c.id)
end

C.disconnect = function(E, c, rest, target)
    E.disconnect_net(c.id)
end
C.quit = C.disconnect

C.help = function(E, c, rest, target)
    local names = {}
    for k in pairs(C) do names[#names + 1] = "/" .. k end
    table.sort(names)
    E.conninfo(c, "commands: " .. table.concat(names, " "))
end

function M.run(E, c, input, target)
    input = input:match("^%s*(.-)%s*$")
    if input == "" then return end
    local literal = input:sub(1, 2) == "//"
    if input:sub(1, 1) ~= "/" or literal then
        if literal then input = input:sub(2) end
        if target then
            E.privmsg(c, target, input, "msg")
        else
            E.conninfo(c, "no target here - /msg <target> <text>, or /quote <raw>")
        end
        return
    end
    local cmd, rest = split1(input:sub(2))
    local fn = C[cmd:lower()]
    if not fn then
        E.conninfo(c, "unknown command /" .. cmd .. " - /help lists them")
        return
    end
    fn(E, c, rest, target)
end

return M
