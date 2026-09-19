--[[
  Web/html.lua — streaming HTML tokenizer -> flat block list (no DOM).

    local P = html.new()
    P:feed(chunk)   -- chunks may split anywhere: tags, entities, comments
    local page = P:finish()

  page = {
    title  = string|nil,
    base   = string|nil,            -- <base href>, raw (resolve at click)
    links  = { href, ... },         -- raw hrefs, entity-decoded
    images = { src, ... },          -- raw srcs, entity-decoded
    blocks = { block, ... },
    forms  = { { action, method = "get"|"post", fields = {field,...} } },
    anchors = { [id] = block-index },   -- fragment targets
    refresh = { delay, url } | nil,     -- <meta http-equiv=refresh>
    truncated = nil | "blocks",
  }
  block = { kind = "p"|"h1".."h6"|"pre"|"rule"|"field",
            indent = 0..6, quote = bool, th = bool|nil (bold whole block),
            anchors = { id, ... },   -- every fragment id landing here
            form, field = indexes (kind "field" only),
            runs = { { text, link = links-index|nil, img = images-index|nil,
                       bold, italic, code, strike, uline = bool }, ... } }
  field = { kind = "text"|"textarea"|"checkbox"|"radio"|"select"|"submit"
                 |"hidden",
            name, value, label, password, checked, options }

  Rendering decisions live in main.lua; this file only classifies. Content
  of script/style/svg/template is discarded, comments and doctypes are
  skipped, entities are decoded (common named set + numeric), whitespace
  collapses outside <pre>. Unknown tags are transparent — their text flows
  into the current block, which is how a no-CSS reader wants tag soup to
  degrade.
]]

local M = {}

local BLOCK_MAX = 800      -- page cap; beyond it the parser drains. One
                           -- widget per block: build time and teardown
                           -- (watchdog) bound this, not memory.
local PARA_CHARS_MAX = 8192   -- spangroup budget per text block
local PRE_CHARS_MAX = 32768   -- label budget per pre block
local TAG_MAX = 4096       -- a "<" with no ">" within this is literal text
local TITLE_MAX = 256
local ANCHORS_MAX = 8      -- fragment ids recorded per block

-- ── Entities ────────────────────────────────────────────────────────────────

local NAMED = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'",
    nbsp = " ", shy = "", copy = "©", reg = "®", trade = "™",
    hellip = "…", mdash = "—", ndash = "–", minus = "−",
    lsquo = "‘", rsquo = "’", ldquo = "“", rdquo = "”",
    laquo = "«", raquo = "»", bull = "•", middot = "·",
    deg = "°", times = "×", divide = "÷", plusmn = "±",
    frac12 = "½", frac14 = "¼", frac34 = "¾", sup2 = "²", sup3 = "³",
    micro = "µ", para = "¶", sect = "§", dagger = "†", larr = "←",
    rarr = "→", uarr = "↑", darr = "↓", harr = "↔", infin = "∞",
    ne = "≠", le = "≤", ge = "≥", asymp = "≈",
    eacute = "é", egrave = "è", ecirc = "ê", agrave = "à", acirc = "â",
    ccedil = "ç", uuml = "ü", ouml = "ö", auml = "ä", szlig = "ß",
    ntilde = "ñ", euro = "€", pound = "£", yen = "¥", cent = "¢",
}

local function decode_entities(s)
    if not s:find("&", 1, true) then return s end
    return (s:gsub("&(#?%w+);", function(e)
        if e:sub(1, 1) == "#" then
            local n
            if e:sub(2, 2):lower() == "x" then
                n = tonumber(e:sub(3), 16)
            else
                n = tonumber(e:sub(2))
            end
            if not n then return "" end
            if n == 9 or n == 10 or n == 13 then return " " end
            if n < 32 or n >= 0x110000 then return "" end
            local ok, c = pcall(utf8.char, n)
            return ok and c or ""
        end
        return NAMED[e] or NAMED[e:lower()] or ("&" .. e .. ";")
    end))
end

M.decode_entities = decode_entities

-- ── Tag attribute extraction ────────────────────────────────────────────────

-- Value of one attribute from a tag's inner text ("a href=... class=...").
-- Quoted or bare values; nil when absent. Values come back entity-decoded.
local function find_attr(tagstr, want)
    local _, e = tagstr:find("^/?%s*[%a][%w-]*")
    local pos = (e or 0) + 1
    while true do
        local s1, e1, name = tagstr:find("([%a][%w:-]*)", pos)
        if not s1 then return nil end
        pos = e1 + 1
        local value
        local _, esp = tagstr:find("^%s*", pos)
        local after = esp + 1
        if tagstr:sub(after, after) == "=" then
            pos = after + 1
            local _, e2 = tagstr:find("^%s*", pos)
            pos = e2 + 1
            local q = tagstr:sub(pos, pos)
            if q == '"' or q == "'" then
                local close = tagstr:find(q, pos + 1, true)
                if not close then return nil end
                value = tagstr:sub(pos + 1, close - 1)
                pos = close + 1
            else
                local s3, e3, bare = tagstr:find("^([^%s]+)", pos)
                value = bare or ""
                pos = (e3 or pos) + 1
            end
        end
        if name:lower() == want then
            -- A present-but-valueless attribute ("checked", "selected")
            -- returns "": distinguishable from absent (nil).
            if value then return decode_entities(value) end
            return ""
        end
    end
end

-- ── Parser ──────────────────────────────────────────────────────────────────

local P = {}
P.__index = P

function M.new()
    return setmetatable({
        mode = "text",  -- text | comment | rawtext | title | tacapture | skip_gt
        pending = "",        -- carry-over between feeds
        raw_close = nil,     -- "</script" | "</style" while in rawtext
        drain = false,

        blocks = {},
        links = {},
        images = {},
        forms = {},
        anchor_map = {},
        cur = nil,           -- open block
        title = nil,
        title_buf = nil,
        base = nil,
        refresh = nil,

        bold = 0, italic = 0, code = 0, strike = 0, uline = 0,
        link_stack = {},     -- link index or false per open <a>
        list_stack = {},     -- {type="ul"|"ol", n=counter}
        quote = 0,
        pre = 0,
        svg = 0,             -- svg/template skip depth
        br_run = 0,          -- consecutive <br> count (2 = paragraph break)

        cur_form = nil,      -- index into forms while a <form> is open
        btncap = nil,        -- <button> label capture {form,name,value,buf}
        sel_field = nil,     -- open <select>'s field
        sel_opt = nil,       -- open <option> {value,selected,buf}
        ta_field = nil,      -- open <textarea>'s field (mode "tacapture")
        ta_buf = nil,
        img_next = nil,      -- images-index for the next appended run
        pending_anchors = {},   -- fragment ids awaiting the next block
    }, P)
end

local function start_block(self, kind, indent)
    P.flush(self)
    if self.drain then return end
    self.cur = {
        kind = kind,
        indent = indent or math.min(#self.list_stack, 6),
        quote = self.quote > 0,
        anchors = self.pending_anchors,
        runs = {},
        chars = 0,
    }
    self.pending_anchors = {}
end

function P:flush()
    local b = self.cur
    self.cur = nil
    if not b then return end
    -- Trim edge whitespace; drop blocks with no visible text.
    local first, last = b.runs[1], b.runs[#b.runs]
    if first then first.text = first.text:gsub("^%s+", "") end
    if last then last.text = last.text:gsub("%s+$", "") end
    local has_text = false
    for _, r in ipairs(b.runs) do
        if r.text ~= "" then has_text = true break end
    end
    if b.kind == "rule" then has_text = true end
    if not has_text then
        -- An empty anchor node (<div id=x></div>) hands its ids to the
        -- next block instead of vanishing.
        for _, a in ipairs(b.anchors) do
            if #self.pending_anchors >= ANCHORS_MAX then break end
            self.pending_anchors[#self.pending_anchors + 1] = a
        end
        return
    end
    if #self.blocks >= BLOCK_MAX then
        self.truncated = "blocks"
        self.drain = true
        return
    end
    self.blocks[#self.blocks + 1] = b
    for _, a in ipairs(b.anchors) do self.anchor_map[a] = #self.blocks end
end

-- Register a form field; every kind except "hidden" also lands a "field"
-- block at the document position so the renderer draws a widget there.
local function add_field(self, f, form_idx)
    form_idx = form_idx or self.cur_form
    local form = self.forms[form_idx]
    if not form or self.drain then return end
    form.fields[#form.fields + 1] = f
    if f.kind == "hidden" then return end
    P.flush(self)
    if self.drain then return end
    if #self.blocks >= BLOCK_MAX then
        self.truncated = "blocks"
        self.drain = true
        return
    end
    local blk = { kind = "field", form = form_idx, field = #form.fields,
                  runs = {}, anchors = self.pending_anchors }
    self.pending_anchors = {}
    self.blocks[#self.blocks + 1] = blk
    for _, a in ipairs(blk.anchors) do self.anchor_map[a] = #self.blocks end
end

-- Append text to the current block (opening a "p" if none), splitting into
-- continuation blocks when a block outgrows its widget budget.
local function append(self, s, raw)
    if self.drain or self.svg > 0 or s == "" then return end
    if not self.cur then start_block(self, "p") end
    if self.drain then return end
    local b = self.cur
    local limit = (b.kind == "pre") and PRE_CHARS_MAX or PARA_CHARS_MAX
    if b.chars + #s > limit then
        local room = limit - b.chars
        local head = s:sub(1, room)
        local tail = s:sub(room + 1)
        append(self, head, raw)
        local kind, indent = b.kind, b.indent
        start_block(self, kind, indent)
        append(self, tail, raw)
        return
    end

    local link = self.link_stack[#self.link_stack] or nil
    if link == false then link = nil end
    local bold = self.bold > 0
    local italic = self.italic > 0
    local code = self.code > 0
    local strike = self.strike > 0
    local uline = self.uline > 0
    local img = self.img_next
    self.img_next = nil

    local runs = b.runs
    local lastr = runs[#runs]
    if not raw then
        -- Collapse the join: a piece starting with a space after a piece
        -- that ended with one (or at block start) keeps a single space.
        local prev_ch = lastr and lastr.text:sub(-1) or ""
        if s:sub(1, 1) == " " and (prev_ch == " " or prev_ch == "" or prev_ch == "\n") then
            s = s:sub(2)
            if s == "" then return end
        end
    end
    if lastr and lastr.img == nil and img == nil
        and lastr.link == link and lastr.bold == bold
        and lastr.italic == italic and lastr.code == code
        and lastr.strike == strike and lastr.uline == uline then
        lastr.text = lastr.text .. s
    else
        runs[#runs + 1] = { text = s, link = link, img = img, bold = bold,
                            italic = italic, code = code,
                            strike = strike, uline = uline }
    end
    b.chars = b.chars + #s
end

local function emit_text(self, s)
    if self.drain or self.svg > 0 then return end
    -- Captures divert flowing text: a <button> label, an <option> label
    -- (text directly inside <select> but outside options is dropped).
    if self.btncap then
        self.btncap.buf[#self.btncap.buf + 1] = decode_entities(s)
        return
    end
    if self.sel_field then
        if self.sel_opt then
            self.sel_opt.buf[#self.sel_opt.buf + 1] = decode_entities(s)
        end
        return
    end
    s = decode_entities(s)
    if self.pre > 0 then
        if self.cur == nil or self.cur.kind ~= "pre" then
            start_block(self, "pre")
        end
        append(self, s, true)
        return
    end
    s = s:gsub("[ \t\r\n]+", " ")
    if s == " " then
        -- Whitespace between tags neither opens a block nor interrupts a
        -- <br><br> paragraph break.
        if self.cur then append(self, s, false) end
        return
    end
    self.br_run = 0
    append(self, s, false)
end

-- ── Tag dispatch ────────────────────────────────────────────────────────────

local BLOCK_TAGS = {
    p = true, div = true, section = true, article = true, main = true,
    header = true, footer = true, aside = true, figure = true,
    figcaption = true, details = true, summary = true, dt = true,
    address = true, center = true, nav = true,
    fieldset = true, tr = true,
}
local HEADINGS = { h1 = "h1", h2 = "h2", h3 = "h3", h4 = "h4",
                   h5 = "h5", h6 = "h6" }
local BOLD_TAGS = { b = true, strong = true }
local ITALIC_TAGS = { i = true, em = true, cite = true, dfn = true }
local CODE_TAGS = { code = true, tt = true, kbd = true, samp = true,
                    var = true }
local STRIKE_TAGS = { s = true, del = true, strike = true }
local ULINE_TAGS = { u = true, ins = true }
local SKIP_TAGS = { svg = true, template = true }

-- Text input types that render as a one-line field; everything else
-- unlisted (file, color, range, date, ...) is skipped.
local TEXT_INPUTS = { text = true, search = true, url = true, email = true,
                      tel = true, number = true, password = true }

local function capped_text(buf)
    local s = table.concat(buf):gsub("[ \t\r\n]+", " ")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function finish_option(self)
    local o = self.sel_opt
    self.sel_opt = nil
    if not o or not self.sel_field then return end
    local label = capped_text(o.buf)
    if label == "" and (o.value == nil or o.value == "") then return end
    self.sel_field.options[#self.sel_field.options + 1] = {
        label = label ~= "" and label or o.value,
        value = (o.value ~= nil and o.value ~= "") and o.value or label,
        selected = o.selected,
    }
end

local function finish_button(self)
    local bc = self.btncap
    self.btncap = nil
    if not bc or bc.skip then return end
    local label = capped_text(bc.buf)
    if label == "" then label = bc.value end
    if label == nil or label == "" then label = "Submit" end
    add_field(self, { kind = "submit", label = label,
                      name = bc.name, value = bc.value }, bc.form)
end

-- Fragment hrefs ("#top") are real links now: the app resolves them to
-- in-page anchor jumps.
local function open_link(self, href)
    if href and href ~= "" and #self.links < 1000 then
        self.links[#self.links + 1] = href
        self.link_stack[#self.link_stack + 1] = #self.links
    else
        self.link_stack[#self.link_stack + 1] = false
    end
end

-- Remember a fragment target: on the open block, else on the next one.
-- EVERY id on the way to a block counts, because the one a link points at
-- is not always the outermost: Wikipedia wraps each heading in
-- <section id="mwQw" ...> around <h2 id="Description">, and its contents
-- links target the inner one. Keeping only the first id threw that away.
local function set_anchor(self, aid)
    if not aid or aid == "" then return end
    local t = self.cur and self.cur.anchors or self.pending_anchors
    if #t < ANCHORS_MAX then t[#t + 1] = aid end
end

function P:handle_tag(tagstr)
    if tagstr == "" then return end
    local closing = tagstr:sub(1, 1) == "/"
    local name = tagstr:match("^/?%s*([%a][%w-]*)")
    if not name then return end
    name = name:lower()

    if name ~= "br" then self.br_run = 0 end

    if SKIP_TAGS[name] then
        if closing then
            self.svg = math.max(0, self.svg - 1)
        elseif tagstr:sub(-1) ~= "/" then
            self.svg = self.svg + 1
        end
        return
    end
    if self.svg > 0 then return end

    if not closing then
        if tagstr:find("id", 1, true) then
            set_anchor(self, find_attr(tagstr, "id"))
        end

        if name == "script" or name == "style" then
            self.mode = "rawtext"
            self.raw_close = "</" .. name
        elseif name == "title" then
            if not self.title then
                self.mode = "title"
                self.title_buf = ""
            else
                self.mode = "rawtext"
                self.raw_close = "</title"
            end
        elseif HEADINGS[name] then
            start_block(self, HEADINGS[name])
        elseif BLOCK_TAGS[name] then
            self:flush()
        elseif name == "br" then
            -- Pages with no block tags (FrogFind's results, much of the
            -- old web) separate paragraphs with <br><br>; without this
            -- the whole document is one block.
            self.br_run = self.br_run + 1
            if self.br_run >= 2 and self.pre == 0 then
                self:flush()
            else
                append(self, "\n", true)
            end
        elseif name == "hr" then
            self:flush()
            if not self.drain and #self.blocks < BLOCK_MAX then
                self.blocks[#self.blocks + 1] = { kind = "rule", runs = {} }
            end
        elseif name == "li" then
            local top = self.list_stack[#self.list_stack]
            local prefix = "• "
            if top and top.type == "ol" then
                top.n = top.n + 1
                prefix = top.n .. ". "
            end
            start_block(self, "p")
            append(self, prefix, true)
        elseif name == "ul" or name == "ol" then
            self:flush()
            if #self.list_stack < 6 then
                self.list_stack[#self.list_stack + 1] = { type = name, n = 0 }
            end
        elseif name == "blockquote" then
            self:flush()
            self.quote = self.quote + 1
        elseif name == "pre" then
            self:flush()
            self.pre = self.pre + 1
        elseif name == "dd" then
            start_block(self, "p", 1)
        elseif name == "td" or name == "th" then
            -- Cells render as indented lines. th marks the BLOCK bold (not
            -- the inline counter: real tables omit </th> all the time, and
            -- a leaked counter would bold the rest of the page).
            start_block(self, "p", 1)
            if name == "th" and self.cur then self.cur.th = true end
        elseif name == "form" then
            self:flush()
            finish_button(self)
            self.forms[#self.forms + 1] = {
                action = find_attr(tagstr, "action"),
                method = (find_attr(tagstr, "method") or "get"):lower(),
                fields = {},
            }
            self.cur_form = #self.forms
        elseif name == "input" then
            local itype = (find_attr(tagstr, "type") or "text"):lower()
            local iname = find_attr(tagstr, "name")
            local ivalue = find_attr(tagstr, "value") or ""
            if itype == "hidden" then
                add_field(self, { kind = "hidden", name = iname,
                                  value = ivalue })
            elseif itype == "submit" then
                add_field(self, { kind = "submit", name = iname,
                                  value = ivalue,
                                  label = ivalue ~= "" and ivalue or "Submit" })
            elseif itype == "checkbox" or itype == "radio" then
                add_field(self, { kind = itype, name = iname,
                                  value = ivalue ~= "" and ivalue or "on",
                                  checked = find_attr(tagstr, "checked") ~= nil })
            elseif TEXT_INPUTS[itype] then
                add_field(self, { kind = "text", name = iname, value = ivalue,
                                  password = itype == "password" })
            end
        elseif name == "button" then
            finish_button(self)
            local btype = (find_attr(tagstr, "type") or "submit"):lower()
            self.btncap = { skip = btype ~= "submit", form = self.cur_form,
                            name = find_attr(tagstr, "name"),
                            value = find_attr(tagstr, "value"), buf = {} }
        elseif name == "textarea" then
            local f = { kind = "textarea", name = find_attr(tagstr, "name"),
                        value = "" }
            add_field(self, f)
            self.ta_field = f
            self.ta_buf = {}
            self.mode = "tacapture"
        elseif name == "select" then
            finish_option(self)
            local f = { kind = "select", name = find_attr(tagstr, "name"),
                        options = {} }
            add_field(self, f)
            self.sel_field = f
        elseif name == "option" then
            finish_option(self)
            if self.sel_field then
                self.sel_opt = { value = find_attr(tagstr, "value"),
                                 selected = find_attr(tagstr, "selected") ~= nil,
                                 buf = {} }
            end
        elseif name == "meta" then
            if not self.refresh and tagstr:lower():find("refresh", 1, true) then
                local content = find_attr(tagstr, "content")
                if content then
                    local delay = tonumber(content:match("^%s*(%d+)"))
                    local url = content:match("[Uu][Rr][Ll]%s*=%s*['\"]?([^'\"]+)")
                    if delay and url then
                        self.refresh = { delay = delay,
                                         url = url:gsub("%s+$", "") }
                    end
                end
            end
        elseif BOLD_TAGS[name] then
            self.bold = self.bold + 1
        elseif ITALIC_TAGS[name] then
            self.italic = self.italic + 1
        elseif CODE_TAGS[name] then
            self.code = self.code + 1
        elseif STRIKE_TAGS[name] then
            self.strike = self.strike + 1
        elseif ULINE_TAGS[name] then
            self.uline = self.uline + 1
        elseif name == "a" then
            set_anchor(self, find_attr(tagstr, "name"))
            open_link(self, find_attr(tagstr, "href"))
            if tagstr:sub(-1) == "/" then
                table.remove(self.link_stack)
            end
        elseif name == "img" then
            local alt = find_attr(tagstr, "alt")
            local src = find_attr(tagstr, "src")
            local wpx = tonumber(find_attr(tagstr, "width") or "")
            local hpx = tonumber(find_attr(tagstr, "height") or "")
            -- Skip tracking pixels / spacers.
            if (wpx and wpx <= 2) or (hpx and hpx <= 2) then src = nil end
            if src and src ~= "" and #self.images < 500 then
                self.images[#self.images + 1] = src
                self.img_next = #self.images
                local label = "[" .. ((alt and alt ~= "") and alt or "image") .. "]"
                append(self, label, false)
                self.img_next = nil
            elseif (alt and alt ~= "") or self.link_stack[#self.link_stack] then
                local label = "[" .. ((alt and alt ~= "") and alt or "img") .. "]"
                self.code = self.code + 1
                append(self, label, false)
                self.code = self.code - 1
            end
        elseif name == "iframe" then
            local src = find_attr(tagstr, "src")
            if src and src ~= "" then
                start_block(self, "p")
                open_link(self, src)
                self.code = self.code + 1
                append(self, "[frame]", false)
                self.code = self.code - 1
                table.remove(self.link_stack)
                self:flush()
            end
        elseif name == "base" then
            if not self.base then
                self.base = find_attr(tagstr, "href")
            end
        end
        return
    end

    -- Closing tags
    if HEADINGS[name] or BLOCK_TAGS[name] or name == "li" then
        self:flush()
    elseif name == "ul" or name == "ol" then
        self:flush()
        if #self.list_stack > 0 then table.remove(self.list_stack) end
    elseif name == "blockquote" then
        self:flush()
        self.quote = math.max(0, self.quote - 1)
    elseif name == "pre" then
        self:flush()
        self.pre = math.max(0, self.pre - 1)
    elseif name == "dd" or name == "td" or name == "th" then
        self:flush()
    elseif name == "form" then
        finish_button(self)
        finish_option(self)
        self.sel_field = nil
        self.cur_form = nil
        self:flush()
    elseif name == "button" then
        finish_button(self)
    elseif name == "select" then
        finish_option(self)
        self.sel_field = nil
    elseif name == "option" then
        finish_option(self)
    elseif BOLD_TAGS[name] then
        self.bold = math.max(0, self.bold - 1)
    elseif ITALIC_TAGS[name] then
        self.italic = math.max(0, self.italic - 1)
    elseif CODE_TAGS[name] then
        self.code = math.max(0, self.code - 1)
    elseif STRIKE_TAGS[name] then
        self.strike = math.max(0, self.strike - 1)
    elseif ULINE_TAGS[name] then
        self.uline = math.max(0, self.uline - 1)
    elseif name == "a" then
        if #self.link_stack > 0 then table.remove(self.link_stack) end
    end
end

-- ── Feed loop ───────────────────────────────────────────────────────────────

function P:title_text(s)
    if #self.title_buf < TITLE_MAX then
        self.title_buf = self.title_buf .. s
    end
end

function P:feed(chunk)
    if self.drain and self.mode == "text" then return end
    local buf = self.pending .. chunk
    self.pending = ""
    local len = #buf
    local pos = 1
    local lowered = nil
    local function low()
        if not lowered then lowered = buf:lower() end
        return lowered
    end

    while pos <= len do
        if self.mode == "comment" then
            local e = buf:find("-->", pos, true)
            if e then
                pos = e + 3
                self.mode = "text"
            else
                self.pending = buf:sub(math.max(pos, len - 1))
                return
            end

        elseif self.mode == "rawtext" then
            local s = low():find(self.raw_close, pos, true)
            if s then
                local gt = buf:find(">", s, true)
                if gt then
                    pos = gt + 1
                    self.mode = "text"
                else
                    self.pending = buf:sub(s)
                    return
                end
            else
                self.pending = buf:sub(math.max(pos, len - #self.raw_close + 2))
                return
            end

        elseif self.mode == "title" then
            local s = low():find("</title", pos, true)
            if s then
                self:title_text(buf:sub(pos, s - 1))
                self.title = decode_entities(self.title_buf)
                    :gsub("[ \t\r\n]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
                local gt = buf:find(">", s, true)
                if gt then
                    pos = gt + 1
                    self.mode = "text"
                else
                    self.mode = "rawtext"
                    self.raw_close = "</title"
                    self.pending = buf:sub(s)
                    return
                end
            else
                local keep = math.max(pos, len - 6)
                if keep > pos then self:title_text(buf:sub(pos, keep - 1)) end
                self.pending = buf:sub(keep)
                return
            end

        elseif self.mode == "tacapture" then
            local s = low():find("</textarea", pos, true)
            if s then
                if self.ta_field then
                    self.ta_buf[#self.ta_buf + 1] = buf:sub(pos, s - 1)
                    -- The spec drops one leading newline inside <textarea>.
                    self.ta_field.value = decode_entities(
                        table.concat(self.ta_buf)):gsub("^\r?\n", "")
                end
                self.ta_field = nil
                self.ta_buf = nil
                local gt = buf:find(">", s, true)
                if gt then
                    pos = gt + 1
                    self.mode = "text"
                else
                    self.mode = "rawtext"
                    self.raw_close = "</textarea"
                    self.pending = buf:sub(s)
                    return
                end
            else
                local keep = math.max(pos, len - 9)
                if keep > pos and self.ta_buf then
                    self.ta_buf[#self.ta_buf + 1] = buf:sub(pos, keep - 1)
                end
                self.pending = buf:sub(keep)
                return
            end

        elseif self.mode == "skip_gt" then
            local gt = buf:find(">", pos, true)
            if gt then
                pos = gt + 1
                self.mode = "text"
            else
                return   -- keep skipping in the next feed
            end

        else -- "text"
            local lt = buf:find("<", pos, true)
            if not lt then
                -- Whole rest is text; hold back a possibly-split entity.
                local hold = nil
                for i = len, math.max(pos, len - 11), -1 do
                    local c = buf:sub(i, i)
                    if c == "&" then hold = i break
                    elseif c == ";" then break end
                end
                if hold then
                    emit_text(self, buf:sub(pos, hold - 1))
                    self.pending = buf:sub(hold)
                else
                    emit_text(self, buf:sub(pos))
                end
                return
            end
            if lt > pos then emit_text(self, buf:sub(pos, lt - 1)) end
            local nc = buf:sub(lt + 1, lt + 1)
            if nc == "" then
                self.pending = "<"
                return
            elseif nc == "!" then
                local four = buf:sub(lt, lt + 3)
                if four == "<!--" then
                    self.mode = "comment"
                    pos = lt + 4
                elseif #four < 4 and ("<!--"):sub(1, #four) == four then
                    self.pending = buf:sub(lt)
                    return
                else
                    self.mode = "skip_gt"
                    pos = lt + 2
                end
            elseif nc == "?" then
                self.mode = "skip_gt"
                pos = lt + 2
            elseif nc == "/" or nc:match("%a") then
                local gt = buf:find(">", lt + 1, true)
                if not gt then
                    if len - lt > TAG_MAX then
                        emit_text(self, "<")
                        pos = lt + 1
                    else
                        self.pending = buf:sub(lt)
                        return
                    end
                else
                    self:handle_tag(buf:sub(lt + 1, gt - 1))
                    pos = gt + 1
                end
            else
                emit_text(self, "<")
                pos = lt + 1
            end
        end
    end
end

function P:finish()
    if self.mode == "title" and self.title_buf then
        self.title = decode_entities(self.title_buf)
            :gsub("[ \t\r\n]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    end
    if self.mode == "tacapture" and self.ta_field then
        self.ta_field.value = decode_entities(
            table.concat(self.ta_buf)):gsub("^\r?\n", "")
        self.ta_field = nil
        self.ta_buf = nil
    end
    finish_button(self)
    finish_option(self)
    self:flush()
    return {
        title = self.title,
        base = self.base,
        links = self.links,
        images = self.images,
        blocks = self.blocks,
        forms = self.forms,
        anchors = self.anchor_map,
        refresh = self.refresh,
        truncated = self.truncated,
    }
end

-- A page structure for a text/plain body: blank-line-separated paragraphs
-- rendered as pre blocks (whitespace preserved, no wrap surprises). A
-- paragraph beyond the pre budget is sliced — a blank-line-free file must
-- not become one unbounded label.
function M.plain_page(text)
    local blocks = {}
    local function add(para)
        if para == "" or #blocks >= BLOCK_MAX then return end
        blocks[#blocks + 1] = {
            kind = "pre", indent = 0, quote = false,
            runs = { { text = para } },
        }
    end
    -- Loop variables are const in Lua 5.5 — work on a local copy.
    for raw_para in (text .. "\n\n"):gmatch("(.-)\n%s*\n") do
        local para = raw_para:gsub("%s+$", "")
        while #para > PRE_CHARS_MAX do
            add(para:sub(1, PRE_CHARS_MAX))
            para = para:sub(PRE_CHARS_MAX + 1)
        end
        add(para)
    end
    return { blocks = blocks, links = {}, images = {}, forms = {},
             anchors = {}, title = nil, base = nil }
end

return M
