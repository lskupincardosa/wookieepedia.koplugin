--[[--
Talks to the Wookieepedia MediaWiki API (starwars.fandom.com/api.php).

No UI code lives here: functions return plain Lua tables, so main.lua decides
how to show them. Fandom doesn't offer TextExtracts (prop=extracts), so we use
action=parse and turn the returned HTML into text with wookhtml.lua.
]]

local JSON = require("json")
local logger = require("logger")
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

--[[--
Turns an action=parse response body into one of:

    { kind = "article", title =, text =, url =, redirected_from = }
    { kind = "disambiguation", title =, options = { {title=, text=}, ... } }
    { kind = "missing" }
    { kind = "error", message = }
]]
function WookApi:interpretParse(body)
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
    return {
        kind = "article",
        title = parse.title,
        text = wookhtml.toText(parse.text),
        url = self:articleUrl(parse.title),
        redirected_from = redirected_from,
    }
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
