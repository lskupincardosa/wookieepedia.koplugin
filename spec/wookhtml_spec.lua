-- Tiny self-contained spec for wookhtml. Run: spec/run.sh
local json = require("dkjson")
local wookhtml = require("wookhtml")

local passed, failed = 0, 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("ok   - " .. name)
    else
        failed = failed + 1
        print("FAIL - " .. name .. "\n       " .. tostring(err))
    end
end

local function eq(actual, expected)
    if actual ~= expected then
        error(string.format("expected %q, got %q", expected, actual), 2)
    end
end

local function has(s, needle)
    if not s:find(needle, 1, true) then
        error(string.format("expected to contain %q", needle), 2)
    end
end

local function hasNot(s, needle)
    if s:find(needle, 1, true) then
        error(string.format("expected NOT to contain %q", needle), 2)
    end
end

local function fixture(name)
    local f = assert(io.open("spec/fixtures/" .. name, "rb"))
    local data = f:read("*a")
    f:close()
    return assert(json.decode(data)).parse.text
end

test("Avar Kriss intro", function()
    local t = wookhtml.toText(fixture("avar_kriss_intro.json"))
    eq(t:sub(1, 40), "Avar Kriss was a human female Jedi Maste")
    assert(not t:find("%[%d+%]"), "citation mark left")
    hasNot(t, "<")
    hasNot(t, "Content approaching")
    hasNot(t, "Homeworld")
    assert(not t:find("^%s") and not t:find("%s$"), "untrimmed")
    assert(not t:find("\n\n\n"), "too many blank lines")
end)

test("Starlight Beacon full article", function()
    local t = wookhtml.toText(fixture("starlight_beacon_full.json"))
    has(t, "\nHistory\n")
    has(t, "\nThe Great Hyperspace Disaster\n")
    has(t, "\nDescription\n")
    for _, s in ipairs({ "Behind the scenes", "Sources", "Appearances",
                         "External links", "Notes and references" }) do
        hasNot(t, s)
    end
    hasNot(t, "Production information")
    hasNot(t, "Contents")
    assert(not t:find("%[%d+%]"), "citation mark left")
end)

test("Mace listLinks", function()
    local links = wookhtml.listLinks(fixture("mace_disambiguation_full.json"))
    local seen = {}
    for _, l in ipairs(links) do
        assert(not seen[l.title], "duplicate " .. l.title)
        seen[l.title] = true
        assert(not l.title:find(":"), "namespace link " .. l.title)
    end
    assert(seen["Mace Windu"], "Mace Windu missing")
    assert(seen["Macemillian-winduart\195\169"], "percent decoding failed")
    eq(links[1].text, "Mace Windu, Jedi Master")
end)

test("entity decoding", function()
    eq(wookhtml.toText("<p>a&#91;1&#93; &amp; b &lt;c&gt; &quot;d&quot; &#039;e&#039;</p>"),
        "a[1] & b <c> \"d\" 'e'")
    eq(wookhtml.toText("<p>x&#x2014;y</p>"), "x\226\128\148y")
    eq(wookhtml.toText("<p>a&nbsp;&nbsp;b&#160;c</p>"), "a b c")
    eq(wookhtml.toText("<p>&amp;lt; &unknown;</p>"), "&lt; &unknown;")
end)

test("paragraphs, headings, br", function()
    local t = wookhtml.toText(
        "<p>One\n  two</p>\n\n\n<h2><span class=\"mw-headline\">Head</span>"
        .. "<span class=\"mw-editsection\">[edit]</span></h2><p>A<br />B</p>"
        .. "<blockquote>Quote</blockquote>")
    eq(t, "One two\n\nHead\n\nA\nB\n\nQuote")
end)

test("nested list indentation", function()
    local t = wookhtml.toText(
        "<ul><li>A<ul><li>B<ul><li>C</li></ul></li><li>D</li></ul></li><li>E</li></ul>")
    eq(t, "\226\128\162 A\n  \226\128\162 B\n    \226\128\162 C\n  \226\128\162 D\n\226\128\162 E")
end)

test("dropped elements", function()
    local t = wookhtml.toText(
        "<p>Keep<sup class=\"reference\"><a>[1]</a></sup><sup>[2]</sup>"
        .. "<sup>th</sup></p><table><tr><td>No</td></tr></table>"
        .. "<div class=\"navbox x\"><p>Nav</p></div><script>var a='<p>';</script>"
        .. "<aside><p>Info</p></aside><figure><figcaption>Cap</figcaption></figure>"
        .. "<div id=\"toc\"><p>Toc</p></div><p>End</p>")
    eq(t, "Keepth\n\nEnd")
end)

test("skip_sections override", function()
    local html = "<p>Intro</p><h2>Alpha</h2><p>a</p><h3>Sub</h3><p>s</p>"
        .. "<h2>Behind the scenes</h2><p>b</p><h2>Omega</h2><p>o</p>"
    eq(wookhtml.toText(html, { skip_sections = { "alpha" } }),
        "Intro\n\nBehind the scenes\n\nb\n\nOmega\n\no")
    eq(wookhtml.toText(html), "Intro\n\nAlpha\n\na\n\nSub\n\ns\n\nOmega\n\no")
end)

test("listLinks keeps colon titles, drops namespaces", function()
    local links = wookhtml.listLinks(
        "<ul><li><a href=\"/wiki/Star_Wars:_The_Acolyte\">A</a></li>"
        .. "<li><a href=\"/wiki/The_High_Republic:_Light_of_the_Jedi#X\">B</a></li>"
        .. "<li><a href=\"/wiki/File:X.png\">C</a></li>"
        .. "<li><a href=\"/wiki/category:Foo\">D</a></li>"
        .. "<li><a href=\"/wiki/Forum_talk:Bar\">E</a></li>"
        .. "<li><a href=\"/wiki/Wookieepedia:Naming_policy\">F</a></li></ul>")
    eq(#links, 2)
    eq(links[1].title, "Star Wars: The Acolyte")
    eq(links[2].title, "The High Republic: Light of the Jedi")
end)

test("toBlocks cites and kinds", function()
    local b = wookhtml.toBlocks(
        "<h2>H</h2><p>A<sup id=\"x\" class=\"reference\"><a href=\"#cite_note-X-1\">"
        .. "<span>&#91;</span>1<span>&#93;</span></a></sup> b"
        .. "<sup class=\"reference\"><a href=\"#cite&#95;note-Y-2\">[2]</a></sup>"
        .. "<sup class=\"reference\"><a href=\"#cite_note-X-1\">[1]</a></sup></p>"
        .. "<ul><li>I<sup class=\"reference\"><a href=\"#cite_note-Z-3\">[3]</a></sup></li><li>J</li></ul>")
    eq(#b, 4)
    eq(b[1].kind, "heading")
    eq(b[1].level, 2)
    eq(b[2].text, "A b")
    eq(table.concat(b[2].cites, ","), "cite_note-X-1,cite_note-Y-2")
    eq(b[3].text, "\226\128\162 I")
    eq(b[3].cites[1], "cite_note-Z-3")
    eq(#b[4].cites, 0)
end)

test("citationSources unit", function()
    local m = wookhtml.citationSources(
        "<ol class=\"references\"><li id=\"cite&#95;note-A-1\"><span class=\"mw-cite-backlink\">"
        .. "<a href=\"/wiki/Back\">x</a></span> <span class=\"reference-text\">"
        .. "<a href=\"/wiki/Databank\">D</a> <i><a href=\"/wiki/The_High_Republic:_Light_of_the_Jedi\">L</a></i>"
        .. " <a href=\"/wiki/232_BBY\">232 BBY</a></span></li>"
        .. "<li id=\"cite&#95;note-B-2\"><span class=\"reference-text\">"
        .. "<a href=\"/wiki/Foo_Bar\">F</a> <a href=\"/wiki/December_17\">d</a>"
        .. " <a href=\"/wiki/File:X\">f</a></span></li></ol>")
    eq(table.concat(m["cite_note-A-1"], "|"), "The High Republic: Light of the Jedi")
    eq(table.concat(m["cite_note-B-2"], "|"), "Foo Bar")
end)

test("avar_kriss_full blocks and sources", function()
    local html = fixture("avar_kriss_full.json")
    local t0 = os.clock()
    local blocks = wookhtml.toBlocks(html)
    local src = wookhtml.citationSources(html)
    print(string.format("       toBlocks+citationSources: %.1f ms", (os.clock() - t0) * 1000))
    local paras, cited, total, resolved = 0, 0, 0, 0
    for _, b in ipairs(blocks) do
        if b.kind == "para" then
            if not b.list then
                paras = paras + 1
                if #b.cites > 0 then cited = cited + 1 end
            end
            for _, id in ipairs(b.cites) do
                total = total + 1
                if src[id] and #src[id] > 0 then resolved = resolved + 1 end
            end
        end
    end
    print(string.format("       non-list paras with cites: %d/%d; cites resolved: %d/%d (%.1f%%)",
        cited, paras, resolved, total, 100 * resolved / math.max(total, 1)))
    assert(cited >= 0.8 * paras, "too few cited paragraphs")
    assert(resolved == total, "unresolved cite ids")
    local lotj, comic = false, false
    for _, titles in pairs(src) do
        for _, ti in ipairs(titles) do
            if ti == "The High Republic: Light of the Jedi" then lotj = true end
            if ti:find("^The High Republic %(2021%) %d+$") then comic = true end
        end
    end
    assert(lotj, "Light of the Jedi missing")
    assert(comic, "no The High Republic (2021) N")
    local parts = {}
    for i, b in ipairs(blocks) do
        parts[i] = b.text
    end
    eq(#blocks > 10, true)
    eq((wookhtml.toText(html):gsub("%s+", " ")), (table.concat(parts, " "):gsub("%s+", " ")))
end)

test("performance on 270 KB article", function()
    local html = fixture("starlight_beacon_full.json")
    local t0 = os.clock()
    for _ = 1, 10 do wookhtml.toText(html) end
    local per = (os.clock() - t0) / 10
    print(string.format("       toText: %.1f ms per run on %d KB", per * 1000, #html / 1024))
end)

-- wookapi needs a few KOReader modules: stub what parseImage/imageType touch.
package.preload["json"] = function() return json end
package.preload["logger"] = function() return { warn = function() end, dbg = function() end } end
package.preload["util"] = function()
    return { trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end }
end
local WookApi = require("wookapi")

local function properties(name)
    local f = assert(io.open("spec/fixtures/" .. name, "rb"))
    local data = f:read("*a")
    f:close()
    return assert(json.decode(data)).parse.properties
end

test("infobox portrait: Avar Kriss", function()
    local image = WookApi:parseImage(properties("avar_kriss_intro.json").infoboxes)
    assert(image, "no image found")
    has(image.url, "https://static.wikia.nocookie.net/starwars/images/")
    has(image.url, "/revision/latest/scale-to-width-down/600")
    eq(image.name ~= nil, true)
end)

test("species from the infobox", function()
    local species = WookApi:parseSpecies(properties("avar_kriss_intro.json").infoboxes)
    eq(species and species[1], "Human")
    eq(#species, 1)
    local hybrid = '[{"data":[{"type":"data","data":{"label":"Species","value":'
        .. '"<a href=\\"/wiki/Twi%27lek\\" title=\\"Twi&#039;lek\\">Twi\'lek</a>/'
        .. '<a href=\\"/wiki/Zabrak\\">Zabrak</a><sup class=\\"reference\\">'
        .. '<a href=\\"#cite_note-1\\">[1]</a></sup>"}}]}]'
    species = WookApi:parseSpecies(hybrid)
    eq(species[1], "Twi'lek")
    eq(species[2], "Zabrak")
    eq(#species, 2)
end)

test("infobox portrait: none without infobox", function()
    eq(WookApi:parseImage(nil), nil)
    eq(WookApi:parseImage("[]"), nil)
end)

test("image type sniffing", function()
    eq(WookApi:imageType("RIFF\0\0\0\0WEBPVP8 "), "webp")
    eq(WookApi:imageType("\137PNG\r\n\26\n...."), "png")
    eq(WookApi:imageType("\255\216\255\224"), "jpg")
    eq(WookApi:imageType("<!DOCTYPE html><html>Just a moment...</html>"), nil)
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
