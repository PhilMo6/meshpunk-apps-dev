--[[
  PICO-8 BBS client over the HTTP protocol PICO-8's own SPLORE browser uses
  on www.lexaloffle.com. No UI here; bbs_view.lua draws the screens.

  Listing: cpost_lister3.php returns a 1024x544 palette PNG holding up to 32
  carts as an 8 x 4 grid of 136px-tall tiles. Each tile is the cart's
  128x128 label image followed by 8 rows of text, one character per pixel
  (the palette entry's R, G and B all hold the character):
      row 0  "<n> <pid> <catsub> 0 0 <YYYY-MM-DD HH:MM:SS>"
      row 1  title
      row 2  author
      row 3  lid - the id get_cart.php takes
  A tile whose row 0 is empty ends the list. start_index is 0-based.
  The text rows are read here in Lua: the image data is inflated with
  _inflate only as far as the last text row, and each text row is taken by
  its offset, which requires PNG filter 0 on that row. Any other filter is
  reported as an error.
  Cart: get_cart.php returns the cart as a 160x205 .p8.png.
]]

local fileman = require("lib/fileman")

local M = {}

M.HOST  = "https://www.lexaloffle.com/bbs/"
M.PAGE  = 16                      -- carts per page: two rows of listing tiles
M.CARTS = "S:/p8carts"            -- a folder the launcher scans for carts
M.WORK  = "S:/meshpunk/p8bbs"     -- the listing and carts fetched for viewing
M.LIST_PATH = M.WORK .. "/list.png"
M.PAGE_PATH = M.WORK .. "/thread.html"

-- sub = the BBS section number; orderby "rating" is the Featured order.
M.SECTIONS = {
    { label = "Featured",         sub = 2, orderby = "rating" },
    { label = "Releases",         sub = 2 },
    { label = "Work in progress", sub = 3 },
    { label = "Jam",              sub = 8 },
    { label = "Workshop",         sub = 5 },
    { label = "Collaboration",    sub = 4 },
    { label = "Code",             sub = 9 },
    { label = "GFX",              sub = 14 },
    { label = "SFX / Music",      sub = 15 },
    { label = "Tutorials",        sub = 12 },
}

-- Section names by sub number; a listing entry's catsub is 1792 + sub.
local SUB_NAMES = {
    [1] = "Chat", [2] = "Releases", [3] = "Work in progress",
    [4] = "Collaboration", [5] = "Workshop", [6] = "Bugs", [7] = "Blogs",
    [8] = "Jam", [9] = "Code", [12] = "Tutorials", [14] = "GFX",
    [15] = "SFX / Music",
}

local PNG_SIG = "\137PNG\r\n\26\n"
local LIST_W, LIST_H = 1024, 544
local ROW_BYTES = LIST_W + 1      -- filter byte + one palette index per pixel
local TILE_ROWS = 4               -- text rows read per tile: header, title, author, lid

local function urlencode(s)
    return (s:gsub("[^%w%-_%.~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

-- Control bytes and bytes above 127 become "?": labels take UTF-8 only.
local function printable(s)
    return (s:gsub("[%c\128-\255]", "?"))
end

local function be32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

function M.sd_ready()
    local ok, info = pcall(_storage_get_info)
    return (ok and type(info) == "table" and info.sd_available) and true or false
end

-- A section searched: { label, sub = 0 (every section), search = text }.
function M.search_section(text)
    return { label = "Search: " .. text, sub = 0, search = text }
end

-- page is 0-based.
function M.listing_url(sec, page)
    local url = M.HOST .. "cpost_lister3.php?cat=7&cfil=0&sub=" .. sec.sub
        .. "&max=" .. M.PAGE .. "&start_index=" .. (page * M.PAGE)
    if sec.orderby then url = url .. "&orderby=" .. sec.orderby end
    if sec.search then url = url .. "&search=" .. urlencode(sec.search) end
    return url
end

function M.cart_url(lid)
    return M.HOST .. "get_cart.php?cat=7&play_src=2&lid=" .. urlencode(lid)
end

function M.thread_url(pid)
    return "lexaloffle.com/bbs/?pid=" .. pid
end

function M.thread_page_url(pid)
    return M.HOST .. "?pid=" .. pid
end

function M.cart_name(lid)
    return lid .. ".p8.png"
end

function M.cart_path(lid)
    return M.CARTS .. "/" .. M.cart_name(lid)
end

-- Where a cart fetched for viewing sits until it is kept or dropped.
function M.preview_path(lid)
    return M.WORK .. "/" .. M.cart_name(lid)
end

-- The listing's palette and its compressed image data: plte, idat | nil, err.
local function read_listing(path)
    local f = io.open(path, "r")
    if not f then return nil, "cannot open " .. path end
    local plte, idat, err = nil, {}, nil
    if f:read(8) ~= PNG_SIG then err = "the BBS did not send a listing" end
    while not err do
        local head = f:read(8)
        if not head or #head < 8 then
            err = "the listing is truncated"
            break
        end
        local len = be32(head, 1)
        local kind = head:sub(5, 8)
        if kind == "IEND" then break end
        local body = f:read(len)
        if not body or #body < len or not f:read(4) then
            err = "the listing is truncated"
            break
        end
        if kind == "IHDR" then
            if be32(body, 1) ~= LIST_W or be32(body, 5) ~= LIST_H or body:byte(9) ~= 8
                or body:byte(10) ~= 3 or body:byte(13) ~= 0 then
                err = "the listing image is not in the expected format"
            end
        elseif kind == "PLTE" then
            plte = body
        elseif kind == "IDAT" then
            idat[#idat + 1] = body
        end
    end
    f:close()
    if err then return nil, err end
    if not plte or #idat == 0 then return nil, "the listing is incomplete" end
    return plte, table.concat(idat)
end

-- Text row k of tile t (both 0-based), cut at its NUL.
local function tile_text(rows, t, k)
    local line = rows[(t // 8) * TILE_ROWS + k + 1]
    local col = t % 8
    local s = line:sub(col * 128 + 1, col * 128 + 128)
    local z = s:find("\0", 1, true)
    if z then s = s:sub(1, z - 1) end
    return s
end

-- carts | nil, err. Each cart: { lid, pid, date, section, title, author };
-- section is nil for a sub number not in SUB_NAMES.
function M.parse_listing(path)
    local plte, idat = read_listing(path)
    if not plte then return nil, idat end
    local last_trow = (M.PAGE - 1) // 8
    local need = (last_trow * 136 + 128 + TILE_ROWS) * ROW_BYTES
    local pixels, perr = _inflate(idat, need)
    if not pixels then return nil, "listing data: " .. tostring(perr) end
    if #pixels < need then return nil, "the listing is truncated" end

    -- Palette index -> the character its red channel holds.
    local map = {}
    for i = 0, #plte // 3 - 1 do
        map[string.char(i)] = string.char(plte:byte(i * 3 + 1))
    end
    local rows = {}
    for trow = 0, last_trow do
        for k = 0, TILE_ROWS - 1 do
            local at = (trow * 136 + 128 + k) * ROW_BYTES
            local filter = pixels:byte(at + 1)
            if filter ~= 0 then
                return nil, "listing row uses PNG filter " .. filter
            end
            rows[#rows + 1] = pixels:sub(at + 2, at + ROW_BYTES):gsub(".", map)
        end
    end

    local carts = {}
    for t = 0, M.PAGE - 1 do
        local head = tile_text(rows, t, 0)
        if head == "" then break end
        local pid, catsub, date = head:match("^%d+ (%d+) (%d+) %d+ %d+ (%d+%-%d+%-%d+)")
        local lid = tile_text(rows, t, 3)
        if not pid or not lid:match("^[%w_%-]+$") then
            return nil, "unreadable listing entry " .. (t + 1)
        end
        local title = printable(tile_text(rows, t, 1))
        carts[#carts + 1] = {
            lid     = lid,
            pid     = pid,
            date    = date,
            section = SUB_NAMES[tonumber(catsub) - 1792],
            title   = title ~= "" and title or lid,
            author  = printable(tile_text(rows, t, 2)),
        }
    end
    return carts
end

-- Downloads and reads one page of the listing: carts | nil, err.
function M.fetch_page(sec, page)
    fileman.mkdir(M.WORK)
    local res = _wifi_download_file(M.listing_url(sec, page), M.LIST_PATH)
    if not (res and res.success) then
        return nil, (res and res.error) or "download failed"
    end
    return M.parse_listing(M.LIST_PATH)
end

-- True when the file starts like a PICO-8 cart image: a 160x205 PNG.
local function is_cart(path)
    local f = io.open(path, "r")
    if not f then return false end
    local head = f:read(24)
    f:close()
    return head ~= nil and #head == 24 and head:sub(1, 8) == PNG_SIG
        and head:sub(13, 16) == "IHDR" and be32(head, 17) == 160 and be32(head, 21) == 205
end

-- Downloads cart lid to M.preview_path(lid): that path | nil, err.
function M.fetch_cart(lid)
    fileman.mkdir(M.WORK)
    local path = M.preview_path(lid)
    local res = _wifi_download_file(M.cart_url(lid), path)
    if not (res and res.success) then
        fileman.remove(path)
        return nil, (res and res.error) or "download failed"
    end
    if not is_cart(path) then
        fileman.remove(path)
        return nil, "the BBS did not send a cart"
    end
    return path
end

-- Moves the fetched copy of cart lid into M.CARTS: path | nil, err.
function M.keep_cart(lid)
    fileman.mkdir(M.CARTS)
    local dest = M.cart_path(lid)
    if fileman.exists(dest) then fileman.remove(dest) end
    local ok, err = fileman.rename(M.preview_path(lid), dest)
    if not ok then return nil, err end
    return dest
end

-- The bytes of a file between the first `open` and the first `close` after
-- it, read in 16KB pieces. nil when a marker is missing or more than `max`
-- bytes lie between them.
local function between(path, open, close, max)
    local f = io.open(path, "r")
    if not f then return nil end
    local acc, started, found = "", false, nil
    while not found do
        local piece = f:read(16384)
        if not piece then break end
        acc = acc .. piece
        if not started then
            local _, e = acc:find(open, 1, true)
            if e then
                started = true
                acc = acc:sub(e + 1)
            else
                acc = acc:sub(-#open)   -- keeps a marker cut by the piece boundary
            end
        end
        if started then
            local s = acc:find(close, 1, true)
            if s then
                found = acc:sub(1, s - 1)
            elseif #acc > max then
                break
            end
        end
    end
    f:close()
    return found
end

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }

-- Code point -> UTF-8. Control characters, surrogates and values past
-- U+10FFFF become a space.
local function utf8_char(cp)
    if cp < 32 or (cp >= 0xD800 and cp <= 0xDFFF) or cp > 0x10FFFF then return " " end
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then
        return string.char(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F))
    end
    if cp < 0x10000 then
        return string.char(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
    end
    return string.char(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F),
                       0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
end

-- "amp", "#8217", "#x2019" -> the character; nil for an unknown name.
local function decode_entity(name)
    local n = name:match("^#(%d+)$")
    if n then return utf8_char(tonumber(n)) end
    n = name:match("^#[xX](%x+)$")
    if n then return utf8_char(tonumber(n, 16)) end
    return ENTITIES[name]
end

-- An HTML fragment as plain text: line breaks for <br>, paragraphs,
-- headings, divs and list items; other tags dropped; entities decoded.
local function html_text(s)
    s = s:gsub("%s+", " ")
    s = s:gsub("<[bB][rR]%f[%s/>][^>]*>", "\n")
    s = s:gsub("</?[pP]%f[%s>][^>]*>", "\n\n")
    s = s:gsub("</?[hH]%d%f[%s>][^>]*>", "\n\n")
    s = s:gsub("</?[dD][iI][vV]%f[%s>][^>]*>", "\n")
    s = s:gsub("<[lL][iI]%f[%s>][^>]*>", "\n- ")
    s = s:gsub("<[^>]*>", "")
    s = s:gsub("<[^>]*$", "")
    s = s:gsub("&(#?%w+);", decode_entity)
    s = s:gsub(" *\n *", "\n")
    s = s:gsub("\n\n\n+", "\n\n")
    return (s:match("^%s*(.-)%s*$"))
end

-- Description, tags, star count and license of a cart, from the post that
-- holds it on its BBS thread page: { text, tags, stars, license } | nil, err.
-- stars and license are nil when the post has none. The page is the forum's
-- HTML: the post is read from the cart's first "cartembed_<lid>" (its Embed
-- link) to the next "class=form_button" (the post's star button); the text
-- is what follows the embed block's </textarea>, up to the first tag.
function M.fetch_info(cart)
    fileman.mkdir(M.WORK)
    local res = _wifi_download_file(M.thread_page_url(cart.pid), M.PAGE_PATH)
    local region
    if res and res.success then
        region = between(M.PAGE_PATH, '"cartembed_' .. cart.lid .. '"',
                         "class=form_button", 65536)
    end
    fileman.remove(M.PAGE_PATH)
    if not (res and res.success) then
        return nil, (res and res.error) or "download failed"
    end
    if not region then return nil, "no description found on the BBS page" end

    local info = { tags = {} }
    info.license = region:match('License:</span>%s*<a[^>]*>([^<]+)</a>')
    info.stars = region:match('i_rate_' .. cart.pid
        .. '_like"[^>]*>%s*<img[^>]*>%s*</div>%s*<div[^>]*>(%d+)</div>')
    for tag in region:gmatch('<span class="tag">([^<]+)</span>') do
        info.tags[#info.tags + 1] = tag
    end
    local k = region:find('id="cartembed_' .. cart.lid .. '"', 1, true)
    local t = k and region:find("</textarea>", k, true)
    local html = t and region:sub(t + #"</textarea>") or ""
    local cut = html:find('<span class="tag">', 1, true)
    if cut then html = html:sub(1, cut - 1) end
    local text = html_text(html)
    if #text > 4000 then
        text = (text:sub(1, 4000):gsub("[\192-\255][\128-\191]*$", "")) .. " ..."
    end
    info.text = text
    return info
end

-- Deletes every fetched-for-viewing cart left in M.WORK.
function M.sweep_previews()
    local entries = fileman.list(M.WORK, {
        sizes = false,
        filter = function(e)
            return e.type == "file" and e.name:lower():match("%.p8%.png$") ~= nil
        end,
    }) or {}
    for _, e in ipairs(entries) do fileman.remove(M.WORK .. "/" .. e.name) end
end

return M
