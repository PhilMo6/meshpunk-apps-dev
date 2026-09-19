--[[
  IRC app - network + settings persistence.

  Files live OUTSIDE the app dir so uploadfs (which rebuilds L: from data/)
  never resets them: S:/meshpunk/irc/ when SD is the mesh-data drive, else
  L:/irc/. Loads fall back to the other drive; saves land on the primary.

  networks.cfg: [network <id>] blocks of key=value lines.
  settings.cfg: flat key=value lines.
  Passwords are stored as plain text (Phil's call).
]]

local fileman = require("lib/fileman")

local M = {}

M.PRESETS = {}   -- preset networks; empty until Phil's server exists

-- Per-network fields and defaults. Booleans persist as 1/0.
local DEFAULTS = {
    name = "", host = "", port = 6697,
    tls = true, verify = "ca", pin = "",
    nick = "meshpunk", alt_nicks = "", user = "", realname = "",
    auth = "none",              -- none | sasl_plain | pass
    password = "", server_password = "",
    -- channels = "#a,#b key,#c": every channel the engine is in, rejoined
    -- on every connect. The engine rewrites it on each join and part.
    autoconnect = false, channels = "", perform = "",
    highlight_words = "", show_joins = false,
}
local BOOLS = { tls = true, autoconnect = true, show_joins = true }
local NUMS  = { port = true }

-- Everything the engine keeps lives in the Lua heap, so the caps and the
-- limits below are the app's memory budget: lines kept per buffer, and how
-- many buffers a connection may have.
local SETTINGS_DEFAULTS = {
    ctcp_replies = true,
    notify_conn = false,    -- connection/WiFi event bells
    notify_login = true,    -- login-failure bells
    notify_cert = true,     -- certificate-approval bells
    true_colors = false,    -- chat text: false = theme colors, true = IRC palette
    bg_low_mem = true,      -- shrink the buffers while another app is in front
    cap_chat = 300,         -- lines kept per channel and per server log
    cap_pm = 100,           -- lines kept per private conversation
    cap_log = 0,            -- raw wire log lines (0 = off, no serial trace)
    max_pms = 10,           -- private conversations allowed per network
    max_chans = 20,         -- channels allowed per network
}
local SETTINGS_BOOLS = { ctcp_replies = true, notify_conn = true,
                         notify_login = true, notify_cert = true,
                         true_colors = true, bg_low_mem = true }
local SETTINGS_NUMS = { cap_chat = true, cap_pm = true, cap_log = true,
                        max_pms = true, max_chans = true }

local function primary_dir()
    local ok, info = pcall(_storage_get_info)
    if ok and info and info.type == "SD" then return "S:/meshpunk/irc" end
    return "L:/irc"
end

local function other_dir()
    return primary_dir():sub(1, 1) == "S" and "L:/irc" or "S:/meshpunk/irc"
end

function M.dir() return primary_dir() end

-- Read a config file from the primary dir, falling back to the other drive
-- (a storage switch does not move these files).
local function read_cfg(fname)
    local data = fileman.read(primary_dir() .. "/" .. fname)
    if data then return data end
    return fileman.read(other_dir() .. "/" .. fname)
end

local function write_cfg(fname, text)
    local dir = primary_dir()
    fileman.mkdir(dir)
    return fileman.write(dir .. "/" .. fname, text)
end

local function coerce(key, val)
    if BOOLS[key] then return val == "1" or val == "true" end
    if NUMS[key] then return tonumber(val) or DEFAULTS[key] end
    return val
end

local function fill_defaults(net)
    for k, v in pairs(DEFAULTS) do
        if net[k] == nil then net[k] = v end
    end
    -- Table field: every network needs its OWN instance.
    net.notify_modes = net.notify_modes or {}
    return net
end

-- -> array of network tables (each with .id), in file order.
function M.load_networks()
    local nets = {}
    local data = read_cfg("networks.cfg")
    if not data then return nets end
    local cur = nil
    for raw in data:gmatch("[^\r\n]+") do
        local line = raw:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local id = line:match("^%[network%s+(.-)%]$")
            if id then
                cur = { id = id }
                nets[#nets + 1] = cur
            elseif cur then
                local k, v = line:match("^([%w_]+)=(.*)$")
                if k == "notify_modes" then
                    -- per-buffer notification modes: key:mode pairs, only
                    -- the non-default entries are stored
                    cur.notify_modes = {}
                    for pair in v:gmatch("[^,]+") do
                        local bk, mode = pair:match("^(.-):(%a+)$")
                        if bk and bk ~= "" then cur.notify_modes[bk] = mode end
                    end
                elseif k and DEFAULTS[k] ~= nil then
                    cur[k] = coerce(k, v)
                elseif k == "autojoin" and cur.channels == nil then
                    cur.channels = v   -- the channel list's former name
                end
            end
        end
    end
    for i = 1, #nets do fill_defaults(nets[i]) end
    return nets
end

function M.save_networks(nets)
    local out = {}
    for i = 1, #nets do
        local n = nets[i]
        out[#out + 1] = "[network " .. n.id .. "]"
        for k in pairs(DEFAULTS) do
            local v = n[k]
            if BOOLS[k] then v = v and "1" or "0" else v = tostring(v) end
            out[#out + 1] = k .. "=" .. v
        end
        if n.notify_modes and next(n.notify_modes) then
            local pairs_out = {}
            for bk, mode in pairs(n.notify_modes) do
                pairs_out[#pairs_out + 1] = bk .. ":" .. mode
            end
            out[#out + 1] = "notify_modes=" .. table.concat(pairs_out, ",")
        end
        out[#out + 1] = ""
    end
    return write_cfg("networks.cfg", table.concat(out, "\n"))
end

function M.load_settings()
    local s = {}
    for k, v in pairs(SETTINGS_DEFAULTS) do s[k] = v end
    local data = read_cfg("settings.cfg")
    if data then
        for raw in data:gmatch("[^\r\n]+") do
            local k, v = raw:match("^([%w_]+)=(.*)$")
            if k and SETTINGS_DEFAULTS[k] ~= nil then
                if SETTINGS_BOOLS[k] then s[k] = (v == "1" or v == "true")
                elseif SETTINGS_NUMS[k] then
                    s[k] = tonumber(v) or SETTINGS_DEFAULTS[k]
                else s[k] = v end
            end
        end
    end
    return s
end

function M.save_settings(s)
    local out = {}
    for k in pairs(SETTINGS_DEFAULTS) do
        local v = s[k]
        if SETTINGS_BOOLS[k] then v = v and "1" or "0" else v = tostring(v) end
        out[#out + 1] = k .. "=" .. v
    end
    return write_cfg("settings.cfg", table.concat(out, "\n"))
end

-- A fresh network table with a unique id against the given list.
function M.new_network(nets)
    local used = {}
    for i = 1, #nets do used[nets[i].id] = true end
    local n = 1
    while used["n" .. n] do n = n + 1 end
    return fill_defaults({ id = "n" .. n })
end

return M
