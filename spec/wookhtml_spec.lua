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

test("performance on 270 KB article", function()
    local html = fixture("starlight_beacon_full.json")
    local t0 = os.clock()
    for _ = 1, 10 do wookhtml.toText(html) end
    local per = (os.clock() - t0) / 10
    print(string.format("       toText: %.1f ms per run on %d KB", per * 1000, #html / 1024))
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
