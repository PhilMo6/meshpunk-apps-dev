--[[
  PICO-8 BBS browser screens: sections, a page of carts as a text list, one
  cart with its cart image and details, search. main.lua runs this chunk once
  and passes its launcher helpers, so every view is built by the launcher's
  show_screen and is one nav scope.

  ctx fields:
    bbs            the bbs.lua module
    root           the launcher's app root; the description popup is its child
    show_screen    the launcher's view swap
    heading        the launcher's heading label helper
    font, accent   the launcher's font and accent colour
    find_cart      fn(cart_name) -> path of that cart in the launcher | nil
    on_downloaded  fn(path, cart_name)
    play           fn(path, cart_name)
    on_back        fn(): shows the launcher's main screen
]]

local lvgl = require("lvgl")
local apps = require("lib/apps")
local nav = require("lib/nav")
local wifi = require("lib/wifi")
local fileman = require("lib/fileman")

local ctx = ...
local bbs = ctx.bbs
local FONT = ctx.font
local ACCENT = ctx.accent

local W = lvgl.HOR_RES()
local H = lvgl.VER_RES()
local GREY = "#888888"
local TEXT = "#CCCCCC"
local META = "#C2C3C7"
local BAD = "#FF6666"
local GOOD = "#00E436"
local ROW_BG = "#1D2B53"
local WIFI_WAIT = 300          -- 50ms pump ticks to wait for WiFi: 15s
local CART_W, CART_H = 160, 205
-- show_screen's container is W wide with 8px padding each side, and the
-- theme's flex gap is 8px. The cart screen puts its text beside the cart
-- image when that leaves at least 120px.
local SIDE_W = W - 16 - CART_W - 8
local SIDE_BY_SIDE = SIDE_W >= 120

local V = {}

local gen = 0          -- bumped by every screen; a job queued by an older screen is dropped
local job = nil        -- { gen, fn, wifi, waited }, run by the pump
local pump = nil       -- the job timer while the BBS is open
local page = nil       -- { sec, n, carts }: the page the list and cart screens show
local preview = nil    -- lid of a cart fetched for viewing and not kept
local status = nil     -- status label of the current screen, if it has one
local last_query = ""

local home, open_page, list, detail, search

local function set_status(text, color)
    if status then status:set { text = text, text_color = color or GREY } end
end

-- Deletes the cart fetched for viewing, unless it was kept. The view
-- showing it must already be gone.
local function drop_preview()
    if preview then
        fileman.remove(bbs.preview_path(preview))
        preview = nil
    end
end

-- Swaps in a new view; no job queued by the previous view runs after this.
local function screen(builder)
    gen = gen + 1
    job = nil
    status = nil
    ctx.show_screen(builder)
    drop_preview()
end

local function tick()
    local j = job
    if not j then return end
    if j.gen ~= gen then
        job = nil
        return
    end
    if j.wifi and not wifi.status().connected then
        j.waited = j.waited + 1
        if j.waited > WIFI_WAIT then
            job = nil
            set_status("WiFi did not connect - check Settings > Wifi", BAD)
        end
        return
    end
    job = nil
    j.fn()
end

-- Runs fn on a later pump tick, so status text set just before paints first.
-- needs_wifi: waits for a connection, starting auto-connect when it is down.
local function run(fn, needs_wifi)
    if needs_wifi and not wifi.status().connected then
        if not wifi.isEnabled() then
            set_status("WiFi is off - turn it on in Settings > Wifi", BAD)
            return
        end
        pcall(_wifi_auto_connect)
        set_status("Connecting to WiFi...")
    end
    job = { gen = gen, fn = fn, wifi = needs_wifi, waited = 0 }
end

-- Returns the button and its label.
local function button(parent, text, fn)
    local b = parent:Button { w = lvgl.PCT(48), h = 30 }
    local lb = b:Label { text = text, align = lvgl.ALIGN.CENTER }
    b:onClicked(fn)
    return b, lb
end

local function label(parent, text, color)
    return parent:Label {
        text = text, text_font = FONT, text_color = color or TEXT,
        w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
    }
end

local function clip(s, n)
    if #s <= n then return s end
    return s:sub(1, n - 1) .. ".."
end

local function page_title(sec, n)
    if n == 0 then return sec.label end
    return sec.label .. " - page " .. (n + 1)
end

-- ── Sections ────────────────────────────────────────────────────────────────
home = function()
    page = nil
    screen(function(c)
        ctx.heading(c, "PICO-8 BBS", ACCENT, lvgl.BUILTIN_FONT.MONTSERRAT_22)
        if not bbs.sd_ready() then
            label(c, "Carts from the BBS are saved to the SD card. Insert one to browse.", BAD)
            button(c, "Back", function() V.close() end)
            return
        end
        label(c, "Carts you download are saved to " .. bbs.CARTS, GREY)
        for _, sec in ipairs(bbs.SECTIONS) do
            button(c, sec.label, function() open_page(sec, 0) end)
        end
        button(c, "Search", function() search() end)
        button(c, "Back", function() V.close() end)
    end)
end

-- ── Loading a page ──────────────────────────────────────────────────────────
-- n is 0-based.
open_page = function(sec, n)
    page = nil
    screen(function(c)
        ctx.heading(c, page_title(sec, n), ACCENT)
        status = label(c, "Loading...", GREY)
        button(c, "Retry", function() open_page(sec, n) end)
        button(c, "Sections", function() home() end)
    end)
    run(function()
        local carts, err = bbs.fetch_page(sec, n)
        if not carts then
            set_status(err, BAD)
            return
        end
        page = { sec = sec, n = n, carts = carts }
        list()
    end, true)
end

-- ── A page of carts ─────────────────────────────────────────────────────────
list = function()
    local p = page
    local first_row
    screen(function(c)
        ctx.heading(c, page_title(p.sec, p.n), ACCENT)
        button(c, "Sections", function() home() end)
        if #p.carts == 0 then
            label(c, p.n == 0 and "No carts here." or "No more carts.", GREY)
        end
        for i, cart in ipairs(p.carts) do
            local on_sd = ctx.find_cart(bbs.cart_name(cart.lid)) ~= nil
            local row = c:Button {
                w = lvgl.PCT(100), h = 38, pad_all = 3,
                bg_color = ROW_BG, bg_opa = 255,
            }
            if i == 1 then first_row = row end
            row:Label {
                text = clip(cart.title, 40), text_font = FONT, text_color = "#FFFFFF",
                w = lvgl.PCT(100), h = 15, x = 0, y = 0,
            }
            row:Label {
                text = on_sd and ("on SD card - by " .. clip(cart.author, 20))
                    or ("by " .. clip(cart.author, 24) .. "   " .. cart.date),
                text_font = FONT, text_color = on_sd and GOOD or META,
                w = lvgl.PCT(100), h = 15, x = 0, y = 16,
            }
            row:onClicked(function() detail(i) end)
        end
        if p.n > 0 then
            button(c, "< Prev", function() open_page(p.sec, p.n - 1) end)
        end
        if #p.carts == bbs.PAGE then
            button(c, "Next >", function() open_page(p.sec, p.n + 1) end)
        end
    end)
    -- The first cart takes focus; Sections sits above it.
    if first_row then nav.set_focused(first_row) end
end

-- ── Description popup ───────────────────────────────────────────────────────
-- A full-screen child of the app root, so an app teardown deletes it with
-- the root. Close is the first focusable; the text sits in its own
-- scrollable, focusable box below it.
local function show_info(cart, info)
    local ov = ctx.root:Object {
        w = W, h = H, x = 0, y = 0,
        bg_color = "#000000", bg_opa = 255, border_width = 0, radius = 0,
        pad_all = 8, pad_row = 6,
        flex = { flex_direction = "column" },
    }
    ov:clear_flag(lvgl.FLAG.SCROLLABLE)
    ov:add_flag(lvgl.FLAG.CLICKABLE)   -- modal: swallows taps meant for the view below

    ov:Label {
        text = cart.title, text_font = FONT, text_color = ACCENT,
        w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
    }
    local close = ov:Button { w = lvgl.PCT(48), h = 30 }
    close:Label { text = "Close", align = lvgl.ALIGN.CENTER }

    local meta = {}
    if info.stars then meta[#meta + 1] = info.stars .. " stars" end
    if info.license then meta[#meta + 1] = "License: " .. info.license end
    if #info.tags > 0 then meta[#meta + 1] = "Tags: " .. table.concat(info.tags, ", ") end
    if #meta > 0 then
        ov:Label {
            text = table.concat(meta, "\n"), text_font = FONT, text_color = GREY,
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }
    end

    local body = ov:Object { w = lvgl.PCT(100), flex_grow = 1, pad_all = 6 }
    body:Label {
        text = info.text ~= "" and info.text or "No description on the BBS page.",
        text_color = TEXT, w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
    }

    nav.push(ov, { flags = nav.ROLLOVER + nav.SCROLL_FIRST })
    close:onClicked(function()
        nav.pop()
        ov:delete()
    end)
end

-- ── One cart ────────────────────────────────────────────────────────────────
-- The cart image comes from the launcher's copy when the cart is already
-- listed there; otherwise the cart is fetched to bbs.preview_path, and
-- Download moves that copy into bbs.CARTS. The cart image is the first
-- focusable, so the view opens at the top; Enter or a tap on it does what
-- the first button does.
detail = function(i)
    local cart = page.carts[i]
    local name = bbs.cart_name(cart.lid)
    local saved = ctx.find_cart(name)
    local slot, act_label

    local function show_cart(path)
        slot:clean()
        local img = slot:Image { src = path, align = lvgl.ALIGN.CENTER }
        img:clear_flag(lvgl.FLAG.CLICKABLE)
    end

    local function keep()
        local kept, err = bbs.keep_cart(cart.lid)
        if not kept then
            set_status(err, BAD)
            return
        end
        preview = nil
        ctx.on_downloaded(kept, name)
        show_cart(kept)
        set_status("Saved to " .. kept, GOOD)
        act_label:set { text = "Play" }
    end

    local function fetch(then_keep)
        run(function()
            local path, err = bbs.fetch_cart(cart.lid)
            if not path then
                set_status(err, BAD)
                return
            end
            preview = cart.lid
            show_cart(path)
            set_status("")
            if then_keep then keep() end
        end, true)
    end

    -- Play when the launcher lists the cart, else Download.
    local function act()
        local path = ctx.find_cart(name)
        if path then
            screen(function(s)
                ctx.heading(s, "Starting " .. cart.title .. "...", ACCENT)
            end)
            V.release()
            ctx.play(path, name)
        elseif preview == cart.lid then
            keep()
        else
            if job then return end   -- the cart is still being fetched
            set_status("Downloading...")
            fetch(true)
        end
    end

    -- Fetches the cart's BBS page on request and shows its description.
    local function describe()
        if job then return end
        set_status("Loading description...")
        run(function()
            local info, err = bbs.fetch_info(cart)
            if not info then
                set_status(err, BAD)
                return
            end
            set_status("")
            show_info(cart, info)
        end, true)
    end

    screen(function(c)
        slot = c:Object {
            w = CART_W, h = CART_H, pad_all = 0, border_width = 0, bg_opa = 0,
        }
        slot:clear_flag(lvgl.FLAG.SCROLLABLE)
        slot:onClicked(act)

        -- Title, details and status: one non-focusable panel beside the
        -- cart image, or below it when the screen is too narrow.
        local side = c:Object {
            w = SIDE_BY_SIDE and SIDE_W or lvgl.PCT(100),
            h = SIDE_BY_SIDE and CART_H or lvgl.SIZE_CONTENT,
            pad_all = 0, pad_row = 4, border_width = 0, bg_opa = 0,
            flex = { flex_direction = "column" },
        }
        side:clear_flag(lvgl.FLAG.SCROLLABLE)
        side:clear_flag(lvgl.FLAG.CLICKABLE)
        side:Label {
            text = clip(cart.title, 48), text_font = FONT, text_color = ACCENT,
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }
        local info = "by " .. clip(cart.author, 32) .. "\nUpdated " .. cart.date
        if cart.section then info = info .. "\n" .. cart.section end
        side:Label {
            text = info .. "\n" .. bbs.thread_url(cart.pid),
            text_font = FONT, text_color = TEXT,
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }
        status = side:Label {
            text = "", text_font = FONT, text_color = GREY,
            w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT,
        }

        local _
        _, act_label = button(c, saved and "Play" or "Download", act)
        button(c, "Description", describe)
        button(c, "Back", function() list() end)

        if saved then show_cart(saved) end
    end)

    if not saved then
        set_status("Loading cart...")
        fetch(false)
    end
end

-- ── Search ──────────────────────────────────────────────────────────────────
search = function()
    screen(function(c)
        ctx.heading(c, "SEARCH THE BBS", ACCENT)
        local ta = c:Textarea { one_line = true, text = last_query, w = lvgl.PCT(100), h = 32 }
        local function submit()
            local q = ta:get("text"):gsub("^%s+", ""):gsub("%s+$", "")
            if q == "" then return end
            last_query = q
            open_page(bbs.search_section(q), 0)
        end
        ta:onevent(lvgl.EVENT.KEY, function()
            if lvgl.indev.get_act():get_key() == lvgl.KEY.ENTER then submit() end
        end)
        button(c, "Search", submit)
        button(c, "Sections", function() home() end)
        label(c, "Searches every section of the BBS.", GREY)
    end)
end

-- ── Entry / exit ────────────────────────────────────────────────────────────
function V.open()
    if not pump then pump = apps.add_timer { period = 50, cb = tick } end
    bbs.sweep_previews()
    home()
end

-- Stops the BBS: drops any pending job, deletes the pump and the cart
-- fetched for viewing, and closes the download client. The view showing
-- that cart must already be gone.
function V.release()
    gen = gen + 1
    job = nil
    status = nil
    page = nil
    if pump then
        pump:delete()
        pump = nil
    end
    drop_preview()
    pcall(_wifi_download_end)
end

-- Back to the launcher's main screen; its view replaces this one first.
function V.close()
    ctx.on_back()
    V.release()
end

return V
