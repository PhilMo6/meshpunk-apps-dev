--[[
  Code Editor — browse, edit, save and run Lua files on the device.

  Files are chosen with lib/filepick (any drive: L:, S:, U:) and read and
  written through lib/fileman, so paths carry a drive prefix ("S:/x.lua").
  Run saves, tears this app down and executes the file with fileman.dofile;
  a file that returns an app root takes over the screen, an error shows a
  Runtime Error page with the message.

  Editing is a plain LVGL Textarea (trackball moves the cursor, touch
  positions it, the keyboard types). View shows the same text read-only in a
  scrolling label. (The old keyword colouring used a label property luavgl
  does not have, so it never coloured anything; it is gone.)
]]

local lvgl     = require("lvgl")
local apps     = require("lib/apps")
local nav      = require("lib/nav")
local utils    = require("lib/utils")
local fileman  = require("lib/fileman")
local filepick = require("lib/filepick")

local W = lvgl.HOR_RES()
local H = lvgl.VER_RES()
local HDR_H = 26
local STS_H = 20
local BODY_H = H - HDR_H - STS_H

local START_DIR = "L:/lua"

-- Where the picker opens next time; follows the file being edited.
local last_dir = START_DIR

local root = apps.new_root()
root:set { w = W, h = H, bg_color = "#16161e", pad_all = 0, border_width = 0 }
root:clear_flag(lvgl.FLAG.SCROLLABLE)

local vw = nil

local show_home, show_editor

local function toast(msg)
    pcall(utils.createNotification, root, tostring(msg), 2500)
end

-- Build a fresh full-screen view; the old one drains away safely.
local function swap_view(builder)
    local old = vw
    vw = root:Object {
        w = W, h = H, x = 0, y = 0,
        bg_color = "#16161e", bg_opa = 255, pad_all = 0, border_width = 0, radius = 0,
    }
    vw:clear_flag(lvgl.FLAG.SCROLLABLE)
    builder(vw)
    if old then apps.delete_view(old) end
end

-- ── Picking files ────────────────────────────────────────────────────────────

local function pick_file()
    filepick.open(root, {
        mode  = "file",
        title = "Open a file",
        start = last_dir,
        on_pick = function(path) show_editor(path) end,
    })
end

-- New file: choose the folder, then the name.
local function new_file()
    filepick.open(root, {
        mode  = "dir",
        title = "Folder for the new file",
        start = last_dir,
        on_pick = function(dir)
            swap_view(function(v)
                local body = v:Object {
                    w = W, h = H, x = 0, y = 0,
                    bg_opa = 0, border_width = 0, pad_all = 10,
                    flex = { flex_direction = "row", flex_wrap = "wrap" },
                }
                nav.replace(body, { flags = nav.ROLLOVER })

                body:Label { text = "New file in " .. dir, text_color = "#565f89",
                             w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT }
                body:Label { text = "Name (.lua is added without an extension):",
                             text_color = "#a9b1d6", w = lvgl.PCT(100), h = 18 }
                local name_ta = body:Textarea {
                    one_line = true, text = "",
                    text_color = "#c0caf5", bg_color = "#24283b",
                    border_color = "#3b4261", border_width = 1,
                    w = lvgl.PCT(100), h = 34, pad_all = 4,
                }
                local status = body:Label { text = "", text_color = "#f7768e",
                                            w = lvgl.PCT(100), h = 18 }

                local function do_create()
                    local fname = name_ta.text or ""
                    if #fname == 0 then status.text = "Enter a name"; return end
                    if fname:find("/", 1, true) then status.text = "No / in names"; return end
                    if not fname:match("%.") then fname = fname .. ".lua" end
                    local fpath = fileman.join(dir, fname)
                    if fileman.exists(fpath) then status.text = "Already exists"; return end
                    local ok, err = fileman.write(fpath, "-- " .. fname .. "\n")
                    if not ok then status.text = err or "Create failed"; return end
                    show_editor(fpath)
                end

                local create_btn = body:Button { w = 80, h = 26 }
                create_btn:Label { text = "Create", align = lvgl.ALIGN.CENTER }
                create_btn:onClicked(do_create)
                local cancel_btn = body:Button { w = 70, h = 26 }
                cancel_btn:Label { text = "Cancel", align = lvgl.ALIGN.CENTER }
                cancel_btn:onClicked(show_home)
                name_ta:onevent(lvgl.EVENT.KEY, function()
                    if lvgl.indev.get_act():get_key() == lvgl.KEY.ENTER then do_create() end
                end)
            end)
        end,
    })
end

-- ── Home ─────────────────────────────────────────────────────────────────────

show_home = function()
    swap_view(function(v)
        local col = v:Object {
            w = W, h = H, x = 0, y = 0,
            bg_opa = 0, border_width = 0, pad_all = 10,
            flex = { flex_direction = "column", flex_wrap = "nowrap" },
        }
        nav.replace(col, { flags = nav.ROLLOVER })

        col:Label { text = "Code Editor", text_color = "#7aa2f7", w = lvgl.PCT(100), h = 22 }
        col:Label { text = "Lua files on any drive. Run executes the file you are editing.",
                    text_color = "#a9b1d6", w = lvgl.PCT(100), h = lvgl.SIZE_CONTENT }

        local function item(text, fn)
            local b = col:Button { w = lvgl.PCT(100), h = 30 }
            b:Label { text = text, align = lvgl.ALIGN.CENTER }
            b:onClicked(fn)
        end
        item("Open file...", pick_file)
        item("New file...", new_file)
        item("Home", function()
            apps.refresh()              -- pick up apps created or edited here
            apps.go_home()
        end)
    end)
end

-- ── Editor ───────────────────────────────────────────────────────────────────

show_editor = function(filepath)
    local content = fileman.read(filepath)
    if not content then
        toast("Cannot read " .. fileman.basename(filepath))
        show_home()
        return
    end
    last_dir = fileman.parent(filepath) or START_DIR

    local previewing = false
    local ta = nil
    local view_lbl, status_lbl

    swap_view(function(v)
        local hdr = v:Object {
            w = W, h = HDR_H, x = 0, y = 0,
            bg_color = "#1a1b26", bg_opa = 255, border_width = 0, radius = 0,
            pad_all = 1, pad_left = 4,
            flex = { flex_direction = "row", align_items = "center" },
        }
        hdr:clear_flag(lvgl.FLAG.SCROLLABLE)
        nav.replace(hdr, { flags = nav.ROLLOVER })

        local fn = fileman.basename(filepath)
        if #fn > 13 then fn = fn:sub(1, 12) .. "~" end
        hdr:Label { text = fn, text_color = "#9ece6a", w = 95 }

        local function grab()
            if not previewing and ta then content = ta.text or content end
        end

        local save_btn = hdr:Button { w = 38, h = 20 }
        save_btn:Label { text = "Sav", align = lvgl.ALIGN.CENTER }
        save_btn:onClicked(function()
            grab()
            local ok, err = fileman.write(filepath, content)
            status_lbl.text = ok and ("Saved " .. #content .. "b") or ("Save failed: " .. tostring(err))
        end)

        -- Run: save, tear this app down, execute the file. A file that builds
        -- an app takes over the screen; an error gets its own page.
        local run_btn = hdr:Button { w = 36, h = 20 }
        run_btn:Label { text = "Run", align = lvgl.ALIGN.CENTER }
        run_btn:onClicked(function()
            grab()
            fileman.write(filepath, content)
            apps.clear_current()
            _nav_clear()
            root:delete()
            -- fileman.dofile: the chunk's first result, or nil + the error.
            local res, err = fileman.dofile(filepath)
            if res ~= nil or err == nil then return end
            local err_root = apps.new_root()
            err_root:set { w = W, h = H, bg_color = "#16161e", pad_all = 10, border_width = 0 }
            err_root:clear_flag(lvgl.FLAG.SCROLLABLE)
            nav.replace(err_root, { flags = nav.ROLLOVER })
            err_root:Label { text = "Runtime Error", text_color = "#f7768e",
                             align = lvgl.ALIGN.TOP_MID, y = 10 }
            local err_msg = tostring(err)
            if #err_msg > 300 then err_msg = err_msg:sub(1, 300) .. "..." end
            err_root:Label { text = err_msg, text_color = "#a9b1d6",
                             align = lvgl.ALIGN.TOP_MID, y = 35, w = W - 30 }
            local back = err_root:Button { w = 100, h = 30, align = lvgl.ALIGN.BOTTOM_MID, y = -10 }
            back:Label { text = "Home", align = lvgl.ALIGN.CENTER }
            back:onClicked(function() apps.go_home() end)
        end)

        local view_btn = hdr:Button { w = 40, h = 20 }
        view_lbl = view_btn:Label { text = "View", align = lvgl.ALIGN.CENTER }

        local back_btn = hdr:Button { w = 28, h = 20 }
        back_btn:Label { text = "<", align = lvgl.ALIGN.CENTER }
        back_btn:onClicked(show_home)

        local body = v:Object {
            w = W, h = BODY_H, x = 0, y = HDR_H,
            bg_color = "#1a1b26", bg_opa = 255, border_width = 0, radius = 0, pad_all = 0,
        }
        body:clear_flag(lvgl.FLAG.SCROLLABLE)

        local function make_editor()
            ta = body:Textarea {
                text = content, one_line = false,
                text_color = "#c0caf5", bg_color = "#1a1b26",
                border_width = 0, pad_all = 4,
                w = W, h = BODY_H,
            }
        end

        local function make_preview()
            local scroll = body:Object {
                w = W, h = BODY_H, bg_color = "#1a1b26", border_width = 0, pad_all = 4,
            }
            scroll:Label { text = content ~= "" and content or "(empty file)",
                           text_color = "#a9b1d6", w = W - 16 }
        end

        make_editor()

        view_btn:onClicked(function()
            if previewing then
                body:clean()
                make_editor()
                view_lbl.text = "View"
                previewing = false
            else
                grab()
                body:clean()
                ta = nil
                make_preview()
                view_lbl.text = "Edit"
                previewing = true
            end
        end)

        local sts = v:Object {
            w = W, h = STS_H, x = 0, y = H - STS_H,
            bg_color = "#24283b", bg_opa = 255, border_width = 0, radius = 0,
            pad_all = 2, pad_left = 6,
        }
        sts:clear_flag(lvgl.FLAG.SCROLLABLE)
        status_lbl = sts:Label { text = #content .. "b", text_color = "#565f89",
                                 align = lvgl.ALIGN.LEFT_MID }
        local disp = filepath
        if #disp > 30 then disp = "..." .. disp:sub(-27) end
        sts:Label { text = disp, text_color = "#565f89", align = lvgl.ALIGN.RIGHT_MID }
    end)
end

show_home()

return root
