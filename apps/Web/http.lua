--[[
  Web/http.lua — streaming HTTP/1.1 client over _tcp_open (lua_net.cpp).

  Non-blocking: the app pumps the request from its timer. One socket per
  request; Connection: close (no keep-alive). TLS is verify="ca" (the IDF
  certificate bundle), so an https page that loads IS verified. Redirects
  (301/302/303/307/308, absolute or relative Location, max 5) are followed
  internally — 301/302/303 downgrade to GET, 307/308 re-send the method
  and body; the caller only ever sees the final response. Body bytes
  stream to on_body as they arrive.

    local req = http.request {
        url        = "https://example.com/",
        method     = "GET" | "POST" (default GET),
        body       = "a=1&b=2",        -- request body (POST)
        content_type = "...",  -- default application/x-www-form-urlencoded
        body_max   = 512 * 1024,  -- soft stop: on_done{truncated=true}
        stall_limit= 500,         -- pumps with zero progress before "stalled"
        on_status  = function(text) end,               -- UI phase line
        on_headers = function(status, headers, final_url) end,
        on_body    = function(chunk) end,              -- decoded transfer only
        on_done    = function(info) end,  -- {status, bytes, truncated, tls}
        on_error   = function(msg) end,
    }
    req:pump()   -- call from a timer until req.phase is "done"/"error"
    req:abort()  -- also fine from inside on_headers (content-type gate)

  Cookies: a session jar per host (name=value only; attributes are
  ignored, nothing persists). M.clear_cookies() empties it.

  gzip: advertised when the firmware has _inflate; a gzip body is
  buffered (body_max counts COMPRESSED bytes) and delivered to on_body
  as ONE inflated string at the end — the caller paces the parse.
  Without _inflate we advertise identity and a forced encoding fails.

  Not handled, by design: IPv6 literals, userinfo URLs, caching.
]]

local M = {}

local REDIRECT_MAX = 5
local HEAD_MAX = 16 * 1024   -- response header section cap
local RECV_MAX = 4096        -- per-recv slice (lua_net RX ring is 16KB)
local SEND_MAX = 4096        -- per-pump body send slice (TX ring is 8KB)
local COOKIE_HOSTS_MAX = 16
local COOKIES_PER_HOST_MAX = 16

-- <client>/<version> (<contact>) <library>/<version>: the shape Wikimedia's
-- User-Agent policy requires. No "Mozilla/5.0" token — the framework's
-- mbedTLS 2.28.7 speaks TLS 1.2 only, and a browser UA over a non-browser
-- handshake matches anti-scraper impersonation rules (Wikipedia answers
-- such clients with 429).
local USER_AGENT =
    "MeshpunkWeb/1.0 (https://github.com/PhilMo6/meshpunk) mbedTLS/2.28.7"

-- ── Session cookie jar ──────────────────────────────────────────────────────
-- jar[host] = { name = value }. Host-exact, attribute-blind, session-only.

local jar = {}

function M.clear_cookies()
    jar = {}
end

local function jar_store(host, setcookie)
    local name, value = setcookie:match("^%s*([^=;%s]+)%s*=%s*([^;]*)")
    if not name then return end
    value = value:gsub("%s+$", "")
    local hj = jar[host]
    if not hj then
        local n = 0
        for _ in pairs(jar) do n = n + 1 end
        if n >= COOKIE_HOSTS_MAX then return end
        hj = {}
        jar[host] = hj
    end
    if value == "" then
        hj[name] = nil
        return
    end
    if hj[name] == nil then
        local n = 0
        for _ in pairs(hj) do n = n + 1 end
        if n >= COOKIES_PER_HOST_MAX then return end
    end
    hj[name] = value
end

local function jar_header(host)
    local hj = jar[host]
    if not hj then return nil end
    local parts = {}
    for k, v in pairs(hj) do parts[#parts + 1] = k .. "=" .. v end
    if #parts == 0 then return nil end
    return table.concat(parts, "; ")
end

-- ── URLs ────────────────────────────────────────────────────────────────────

-- "https://host:8443/a/b?q=1#x" -> { scheme, host, port, path } (path keeps
-- the query, drops the fragment). A bare "host/path" defaults to http.
function M.parse_url(url)
    url = url:gsub("^%s+", ""):gsub("%s+$", "")
    local scheme, rest = url:match("^(%a[%w+.-]*)://(.*)$")
    if not scheme then
        scheme, rest = "http", url
    end
    scheme = scheme:lower()
    if scheme ~= "http" and scheme ~= "https" then
        return nil, "unsupported scheme: " .. scheme
    end
    local hostport, path = rest:match("^([^/?#]+)(.*)$")
    if not hostport or hostport == "" then return nil, "no host in URL" end
    if hostport:find("@", 1, true) then return nil, "userinfo URLs not supported" end
    local host, port = hostport:match("^(.-):(%d+)$")
    if host and host ~= "" then
        port = tonumber(port)
    else
        host = hostport
        port = (scheme == "https") and 443 or 80
    end
    local frag = path:find("#", 1, true)
    if frag then path = path:sub(1, frag - 1) end
    if path == "" then path = "/" end
    -- "host?q=1" parses to a query-only path; the request line needs "/?q=1".
    if path:sub(1, 1) ~= "/" then path = "/" .. path end
    return { scheme = scheme, host = host:lower(), port = port, path = path }
end

local function origin_of(base)
    local default = (base.scheme == "https") and 443 or 80
    local port = (base.port ~= default) and (":" .. base.port) or ""
    return base.scheme .. "://" .. base.host .. port
end

-- Resolve href against a base (parsed table or URL string). Returns an
-- absolute URL string, or nil for a same-page fragment reference. An
-- already-absolute ref needs no base, so it is answered before the base is
-- even parsed (a bookmark opened from the home view has none).
function M.resolve(base, ref)
    ref = ref:gsub("^%s+", ""):gsub("%s+$", "")
    if ref:match("^%a[%w+.-]*:") then
        -- Absolute (any scheme, mailto:/javascript: included — the caller
        -- filters navigable schemes).
        return ref
    end
    if type(base) == "string" then
        local parsed, err = M.parse_url(base)
        if not parsed then return nil, err end
        base = parsed
    end
    if ref == "" then return origin_of(base) .. base.path end
    if ref:sub(1, 2) == "//" then return base.scheme .. ":" .. ref end
    if ref:sub(1, 1) == "#" then return nil end
    if ref:sub(1, 1) == "?" then
        local p = base.path:match("^([^?]*)")
        return origin_of(base) .. p .. ref
    end
    if ref:sub(1, 1) == "/" then return origin_of(base) .. ref end
    -- Relative path: against the base directory, then normalize ./ and ../
    local dir = base.path:match("^([^?]*)"):match("^(.*/)[^/]*$") or "/"
    local path = dir .. ref
    path = path:gsub("/%./", "/")
    local prev
    repeat
        prev = path
        path = path:gsub("/[^/]+/%.%./", "/", 1)
    until path == prev
    path = path:gsub("^(/%.%.)+/", "/")
    return origin_of(base) .. path
end

function M.urlencode(s)
    return (s:gsub("[^%w%-%._~]", function(c)
        if c == " " then return "+" end
        return ("%%%02X"):format(c:byte())
    end))
end

-- ── Request ─────────────────────────────────────────────────────────────────

local Req = {}
Req.__index = Req

local function fail(self, msg)
    if self.phase == "done" or self.phase == "error" then return end
    self.phase = "error"
    if self.sock then self.sock:close(); self.sock = nil end
    self.cb.on_error(msg)
end

local function finish(self, truncated)
    if self.phase == "done" or self.phase == "error" then return end
    self.phase = "done"
    if self.sock then self.sock:close(); self.sock = nil end
    local bytes = self.body_bytes
    if self.gzip and self.gzparts then
        -- body_max counted compressed bytes; deliver the inflated body as
        -- one on_body call (the caller paces its parse).
        local raw, trunc2 = _inflate(table.concat(self.gzparts))
        self.gzparts = nil
        if not raw then
            self.phase = "error"
            self.cb.on_error("gzip decode failed: " .. tostring(trunc2))
            return
        end
        if trunc2 then truncated = true end
        bytes = #raw
        if #raw > 0 then self.cb.on_body(raw) end
    end
    self.cb.on_done {
        status = self.status,
        bytes = bytes,
        truncated = truncated or false,
        tls = self.parsed.scheme == "https",
    }
end

function Req:abort()
    if self.phase == "done" or self.phase == "error" then return end
    self.phase = "error"
    if self.sock then self.sock:close(); self.sock = nil end
end

local function status_line(self, text)
    if self.cb.on_status then self.cb.on_status(text) end
end

-- Open the socket for self.parsed and reset per-hop state.
local function open_hop(self)
    self.buf = ""
    self.sent = false
    self.status = nil
    self.headers = {}
    self.setcookies = {}
    self.body_mode = nil
    self.body_left = nil
    self.chunk_state = "size"
    self.chunk_left = 0
    self.idle = 0
    self.gzip = false
    self.gzparts = nil
    self.tx_pending = nil
    local opts = { tls = self.parsed.scheme == "https", verify = "ca" }
    local sock, err = _tcp_open(self.parsed.host, self.parsed.port, opts)
    if not sock then
        fail(self, "open failed: " .. tostring(err))
        return
    end
    self.sock = sock
    self.phase = "connect"
    status_line(self, "Connecting to " .. self.parsed.host .. "…")
end

local function redirect_to(self, location)
    self.redirects = self.redirects + 1
    if self.redirects > REDIRECT_MAX then
        fail(self, "too many redirects")
        return
    end
    local abs = M.resolve(self.parsed, location)
    if not abs then
        fail(self, "bad redirect Location")
        return
    end
    local parsed, err = M.parse_url(abs)
    if not parsed then
        fail(self, "redirect: " .. err)
        return
    end
    -- Browser method semantics: 301/302/303 downgrade to GET and drop the
    -- body; 307/308 replay the request as-is.
    if self.status ~= 307 and self.status ~= 308 then
        self.method = "GET"
        self.body = nil
        self.content_type = nil
    end
    self.sock:close()
    self.sock = nil
    self.parsed = parsed
    self.url = abs
    open_hop(self)
end

local function send_request(self)
    local p = self.parsed
    local default = (p.scheme == "https") and 443 or 80
    local host = p.host .. ((p.port ~= default) and (":" .. p.port) or "")
    -- Encode bytes a request line can't carry raw (page links often hold
    -- raw UTF-8); existing %XX escapes pass through untouched.
    local path = p.path:gsub("[%c \128-\255]", function(c)
        return ("%%%02X"):format(c:byte())
    end)
    local enc = (type(_inflate) == "function") and "gzip, identity"
        or "identity"
    local lines = {
        self.method .. " " .. path .. " HTTP/1.1",
        "Host: " .. host,
        "User-Agent: " .. USER_AGENT,
        "Accept: text/html,text/plain;q=0.8,*/*;q=0.2",
        "Accept-Encoding: " .. enc,
        "Connection: close",
    }
    local cookies = jar_header(p.host)
    if cookies then lines[#lines + 1] = "Cookie: " .. cookies end
    if self.body then
        lines[#lines + 1] = "Content-Type: "
            .. (self.content_type or "application/x-www-form-urlencoded")
        lines[#lines + 1] = "Content-Length: " .. #self.body
    end
    local head = table.concat(lines, "\r\n") .. "\r\n\r\n"
    local n, err = self.sock:send(head)
    if not n then
        fail(self, "send failed: " .. tostring(err))
        return
    end
    -- The body follows in bounded slices from pump(): send() is
    -- all-or-nothing into an 8KB TX ring, so a large body can't go in
    -- one call.
    self.tx_pending = self.body
    self.sent = true
    self.phase = "headers"
end

-- Push pending body bytes; a full TX ring just retries next pump.
local function pump_tx(self)
    while self.tx_pending and #self.tx_pending > 0 do
        local slice = self.tx_pending:sub(1, SEND_MAX)
        local n = self.sock:send(slice)
        if not n then return end
        self.tx_pending = self.tx_pending:sub(#slice + 1)
        self.idle = 0
    end
    self.tx_pending = nil
end

-- Emit body bytes toward the sink, respecting the cap (which counts
-- compressed bytes for a gzip body).
local function emit(self, chunk)
    if #chunk == 0 then return true end
    local room = self.body_max - self.body_bytes
    if room <= 0 then
        finish(self, true)
        return false
    end
    if #chunk > room then chunk = chunk:sub(1, room) end
    self.body_bytes = self.body_bytes + #chunk
    if self.gzip then
        self.gzparts[#self.gzparts + 1] = chunk
    else
        self.cb.on_body(chunk)
    end
    if self.body_bytes >= self.body_max then
        finish(self, true)
        return false
    end
    return self.phase == "body"   -- an on_body abort stops the drain
end

-- Consume self.buf according to the chunked-transfer state machine.
local function drain_chunked(self)
    while true do
        if self.chunk_state == "size" or self.chunk_state == "trailer" then
            local nl = self.buf:find("\r\n", 1, true)
            if not nl then
                if #self.buf > 1024 then fail(self, "bad chunked encoding") end
                return
            end
            local line = self.buf:sub(1, nl - 1)
            self.buf = self.buf:sub(nl + 2)
            if self.chunk_state == "size" then
                local hex = line:match("^(%x+)")
                if not hex then
                    fail(self, "bad chunk size")
                    return
                end
                self.chunk_left = tonumber(hex, 16)
                if self.chunk_left == 0 then
                    self.chunk_state = "trailer"
                else
                    self.chunk_state = "data"
                end
            else -- trailer
                if line == "" then
                    finish(self)
                    return
                end
            end
        elseif self.chunk_state == "data" then
            if #self.buf == 0 then return end
            local take = math.min(#self.buf, self.chunk_left)
            local piece = self.buf:sub(1, take)
            self.buf = self.buf:sub(take + 1)
            self.chunk_left = self.chunk_left - take
            if self.chunk_left == 0 then self.chunk_state = "crlf" end
            if not emit(self, piece) then return end
        elseif self.chunk_state == "crlf" then
            if #self.buf < 2 then return end
            self.buf = self.buf:sub(3)
            self.chunk_state = "size"
        end
    end
end

local function drain_body(self)
    if self.body_mode == "chunked" then
        drain_chunked(self)
    elseif self.body_mode == "length" then
        if #self.buf == 0 then return end
        local take = math.min(#self.buf, self.body_left)
        local piece = self.buf:sub(1, take)
        self.buf = self.buf:sub(take + 1)
        self.body_left = self.body_left - take
        if emit(self, piece) and self.body_left == 0 then finish(self) end
    else -- close-delimited
        local piece = self.buf
        self.buf = ""
        emit(self, piece)
    end
end

local function on_headers_complete(self, raw)
    local first_end = raw:find("\r\n", 1, true) or #raw + 1
    local statusline = raw:sub(1, first_end - 1)
    local code = statusline:match("^HTTP/%d%.%d%s+(%d%d%d)")
    if not code then
        fail(self, "bad status line")
        return
    end
    self.status = tonumber(code)
    for line in raw:sub(first_end + 2):gmatch("([^\r\n]+)") do
        local k, v = line:match("^([^:]+):%s*(.-)%s*$")
        if k then
            k = k:lower()
            if k == "set-cookie" then
                -- May repeat; the last-wins header map would drop all but one.
                self.setcookies[#self.setcookies + 1] = v
            else
                self.headers[k] = v
            end
        end
    end
    for _, sc in ipairs(self.setcookies) do
        jar_store(self.parsed.host, sc)
    end

    if self.status >= 301 and self.status <= 308 and self.status ~= 304
        and self.status ~= 305 and self.status ~= 306
        and self.headers["location"] then
        status_line(self, "Redirected…")
        redirect_to(self, self.headers["location"])
        return
    end

    local enc = (self.headers["content-encoding"] or "identity"):lower()
    if enc:find("gzip", 1, true) then
        if type(_inflate) ~= "function" then
            fail(self, "server forced content-encoding: " .. enc)
            return
        end
        self.gzip = true
        self.gzparts = {}
    elseif enc ~= "identity" and enc ~= "" then
        fail(self, "server forced content-encoding: " .. enc)
        return
    end

    self.phase = "body"
    local te = (self.headers["transfer-encoding"] or ""):lower()
    if te:find("chunked", 1, true) then
        self.body_mode = "chunked"
    elseif self.headers["content-length"] then
        local len = tonumber(self.headers["content-length"])
        if not len then
            fail(self, "bad Content-Length")
            return
        end
        self.body_mode = "length"
        self.body_left = len
    else
        self.body_mode = "close"
    end

    if self.cb.on_headers then
        self.cb.on_headers(self.status, self.headers, self.url)
    end
    if self.phase ~= "body" then return end   -- on_headers aborted
    if self.body_mode == "length" and self.body_left == 0 then
        finish(self)
        return
    end
    drain_body(self)
end

function Req:pump()
    if self.phase == "done" or self.phase == "error" then return end

    local st, reason = self.sock:state()
    if self.phase == "connect" then
        if st == "open" then
            self.idle = 0
            send_request(self)
        elseif st == "closed" then
            fail(self, "connect failed: " .. tostring(reason))
        elseif st == "untrusted" then
            -- verify="ca" never parks in untrusted; seeing it is a bug.
            fail(self, "unexpected untrusted TLS state")
        else
            self.idle = self.idle + 1
            if self.idle > self.stall_limit then fail(self, "connect stalled") end
        end
        return
    end

    if self.tx_pending then pump_tx(self) end

    local progressed = false
    while true do
        local data, why = self.sock:recv(RECV_MAX)
        if data == nil then
            -- Closed and drained. For a close-delimited body that IS the end.
            if self.phase == "body" and self.body_mode == "close" then
                finish(self)
            elseif self.phase == "body" and self.body_mode == "length" then
                fail(self, "connection lost mid-body (" .. tostring(why) .. ")")
            elseif self.phase == "body" then -- chunked
                fail(self, "connection lost mid-chunk (" .. tostring(why) .. ")")
            else
                fail(self, "connection closed in headers (" .. tostring(why) .. ")")
            end
            return
        end
        if data == "" then break end
        progressed = true
        self.buf = self.buf .. data

        if self.phase == "headers" then
            local term = self.buf:find("\r\n\r\n", 1, true)
            if term then
                local raw = self.buf:sub(1, term - 1)
                self.buf = self.buf:sub(term + 4)
                on_headers_complete(self, raw)
            elseif #self.buf > HEAD_MAX then
                fail(self, "response headers too large")
            end
        elseif self.phase == "body" then
            drain_body(self)
        end

        if self.phase ~= "headers" and self.phase ~= "body" then return end
    end

    if progressed then
        self.idle = 0
        if self.phase == "body" then
            status_line(self, ("Loading… %d KB"):format(self.body_bytes // 1024))
        end
    else
        self.idle = self.idle + 1
        if self.idle > self.stall_limit then fail(self, "transfer stalled") end
    end
end

function M.request(opts)
    local parsed, err = M.parse_url(opts.url)
    if not parsed then
        opts.on_error(err)
        return nil
    end
    local self = setmetatable({
        cb = opts,
        url = opts.url,
        parsed = parsed,
        method = (opts.method or "GET"):upper(),
        body = opts.body,
        content_type = opts.content_type,
        redirects = 0,
        body_max = opts.body_max or 512 * 1024,
        stall_limit = opts.stall_limit or 500,
        body_bytes = 0,
        phase = "connect",
    }, Req)
    open_hop(self)
    -- A synchronous open failure already ran on_error; hand back nil so the
    -- caller doesn't hold (and pump) a dead request.
    if self.phase == "error" then return nil end
    return self
end

return M
