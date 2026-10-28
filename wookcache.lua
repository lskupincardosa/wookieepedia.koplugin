--[[--
Offline store for looked-up articles.

Every article we fetch is saved, so looking it up again works without Wi-Fi
and costs no network traffic. Layout under <koreader data dir>/wookieepedia/:

    index.lua              aliases (what was selected -> article title) and titles
    articles/<md5>.lua     one file per article
    images/<md5>.<ext>     infobox portraits, downloaded on demand

LEARN: LuaSettings stores a Lua table as a .lua file (the same mechanism as
KOReader's own settings), so we get reading/writing for free.
We deliberately don't use KOReader's cache/ dir: "clear cache" would wipe it.
]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local md5 = require("ffi/sha2").md5
local util = require("util")

local WookCache = {}

function WookCache:new(dir)
    local o = { dir = dir or DataStorage:getDataDir() .. "/wookieepedia" }
    setmetatable(o, self)
    self.__index = self
    util.makePath(o.dir .. "/articles")
    o.index = LuaSettings:open(o.dir .. "/index.lua")
    return o
end

local function normalize(term)
    return util.trim(term):lower()
end

function WookCache:articlePath(title)
    return string.format("%s/articles/%s.lua", self.dir, md5(title))
end

-- Returns the saved entry for a selected term or exact title, or nil.
function WookCache:lookup(term)
    local aliases = self.index:readSetting("aliases", {})
    local title = aliases[normalize(term)]
    if not title then
        local titles = self.index:readSetting("titles", {})
        if titles[term] then title = term end
    end
    if not title then return end
    return self:get(title)
end

function WookCache:get(title)
    local path = self:articlePath(title)
    if not util.fileExists(path) then return end
    return LuaSettings:open(path):readSetting("entry")
end

--- Saves an entry (merged into any existing one, so a full article doesn't
--- lose its intro and vice versa) and remembers `aliases` as ways to reach it.
function WookCache:put(entry, aliases)
    local merged = self:get(entry.title) or {}
    for k, v in pairs(entry) do merged[k] = v end
    merged.saved = os.time()
    local file = LuaSettings:open(self:articlePath(entry.title))
    file:saveSetting("entry", merged)
    file:flush()

    local index_aliases = self.index:readSetting("aliases", {})
    for _, alias in ipairs(aliases or {}) do
        index_aliases[normalize(alias)] = entry.title
    end
    index_aliases[normalize(entry.title)] = entry.title
    local titles = self.index:readSetting("titles", {})
    titles[entry.title] = merged.saved
    self.index:saveSetting("aliases", index_aliases)
    self.index:saveSetting("titles", titles)
    self.index:flush()
    return merged
end

-- Path of a saved portrait (nil if it isn't downloaded yet).
function WookCache:imagePath(image)
    local base = string.format("%s/images/%s.", self.dir, md5(image.url))
    for _, ext in ipairs{ "webp", "png", "jpg", "gif" } do
        if util.fileExists(base .. ext) then return base .. ext end
    end
end

function WookCache:putImage(image, data, ext)
    util.makePath(self.dir .. "/images")
    local path = string.format("%s/images/%s.%s", self.dir, md5(image.url), ext)
    local file = io.open(path, "wb")
    if not file then return end
    file:write(data)
    file:close()
    return path
end

--- Source classification ("screen"/"story"/"neutral") per cited title, shared by all articles.
function WookCache:kinds()
    if not self.kinds_file then
        self.kinds_file = LuaSettings:open(self.dir .. "/source_kinds.lua")
    end
    return self.kinds_file:readSetting("kinds", {})
end

function WookCache:saveKinds(new_kinds)
    local kinds = self:kinds()
    for title, kind in pairs(new_kinds) do kinds[title] = kind end
    self.kinds_file:saveSetting("kinds", kinds)
    self.kinds_file:flush()
end

function WookCache:count()
    local n = 0
    for _ in pairs(self.index:readSetting("titles", {})) do n = n + 1 end
    return n
end

function WookCache:clear()
    for title in pairs(self.index:readSetting("titles", {})) do
        os.remove(self:articlePath(title))
    end
    self.index:saveSetting("aliases", {})
    self.index:saveSetting("titles", {})
    self.index:flush()
    os.remove(self.dir .. "/source_kinds.lua")
    require("ffi/util").purgeDir(self.dir .. "/images")
    self.kinds_file = nil
end

return WookCache
