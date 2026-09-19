--[[
  Web — reader-class browser.

  Fetch: Web/http.lua — raw HTTP/1.1 over _tcp_open, TLS verify="ca",
  GET + form POST, session cookies, gzip (when the firmware has
  _inflate), redirects followed, 512KB body cap. Parse: Web/html.lua —
  streaming tokenizer -> flat block list + forms + fragment anchors.
  Render: one Spangroup per text block (luavgl Spangroup binding, FW_API
  14), STREAMED — blocks appear while the body still downloads. Forms
  render as real widgets (text/textarea/checkbox/radio/select/submit;
  Enter in a text field submits). Fragment links jump to their block.
  Tapping an [image] fetches it (async, 1.5MB cap) into the shared
  fit/pan viewer; tap dismisses. The bar's Menu button opens a popup holding
  find-in-page, the history and bookmark lists, reader mode (the r key still
  reaches it directly) and clearing the cookie jar. f or / finds in the page
  (match block flashes). pre/code use UNSCII mono when compiled in.

  Known simplifications: back to a POST result re-GETs; password fields
  render unmasked; select shows its preselected option first; cookies
  are session-only and attribute-blind. No JS, no CSS layout — that
  ceiling is the litehtml module path in the spec.

  Chrome: a 16px status strip stays visible; the control bar (full-width
  URL/search field over two rows of large buttons) is a summonable overlay —
  m key, a tap on the status strip, or its own v button dismisses it, and
  any navigation closes it. The bar is its own nav scope (nav.push/pop),
  which is what makes its buttons trackball-reachable as direct children.

  Input model:
    URL bar       omnibox: URL-shaped input navigates, anything else is
                  searched on the chosen engine (home view cycles it)
    m / status    open the bar (m) / toggle it (tap the status strip)
    arrows        gridnav SCROLL_FIRST scrolls the page (content is the
                  focused scrollable)
    n / space, p  cycle link focus forward / back
    Enter         open the focused link (on content) / go (in the URL bar)
    q, Backspace  back — a per-session stack, home is an entry
    b / Book      toggle bookmark     h / H: home     Home/End: jump
    touch         tap a link block (one link opens it, several open a
                  chooser); textareas raise the OSK on touch boards

  Persistence (L:/browser/): bookmarks and a Recent visited list (both
  shown on the home view as link lines), settings (search engine). The
  back/forward stack is per-session and not persisted.

  Italic renders as plain text (no italic face); bold renders as the
  theme highlight color.
]]

local app_dir = ...

local lvgl = require("lvgl")
local apps = require("lib/apps")
local nav = require("lib/nav")
local theme = require("lib/theme")
local wifi = require("lib/wifi")
local fileman = require("lib/fileman")
local imgview = require("lib/imgview")

-- Sibling chunks, Map-style: strip the drive prefix for loadfile, and the
-- extra parens truncate gsub's count return.
local http = assert(loadfile(((app_dir .. "/http.lua"):gsub("^[Ll]:", ""))))()
local html = assert(loadfile(((app_dir .. "/html.lua"):gsub("^[Ll]:", ""))))()

local W, H = lvgl.HOR_RES(), lvgl.VER_RES()
local pal = theme.palette()

local CPAD = 6                      -- content padding
local STATUS_H = 16                 -- permanent status strip height
local STACK_MAX = 50                -- session back/forward entries
local RECENT_MAX = 50               -- persisted visited list
local RECENT_SHOW = 8               -- newest entries listed on home
local CHOOSE_MAX = 50               -- buttons in a pick-one popup; covers a
                                    -- full RECENT_MAX history list
local TOUCH_H = 40                  -- every chrome button and popup row:
                                    -- finger-sized beats fitting more on
                                    -- screen, and popups scroll
local BODY_MAX = 512 * 1024
local DATA_DIR = "L:/browser"       -- bookmarks / history / settings

local ENGINES = {
    -- html.duckduckgo.com is the no-JS endpoint and serves us fine; the
    -- lite.duckduckgo.com one 403s non-browser clients.
    { id = "ddg", name = "DuckDuckGo",
      q = "https://html.duckduckgo.com/html/?q=" },
    { id = "marginalia", name = "Marginalia",
      q = "https://marginalia-search.com/search?query=" },
    { id = "wiby", name = "Wiby", q = "https://wiby.me/?q=" },
    { id = "frogfind", name = "FrogFind", q = "http://frogfind.com/?q=" },
}

-- Theme "text"-role faces for headings; nil = default font (documented
-- theme pattern: pcall, a theme without TTF keeps the built-in face).
local function role_font(size)
    local ok, f = pcall(lvgl.Font, "text", size)
    if ok then return f end
    return nil
end
local HFONT = { h1 = role_font(22), h2 = role_font(19), h3 = role_font(17) }
local HCOLOR = { h4 = true, h5 = true, h6 = true }

-- Monospace for pre/code when the firmware compiles UNSCII in.
local MONO = (function()
    local ok, f = pcall(lvgl.Font, "unscii", 16)
    if ok then return f end
    return nil
end)()

local function trim_text(s, n)
    local ok, pos = pcall(utf8.offset, s, n + 1)
    if ok and pos and pos <= #s then return s:sub(1, pos - 1) .. "…" end
    return s
end

-- ── App state ───────────────────────────────────────────────────────────────

local req = nil            -- active http request
local pending_nav = nil    -- navigation parked on WiFi coming up
local parser = nil
local plain_buf = nil      -- text/plain accumulation
local latin1 = false
local loading_via_history = false
local current_final = nil  -- final URL of the loaded/loading page
local page_effbase = nil   -- <base href>-adjusted resolution base
local stack, stack_pos = { "home" }, 1  -- session back/forward; "home" = home view
local recent = {}          -- persisted visited pages {url, title|nil}, oldest first
local links_ui = {}        -- render-order entries {sg, spans, text, href|img|action}
local cur_link = 0
local page_holder = nil
local build_job = nil      -- page build {page, holder, i, open, info}
local page_ctx = nil       -- {page, widgets = {block-idx -> widget}, anchor_pending}
local feed_q = nil         -- oversized body chunk paced into the parser
local done_info = nil      -- on_done info parked while feed_q drains
local after_anchor = nil   -- fragment to jump to once the next page renders
local find_state = nil     -- in-page find {q, at}
local img_req = nil        -- in-flight image fetch
local img_file = nil
local refresh_hops = 0     -- meta-refresh chain counter
local resp_retry_after = nil  -- Retry-After of the page being loaded
local bookmarks = {}       -- array of {url, title|nil}, home-view order
local engine_idx = 1       -- index into ENGINES
local current_title = nil  -- title of the loaded page (bookmark label)

-- Forward decls (used from handlers defined above their assignment)
local navigate, follow, activate, cycle_engine, view_image, jump_anchor

-- ── Persistence (plain line files under L:/browser) ─────────────────────────
-- settings:  "engine=<id>"
-- bookmarks and history: "url<TAB>title" per line (title may be empty;
-- history = the Recent visited list, oldest first)

local function sanitize_line(s)
    return (tostring(s or ""):gsub("%c", " "))
end

local function load_store()
    fileman.mkdir(DATA_DIR)
    local s = fileman.read(DATA_DIR .. "/settings")
    if s then
        local id = s:match("engine=([%w_-]+)")
        for i, e in ipairs(ENGINES) do
            if e.id == id then engine_idx = i end
        end
    end
    local h = fileman.read(DATA_DIR .. "/history")
    if h then
        for line in h:gmatch("([^\n]+)") do
            local url, title = line:match("^([^\t]+)\t?(.*)$")
            if url then
                recent[#recent + 1] =
                    { url = url, title = title ~= "" and title or nil }
            end
        end
        -- Oldest entries drop first if the file ever exceeds the cap.
        while #recent > RECENT_MAX do table.remove(recent, 1) end
    end
    local b = fileman.read(DATA_DIR .. "/bookmarks")
    if b then
        for line in b:gmatch("([^\n]+)") do
            local url, title = line:match("^([^\t]+)\t?(.*)$")
            if url then
                bookmarks[#bookmarks + 1] =
                    { url = url, title = title ~= "" and title or nil }
            end
        end
    end
end

local function save_settings()
    fileman.write(DATA_DIR .. "/settings",
        "engine=" .. ENGINES[engine_idx].id .. "\n")
end

local function save_recent()
    local out = {}
    for _, r in ipairs(recent) do
        out[#out + 1] = sanitize_line(r.url) .. "\t"
            .. sanitize_line(r.title or "")
    end
    fileman.write(DATA_DIR .. "/history", table.concat(out, "\n") .. "\n")
end

local function save_bookmarks()
    local out = {}
    for _, bm in ipairs(bookmarks) do
        out[#out + 1] = sanitize_line(bm.url) .. "\t"
            .. sanitize_line(bm.title or "")
    end
    fileman.write(DATA_DIR .. "/bookmarks", table.concat(out, "\n") .. "\n")
end

local function bookmark_index(url)
    for i, bm in ipairs(bookmarks) do
        if bm.url == url then return i end
    end
    return nil
end

-- ── Chrome ──────────────────────────────────────────────────────────────────
-- Absolute layout: a permanent 16px status strip on top, the content
-- underneath at full remaining height, and the control bar as a HIDDEN
-- overlay at the strip's lower edge (created after content, so it draws
-- above it). Base nav scope = root, whose only focusable direct child is
-- content (the status strip is clickable but not CLICK_FOCUSABLE, so
-- gridnav skips it — focusable needs both flags). The bar is a separate
-- nav scope pushed while visible; its widgets are the bar's DIRECT
-- children (flex row wrap: the full-width field forms row one, the
-- buttons row two), which is what gridnav's direct-children rule needs.

local root = apps.new_root {
    w = W, h = H, bg_color = pal.scr,
    border_width = 0, radius = 0,
    pad_all = 0, pad_row = 0, pad_column = 0,
}
root:clear_flag(lvgl.FLAG.SCROLLABLE)

local status_obj = root:Object {
    x = 0, y = 0, w = W, h = STATUS_H,
    bg_color = pal.card, bg_opa = 255, border_width = 0, radius = 0,
    pad_all = 0,
}
status_obj:clear_flag(lvgl.FLAG.CLICK_FOCUSABLE)
status_obj:clear_flag(lvgl.FLAG.SCROLLABLE)
local status_lb = status_obj:Label {
    text = "", w = lvgl.PCT(100), align = lvgl.ALIGN.LEFT_MID,
    pad_left = 4, text_color = pal.grey,
}

local CONTENT_H = H - STATUS_H
local CONTENT_W = W - 2 * CPAD       -- content padding

local content = root:Object {
    x = 0, y = STATUS_H, w = W, h = CONTENT_H,
    bg_opa = 0, border_width = 0, radius = 0,
    pad_all = CPAD, pad_row = 0, pad_column = 0,
}
content:add_flag(lvgl.FLAG.CLICK_FOCUSABLE)

local bar = root:Object {
    x = 0, y = STATUS_H, w = W, h = lvgl.SIZE_CONTENT,
    bg_color = pal.card, bg_opa = 255,
    border_width = 1, border_color = pal.grey, radius = 0,
    pad_all = 4, pad_row = 3, pad_column = 3,
    flex = { flex_direction = "row", flex_wrap = "wrap" },
}

local url_ta = bar:Textarea { one_line = true, text = "", w = lvgl.PCT(100), h = 32 }

local function bar_button(txt, w)
    local b = bar:Button { w = w, h = TOUCH_H }
    local lb = b:Label { text = txt, align = lvgl.ALIGN.CENTER }
    return b, lb
end

-- Eight buttons in two rows, five then three. The bar's usable width is its
-- own width minus pad_all on both sides AND its 1px border on both sides;
-- each row's buttons plus its pad_column gaps must fit inside THAT, or flex
-- wraps early and a button lands on a row of its own. Find lives in the Menu
-- rather than here; everything a keyboard can do is reachable by touch
-- through these buttons and that menu.
local BAR_INNER = W - 2 * 4 - 2
local BTN_W = (BAR_INNER - 4 * 3) // 5    -- five across row one
local BTN_W2 = (BAR_INNER - 2 * 3) // 3   -- three across row two
local back_b = bar_button("<", BTN_W)
local fwd_b = bar_button(">", BTN_W)
local go_b, go_lb = bar_button("Go", BTN_W)
local home_b = bar_button("H", BTN_W)
local hide_b = bar_button("v", BTN_W)
local star_b = bar_button("Book", BTN_W2)
local menu_b = bar_button("Menu", BTN_W2)
local quit_b = bar_button("x", BTN_W2)

bar:add_flag(lvgl.FLAG.HIDDEN)

-- In-page find: its own summonable strip (/, or f, opens it).
local findbar = root:Object {
    x = 0, y = STATUS_H, w = W, h = lvgl.SIZE_CONTENT,
    bg_color = pal.card, bg_opa = 255,
    border_width = 1, border_color = pal.grey, radius = 0,
    pad_all = 4, pad_row = 3, pad_column = 3,
    flex = { flex_direction = "row", flex_wrap = "wrap" },
}
local find_ta = findbar:Textarea { one_line = true, text = "", w = lvgl.PCT(100), h = 32 }
local fnext_b = findbar:Button { w = 150, h = TOUCH_H }
fnext_b:Label { text = "Next", align = lvgl.ALIGN.CENTER }
local fclose_b = findbar:Button { w = 150, h = TOUCH_H }
fclose_b:Label { text = "Close", align = lvgl.ALIGN.CENTER }
findbar:add_flag(lvgl.FLAG.HIDDEN)

local function status(msg, is_err)
    status_lb:set { text = msg, text_color = is_err and "#ff5555" or pal.grey }
end

-- Show/hide keep the nav stack balanced: each strip's scope is pushed
-- exactly while it is visible, pop comes BEFORE hiding (same ordering
-- rule as pop-before-delete for popups), and only one strip is up at a
-- time.
local bar_visible = false
local find_visible = false

local function hide_find()
    if not find_visible then return end
    find_visible = false
    nav.pop()
    findbar:add_flag(lvgl.FLAG.HIDDEN)
end

local function hide_bar()
    if not bar_visible then return end
    bar_visible = false
    nav.pop()
    bar:add_flag(lvgl.FLAG.HIDDEN)
end

local function show_bar()
    if bar_visible then return end
    hide_find()
    bar_visible = true
    bar:clear_flag(lvgl.FLAG.HIDDEN)
    nav.push(bar, { flags = nav.ROLLOVER, focus = url_ta })
end

local function show_find()
    if find_visible then return end
    hide_bar()
    find_visible = true
    findbar:clear_flag(lvgl.FLAG.HIDDEN)
    nav.push(findbar, { flags = nav.ROLLOVER, focus = find_ta })
end

local function toggle_bar()
    if bar_visible then hide_bar() else show_bar() end
end

-- ── Page holder lifecycle ───────────────────────────────────────────────────

-- nav.replace first moves gridnav's focus references off the outgoing
-- subtree, then apps.delete_view drains it watchdog-safely (a big page torn
-- down in one synchronous :delete() can starve Core 0 past the task
-- watchdog — see lib/apps).
local function new_holder()
    local old = page_holder
    links_ui = {}
    cur_link = 0
    build_job = nil
    page_ctx = nil
    find_state = nil
    if old then
        nav.replace(root, { flags = nav.ROLLOVER + nav.SCROLL_FIRST })
        apps.delete_view(old)
    end
    page_holder = content:Object {
        w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        bg_opa = 0, border_width = 0, radius = 0,
        pad_all = 0, pad_row = 6, pad_column = 0,
        flex = { flex_direction = "column" },
    }
    page_holder:clear_flag(lvgl.FLAG.CLICKABLE)
    content:scroll_to { x = 0, y = 0, anim = false }
    return page_holder
end

-- ── Link focus ──────────────────────────────────────────────────────────────

local function set_link_style(entry, color)
    for _, si in ipairs(entry.spans) do
        entry.sg:set_span(si, { text_color = color, underline = true })
    end
end

local function cycle_link(d)
    if #links_ui == 0 then return end
    if cur_link >= 1 and links_ui[cur_link] then
        set_link_style(links_ui[cur_link], pal.accent_text)
    end
    cur_link = cur_link + d
    if cur_link < 1 then cur_link = #links_ui end
    if cur_link > #links_ui then cur_link = 1 end
    local entry = links_ui[cur_link]
    set_link_style(entry, pal.highlight)
    entry.sg:scroll_to_view_recursive(1)
end

-- A bounded, scrollable pick-one popup. Entries are links_ui-shaped
-- ({ text, href | img | action }), so the same list serves a block's links
-- and the bookmark list; `noun` only names them in the overflow note.
local function choose_link(items, noun)
    local ov = root:Object {
        w = W, h = H, bg_color = "#000000", bg_opa = 140,
        border_width = 0, radius = 0, pad_all = 0,
    }
    ov:add_flag(lvgl.FLAG.CLICKABLE)
    -- max_height keeps the box on screen however many links the block
    -- holds; the rest scrolls (SCROLLABLE is the Object default).
    local box = ov:Object {
        w = 280, h = lvgl.SIZE_CONTENT, max_height = H - 36,
        align = lvgl.ALIGN.CENTER,
        bg_color = pal.card, radius = 6, pad_all = 6, pad_row = 4,
        flex = { flex_direction = "column" },
    }
    box:add_flag(lvgl.FLAG.CLICKABLE)   -- swallow taps: only the dim
                                        -- margin outside dismisses
    local function close()
        nav.pop()
        ov:delete()
    end
    local shown = math.min(#items, CHOOSE_MAX)
    for i = 1, shown do
        local it = items[i]
        local b = box:Button { w = lvgl.PCT(100), h = TOUCH_H }
        b:Label { text = trim_text(it.text, 30) }
        b:onClicked(function()
            close()
            activate(it)
        end)
    end
    if #items > shown then
        box:Label { text = ("+%d more %s not shown")
            :format(#items - shown, noun or "links"), text_color = pal.grey }
    end
    local c = box:Button { w = lvgl.PCT(100), h = TOUCH_H }
    c:Label { text = "Cancel", align = lvgl.ALIGN.CENTER }
    c:onClicked(close)
    ov:onClicked(close)
    nav.push(box, {})
end

-- ── Renderer ────────────────────────────────────────────────────────────────

local function add_rule(holder)
    local r = holder:Object {
        w = lvgl.PCT(100), h = 2, bg_color = pal.grey, bg_opa = 140,
        border_width = 0, radius = 0, pad_all = 0,
    }
    r:clear_flag(lvgl.FLAG.CLICKABLE)
    return r
end

local function add_pre_block(holder, blk)
    local parts = {}
    for _, r in ipairs(blk.runs) do parts[#parts + 1] = r.text end
    local box = holder:Object {
        w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        bg_color = pal.card, bg_opa = 255, border_width = 0, radius = 4,
        pad_all = 4, pad_row = 0, pad_column = 0,
    }
    local lb = box:Label {
        text = table.concat(parts):gsub("\t", "    "),
        w = lvgl.SIZE_CONTENT, text_color = pal.text,
    }
    if MONO then lb:set { text_font = MONO } end
    return box
end

local function add_text_block(holder, blk, page)
    local parent = holder
    local indent = (blk.indent or 0) * 12 + (blk.quote and 10 or 0)
    local wrap_w = CONTENT_W
    local heading = HFONT[blk.kind] ~= nil or HCOLOR[blk.kind] ~= nil
    if blk.quote then
        -- Quotes read as a card, not as dimmed text.
        indent = math.min(indent, CONTENT_W // 2)
        parent = holder:Object {
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
            bg_color = pal.card, bg_opa = 255, border_width = 0, radius = 4,
            pad_all = 6, pad_row = 0, pad_column = 0, pad_left = 6 + indent,
        }
        parent:clear_flag(lvgl.FLAG.CLICK_FOCUSABLE)
        wrap_w = CONTENT_W - indent - 12
    elseif indent > 0 then
        indent = math.min(indent, CONTENT_W // 2)
        parent = holder:Object {
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
            bg_opa = 0, border_width = 0, radius = 0,
            pad_all = 0, pad_row = 0, pad_column = 0, pad_left = indent,
        }
        parent:clear_flag(lvgl.FLAG.CLICKABLE)
        wrap_w = CONTENT_W - indent
    end

    local sg = parent:Spangroup {
        w = wrap_w, h = lvgl.SIZE_CONTENT,
        pad_top = heading and 8 or 0,
    }
    sg:set_mode("break")

    local blk_list = {}
    -- Keyed by HREF, not by link index: a result whose title and URL are
    -- two <a> tags with the same target is one destination, so tapping it
    -- opens the page instead of asking which copy you meant.
    local by_href = {}
    for _, r in ipairs(blk.runs) do
        if r.text ~= "" then
            local st = {}
            if HFONT[blk.kind] then st.text_font = HFONT[blk.kind] end
            if r.strike then st.strike = true end
            -- Image before link: wiki thumbnails sit inside a link to their
            -- File: page, and someone tapping "[image: …]" wants the image.
            if r.img then
                st.text_color = pal.accent_text
            elseif r.link then
                st.text_color = pal.accent_text
                st.underline = true
            elseif r.uline then
                st.underline = true
                st.text_color = pal.text
            elseif r.bold or blk.th or HCOLOR[blk.kind] then
                st.text_color = pal.highlight
            elseif r.code then
                if MONO then
                    st.text_font = MONO
                    st.text_color = pal.text
                else
                    st.text_color = pal.grey
                end
            end
            if next(st) == nil then st = nil end
            local idx = sg:add_span(r.text, st)
            local entry
            if r.img then
                entry = { sg = sg, spans = { idx }, text = r.text,
                          img = page.images[r.img] }
                blk_list[#blk_list + 1] = entry
                links_ui[#links_ui + 1] = entry
            elseif r.link then
                local href = page.links[r.link]
                entry = by_href[href]
                if not entry then
                    entry = { sg = sg, spans = {}, text = r.text, href = href }
                    by_href[href] = entry
                    blk_list[#blk_list + 1] = entry
                    links_ui[#links_ui + 1] = entry
                end
                entry.spans[#entry.spans + 1] = idx
            end
        end
    end

    if #blk_list > 0 then
        sg:add_flag(lvgl.FLAG.CLICKABLE)
        nav.tap(sg, function()
            if #blk_list == 1 then
                activate(blk_list[1])
            else
                choose_link(blk_list)
            end
        end)
    else
        sg:clear_flag(lvgl.FLAG.CLICKABLE)
    end
    return parent == holder and sg or parent
end

-- ── Forms ───────────────────────────────────────────────────────────────────

local function submit_form(page, form_idx, clicked)
    local form = page.forms[form_idx]
    if not form then return end
    local parts = {}
    local function put(name, value)
        parts[#parts + 1] = http.urlencode(name) .. "="
            .. http.urlencode(value or "")
    end
    for _, f in ipairs(form.fields) do
        local n = f.name
        if n and n ~= "" then
            if f.kind == "hidden" then
                put(n, f.value)
            elseif f.kind == "text" or f.kind == "textarea" then
                put(n, f.widget and f.widget:get("text") or f.value)
            elseif f.kind == "checkbox" or f.kind == "radio" then
                if f.checked then put(n, f.value) end
            elseif f.kind == "select" then
                local sel = f.widget and f.widget:get("selected_str")
                local v = sel and f.value_of and f.value_of[sel]
                put(n, v or sel)
            elseif f.kind == "submit" then
                if f == clicked then put(n, f.value) end
            end
        end
    end
    local body = table.concat(parts, "&")
    local base = page_effbase or current_final or ""
    local url
    if form.action and form.action ~= "" then
        url = http.resolve(base, (form.action:gsub("#.*$", "")))
    else
        url = current_final
    end
    if not url then
        status("Bad form action", true)
        return
    end
    if form.method == "post" then
        navigate(url, false, body)
    else
        url = (url:gsub("%?.*$", ""))
        navigate(body ~= "" and (url .. "?" .. body) or url)
    end
end

local function add_field_block(holder, blk, page)
    local form = page.forms[blk.form]
    local f = form and form.fields[blk.field]
    if not f then
        return holder:Object { w = 1, h = 1, bg_opa = 0, border_width = 0 }
    end
    if f.kind == "text" then
        local ta = holder:Textarea {
            one_line = true, text = f.value or "", w = lvgl.PCT(100), h = 32,
        }
        f.widget = ta
        ta:onevent(lvgl.EVENT.KEY, function()
            if lvgl.indev.get_act():get_key() == lvgl.KEY.ENTER then
                submit_form(page, blk.form, nil)
            end
        end)
        return ta
    elseif f.kind == "textarea" then
        local ta = holder:Textarea {
            text = f.value or "", w = lvgl.PCT(100), h = 80,
        }
        f.widget = ta
        return ta
    elseif f.kind == "checkbox" or f.kind == "radio" then
        local cb = holder:Checkbox {}
        cb:set { text = f.kind == "radio" and "( )" or "" }
        if f.checked then cb:add_state(lvgl.STATE.CHECKED) end
        f.widget = cb
        cb:onClicked(function()
            if f.kind == "radio" then
                for _, f2 in ipairs(form.fields) do
                    if f2 ~= f and f2.kind == "radio" and f2.name == f.name then
                        f2.checked = false
                        if f2.widget then
                            f2.widget:clear_state(lvgl.STATE.CHECKED)
                        end
                    end
                end
                f.checked = true
                cb:add_state(lvgl.STATE.CHECKED)
            else
                f.checked = not f.checked
            end
        end)
        return cb
    elseif f.kind == "select" then
        local dd = holder:Dropdown { w = 200, h = 34 }
        dd:clear_option()
        -- Selected option first: the dropdown shows index 0, so an
        -- untouched submit sends the page's own preselection.
        f.value_of = {}
        local ordered = {}
        for _, o in ipairs(f.options) do
            if o.selected then ordered[#ordered + 1] = o end
        end
        for _, o in ipairs(f.options) do
            if not o.selected then ordered[#ordered + 1] = o end
        end
        for _, o in ipairs(ordered) do
            local tl = trim_text(o.label or o.value or "", 26)
            dd:add_option(tl, 65535)
            if f.value_of[tl] == nil then f.value_of[tl] = o.value end
        end
        f.widget = dd
        return dd
    elseif f.kind == "submit" then
        local b = holder:Button { h = 34, w = lvgl.SIZE_CONTENT }
        b:Label { text = trim_text(f.label or "Submit", 24) }
        b:onClicked(function() submit_form(page, blk.form, f) end)
        return b
    end
    return holder:Object { w = 1, h = 1, bg_opa = 0, border_width = 0 }
end

-- Pages build in bounded batches across timer ticks, never in one
-- callback: one lv_timer_handler pass runs the build AND the layout
-- measure of every new spangroup AND the redraw before loop() feeds the
-- task watchdog — a full-page build in one shot can starve it past 5s,
-- stacked on the outgoing page's delete_view drain.
local BUILD_BATCH = 12

-- A pending fragment jump lands as soon as its block's widget exists.
local function try_anchor_scroll()
    local ctx = page_ctx
    if not ctx or not ctx.anchor_pending then return end
    local bi = ctx.page.anchors and ctx.page.anchors[ctx.anchor_pending]
    if bi and ctx.widgets[bi] then
        ctx.widgets[bi]:scroll_to_view_recursive(1)
        ctx.anchor_pending = nil
    end
end

local function build_step()
    local job = build_job
    if not job then return end
    local page, holder = job.page, job.holder
    local n = 0
    while job.i <= #page.blocks and n < BUILD_BATCH do
        local blk = page.blocks[job.i]
        local w
        if blk.kind == "rule" then
            w = add_rule(holder)
        elseif blk.kind == "pre" then
            w = add_pre_block(holder, blk)
        elseif blk.kind == "field" then
            w = add_field_block(holder, blk, page)
        else
            w = add_text_block(holder, blk, page)
        end
        if page_ctx then page_ctx.widgets[job.i] = w end
        job.i = job.i + 1
        n = n + 1
    end
    try_anchor_scroll()
    -- Finalize only once the document is complete (streaming keeps the
    -- job open while the body still downloads).
    if job.i > #page.blocks and not job.open then
        if #page.blocks == 0 then
            holder:Label { text = "(empty page)", text_color = pal.grey }
        end
        if page.truncated or (job.info and job.info.truncated) then
            holder:Label { text = "[page truncated]", text_color = pal.grey }
        end
        if page_ctx and page_ctx.anchor_pending then
            page_ctx.anchor_pending = nil
        end
        build_job = nil
    end
end

-- Non-streamed render (the home view's plain pages and text/plain).
local function render_page(page, info)
    local holder = new_holder()
    page_ctx = { page = page, widgets = {} }
    build_job = { page = page, info = info, holder = holder, i = 1,
                  open = false }
    build_step()   -- first batch now: the first screenful appears at once
end

-- Streamed render: called once the response headers say text/html. The
-- page table shares the parser's live arrays, so blocks render while the
-- body is still arriving.
local function begin_page_stream()
    local holder = new_holder()
    local live = {
        blocks = parser.blocks, links = parser.links,
        images = parser.images, forms = parser.forms,
        anchors = parser.anchor_map,
    }
    page_ctx = { page = live, widgets = {}, anchor_pending = after_anchor }
    after_anchor = nil
    build_job = { page = live, holder = holder, i = 1, open = true }
end

-- ── Home view + omnibox ─────────────────────────────────────────────────────
-- The URL bar doubles as search: input that doesn't look like a URL is
-- searched on the selected engine. The home view holds no gridnav widgets
-- (nested ones are unreachable — direct-children rule); its interactive
-- lines (engine change, bookmarks) are links_ui entries, driven by the
-- same tap / n-p / Enter machinery as page links.

local function looks_like_url(s)
    if s:find("://", 1, true) then return true end
    local host = s:match("^([^/%s]+)")
    if not host then return false end
    host = host:gsub(":%d+$", "")
    if host:match("^%d+%.%d+%.%d+%.%d+$") then return true end
    return host:match("%.%a%a+$") ~= nil
end

local function go_input(s)
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return end
    if looks_like_url(s) then
        navigate(s)
    else
        navigate(ENGINES[engine_idx].q .. http.urlencode(s))
    end
end

local function toggle_bookmark()
    if not current_final then
        status("Load a page to bookmark it")
        return
    end
    local i = bookmark_index(current_final)
    if i then
        table.remove(bookmarks, i)
        save_bookmarks()
        status("Bookmark removed")
    else
        bookmarks[#bookmarks + 1] = { url = current_final,
                                      title = current_title }
        save_bookmarks()
        status("Bookmarked")
    end
end

-- A home-view link line: one spangroup whose whole text is the tappable /
-- cyclable entry (rides the same links_ui machinery as page links).
local function home_entry(holder, label, style, entry)
    local sg = holder:Spangroup { w = CONTENT_W, h = lvgl.SIZE_CONTENT }
    sg:set_mode("break")
    local si = sg:add_span(label, style)
    entry.sg = sg
    entry.spans = { si }
    entry.text = label
    links_ui[#links_ui + 1] = entry
    sg:add_flag(lvgl.FLAG.CLICKABLE)
    nav.tap(sg, function() activate(entry) end)
    return sg
end

local function build_home()
    local holder = new_holder()
    holder:Label {
        text = "Meshpunk Web", text_color = pal.highlight,
        text_font = HFONT.h1,
    }

    -- Engine line: "Search: <name>  (change)" — the whole line cycles it.
    local eng = holder:Spangroup { w = CONTENT_W, h = lvgl.SIZE_CONTENT }
    eng:set_mode("break")
    eng:add_span("Search: ")
    eng:add_span(ENGINES[engine_idx].name, { text_color = pal.highlight })
    local ci = eng:add_span("  (change)",
        { text_color = pal.accent_text, underline = true })
    local eng_entry = { sg = eng, spans = { ci }, text = "change engine",
                        action = function() cycle_engine() end }
    links_ui[#links_ui + 1] = eng_entry
    eng:add_flag(lvgl.FLAG.CLICKABLE)
    nav.tap(eng, function() activate(eng_entry) end)

    if #bookmarks > 0 then
        holder:Label {
            text = "Bookmarks", text_color = pal.highlight,
            text_font = HFONT.h3,
        }
        for _, bm in ipairs(bookmarks) do
            home_entry(holder, bm.title or bm.url,
                { text_color = pal.accent_text, underline = true },
                { href = bm.url })
        end
    end

    if #recent > 0 then
        holder:Label {
            text = "Recent", text_color = pal.highlight,
            text_font = HFONT.h3,
        }
        local shown = 0
        for i = #recent, 1, -1 do
            if shown >= RECENT_SHOW then break end
            local r = recent[i]
            home_entry(holder, r.title or r.url,
                { text_color = pal.accent_text, underline = true },
                { href = r.url })
            shown = shown + 1
        end
    end

    holder:Label {
        text = "Press m (or tap the top strip) for the address bar.\n\n"
            .. "arrows scroll · n/p cycle links · Enter opens\n"
            .. "q or Backspace back · b bookmarks the page\n"
            .. "h home · f find in page · r reader mode\n"
            .. "Tap links to open them, [images] to view them.",
        w = lvgl.PCT(100), text_color = pal.text,
    }
end

-- Render the home view and clear the "where am I" state. No stack change:
-- back/forward land here through a "home" stack entry, and nav_home (the
-- H button / h key) pushes that entry itself.
local function show_home()
    if req then
        req:abort()
        req = nil
        go_lb:set { text = "Go" }
    end
    current_final = nil
    current_title = nil
    url_ta:set { text = "" }
    build_home()
    status("MeshpunkWeb/1.0")
end

cycle_engine = function()
    -- Strips down first: build_home's new_holder does nav.replace on the
    -- BASE scope, which must be the top one (content taps still land
    -- while an overlay strip is open).
    hide_bar()
    hide_find()
    engine_idx = engine_idx % #ENGINES + 1
    save_settings()
    build_home()
end

-- ── Back / forward (session stack) ──────────────────────────────────────────
-- Browser semantics: every navigation (pages AND the home view) pushes an
-- entry and truncates the forward side; back/forward walk the stack. The
-- stack starts as {"home"} and is not persisted — the persisted Recent
-- list on the home view is the cross-session memory.

local function push_entry(entry)
    if stack[stack_pos] == entry then return end
    for i = #stack, stack_pos + 1, -1 do stack[i] = nil end
    stack[stack_pos + 1] = entry
    stack_pos = stack_pos + 1
    while #stack > STACK_MAX do
        table.remove(stack, 1)
        stack_pos = stack_pos - 1
    end
end

local function go_entry(entry)
    hide_bar()
    hide_find()
    if entry == "home" then
        show_home()
    else
        navigate(entry, true)
    end
end

local function go_back()
    if stack_pos > 1 then
        stack_pos = stack_pos - 1
        go_entry(stack[stack_pos])
    end
end

local function go_forward()
    if stack_pos < #stack then
        stack_pos = stack_pos + 1
        go_entry(stack[stack_pos])
    end
end

-- The H button / h key: going home is a navigation like any other.
local function nav_home()
    hide_bar()
    hide_find()
    push_entry("home")
    show_home()
end

-- ── Loading pipeline ────────────────────────────────────────────────────────

local LATIN1 = {}
for b = 128, 255 do LATIN1[string.char(b)] = utf8.char(b) end

local function finalize_page(info)
    local page
    if plain_buf then
        page = html.plain_page(table.concat(plain_buf))
        plain_buf = nil
        render_page(page, info)
    else
        page = parser:finish()
        parser = nil
        -- <meta http-equiv=refresh> acts like a redirect, chain-capped.
        if page.refresh and page.refresh.delay <= 3 and refresh_hops < 3 then
            local effb = current_final
            if page.base then
                local a = http.resolve(current_final, page.base)
                if a then effb = a end
            end
            local target = http.resolve(effb, (page.refresh.url:gsub("#.*$", "")))
            if target and target ~= current_final
                and target:match("^https?://") then
                status("Redirecting…")
                navigate(target, false, nil, true)
                return
            end
        end
        if build_job and build_job.page.blocks == page.blocks then
            -- Streamed: the widgets are already (partly) built; close the
            -- job so the trailer lands after the last batch.
            build_job.open = false
            build_job.info = info
            build_job.page.truncated = page.truncated
        else
            render_page(page, info)
        end
    end
    page_effbase = current_final
    if page.base then
        local abs = http.resolve(current_final, page.base)
        if abs then page_effbase = abs end
    end
    current_title = page.title
    if not loading_via_history then push_entry(current_final) end
    -- Error responses stay in the back/forward trail (browser behavior)
    -- but never enter the Recent list.
    local failed = info.status >= 400
    if not failed then
        -- Recent list: move-to-front (stored oldest-first), then persist.
        for i = #recent, 1, -1 do
            if recent[i].url == current_final then table.remove(recent, i) end
        end
        recent[#recent + 1] = { url = current_final, title = current_title }
        while #recent > RECENT_MAX do table.remove(recent, 1) end
        save_recent()
    end
    local parts = { ("%d · %d KB"):format(info.status, (info.bytes + 1023) // 1024) }
    if info.tls then parts[1] = parts[1] .. " · tls" end
    local wait = failed and tonumber(resp_retry_after or "")
    if wait then parts[#parts + 1] = ("retry in %ds"):format(wait) end
    if page.title then parts[#parts + 1] = trim_text(page.title, 36) end
    status(table.concat(parts, " · "), failed)
    go_lb:set { text = "Go" }
    req = nil
end

navigate = function(url, via_history, post_body, is_refresh)
    hide_bar()
    hide_find()
    if req then
        req:abort()
        req = nil
    end
    if img_req then
        img_req:abort()
        img_req = nil
    end
    url = url:gsub("^%s+", ""):gsub("%s+$", "")
    if url == "" then return end
    if not url:find("://", 1, true) then url = "http://" .. url end
    refresh_hops = is_refresh and (refresh_hops + 1) or 0

    if not wifi.status().connected then
        pcall(_wifi_auto_connect)
        pending_nav = { url = url, via = via_history, post = post_body,
                        waited = 0 }
        status("WiFi down — auto-connecting…", true)
        return
    end

    pending_nav = nil
    loading_via_history = via_history or false
    current_final = url
    current_title = nil
    parser = html.new()
    plain_buf = nil
    latin1 = false
    feed_q = nil
    done_info = nil
    after_anchor = nil   -- follow() re-arms it right after this call
    url_ta:set { text = url }
    status("Connecting…")

    req = http.request {
        url = url,
        method = post_body and "POST" or "GET",
        body = post_body,
        body_max = BODY_MAX,
        on_status = function(txt) status(txt) end,
        on_headers = function(code, headers, final_url)
            current_final = final_url
            resp_retry_after = headers["retry-after"]
            url_ta:set { text = final_url }
            local ct = (headers["content-type"] or "text/html"):lower()
            if ct:find("text/plain", 1, true) then
                plain_buf = {}
                parser = nil
            elseif not (ct:find("text/html", 1, true)
                or ct:find("application/xhtml", 1, true)) then
                req:abort()
                status("Can't display: " .. ct:match("^([^;]*)"), true)
                go_lb:set { text = "Go" }
                req = nil
                return
            end
            local cs = ct:match("charset=([%w%-]+)")
            if cs then
                cs = cs:lower()
                latin1 = cs == "iso-8859-1" or cs == "latin-1"
                    or cs == "latin1" or cs == "windows-1252" or cs == "cp1252"
            end
            if parser then begin_page_stream() end
        end,
        on_body = function(chunk)
            if latin1 then chunk = chunk:gsub("[\128-\255]", LATIN1) end
            if plain_buf then
                plain_buf[#plain_buf + 1] = chunk
            elseif #chunk > 32768 then
                -- One big inflated gzip body: pace it into the parser from
                -- the timer so a single tick never parses megabytes.
                feed_q = { data = chunk, pos = 1 }
            else
                parser:feed(chunk)
            end
        end,
        on_done = function(info)
            if feed_q then done_info = info else finalize_page(info) end
        end,
        on_error = function(msg)
            status("Error: " .. msg, true)
            go_lb:set { text = "Go" }
            req = nil
            parser = nil
            plain_buf = nil
            feed_q = nil
            done_info = nil
            if build_job then build_job.open = false end
        end,
    }
    if req then go_lb:set { text = "X" } end
end

-- Scroll to a fragment target; while a page is still building, the jump
-- parks until its block's widget exists (try_anchor_scroll).
jump_anchor = function(frag)
    local ctx = page_ctx
    if not ctx then return end
    ctx.anchor_pending = frag
    try_anchor_scroll()
    if ctx.anchor_pending and not build_job then
        ctx.anchor_pending = nil
        status("No section \"" .. frag .. "\" here", true)
    end
end

follow = function(href)
    if not href then return end
    local base_part, frag = href:match("^([^#]*)#?(.*)$")
    if base_part == "" then
        if frag ~= "" then jump_anchor(frag) end
        return
    end
    local abs = http.resolve(page_effbase or current_final or "", base_part)
    if not abs then return end
    local scheme = abs:match("^(%a[%w+.-]*)://")
    if not scheme or (scheme ~= "http" and scheme ~= "https") then
        status("Unsupported link type", true)
        return
    end
    if frag ~= "" and abs == current_final then
        jump_anchor(frag)
        return
    end
    navigate(abs)
    -- After navigate's state reset, so the fragment survives to the
    -- stream start of THIS load.
    after_anchor = frag ~= "" and frag or nil
end

-- Fetch an image to a temp file with the page client (async, capped,
-- redirect-following) and open it in the shared fit/pan viewer. Tap
-- dismisses.
view_image = function(src)
    if not src or img_req then return end
    local abs = http.resolve(page_effbase or current_final or "",
        (src:gsub("#.*$", "")))
    if not abs or not abs:match("^https?://") then
        status("Bad image link", true)
        return
    end
    img_file = DATA_DIR .. "/img.tmp"
    local f = io.open(img_file, "w")
    if not f then
        status("Can't open temp file", true)
        return
    end
    status("Fetching image…")
    img_req = http.request {
        url = abs,
        body_max = 1536 * 1024,
        on_status = function(txt) status(txt) end,
        -- The decoder handles PNG, baseline JPEG, GIF (first frame) and
        -- RGB565 .bin (src/img_bridge.cpp). Say so from the Content-Type
        -- instead of downloading the file to fail on it.
        on_headers = function(code, headers)
            local ct = (headers["content-type"] or ""):lower()
            local kind = ct:match("^image/([%w.+-]+)")
            local msg
            if kind then
                if kind ~= "png" and kind ~= "jpeg" and kind ~= "jpg"
                    and kind ~= "gif" then
                    msg = "Can't show " .. kind:upper()
                        .. " images (PNG/JPEG/GIF only)"
                end
            elseif ct ~= "" then
                msg = "Not an image: " .. (ct:match("^([^;]*)") or ct)
            end
            if msg then
                img_req:abort()
                img_req = nil
                f:close()
                fileman.remove(img_file)
                status(msg, true)
            end
        end,
        on_body = function(chunk) f:write(chunk) end,
        on_done = function(info)
            f:close()
            img_req = nil
            if info.truncated then
                fileman.remove(img_file)
                status("Image too large", true)
                return
            end
            local ov = root:Object {
                x = 0, y = 0, w = W, h = H, bg_color = "#000000",
                bg_opa = 255, border_width = 0, radius = 0, pad_all = 0,
            }
            ov:add_flag(lvgl.FLAG.CLICKABLE)
            local v = imgview.new(ov, { w = W, h = H })
            local ok, err = v:load(img_file)
            if not ok then
                v:destroy()
                ov:delete()
                fileman.remove(img_file)
                status("Image: " .. tostring(err), true)
                return
            end
            local closed = false
            local function dismiss()
                if closed then return end
                closed = true
                nav.pop()
                v:destroy()
                ov:delete()
                fileman.remove(img_file)
                status(current_title and trim_text(current_title, 36) or "")
            end
            -- The tap handler belongs to imgview's OWN container: it is
            -- clickable (it owns drag-to-pan) and covers the overlay, so a
            -- handler on the overlay never sees the press. enable_drag runs
            -- on_tap only for a press that did not move, so panning still
            -- works in 1:1 mode.
            v:enable_drag(dismiss)
            v.cont:onevent(lvgl.EVENT.KEY, function()
                local k = lvgl.indev.get_act():get_key()
                if k == lvgl.KEY.ESC or k == lvgl.KEY.ENTER
                    or k == lvgl.KEY.BACKSPACE or k == string.byte("q") then
                    dismiss()
                end
            end)
            status("Tap to close · " .. trim_text(abs, 26))
            nav.push(ov, {})
        end,
        on_error = function(msg)
            f:close()
            img_req = nil
            fileman.remove(img_file)
            status("Image: " .. msg, true)
        end,
    }
end

-- A links_ui entry: page link (href), image (img = raw src), or a
-- home-view action.
activate = function(entry)
    if not entry then return end
    if entry.action then
        entry.action()
    elseif entry.img then
        view_image(entry.img)
    elseif entry.href then
        follow(entry.href)
    end
end

-- ── In-page find ────────────────────────────────────────────────────────────

local function block_text(b)
    local parts = {}
    for _, r in ipairs(b.runs) do parts[#parts + 1] = r.text end
    return table.concat(parts)
end

local function flash_widget(wdg)
    wdg:set { outline_width = 2, outline_color = pal.highlight }
    lvgl.Timer { period = 700, cb = function(t)
        t:delete()
        pcall(function() wdg:set { outline_width = 0 } end)
    end }
end

local function find_next()
    local ctx = page_ctx
    local q = find_ta:get("text"):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if not ctx or q == "" then return end
    local blocks = ctx.page.blocks
    local n = #blocks
    if n == 0 then return end
    if not find_state or find_state.q ~= q then
        find_state = { q = q, at = 0 }
    end
    for k = 1, n do
        local i = (find_state.at + k - 1) % n + 1
        local b = blocks[i]
        if b.runs and #b.runs > 0
            and block_text(b):lower():find(q, 1, true) then
            find_state.at = i
            local wdg = ctx.widgets[i]
            if wdg then
                wdg:scroll_to_view_recursive(1)
                flash_widget(wdg)
            end
            return
        end
    end
    status("Not found: " .. q, true)
end

local function open_reader()
    if current_final then
        navigate("http://frogfind.com/read.php?a="
            .. http.urlencode(current_final))
    else
        status("Load a page first")
    end
end

-- The bar's M button: a home for actions that don't earn a button of their
-- own. Modal over the page, and the bar closes first so the nav stack stays
-- one deep (same push/pop-before-delete rules as the link chooser).
local function open_menu()
    hide_bar()
    local ov = root:Object {
        x = 0, y = 0, w = W, h = H, bg_color = "#000000", bg_opa = 140,
        border_width = 0, radius = 0, pad_all = 0,
    }
    ov:add_flag(lvgl.FLAG.CLICKABLE)
    -- Taller than the screen on purpose: the box scrolls, and finger-sized
    -- rows matter more than seeing every entry at once.
    local box = ov:Object {
        w = 240, h = lvgl.SIZE_CONTENT, max_height = H - 24,
        align = lvgl.ALIGN.CENTER,
        bg_color = pal.card, radius = 6, pad_all = 6, pad_row = 4,
        flex = { flex_direction = "column" },
    }
    box:add_flag(lvgl.FLAG.CLICKABLE)
    local function close()
        nav.pop()
        ov:delete()
    end
    local function item(label, fn)
        local b = box:Button { w = lvgl.PCT(100), h = TOUCH_H }
        b:Label { text = label, align = lvgl.ALIGN.CENTER }
        b:onClicked(function()
            close()
            if fn then fn() end
        end)
    end
    item("Find in page", show_find)
    item("History", function()
        if #recent == 0 then
            status("No history yet")
            return
        end
        -- `recent` is stored oldest-first; the list reads newest-first.
        local list = {}
        for i = #recent, 1, -1 do
            local r = recent[i]
            list[#list + 1] = { text = r.title or r.url, href = r.url }
        end
        choose_link(list, "entries")
    end)
    item("Bookmarks", function()
        if #bookmarks == 0 then
            status("No bookmarks yet — use Book on a page")
            return
        end
        local list = {}
        for _, bm in ipairs(bookmarks) do
            list[#list + 1] = { text = bm.title or bm.url, href = bm.url }
        end
        choose_link(list, "bookmarks")
    end)
    item("Reader mode", open_reader)
    item("Clear cookies", function()
        http.clear_cookies()
        status("Session cookies cleared")
    end)
    item("Clear history", function()
        recent = {}
        save_recent()
        status("History cleared")
        -- The home view lists Recent, so redraw it if that is what's up.
        if not current_final then build_home() end
    end)
    item("Cancel", nil)
    ov:onClicked(close)
    nav.push(box, {})
end

-- ── Wiring ──────────────────────────────────────────────────────────────────

back_b:onClicked(go_back)
fwd_b:onClicked(go_forward)
go_b:onClicked(function()
    if req then
        req:abort()
        req = nil
        status("Stopped")
        go_lb:set { text = "Go" }
    else
        go_input(url_ta:get("text"))
    end
end)
quit_b:onClicked(function() apps.go_home() end)
home_b:onClicked(nav_home)
star_b:onClicked(toggle_bookmark)
hide_b:onClicked(hide_bar)
menu_b:onClicked(open_menu)
fnext_b:onClicked(find_next)
fclose_b:onClicked(hide_find)
nav.tap(status_obj, toggle_bar)

find_ta:onevent(lvgl.EVENT.KEY, function()
    if lvgl.indev.get_act():get_key() == lvgl.KEY.ENTER then
        find_next()
    end
end)

url_ta:onevent(lvgl.EVENT.KEY, function()
    if lvgl.indev.get_act():get_key() == lvgl.KEY.ENTER then
        go_input(url_ta:get("text"))
    end
end)

content:onevent(lvgl.EVENT.KEY, function()
    local k = lvgl.indev.get_act():get_key()
    if k == lvgl.KEY.ENTER then
        activate(links_ui[cur_link])
    elseif k == string.byte("n") or k == string.byte(" ") then
        cycle_link(1)
    elseif k == string.byte("p") then
        cycle_link(-1)
    elseif k == string.byte("q") or k == lvgl.KEY.BACKSPACE then
        go_back()
    elseif k == string.byte("b") then
        toggle_bookmark()
    elseif k == string.byte("h") then
        nav_home()
    elseif k == string.byte("m") then
        show_bar()
    elseif k == string.byte("f") or k == string.byte("/") then
        show_find()
    elseif k == string.byte("r") then
        open_reader()
    elseif k == lvgl.KEY.HOME then
        content:scroll_to { x = 0, y = 0, anim = false }
    elseif k == lvgl.KEY.END then
        content:scroll_to { x = 0, y = 1000000, anim = false }
    end
end)

apps.add_timer { period = 60, cb = function()
    if feed_q and parser then
        local slice = feed_q.data:sub(feed_q.pos, feed_q.pos + 24575)
        parser:feed(slice)
        feed_q.pos = feed_q.pos + 24576
        if feed_q.pos > #feed_q.data then
            feed_q = nil
            if done_info then
                local info = done_info
                done_info = nil
                finalize_page(info)
            end
        end
    end
    if build_job then build_step() end
    if req then req:pump() end
    if img_req then img_req:pump() end
    if pending_nav then
        if wifi.status().connected then
            local p = pending_nav
            pending_nav = nil
            navigate(p.url, p.via, p.post)
        else
            pending_nav.waited = pending_nav.waited + 1
            if pending_nav.waited > 250 then
                pending_nav = nil
                status("WiFi not connected — check Settings", true)
            end
        end
    end
end }

apps.set_on_close(function()
    if req then req:abort() end
    if img_req then img_req:abort() end
    if img_file then fileman.remove(img_file) end
    http.clear_cookies()
end)

load_store()
show_home()
nav.replace(root, { flags = nav.ROLLOVER + nav.SCROLL_FIRST })
show_bar()

return root
