--[[--
Spoiler filter for full articles.

Wookieepedia cites the source of almost every paragraph. A paragraph is
hidden when it cites a book, comic or audio drama the reader hasn't reached
yet in their reading order (data/reading_order.lua). Films and TV are always
safe; reference sites and dates don't count either way.

"Reached" means: earlier in the reading order than the book being read now.
The book being read now is unsafe too: it may spoil its own later chapters.
]]

local util = require("util")
local wookhtml = require("wookhtml")

local WookSpoiler = {}

local order_data
function WookSpoiler:order()
    if order_data == nil then
        local dir = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
        local ok, data = pcall(dofile, dir .. "/data/reading_order.lua")
        order_data = ok and type(data) == "table" and data or false
    end
    return order_data or nil
end

-- Lowercase, keep only letters/digits (incl. UTF-8 letters), single spaces.
local function normalize(s)
    s = s:lower():gsub("[%p%c]", " "):gsub("%s+", " ")
    return util.trim(s)
end

--- Finds the reading-order entry for a book title (from the ebook's metadata).
--- The longest matching variant wins, so "The Rising Storm" beats "Storm".
--- Short variants ("Convergence", "The Blade") only count when the title also
--- names the series, so an unrelated book can't move the reading position.
--- Split entries share their variants (Trail of Shadows #1–2, #3, #4–5): then
--- the first one at or after `hint` (the previous position) wins, since
--- reading moves forward. Returns index, entry or nil.
function WookSpoiler:findEntry(book_title, hint)
    local order = self:order()
    if not order or not book_title or book_title == "" then return end
    local haystack = " " .. normalize(book_title) .. " "
    local has_series = false
    for _, name in ipairs(order.series_names or { order.name, "star wars" }) do
        if haystack:find(" " .. normalize(name) .. " ", 1, true) then has_series = true end
    end
    if haystack:find(" star wars ", 1, true) then has_series = true end
    local best_len, candidates = 0, {}
    for i, entry in ipairs(order.entries) do
        local entry_len = 0
        for _, variant in ipairs(entry.match or {}) do
            local norm = normalize(variant)
            local _, words = norm:gsub("%S+", "")
            local needle = " " .. norm .. " "
            if #norm > 0 and (words > 2 or has_series) and haystack:find(needle, 1, true) then
                entry_len = math.max(entry_len, #needle)
            end
        end
        if entry_len > best_len then
            best_len, candidates = entry_len, { i }
        elseif entry_len > 0 and entry_len == best_len then
            table.insert(candidates, i)
        end
    end
    if #candidates == 0 then return end
    local best = candidates[1]
    for _, i in ipairs(candidates) do
        if hint and i >= hint then best = i break end
    end
    return best, order.entries[best]
end

--- Wookieepedia titles of everything before position `horizon` (read), and
--- of the entry at `horizon` (being read). A title shared by several entries
--- (a comic series page, a split volume) is read only once all of them are.
--- With no horizon nothing counts as read.
function WookSpoiler:readSets(horizon)
    local read, current = {}, {}
    local order = self:order()
    if not order or not horizon then return read, current end
    local last_index = {}
    for i, entry in ipairs(order.entries) do
        for _, title in ipairs(entry.wook or {}) do
            last_index[title] = i
            if i == horizon then current[title] = true end
        end
    end
    for title, i in pairs(last_index) do
        if i < horizon then read[title] = true end
    end
    return read, current
end

-- Category substrings, checked in this order. Reference works (encyclopedias,
-- magazines, timelines) are mostly cited for dates next to the story source,
-- so they don't count; otherwise harmless paragraphs would be hidden.
local SCREEN = { "films", "television series", "television episodes", "episodes" }
local NEUTRAL = { "reference", "magazine", "encyclopedia", "databank", "websites" }
local STORY = { "novels", "issues", "comics", "comic stor", "audio drama", "audiobook",
    "short stor", "antholog", "books", "manga", "webcomics" }

--- "screen" (film/TV: safe), "story" (book/comic/audio: needs to be read) or "neutral".
function WookSpoiler:classify(categories)
    local lower = {}
    for _, c in ipairs(categories or {}) do table.insert(lower, c:lower()) end
    for _, word in ipairs(SCREEN) do
        for _, c in ipairs(lower) do
            if c:find(word, 1, true) then return "screen" end
        end
    end
    for _, word in ipairs(NEUTRAL) do
        for _, c in ipairs(lower) do
            if c:find(word, 1, true) then return "neutral" end
        end
    end
    for _, word in ipairs(STORY) do
        for _, c in ipairs(lower) do
            if c:find(word, 1, true) then return "story" end
        end
    end
    return "neutral"
end

--[[--
Marks blocks (from wookhtml.toBlocks) as hidden.

    sources: note id -> { cited titles }   (wookhtml.citationSources)
    kinds:   title -> "screen" | "story" | "neutral"
    read, current: sets from readSets()

Returns the blocks with `hidden = true` set where needed. A paragraph without
citations shares the verdict of the paragraph before it; in the uncited lead,
only the first paragraph is shown. A heading is hidden
when any paragraph of its section is (headings like "Fall of Starlight" spoil).
]]
function WookSpoiler:filter(blocks, sources, kinds, read, current)
    local hidden_before = false
    local in_lead, lead_paras = true, 0
    for _, block in ipairs(blocks) do
        if block.kind == "heading" then in_lead = false end
        if block.kind == "para" then
            block.from_current = nil
            if in_lead and #(block.cites or {}) == 0 then
                -- The lead summarizes the whole story without citations, so we
                -- can't date it: keep only its first paragraph, as for intros.
                lead_paras = lead_paras + 1
                block.hidden = lead_paras > 1
            elseif block.cites and #block.cites > 0 then
                local unsafe = false
                for _, note in ipairs(block.cites) do
                    for _, title in ipairs(sources[note] or {}) do
                        if kinds[title] == "story" and not read[title] then
                            unsafe = true
                            block.from_current = block.from_current or current[title] or false
                        end
                    end
                end
                block.hidden = unsafe
            else
                block.hidden = hidden_before
            end
            if not in_lead then hidden_before = block.hidden end
        end
    end
    -- Headings: look ahead to the next heading of the same or a higher level.
    for i, block in ipairs(blocks) do
        if block.kind == "heading" then
            block.hidden = false
            for j = i + 1, #blocks do
                local b = blocks[j]
                if b.kind == "heading" and b.level <= block.level then break end
                if b.kind == "para" and b.hidden then
                    block.hidden = true
                    break
                end
            end
        end
    end
    return blocks
end

--- Joins blocks into text; each run of hidden blocks becomes one short notice.
--- Returns the text and the number of hidden paragraphs.
function WookSpoiler:render(blocks, notice_func)
    local out, run, total = {}, 0, 0
    local function flush()
        if run > 0 then table.insert(out, { kind = "para", text = notice_func(run) }) end
        total = total + run
        run = 0
    end
    for _, block in ipairs(blocks) do
        if block.hidden then
            if block.kind == "para" then run = run + 1 end
        else
            flush()
            table.insert(out, block)
        end
    end
    flush()
    return wookhtml.joinBlocks(out), total
end

return WookSpoiler
