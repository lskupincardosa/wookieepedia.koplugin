--[[--
Talks to the Wookieepedia MediaWiki API (starwars.fandom.com/api.php).

No UI code lives here: functions return plain Lua tables, so main.lua decides
how to show them. Fandom doesn't offer TextExtracts (prop=extracts), so we use
action=parse and turn the returned HTML into text with wookhtml.lua.
]]

local JSON = require("json")
local logger = require("logger")
local util = require("util")
local wookhtml = require("wookhtml")

local WookApi = {
    api_url = "https://starwars.fandom.com/api.php",
    wiki_url = "https://starwars.fandom.com/wiki/",
    version = "0.1",
}

-- LEARN: KOReader already sends "KOReader/<version> (...)" as User-Agent
-- (socketutil patches http.USERAGENT). We prepend our own product token so
-- Fandom can tell where the traffic comes from.
function WookApi:userAgent()
    local http = require("socket.http")
    return string.format("wookieepedia.koplugin/%s (+https://github.com/koreader/koreader) %s",
        self.version, http.USERAGENT or "")
end

-- Builds "https://...api.php?k=v&..." with escaped values, keys sorted so URLs are stable.
function WookApi:buildUrl(params)
    local url = require("socket.url")
    local keys = {}
    for k in pairs(params) do table.insert(keys, k) end
    table.sort(keys)
    local query = {}
    for _, k in ipairs(keys) do
        table.insert(query, k .. "=" .. url.escape(tostring(params[k])))
    end
    return self.api_url .. "?" .. table.concat(query, "&")
end

function WookApi:articleUrl(title)
    local url = require("socket.url")
    return self.wiki_url .. url.escape((title:gsub(" ", "_"))):gsub("%%2F", "/")
end

-- Returns true, body or false, error_message. Mirrors frontend/ui/wikipedia.lua.
function WookApi:httpGet(url, timeout, maxtime)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")

    local sink = {}
    socketutil:set_timeout(timeout or socketutil.LARGE_BLOCK_TIMEOUT, maxtime or socketutil.LARGE_TOTAL_TIMEOUT)
    local code, headers = socket.skip(1, http.request{
        url = url,
        method = "GET",
        headers = { ["User-Agent"] = self:userAgent() },
        sink = maxtime and socketutil.table_sink(sink) or ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    local content = table.concat(sink)

    if code == socketutil.TIMEOUT_CODE or code == socketutil.SSL_HANDSHAKE_CODE
            or code == socketutil.SINK_TIMEOUT_CODE then
        logger.warn("Wookieepedia: request timed out", url, code)
        return false, "timeout"
    end
    if headers == nil then
        logger.warn("Wookieepedia: network unavailable", url, code)
        return false, "network"
    end
    if type(code) ~= "number" or code < 200 or code > 299 then
        logger.warn("Wookieepedia: HTTP error", url, code)
        return false, "http " .. tostring(code)
    end
    return true, content
end

--- Image formats KOReader can render. Anything else (e.g. an HTML error or
--- bot-check page served with status 200) is rejected. Returns the file extension.
function WookApi:imageType(body)
    if type(body) ~= "string" then return end
    if body:sub(1, 4) == "RIFF" and body:sub(9, 12) == "WEBP" then return "webp" end
    if body:sub(1, 8) == "\137PNG\r\n\26\n" then return "png" end
    if body:sub(1, 3) == "\255\216\255" then return "jpg" end
    if body:sub(1, 4) == "GIF8" then return "gif" end
end

-- Request parameters (separated from the network call so they can run in a subprocess).
function WookApi:parseUrl(title, full)
    local params = {
        action = "parse",
        page = title,
        prop = "text|properties",
        redirects = 1,
        disablelimitreport = 1,
        disableeditsection = 1,
        format = "json",
        formatversion = 2,
    }
    if not full then
        params.section = 0 -- lead section only: smaller download, fewer spoilers
    end
    return self:buildUrl(params)
end

function WookApi:searchUrl(term)
    return self:buildUrl{
        action = "query",
        list = "search",
        srsearch = term,
        srlimit = 8,
        srnamespace = 0,
        srprop = "",
        format = "json",
        formatversion = 2,
    }
end

local function decode(body)
    local ok, data = pcall(JSON.decode, body)
    if not ok or type(data) ~= "table" then
        return nil
    end
    return data
end

-- Infobox labels we keep, and the field they go to.
local LOCATION_LABELS = {
    ["Region"] = "region",
    ["Sector"] = "sector",
    ["System"] = "system",
    ["Grid square"] = "grid",
}

-- An infobox value is HTML, often a <ul> of several entries: return a list of plain strings.
local function valueList(html)
    local list = {}
    for line in wookhtml.toText(html):gmatch("[^\n]+") do
        line = util.trim((line:gsub("^%s*•%s*", "")))
        if line ~= "" then table.insert(list, line) end
    end
    return list
end

--[[--
Pulls planet location data out of the `infoboxes` page property (a JSON
string describing Fandom's "portable infobox"). Returns nil when there is none, or

    { region = { "Outer Rim Territories", "The Slice" }, sector = {...},
      system = {...}, grid = "Q-16" }
]]
function WookApi:parseLocation(infoboxes_json)
    if type(infoboxes_json) ~= "string" then return end
    local infoboxes = decode(infoboxes_json)
    if not infoboxes then return end
    local location = {}
    local function walk(node)
        if type(node) ~= "table" then return end
        if node.type == "data" and type(node.data) == "table" then
            local field = LOCATION_LABELS[node.data.label]
            if field and type(node.data.value) == "string" and not location[field] then
                location[field] = valueList(node.data.value)
            end
        end
        for _, child in pairs(node) do walk(child) end
    end
    walk(infoboxes)
    if location.grid then
        -- Keep the first square that looks like "L-9".
        local grid
        for _, g in ipairs(location.grid) do
            grid = grid or g:match("^(%u%-%d%d?)")
        end
        location.grid = grid
    end
    if next(location) == nil then return end
    return location
end

--[[--
Species of a character, from the infobox's "Species" field: the linked
articles, in order. Returns nil when there is no such field, or

    { "Twi'lek" }    or, for hybrids,    { "Human", "Zabrak" }
]]
function WookApi:parseSpecies(infoboxes_json)
    if type(infoboxes_json) ~= "string" then return end
    local infoboxes = decode(infoboxes_json)
    if not infoboxes then return end
    local value
    local function walk(node)
        if value or type(node) ~= "table" then return end
        if node.type == "data" and type(node.data) == "table"
                and node.data.label == "Species" and type(node.data.value) == "string" then
            value = node.data.value
            return
        end
        for _, child in pairs(node) do walk(child) end
    end
    walk(infoboxes)
    if not value then return end
    local species, seen = {}, {}
    -- Citation links point to "#cite_note-…", so only article links match "/wiki/".
    for href in value:gmatch("<a [^>]*href=\"/wiki/([^\"#?]+)\"") do
        local title = wookhtml.decode(href)
            :gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
            :gsub("_", " ")
        if not seen[title] and not title:find(":", 1, true) then
            seen[title] = true
            table.insert(species, title)
        end
    end
    if #species == 0 then return end
    return species
end

-- Portraits are scaled by Fandom's image server to this width: big enough
-- for a full e-reader screen, about 100 KB as WebP.
local IMAGE_WIDTH = 600

--[[--
Pulls the main infobox image (character portrait, species picture, ...) out
of the `infoboxes` page property. Returns nil when there is none, or

    { name = "AvarKriss-SWULotF.png",
      url = "https://static.wikia.nocookie.net/.../revision/latest/scale-to-width-down/600?cb=..." }
]]
function WookApi:parseImage(infoboxes_json)
    if type(infoboxes_json) ~= "string" then return end
    local infoboxes = decode(infoboxes_json)
    if not infoboxes then return end
    local found
    local function walk(node)
        if found or type(node) ~= "table" then return end
        if node.type == "image" and type(node.data) == "table" then
            -- Some infoboxes have tabs (e.g. "Masked"/"Unmasked"): take the first.
            local first = node.data[1]
            if type(first) == "table" and type(first.url) == "string" and not first.isVideo then
                found = first
                return
            end
        end
        -- ipairs, not pairs: the first image in document order wins.
        for _, child in ipairs(node) do walk(child) end
        if type(node.data) == "table" then walk(node.data) end
        if type(node.value) == "table" then walk(node.value) end
    end
    walk(infoboxes)
    if not found then return end
    -- ".../revision/latest?cb=1" -> ".../revision/latest/scale-to-width-down/600?cb=1"
    local url = found.url:gsub("/revision/latest", "/revision/latest/scale-to-width-down/" .. IMAGE_WIDTH, 1)
    return { name = found.name or found.key, url = url }
end

--[[--
Turns an action=parse response body into one of:

    { kind = "article", title =, url =, redirected_from =, location =, image =, species =,
      text = (intro)  or  blocks =, sources = (full article, see wookhtml) }
    { kind = "disambiguation", title =, options = { {title=, text=}, ... } }
    { kind = "missing" }
    { kind = "error", message = }
]]
function WookApi:interpretParse(body, full)
    local data = decode(body)
    if not data then
        return { kind = "error", message = "invalid response" }
    end
    if data.error then
        if data.error.code == "missingtitle" or data.error.code == "invalidtitle" then
            return { kind = "missing" }
        end
        return { kind = "error", message = data.error.info or data.error.code }
    end
    local parse = data.parse
    if type(parse) ~= "table" or type(parse.text) ~= "string" then
        return { kind = "error", message = "unexpected response" }
    end
    local props = type(parse.properties) == "table" and parse.properties or {}
    if props.disambiguation ~= nil then
        return {
            kind = "disambiguation",
            title = parse.title,
            options = wookhtml.listLinks(parse.text),
        }
    end
    local redirected_from
    if type(parse.redirects) == "table" and parse.redirects[1] then
        redirected_from = parse.redirects[1].from
    end
    local result = {
        kind = "article",
        title = parse.title,
        url = self:articleUrl(parse.title),
        redirected_from = redirected_from,
        location = self:parseLocation(props.infoboxes),
        image = self:parseImage(props.infoboxes),
        species = self:parseSpecies(props.infoboxes),
    }
    if full then
        -- Full articles keep paragraph structure and citations for the spoiler filter.
        result.blocks = wookhtml.toBlocks(parse.text)
        result.sources = wookhtml.citationSources(parse.text)
    else
        result.text = wookhtml.toText(parse.text)
    end
    return result
end

-- Categories of up to 50 pages (the API's limit per request), to tell films from novels.
function WookApi:categoriesUrl(titles)
    return self:buildUrl{
        action = "query",
        titles = table.concat(titles, "|"),
        prop = "categories",
        cllimit = "max",
        clshow = "!hidden",
        redirects = 1,
        format = "json",
        formatversion = 2,
    }
end

--- Returns requested title -> { category names without "Category:" }, or nil.
--- Titles that redirect are reported under the title we asked for.
function WookApi:interpretCategories(body)
    local data = decode(body)
    if not data or type(data.query) ~= "table" then return end
    local query = data.query
    local by_title = {}
    for _, page in ipairs(query.pages or {}) do
        local cats = {}
        for _, c in ipairs(page.categories or {}) do
            table.insert(cats, (c.title:gsub("^Category:", "")))
        end
        by_title[page.title] = cats
    end
    -- Map back through "normalized" and "redirects" steps to the requested titles.
    local result = {}
    for title, cats in pairs(by_title) do result[title] = cats end
    for _, step in ipairs{ "redirects", "normalized" } do
        for _, r in ipairs(query[step] or {}) do
            if result[r.to] then result[r.from] = result[r.to] end
        end
    end
    return result
end

-- Returns an array of titles (possibly empty), or nil on a bad response.
function WookApi:interpretSearch(body)
    local data = decode(body)
    if not data or type(data.query) ~= "table" or type(data.query.search) ~= "table" then
        return nil
    end
    local titles = {}
    for _, hit in ipairs(data.query.search) do
        table.insert(titles, hit.title)
    end
    return titles
end

return WookApi
