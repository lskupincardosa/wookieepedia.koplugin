--[[--
Galaxy map for a planet's grid square, with three views (tap to switch):

- Galaxy:  the whole grid, regions as smooth gray shapes with their names,
           a few well-known planets for orientation, the planet ringed.
- Close-up: the 5x5 squares around the planet, with the planets in each.
- Atlas:   optional; your own map image with the square marked (see DEV.md).

The galaxy and close-up views are drawn only from data/galaxy_grid.lua, which
is generated from the grid squares and regions Wookieepedia lists for each
planet (tools/build_galaxy_grid.py). No official map artwork is included.

LEARN: KOReader draws everything into a Blitbuffer (an in-memory image of the
screen). A widget's paintTo(bb, x, y) paints itself at x/y; UIManager decides
when, and how the e-ink screen gets refreshed.
]]

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderImage = require("ui/renderimage")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

-- Region fills, from the galactic center outwards (darker = more central).
local SHADES = {
    Blitbuffer.COLOR_GRAY_5,     -- Deep Core
    Blitbuffer.COLOR_GRAY_7,     -- Core Worlds
    Blitbuffer.COLOR_GRAY_9,     -- Colonies
    Blitbuffer.COLOR_GRAY_B,     -- Inner Rim
    Blitbuffer.COLOR_LIGHT_GRAY, -- Expansion Region
    Blitbuffer.COLOR_GRAY_D,     -- Mid Rim
    Blitbuffer.COLOR_GRAY_E,     -- Outer Rim Territories
}
-- Lighter fills for the close-up, where text sits on top.
local LIGHT_SHADES = {
    Blitbuffer.COLOR_GRAY_B, Blitbuffer.COLOR_LIGHT_GRAY, Blitbuffer.COLOR_GRAY_D, Blitbuffer.COLOR_GRAY_D,
    Blitbuffer.COLOR_GRAY_E, Blitbuffer.COLOR_GRAY_E, Blitbuffer.COLOR_WHITE,
}
local EDGE = Blitbuffer.COLOR_GRAY_4

local grid_data
local function loadGrid()
    if grid_data == nil then
        local dir = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
        local ok, data = pcall(dofile, dir .. "/data/galaxy_grid.lua")
        if not ok then logger.warn("Wookieepedia: no galaxy grid data:", data) end
        grid_data = ok and data or false
    end
    return grid_data or nil
end

-- Optional user-supplied map image + calibration, kept outside the plugin (and the repo).
local function loadAtlas()
    local dir = DataStorage:getDataDir() .. "/wookieepedia"
    local ok, calib = pcall(dofile, dir .. "/galaxy_map.lua")
    if not ok or type(calib) ~= "table" or not calib.image then return end
    calib.path = dir .. "/" .. calib.image
    if not util.fileExists(calib.path) then
        logger.warn("Wookieepedia: atlas image missing:", calib.path)
        return
    end
    return calib
end

local function parseGrid(grid, square)
    local col, row = (square or ""):match("^(%u)%-(%d+)$")
    if not col then return end
    for ci, c in ipairs(grid.cols) do
        if c == col then return ci, tonumber(row) - grid.rows_min + 1 end
    end
end

local function textSize(text, face, bold)
    local tw = TextWidget:new{ text = text, face = face, bold = bold }
    local size = tw:getSize()
    tw:free()
    return size.w, size.h
end

-- Text with a white box behind it, so it stays readable on gray.
local function paintLabel(bb, text, face, x, y, bold, pad)
    local tw = TextWidget:new{ text = text, face = face, bold = bold }
    local size = tw:getSize()
    pad = pad or 0
    if pad > 0 then
        bb:paintRect(x - pad, y, size.w + 2 * pad, size.h, Blitbuffer.COLOR_WHITE)
    end
    tw:paintTo(bb, x, y)
    tw:free()
    return size.w, size.h
end

local function overlaps(rect, placed)
    for _, r in ipairs(placed) do
        if rect.x < r.x + r.w and r.x < rect.x + rect.w and rect.y < r.y + r.h and r.y < rect.y + rect.h then
            return true
        end
    end
    return false
end

local MapCanvas = Widget:extend{
    width = nil,
    height = nil,
    grid = nil,
    atlas = nil,
    title = nil,
    target = nil,   -- "L-9"
    mode = "galaxy", -- "galaxy" | "closeup" | "atlas"
}

function MapCanvas:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.small_face = Font:getFace("cfont", 11)
    self.label_face = Font:getFace("cfont", 13)
    self.name_face = Font:getFace("cfont", 15)
end

function MapCanvas:getSize()
    return self.dimen
end

function MapCanvas:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
    if self.mode == "closeup" then
        self:paintCloseup(bb, x, y)
    elseif self.mode == "atlas" then
        self:paintAtlas(bb, x, y)
    else
        self:paintGalaxy(bb, x, y)
    end
end

-- Paints the smoothed region raster for squares [c0..c1] x [r0..r1] (1-based) into a box.
function MapCanvas:paintRaster(bb, ox, oy, cell, c0, c1, r0, r1, shades, outlines)
    local grid, sub = self.grid, self.grid.sub
    local function px(i) return math.floor(i * cell / sub) end
    for sy = (r0 - 1) * sub, r1 * sub - 1 do
        local row = grid.raster[sy + 1]
        local y0, y1 = px(sy - (r0 - 1) * sub), px(sy - (r0 - 1) * sub + 1)
        for sx = (c0 - 1) * sub, c1 * sub - 1 do
            local code = tonumber(row:sub(sx + 1, sx + 1))
            if code then
                local x0, x1 = px(sx - (c0 - 1) * sub), px(sx - (c0 - 1) * sub + 1)
                bb:paintRect(ox + x0, oy + y0, x1 - x0, y1 - y0, shades[code])
                -- Region outlines: where the right or lower neighbour differs.
                local right = outlines and row:sub(sx + 2, sx + 2)
                if right and sx + 1 < c1 * sub and right ~= tostring(code) then
                    bb:paintRect(ox + x1 - 1, oy + y0, 1, y1 - y0, EDGE)
                end
                local below = outlines and grid.raster[sy + 2]
                if below and sy + 1 < r1 * sub and below:sub(sx + 1, sx + 1) ~= tostring(code) then
                    bb:paintRect(ox + x0, oy + y1 - 1, x1 - x0, 1, EDGE)
                end
            elseif outlines then
                -- Empty subcell: outline towards a filled neighbour.
                local x0, x1 = px(sx - (c0 - 1) * sub), px(sx - (c0 - 1) * sub + 1)
                local right = sx + 1 < c1 * sub and tonumber(row:sub(sx + 2, sx + 2))
                local below = sy + 1 < r1 * sub and grid.raster[sy + 2] and tonumber(grid.raster[sy + 2]:sub(sx + 1, sx + 1))
                if right then bb:paintRect(ox + x1 - 1, oy + y0, 1, y1 - y0, EDGE) end
                if below then bb:paintRect(ox + x0, oy + y1 - 1, x1 - x0, 1, EDGE) end
            end
        end
    end
end

-- Column letters on top, row numbers on the left; the target's in bold.
function MapCanvas:paintAxes(bb, ox, oy, cell, c0, c1, r0, r1, tc, tr)
    local grid = self.grid
    for ci = c0, c1 do
        local text = grid.cols[ci]
        local w, h = textSize(text, self.small_face, ci == tc)
        paintLabel(bb, text, self.small_face, ox + (ci - c0) * cell + math.floor((cell - w) / 2), oy - h - 2, ci == tc)
    end
    for ri = r0, r1 do
        local text = tostring(ri + grid.rows_min - 1)
        local w, h = textSize(text, self.small_face, ri == tr)
        paintLabel(bb, text, self.small_face, ox - w - 4, oy + (ri - r0) * cell + math.floor((cell - h) / 2), ri == tr)
    end
end

function MapCanvas:paintGalaxy(bb, x, y)
    local grid = self.grid
    local ncols, nrows = #grid.cols, grid.rows_max - grid.rows_min + 1
    local margin = Screen:scaleBySize(20)
    local cell = math.floor(math.min((self.width - margin - 4) / ncols, (self.height - margin - 4) / nrows))
    local ox = x + margin + math.floor((self.width - margin - cell * ncols) / 2)
    local oy = y + margin
    local tc, tr = parseGrid(grid, self.target)

    self:paintRaster(bb, ox, oy, cell, 1, ncols, 1, nrows, SHADES, true)
    -- Faint grid: white lines over the fills.
    for ci = 1, ncols - 1 do bb:paintRect(ox + ci * cell, oy, 1, nrows * cell, Blitbuffer.COLOR_WHITE) end
    for ri = 1, nrows - 1 do bb:paintRect(ox, oy + ri * cell, ncols * cell, 1, Blitbuffer.COLOR_WHITE) end
    bb:paintBorder(ox, oy, ncols * cell + 1, nrows * cell + 1, 1, Blitbuffer.COLOR_GRAY_9)
    self:paintAxes(bb, ox, oy, cell, 1, ncols, 1, nrows, tc, tr)

    local placed = {}
    local sub = grid.sub
    -- The target first, so its label always gets its spot.
    local tx, ty
    if tc then
        tx, ty = ox + math.floor((tc - 0.5) * cell), oy + math.floor((tr - 0.5) * cell)
        -- Crosshair lines to the axes help read the coordinate.
        for i = oy, oy + nrows * cell, 6 do bb:paintRect(tx, i, 1, 3, Blitbuffer.COLOR_BLACK) end
        for i = ox, ox + ncols * cell, 6 do bb:paintRect(i, ty, 3, 1, Blitbuffer.COLOR_BLACK) end
        local r = math.max(math.floor(cell * 0.6), Screen:scaleBySize(8))
        bb:paintCircle(tx, ty, r, Blitbuffer.COLOR_BLACK, Screen:scaleBySize(3))
        bb:paintCircle(tx, ty, Screen:scaleBySize(3), Blitbuffer.COLOR_BLACK)
        local w, h = textSize(self.title, self.name_face, true)
        local lx = tx + r + 4
        if lx + w > x + self.width then lx = tx - r - 4 - w end
        local ly = ty - math.floor(h / 2)
        paintLabel(bb, self.title, self.name_face, lx, ly, true, 3)
        table.insert(placed, { x = tx - r, y = ty - r, w = 2 * r, h = 2 * r })
        table.insert(placed, { x = lx - 3, y = ly, w = w + 6, h = h })
    end
    -- Well-known planets as small dots, skipped where they'd collide.
    for _, lm in ipairs(grid.landmarks or {}) do
        local lc, lr = parseGrid(grid, lm.grid)
        if lc and lm.name ~= self.title then
            local dx, dy = ox + math.floor((lc - 0.5) * cell), oy + math.floor((lr - 0.5) * cell)
            local w, h = textSize(lm.name, self.small_face)
            -- Name to the right of the dot, or to the left near the right edge.
            local lx = dx + 5
            if lx + w > x + self.width - 2 then lx = dx - 5 - w end
            local rect = { x = math.min(lx, dx - 3), y = dy - math.floor(h / 2), w = w + 10, h = h }
            if not overlaps(rect, placed) then
                bb:paintCircle(dx, dy, Screen:scaleBySize(3), Blitbuffer.COLOR_BLACK)
                paintLabel(bb, lm.name, self.small_face, lx, dy - math.floor(h / 2), false, 1)
                table.insert(placed, rect)
            end
        end
    end
    -- Region names, where they don't collide with planets.
    for _, label in ipairs(grid.labels or {}) do
        local w, h = textSize(label.text, self.label_face, true)
        local lx = ox + math.floor(label.x * cell / sub - w / 2)
        local ly = oy + math.floor(label.y * cell / sub - h / 2)
        local rect = { x = lx, y = ly, w = w, h = h }
        if not overlaps(rect, placed) then
            paintLabel(bb, label.text, self.label_face, lx, ly, true, 2)
            table.insert(placed, rect)
        end
    end
end

function MapCanvas:paintCloseup(bb, x, y)
    local grid = self.grid
    local ncols, nrows = #grid.cols, grid.rows_max - grid.rows_min + 1
    local tc, tr = parseGrid(grid, self.target)
    if not tc then return end
    local span = 5
    local c0 = math.max(1, math.min(tc - 2, ncols - span + 1))
    local r0 = math.max(1, math.min(tr - 2, nrows - span + 1))
    local c1, r1 = c0 + span - 1, r0 + span - 1
    local margin = Screen:scaleBySize(20)
    local cell = math.floor(math.min((self.width - margin - 4) / span, (self.height - margin - 4) / span))
    local ox = x + margin + math.floor((self.width - margin - cell * span) / 2)
    local oy = y + margin

    self:paintRaster(bb, ox, oy, cell, c0, c1, r0, r1, LIGHT_SHADES)
    self:paintAxes(bb, ox, oy, cell, c0, c1, r0, r1, tc, tr)
    local pad = Screen:scaleBySize(4)
    for ri = r0, r1 do
        for ci = c0, c1 do
            local sx, sy = ox + (ci - c0) * cell, oy + (ri - r0) * cell
            bb:paintBorder(sx, sy, cell + 1, cell + 1, 1, Blitbuffer.COLOR_GRAY_9)
            local square = grid.cols[ci] .. "-" .. (ri + grid.rows_min - 1)
            local info = grid.planets[square]
            local ly = sy + pad
            if info then
                -- The looked-up planet first, then the best-known ones.
                local names = {}
                if ci == tc and ri == tr then table.insert(names, self.title) end
                for _, name in ipairs(info) do
                    if name ~= self.title then table.insert(names, name) end
                end
                local max_lines = math.max(1, math.floor((cell - 2 * pad) / select(2, textSize("Ag", self.small_face))) - 1)
                for i = 1, math.min(#names, max_lines) do
                    local bold = (i == 1 and ci == tc and ri == tr)
                    local tw = TextWidget:new{ text = names[i], face = self.small_face, bold = bold,
                        max_width = cell - 2 * pad }
                    tw:paintTo(bb, sx + pad, ly)
                    ly = ly + tw:getSize().h
                    tw:free()
                end
                local rest = info.n - math.min(#names, max_lines)
                if rest > 0 then
                    paintLabel(bb, T(_("+%1 more"), rest), self.small_face, sx + pad, ly)
                end
            end
        end
    end
    local tx, ty = ox + (tc - c0) * cell, oy + (tr - r0) * cell
    bb:paintBorder(tx - 1, ty - 1, cell + 3, cell + 3, Screen:scaleBySize(3), Blitbuffer.COLOR_BLACK)
end

-- The user's map image, cropped to `span` x `span` squares around the planet
-- (a whole galaxy map is unreadable on a 6" screen), with the square marked.
function MapCanvas:paintAtlas(bb, x, y)
    local a = self.atlas
    local col, row = (self.target or ""):match("^(%u)%-(%d+)$")
    local ncols = a.last_col:byte() - a.first_col:byte() + 1
    local nrows = a.last_row - a.first_row + 1
    local cw, ch = (a.right - a.left) / ncols, (a.bottom - a.top) / nrows -- one square, image pixels
    if not self.atlas_bb then
        local img = RenderImage:renderImageFile(a.path, false)
        if not img then
            paintLabel(bb, _("Couldn't open the map image."), self.label_face, x + 10, y + 10)
            return
        end
        local iw, ih = img:getWidth(), img:getHeight()
        -- Crop window centred on the target square, kept inside the image.
        local span = a.span or 7
        local ww = math.min(iw, math.floor(span * cw))
        local wh = math.min(ih, math.floor(ww * self.height / self.width))
        local tcx = col and (a.left + (col:byte() - a.first_col:byte() + 0.5) * cw) or iw / 2
        local tcy = row and (a.top + (tonumber(row) - a.first_row + 0.5) * ch) or ih / 2
        local x0 = math.max(0, math.min(iw - ww, math.floor(tcx - ww / 2)))
        local y0 = math.max(0, math.min(ih - wh, math.floor(tcy - wh / 2)))
        local crop = img:viewport(x0, y0, ww, wh):copy()
        img:free()
        local scale = math.min(self.width / ww, self.height / wh)
        self.atlas_bb = RenderImage:scaleBlitBuffer(crop, math.floor(ww * scale), math.floor(wh * scale), true)
        self.atlas_scale, self.atlas_x0, self.atlas_y0 = scale, x0, y0
    end
    local iw, ih = self.atlas_bb:getWidth(), self.atlas_bb:getHeight()
    local ix, iy = x + math.floor((self.width - iw) / 2), y + math.floor((self.height - ih) / 2)
    bb:blitFrom(self.atlas_bb, ix, iy, 0, 0, iw, ih)
    if not col then return end
    local s = self.atlas_scale
    local sx = ix + (a.left + (col:byte() - a.first_col:byte()) * cw - self.atlas_x0) * s
    local sy = iy + (a.top + (tonumber(row) - a.first_row) * ch - self.atlas_y0) * s
    local bw = Screen:scaleBySize(3)
    -- White then black frame, visible on dark and light parts of the image.
    bb:paintBorder(math.floor(sx) - 2 * bw, math.floor(sy) - 2 * bw, math.floor(cw * s) + 4 * bw,
        math.floor(ch * s) + 4 * bw, bw, Blitbuffer.COLOR_WHITE)
    bb:paintBorder(math.floor(sx) - bw, math.floor(sy) - bw, math.floor(cw * s) + 2 * bw,
        math.floor(ch * s) + 2 * bw, bw, Blitbuffer.COLOR_BLACK)
end

function MapCanvas:free()
    if self.atlas_bb then
        self.atlas_bb:free()
        self.atlas_bb = nil
    end
end

local WookMap = InputContainer:extend{
    title = nil,
    location = nil,
}

local MODE_HINTS = {
    galaxy = _("Tap the map for a close-up."),
    closeup = _("Close-up of the squares around it. Tap to switch view."),
    atlas = _("Your map image, around the planet. Tap to switch view."),
}

function WookMap:init()
    self.grid = loadGrid()
    self.atlas = loadAtlas()
    self.modes = { "galaxy", "closeup" }
    if self.atlas then table.insert(self.modes, "atlas") end
    self.mode_index = 1

    local width, height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = width, h = height }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    if Device:isTouchDevice() then
        self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    end

    local region = self.location.region and self.location.region[1]
    self.title_bar = TitleBar:new{
        width = width,
        fullscreen = true,
        title = self.title,
        subtitle = region and T(_("Grid %1 · %2"), self.location.grid, region) or T(_("Grid %1"), self.location.grid),
        with_bottom_line = true,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    self.hint = TextWidget:new{
        text = MODE_HINTS.galaxy,
        face = Font:getFace("x_smallinfofont"),
        max_width = width - 2 * Screen:scaleBySize(10),
    }
    local canvas_height = height - self.title_bar:getSize().h - self.hint:getSize().h - Screen:scaleBySize(16)
    if self.grid then
        self.canvas = MapCanvas:new{ width = width, height = canvas_height, grid = self.grid,
            atlas = self.atlas, title = self.title, target = self.location.grid }
    end
    self[1] = FrameContainer:new{
        width = width,
        height = height,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        VerticalGroup:new{
            self.title_bar,
            self.canvas or TextWidget:new{ text = _("Galaxy map data is missing."), face = Font:getFace("infofont") },
            FrameContainer:new{ bordersize = 0, padding = Screen:scaleBySize(8), self.hint },
        },
    }
end

function WookMap:onTap(_, ges)
    -- Taps on the title bar (close button) are handled there.
    if ges and ges.pos and self.title_bar.dimen and ges.pos:intersectWith(self.title_bar.dimen) then
        return false
    end
    if not self.canvas then return self:onClose() end
    self.mode_index = self.mode_index % #self.modes + 1
    local mode = self.modes[self.mode_index]
    self.canvas.mode = mode
    self.hint:setText(MODE_HINTS[mode])
    UIManager:setDirty(self, "flashui")
    return true
end

function WookMap:onClose()
    UIManager:close(self)
    return true
end

function WookMap:onCloseWidget()
    if self.canvas then self.canvas:free() end
    UIManager:setDirty(nil, "flashui")
end

function WookMap:onShow()
    UIManager:setDirty(self, "flashui")
end

function WookMap:show(title, location)
    UIManager:show(WookMap:new{ title = title, location = location })
end

return WookMap
