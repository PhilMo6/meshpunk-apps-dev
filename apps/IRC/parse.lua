--[[
  IRC app - wire parsing. No UI, no sockets, no state beyond its arguments.

  M.line(raw)        -> msg {tags, prefix, nick, user, host, cmd, params} | nil
  M.casemap(s, map)  -> lowercased per CASEMAPPING ("rfc1459" default, "ascii")
  M.strip(text)      -> plain, runs  (mIRC/IRCv3 formatting codes parsed out;
                        runs carry per-segment styles for the renderer)
  M.plain(text)      -> plain  (no runs table built: the hot path)
  M.ctcp(text)       -> CMD, arg | nil  (\x01-delimited)
  M.tstamp(tag)      -> epoch seconds from an IRCv3 server-time tag | nil
  M.isupport(params, t)  applies one 005's tokens onto t
  M.utf8_clean(s)    -> s with invalid UTF-8 bytes replaced by U+FFFD
  M.cut(s, maxb)     -> prefix, rest  (UTF-8-safe split, prefers a space)
]]

local M = {}

local TAG_UNESC = { [":"] = ";", s = " ", r = "\r", n = "\n", ["\\"] = "\\" }

function M.line(raw)
    local msg = { tags = {}, params = {} }
    local pos = 1
    if raw:sub(1, 1) == "@" then
        local sp = raw:find(" ", 1, true)
        if not sp then return nil end
        for tag in raw:sub(2, sp - 1):gmatch("[^;]+") do
            local k, v = tag:match("^([^=]+)=?(.*)$")
            if k then
                if v ~= "" then
                    v = v:gsub("\\(.?)", function(c) return TAG_UNESC[c] or c end)
                end
                msg.tags[k] = v
            end
        end
        pos = sp + 1
    end
    while raw:sub(pos, pos) == " " do pos = pos + 1 end
    if raw:sub(pos, pos) == ":" then
        local sp = raw:find(" ", pos, true)
        if not sp then return nil end
        msg.prefix = raw:sub(pos + 1, sp - 1)
        msg.nick = msg.prefix:match("^([^!@]+)")
        msg.user = msg.prefix:match("!([^@]+)")
        msg.host = msg.prefix:match("@(.+)$")
        pos = sp + 1
        while raw:sub(pos, pos) == " " do pos = pos + 1 end
    end
    local sp = raw:find(" ", pos, true)
    if sp then
        msg.cmd = raw:sub(pos, sp - 1):upper()
        pos = sp + 1
    else
        msg.cmd = raw:sub(pos):upper()
        pos = #raw + 1
    end
    if msg.cmd == "" then return nil end
    while pos <= #raw do
        while raw:sub(pos, pos) == " " do pos = pos + 1 end
        if pos > #raw then break end
        if raw:sub(pos, pos) == ":" then
            msg.params[#msg.params + 1] = raw:sub(pos + 1)
            break
        end
        local nsp = raw:find(" ", pos, true)
        if nsp then
            msg.params[#msg.params + 1] = raw:sub(pos, nsp - 1)
            pos = nsp + 1
        else
            msg.params[#msg.params + 1] = raw:sub(pos)
            break
        end
    end
    return msg
end

-- rfc1459: []\~ are the uppercase forms of {}|^ (the default mapping).
local MAP1459 = { ["["] = "{", ["]"] = "}", ["\\"] = "|", ["~"] = "^" }

function M.casemap(s, mapping)
    s = s:lower()
    if mapping ~= "ascii" then
        s = s:gsub("[%[%]\\~]", MAP1459)
    end
    return s
end

-- The bytes M.strip acts on; text without any of them is already plain.
local FMT_BYTES = "[\2\3\4\15\17\22\29\30\31]"

-- The stripped text alone. Every arriving message and every row preview
-- goes through here, so the common case (no codes at all) must not walk
-- the string or build a runs table.
function M.plain(text)
    if not text:find(FMT_BYTES) then return text end
    return (M.strip(text))
end

-- Formatting codes: ^B bold, ^] (0x1D) italic, ^_ underline, 0x1E strike,
-- 0x11 monospace, ^V reverse, ^C color (1-2 digit fg[,bg]), ^D hex color,
-- ^O reset.
function M.strip(text)
    if not text:find(FMT_BYTES) then return text, { { text = text } } end
    local runs, out, buf = {}, {}, {}
    local cur = {}
    local i, n = 1, #text
    local function flush()
        if #buf > 0 then
            local r = { text = table.concat(buf) }
            for k, v in pairs(cur) do r[k] = v end
            runs[#runs + 1] = r
            out[#out + 1] = r.text
            buf = {}
        end
    end
    while i <= n do
        local b = text:byte(i)
        if b == 0x02 then flush(); cur.bold = not cur.bold or nil; i = i + 1
        elseif b == 0x1D then flush(); cur.italic = not cur.italic or nil; i = i + 1
        elseif b == 0x1F then flush(); cur.underline = not cur.underline or nil; i = i + 1
        elseif b == 0x1E then flush(); cur.strike = not cur.strike or nil; i = i + 1
        elseif b == 0x11 then flush(); cur.mono = not cur.mono or nil; i = i + 1
        elseif b == 0x16 then flush(); cur.reverse = not cur.reverse or nil; i = i + 1
        elseif b == 0x0F then flush(); cur = {}; i = i + 1
        elseif b == 0x03 then
            flush()
            i = i + 1
            local fg = text:match("^(%d%d?)", i)
            if fg then
                i = i + #fg
                cur.fg = tonumber(fg)
                local bg = text:match("^,(%d%d?)", i)
                if bg then
                    i = i + #bg + 1
                    cur.bg = tonumber(bg)
                end
            else
                cur.fg, cur.bg = nil, nil
            end
        elseif b == 0x04 then
            flush()
            i = i + 1
            local fg = text:match("^(%x%x%x%x%x%x)", i)
            if fg then
                i = i + 6
                cur.fg = "#" .. fg
                local bg = text:match("^,(%x%x%x%x%x%x)", i)
                if bg then
                    i = i + 7
                    cur.bg = "#" .. bg
                end
            else
                cur.fg, cur.bg = nil, nil
            end
        else
            buf[#buf + 1] = text:sub(i, i)
            i = i + 1
        end
    end
    flush()
    return table.concat(out), runs
end

function M.ctcp(text)
    if text:byte(1) ~= 0x01 then return nil end
    local body = text:sub(2)
    if body:byte(#body) == 0x01 then body = body:sub(1, -2) end
    local cmd, arg = body:match("^(%S+)%s*(.*)$")
    if not cmd then return nil end
    return cmd:upper(), arg
end

-- IRCv3 server-time ("2026-09-17T12:34:56.789Z", always UTC) -> epoch
-- seconds on utils.now()'s scale. nil when the tag is absent or malformed.
function M.tstamp(s)
    if type(s) ~= "string" then return nil end
    local Y, Mo, D, h, mi, sec = s:match(
        "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
    if not Y then return nil end
    Y, Mo, D = tonumber(Y), tonumber(Mo), tonumber(D)
    h, mi, sec = tonumber(h), tonumber(mi), tonumber(sec)
    -- days_from_civil: the inverse of the civil-date maths in lib/utils.
    local y = Y - (Mo <= 2 and 1 or 0)
    local era = (y >= 0 and y or (y - 399)) // 400
    local yoe = y - era * 400
    local doy = (153 * (Mo + (Mo > 2 and -3 or 9)) + 2) // 5 + D - 1
    local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return (era * 146097 + doe - 719468) * 86400 + h * 3600 + mi * 60 + sec
end

function M.isupport(params, t)
    for i = 2, #params - 1 do
        local tok = params[i]
        if tok:sub(1, 1) == "-" then
            t[tok:sub(2):upper()] = nil
        else
            local k, v = tok:match("^([^=]+)=?(.*)$")
            if k then
                k = k:upper()
                if k == "PREFIX" then
                    local modes, syms = v:match("^%(([^)]*)%)(.*)$")
                    t.prefix_modes = modes or "ov"
                    t.prefix_syms = syms or "@+"
                elseif k == "CHANMODES" then
                    local a, b, c, d = v:match("^([^,]*),([^,]*),([^,]*),(.*)$")
                    t.chanmodes = { a = a or "", b = b or "", c = c or "", d = d or "" }
                else
                    t[k] = (v ~= "") and v or true
                end
            end
        end
    end
end

function M.utf8_clean(s)
    -- Fast path: pure ASCII needs no work.
    if not s:find("[\128-\255]") then return s end
    local out, i, n = {}, 1, #s
    while i <= n do
        local b = s:byte(i)
        local len
        if b < 0x80 then len = 1
        elseif b >= 0xC2 and b <= 0xDF then len = 2
        elseif b >= 0xE0 and b <= 0xEF then len = 3
        elseif b >= 0xF0 and b <= 0xF4 then len = 4
        else len = 0 end
        if len == 1 then
            out[#out + 1] = s:sub(i, i)
            i = i + 1
        elseif len == 0 then
            out[#out + 1] = "\239\191\189"   -- U+FFFD
            i = i + 1
        else
            local ok = i + len - 1 <= n
            if ok then
                for k = 1, len - 1 do
                    local c = s:byte(i + k)
                    if not c or c < 0x80 or c > 0xBF then ok = false end
                end
            end
            if ok then
                out[#out + 1] = s:sub(i, i + len - 1)
                i = i + len
            else
                out[#out + 1] = "\239\191\189"
                i = i + 1
            end
        end
    end
    return table.concat(out)
end

function M.cut(s, maxb)
    if #s <= maxb then return s, "" end
    local cut = maxb
    -- Back up out of a multi-byte sequence (continuation bytes are 80-BF).
    while cut > 1 do
        local b = s:byte(cut + 1)
        if not b or b < 0x80 or b > 0xBF then break end
        cut = cut - 1
    end
    local seg = s:sub(1, cut)
    local last_sp = seg:match(".*() ")
    if last_sp and last_sp > maxb // 2 then
        return s:sub(1, last_sp - 1), s:sub(last_sp + 1)
    end
    return seg, s:sub(cut + 1)
end

return M
