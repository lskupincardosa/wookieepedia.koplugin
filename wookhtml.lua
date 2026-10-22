--[[--
Turns MediaWiki `action=parse` HTML (starwars.fandom.com) into plain text
for a scrollable text viewer, and extracts the link list of disambiguation
pages.

Pure Lua, no dependencies. A hand-rolled single-pass scanner is used instead
of a DOM parser: it never builds a tree, so it is fast and light on memory
for 1-2 MB articles on e-readers.

    local wookhtml = require("wookhtml")
    local text = wookhtml.toText(html)
    local links = wookhtml.listLinks(html)
]]

local concat = table.concat
local find, sub, byte, match, gsub, lower, rep, char =
    string.find, string.sub, string.byte, string.match, string.gsub,
    string.lower, string.rep, string.char

local wookhtml = {}

-- Sections (h2) dropped by default.
local DEFAULT_SKIP_SECTIONS = {
    "Behind the scenes", "Appearances", "Non-canon appearances", "Sources",
    "Non-canon sources", "Notes and references", "External links",
    "Explanatory notes",
}

-- Elements dropped together with everything inside them.
local DROP_TAGS = {
    aside = true, table = true, figure = true, noscript = true, svg = true,
    nav = true, style = true, script = true,
}

-- If an element's class contains one of these substrings, it is dropped.
local DROP_CLASS = {
    "messagebox", "iumb", "notice", "navbox", "noprint", "mobiletopicons",
    "mw-references-wrap", "reference", "thumb", "gallery", "hidable",
    "mw-empty-elt", "metadata", "mw-editsection",
}

-- Tags without content or closing tag.
local VOID = {
    br = true, img = true, hr = true, input = true, meta = true, link = true,
    wbr = true, source = true, col = true, area = true, base = true,
    embed = true, param = true, track = true,
}

-- Tags that end the current text run (paragraph/line).
local BLOCK = {
    p = true, div = true, blockquote = true, section = true, center = true,
    dl = true, h1 = true, h5 = true, h6 = true, pre = true, hr = true,
}

local ENTITIES = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
    ndash = "\226\128\147", mdash = "\226\128\148",
    hellip = "\226\128\166", lsquo = "\226\128\152", rsquo = "\226\128\153",
    ldquo = "\226\128\156", rdquo = "\226\128\157", bull = "\226\128\162",
    middot = "\194\183", copy = "\194\169", reg = "\194\174",
    deg = "\194\176", times = "\195\151", laquo = "\194\171",
    raquo = "\194\187", shy = "",
}

-- LEARN: LuaJIT (Lua 5.1) has no utf8 library, so we encode by hand.
local function utf8char(cp)
    if cp < 0x80 then
        return char(cp)
    elseif cp < 0x800 then
        return char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return char(0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    elseif cp < 0x110000 then
        return char(0xF0 + math.floor(cp / 0x40000),
            0x80 + math.floor(cp / 0x1000) % 0x40,
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return ""
end

local function decodeEntity(body)
    if byte(body, 1) == 35 then -- "#"
        local cp
        if byte(body, 2) == 120 or byte(body, 2) == 88 then -- x / X
            cp = tonumber(sub(body, 3), 16)
        else
            cp = tonumber(sub(body, 2), 10)
        end
        if not cp then return nil end
        if cp == 160 then return " " end
        return utf8char(cp)
    end
    return ENTITIES[body]
end

local function decode(s)
    if not find(s, "&", 1, true) then return s end
    -- Returning nil from the gsub callback keeps the original text.
    return (gsub(s, "&(#?%w+);", decodeEntity))
end
wookhtml.decode = decode

local function trim(s)
    return match(s, "^%s*(.-)%s*$")
end

-- Collapse whitespace; "\1" markers (from <br>) become newlines.
local function collapse(buf, n)
    local s = gsub(concat(buf, "", 1, n), "%s+", " ")
    if find(s, "\1", 1, true) then
        s = gsub(s, "[ \1]*\1[ \1]*", "\n")
    end
    return trim(s)
end

local function attrValue(attrs, name)
    local v = match(attrs, "[%s\"']" .. name .. "%s*=%s*\"([^\"]*)\"")
        or match(attrs, "[%s\"']" .. name .. "%s*=%s*'([^']*)'")
    return v
end

local function shouldDrop(name, attrs)
    if DROP_TAGS[name] then return true end
    if attrs == "" then return false end
    if find(attrs, "id", 1, true) then
        local id = attrValue(attrs, "id")
        if id == "title-eraicons" or id == "toc" or id == "p-lang" then return true end
    end
    if find(attrs, "class", 1, true) then
        local cls = attrValue(attrs, "class")
        if cls then
            cls = lower(cls)
            for i = 1, #DROP_CLASS do
                if find(cls, DROP_CLASS[i], 1, true) then return true end
            end
            local padded = " " .. cls .. " "
            if find(padded, " toc ", 1, true) then return true end
            -- Epigraph quote at the top of articles (div.quote).
            if name == "div" and find(padded, " quote ", 1, true) then return true end
        end
    end
    return false
end

--- Single-pass scanner. Calls on_open(name, attrs, is_void),
-- on_close(name) and on_text(raw_text) for everything that is NOT inside a
-- dropped element. A stack of open tag names tells us when a dropped element
-- ends.
local function walk(html, on_open, on_close, on_text)
    local stack, sn = {}, 0
    local skip_from -- stack index of the dropped element we are inside
    local pos, len = 1, #html
    while pos <= len do
        local lt = find(html, "<", pos, true)
        if not lt then
            if not skip_from then on_text(sub(html, pos)) end
            break
        end
        if lt > pos and not skip_from then on_text(sub(html, pos, lt - 1)) end
        local c = byte(html, lt + 1)
        if c == 33 then -- "<!": comment or doctype
            local e
            if sub(html, lt + 2, lt + 3) == "--" then
                e = find(html, "-->", lt + 4, true)
                pos = e and e + 3 or len + 1
            else
                e = find(html, ">", lt + 2, true)
                pos = e and e + 1 or len + 1
            end
        elseif c == 47 then -- "</": closing tag
            local name, e = match(html, "^</([%a][%w:-]*)[^>]*>()", lt)
            if not name then
                if not skip_from then on_text("<") end
                pos = lt + 1
            else
                pos = e
                name = lower(name)
                local i = sn
                while i > 0 and stack[i] ~= name do i = i - 1 end
                if i > 0 then
                    local was_skipping = skip_from
                    if not was_skipping then
                        -- Also closes implicitly open tags above it.
                        for j = sn, i, -1 do on_close(stack[j]) end
                    end
                    sn = i - 1
                    if skip_from and sn < skip_from then skip_from = nil end
                end
            end
        else
            local name, attrs, e = match(html, "^<([%a][%w:-]*)([^>]*)>()", lt)
            if not name then
                if not skip_from then on_text("<") end
                pos = lt + 1
            else
                pos = e
                name = lower(name)
                local selfclose = byte(attrs, #attrs) == 47 -- "/"
                if VOID[name] or selfclose then
                    if not skip_from then on_open(name, attrs, true) end
                elseif name == "script" or name == "style" then
                    -- Raw text element: jump straight to its end tag.
                    local _, ce = find(html, "</" .. name .. ">", e, true)
                    pos = ce and ce + 1 or len + 1
                elseif skip_from then
                    sn = sn + 1
                    stack[sn] = name
                else
                    local handled = false
                    if name == "sup" then
                        -- Drop <sup> holding only a "[n]" citation mark.
                        local s2, e2 = find(html, "</sup>", e, true)
                        if s2 and s2 - e < 300 then
                            local inner = decode(gsub(sub(html, e, s2 - 1), "<[^>]*>", ""))
                            if match(inner, "^%s*%[[^%]]*%]%s*$") then
                                pos = e2 + 1
                                handled = true
                            end
                        end
                    end
                    if not handled then
                        sn = sn + 1
                        stack[sn] = name
                        if shouldDrop(name, attrs) then
                            skip_from = sn
                        else
                            on_open(name, attrs, false)
                        end
                    end
                end
            end
        end
    end
end

--- Plain text of an article.
-- @tparam string html
-- @tparam[opt] table opts `skip_sections`: array of h2 titles to drop
function wookhtml.toText(html, opts)
    if type(html) ~= "string" or html == "" then return "" end
    local skip_list = opts and opts.skip_sections or DEFAULT_SKIP_SECTIONS
    local skip_set = {}
    for _, t in ipairs(skip_list) do skip_set[lower(trim(t))] = true end

    local buf, n = {}, 0
    local outk, outt, on = {}, {}, 0 -- output blocks: kind, text
    local depth = 0 -- ul/ol nesting
    local in_dd = false
    local heading -- 2..4 while inside such a heading
    local bullet = false -- next flush in this <li> gets a bullet
    local skipping = false -- inside a skipped h2 section

    local function emit(kind, text)
        if skipping or text == "" then return end
        on = on + 1
        outk[on], outt[on] = kind, text
    end

    local function flush()
        if n == 0 or heading then return end
        local s = collapse(buf, n)
        n = 0
        if s == "" then return end
        if depth > 0 then
            local pre = rep("  ", depth - 1) .. (bullet and "\226\128\162 " or "  ")
            bullet = false
            emit("li", pre .. s)
        elseif in_dd then
            emit("dd", s)
        else
            emit("p", s)
        end
    end

    local function onOpen(name, _, void)
        if name == "br" then
            n = n + 1
            buf[n] = "\1"
        elseif void then
            return
        elseif name == "li" then
            flush()
            bullet = true
        elseif name == "ul" or name == "ol" then
            flush()
            depth = depth + 1
        elseif name == "dd" or name == "dt" then
            flush()
            in_dd = true
        elseif name == "h2" or name == "h3" or name == "h4" then
            flush()
            heading = tonumber(sub(name, 2))
        elseif BLOCK[name] then
            flush()
        end
    end

    local function onClose(name)
        if name == "li" then
            flush()
            bullet = false
        elseif name == "ul" or name == "ol" then
            flush()
            if depth > 0 then depth = depth - 1 end
        elseif name == "dd" or name == "dt" then
            flush()
            in_dd = false
        elseif name == "h2" or name == "h3" or name == "h4" then
            if heading then
                local s = collapse(buf, n)
                n = 0
                if heading == 2 then skipping = skip_set[lower(s)] or false end
                heading = nil
                emit("h", s)
            end
        elseif BLOCK[name] then
            flush()
        end
    end

    local function onText(t)
        if n == 0 and not find(t, "%S") then return end
        n = n + 1
        buf[n] = decode(t)
    end

    walk(html, onOpen, onClose, onText)
    flush()

    -- Join blocks: list/dialogue lines stay together, others get a blank line.
    local parts = {}
    for i = 1, on do
        if i > 1 then
            local k, pk = outk[i], outk[i - 1]
            parts[#parts + 1] = (k == pk and (k == "li" or k == "dd")) and "\n" or "\n\n"
        end
        parts[#parts + 1] = outt[i]
    end
    return concat(parts)
end

--- Links of list items pointing to main-namespace articles
-- (for disambiguation pages).
-- @treturn table array of { title = "...", text = "..." }
function wookhtml.listLinks(html)
    local result = {}
    if type(html) ~= "string" or html == "" then return result end
    local all, open = {}, {} -- all <li> records; stack of currently open ones
    local top = 0

    local function onOpen(name, attrs)
        if name == "li" then
            local rec = { buf = {}, n = 0 }
            all[#all + 1] = rec
            top = top + 1
            open[top] = rec
        elseif name == "a" and top > 0 then
            local rec = open[top]
            if not rec.seen_a then
                rec.seen_a = true
                local href = attrValue(attrs, "href")
                if href then
                    href = decode(href)
                    local t = match(href, "^/wiki/([^#?]*)")
                    if t then
                        t = gsub(t, "%%(%x%x)", function(h) return char(tonumber(h, 16)) end)
                        t = gsub(t, "_", " ")
                        if t ~= "" and not find(t, ":", 1, true) then
                            rec.title = t
                        end
                    end
                end
            end
        elseif name == "br" and top > 0 then
            local rec = open[top]
            rec.n = rec.n + 1
            rec.buf[rec.n] = " "
        end
    end

    local function onClose(name)
        if name == "li" and top > 0 then
            open[top] = nil
            top = top - 1
        end
    end

    local function onText(t)
        if top == 0 then return end
        local rec = open[top]
        rec.n = rec.n + 1
        rec.buf[rec.n] = decode(t)
    end

    walk(html, onOpen, onClose, onText)

    local seen = {}
    for _, rec in ipairs(all) do
        local title = rec.title
        if title and not seen[title] then
            seen[title] = true
            result[#result + 1] = { title = title, text = collapse(rec.buf, rec.n) }
        end
    end
    return result
end

return wookhtml
