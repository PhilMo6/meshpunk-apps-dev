-- Seeed Studio — Seeed's brand colors, Seeed Green #8FC31F (PANTONE 376C) and
-- Seeed Blue #003A4A (PANTONE 7546C), with Montserrat Medium as the UI font.
-- Wallpaper: green seeds on a Seeed Blue gradient over a faint perfboard dot
-- grid. Each seed is linked to its two nearest neighbours, some seeds sprout a
-- two-leaf shoot, and signal dots sit on a few of the links. The layout is
-- re-rolled each time the wallpaper draws.
--
-- Montserrat-Medium.ttf: Copyright 2011 The Montserrat Project Authors
-- (https://github.com/JulietaUla/Montserrat), SIL Open Font License 1.1 — see
-- OFL.txt in this folder.
return {
    name = "Seeed Studio",
    apply = function(t)
        t.set_palette {
            scr      = "#00222c",   -- deep Seeed Blue
            card     = "#003a4a",   -- Seeed Blue
            text     = "#e8f2ee",
            grey     = "#1b5a6c",   -- light Seeed Blue (borders / muted chrome)
            accent   = "#8fc31f",   -- Seeed Green
            btn_text = "#003a4a",   -- Seeed Blue on Seeed Green
            highlight   = "#5fd3f3",   -- Seeed Blue's hue, lighter (strong emphasized text)
            accent_text = "#ffb454",   -- amber (secondary emphasized text)
            dark     = true,
        }

        -- UI role only; the "text" role keeps the Settings > Fonts default.
        t.set_font(t.dir .. "/Montserrat-Medium.ttf")

        t.background.procedural(function(c, w, h)
            local GREEN  = "#8fc31f"   -- Seeed Green
            local LEAF   = "#b0d461"   -- lighter Seeed Green
            local GLINT  = "#d8eea0"
            local SOCKET = "#00222c"   -- scr
            local GRID   = "#1b5a6c"   -- grey
            local SIGNAL = "#5fd3f3"   -- highlight

            local s = math.min(w, h) / 240   -- size scale: 1.0 on a 240 px short side

            local function px(v) return math.floor(v + 0.5) end

            local function dot(x, y, r, col, opa)
                c:draw_rect({ x1 = px(x - r), y1 = px(y - r), x2 = px(x + r), y2 = px(y + r),
                              radius = px(r), bg_color = col, bg_opa = opa })
            end

            local function line(x1, y1, x2, y2, col, width, opa, round)
                c:draw_line({ p1 = { x = px(x1), y = px(y1) }, p2 = { x = px(x2), y = px(y2) },
                              color = col, width = width, opa = opa,
                              round_start = round and 1 or 0, round_end = round and 1 or 0 })
            end

            local function tri(x1, y1, x2, y2, x3, y3, col)
                c:draw_triangle({ p1 = { x = x1, y = y1 }, p2 = { x = x2, y = y2 },
                                  p3 = { x = x3, y = y3 }, bg_color = col, bg_opa = 255 })
            end

            ----------------------------------------------------------
            -- GRADIENT: scr #00222c at the top -> Seeed Blue #003a4a at the bottom
            ----------------------------------------------------------
            local BANDS = 24
            for i = 0, BANDS - 1 do
                local f = i / (BANDS - 1)
                c:draw_rect({ x1 = 0, y1 = math.floor(i * h / BANDS),
                              x2 = w - 1, y2 = math.floor((i + 1) * h / BANDS) - 1,
                              bg_color = string.format("#00%02x%02x", px(34 + 24 * f), px(44 + 30 * f)),
                              bg_opa = 255 })
            end

            ----------------------------------------------------------
            -- PERFBOARD DOT GRID
            ----------------------------------------------------------
            local pitch = 20 * s
            local dot_size = math.max(2, px(2 * s))
            for gy = pitch / 2, h - 1, pitch do
                for gx = pitch / 2, w - 1, pitch do
                    local x, y = px(gx), px(gy)
                    c:draw_rect({ x1 = x, y1 = y, x2 = x + dot_size - 1, y2 = y + dot_size - 1,
                                  bg_color = GRID, bg_opa = 130 })
                end
            end

            ----------------------------------------------------------
            -- SEEDS: one per cell of a jittered grid (5x3 on 320x240)
            ----------------------------------------------------------
            local cell = 64 * s
            local cols = math.max(2, math.floor(w / cell))
            local rows = math.max(2, math.floor(h / cell))
            local cell_w, cell_h = w / cols, h / rows
            local seeds = {}
            for row = 0, rows - 1 do
                for col = 0, cols - 1 do
                    seeds[#seeds + 1] = {
                        x = (col + 0.5 + (math.random() - 0.5) * 0.6) * cell_w,
                        y = (row + 0.5 + (math.random() - 0.5) * 0.6) * cell_h,
                        k = 0.85 + math.random() * 0.35,   -- per-seed size factor
                        sprout = math.random() < 0.45,
                    }
                end
            end

            ----------------------------------------------------------
            -- LINKS: each seed to its two nearest neighbours
            ----------------------------------------------------------
            local seen, links = {}, {}
            for i, a in ipairs(seeds) do
                local best, best2
                for j, b in ipairs(seeds) do
                    if j ~= i then
                        local d = (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2
                        if not best or d < best.d then
                            best2 = best
                            best = { j = j, d = d }
                        elseif not best2 or d < best2.d then
                            best2 = { j = j, d = d }
                        end
                    end
                end
                for _, pick in ipairs({ best, best2 }) do
                    local lo, hi = math.min(i, pick.j), math.max(i, pick.j)
                    local key = lo .. "-" .. hi
                    if not seen[key] then
                        seen[key] = true
                        links[#links + 1] = { a = seeds[lo], b = seeds[hi] }
                    end
                end
            end

            local link_w = math.max(1, px(s))
            for _, l in ipairs(links) do
                line(l.a.x, l.a.y, l.b.x, l.b.y, GREEN, link_w, 80, false)
            end

            ----------------------------------------------------------
            -- SIGNALS: dots with a faint halo on a few links
            ----------------------------------------------------------
            for _ = 1, math.min(6, #links) do
                local l = links[math.random(#links)]
                local f = 0.2 + math.random() * 0.6
                local x = l.a.x + (l.b.x - l.a.x) * f
                local y = l.a.y + (l.b.y - l.a.y) * f
                dot(x, y, 4 * s, SIGNAL, 50)
                dot(x, y, 1.5 * s, SIGNAL, 230)
            end

            ----------------------------------------------------------
            -- SEED BODIES: dark socket, green pill, glint
            ----------------------------------------------------------
            for _, sd in ipairs(seeds) do
                local half_w, half_h = 3.5 * s * sd.k, 5 * s * sd.k
                local ring = 2 * s
                c:draw_rect({ x1 = px(sd.x - half_w - ring), y1 = px(sd.y - half_h - ring),
                              x2 = px(sd.x + half_w + ring), y2 = px(sd.y + half_h + ring),
                              radius = px(half_w + ring), bg_color = SOCKET, bg_opa = 255 })
                c:draw_rect({ x1 = px(sd.x - half_w), y1 = px(sd.y - half_h),
                              x2 = px(sd.x + half_w), y2 = px(sd.y + half_h),
                              radius = px(half_w), bg_color = GREEN, bg_opa = 255 })
                dot(sd.x - half_w * 0.35, sd.y - half_h * 0.45, 0.8 * s, GLINT, 200)
            end

            ----------------------------------------------------------
            -- SPROUTS: bent stem from the seed top, two diamond leaves at the tip
            ----------------------------------------------------------
            local stem_w = math.max(2, px(2 * s))
            for _, sd in ipairs(seeds) do
                if sd.sprout then
                    local top = sd.y - 5 * s * sd.k
                    local len = (10 + math.random() * 6) * s * sd.k
                    local bend = (math.random() < 0.5 and -2 or 2) * s
                    local mx, my = sd.x + bend, top - len * 0.5
                    local tx, ty = sd.x, top - len
                    line(sd.x, top, mx, my, GREEN, stem_w, 255, true)
                    line(mx, my, tx, ty, GREEN, stem_w, 255, true)

                    local leaf_len, leaf_w = 7 * s * sd.k, 2.4 * s * sd.k
                    for _, dir in ipairs({ { -0.8, -0.6 }, { 0.8, -0.6 } }) do
                        local ex, ey = tx + dir[1] * leaf_len, ty + dir[2] * leaf_len   -- leaf tip
                        local cx, cy = tx + dir[1] * leaf_len * 0.5, ty + dir[2] * leaf_len * 0.5
                        local nx, ny = -dir[2] * leaf_w, dir[1] * leaf_w   -- perpendicular half-width
                        tri(tx, ty, cx + nx, cy + ny, ex, ey, LEAF)
                        tri(tx, ty, ex, ey, cx - nx, cy - ny, LEAF)
                    end
                end
            end

            ----------------------------------------------------------
            -- EDGE VIGNETTE
            ----------------------------------------------------------
            local e = px(12 * s)
            c:draw_rect({ x1 = 0, y1 = 0, x2 = w - 1, y2 = e - 1, bg_color = "#000000", bg_opa = 60 })
            c:draw_rect({ x1 = 0, y1 = h - e, x2 = w - 1, y2 = h - 1, bg_color = "#000000", bg_opa = 60 })
            c:draw_rect({ x1 = 0, y1 = 0, x2 = e - 1, y2 = h - 1, bg_color = "#000000", bg_opa = 60 })
            c:draw_rect({ x1 = w - e, y1 = 0, x2 = w - 1, y2 = h - 1, bg_color = "#000000", bg_opa = 60 })
        end)
    end,
}
