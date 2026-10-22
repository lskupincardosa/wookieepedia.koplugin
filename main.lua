--[[--
Wookieepedia lookup for KOReader.

LEARN: A plugin's main.lua returns a WidgetContainer subclass. KOReader
creates one instance per opened document (and one for the file browser),
and passes `self.ui` (ReaderUI or FileManager) to it.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local WookApi = require("wookapi")
local WookCache = require("wookcache")
local WookSpoiler = require("wookspoiler")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local T = require("ffi/util").template

local Wookieepedia = WidgetContainer:extend{
    name = "wookieepedia",
    is_doc_only = false, -- also load in the file browser, not only in an open book
}

function Wookieepedia:init()
    -- LEARN: our own settings file in koreader/settings/, separate from KOReader's.
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/wookieepedia.lua")
    self.cache = WookCache:new()

    -- LEARN: registering lets the menu call our addToMainMenu() below.
    self.ui.menu:registerToMainMenu(self)

    -- LEARN: self.ui.highlight only exists in the reader (not the file browser).
    -- Buttons are sorted by key, so "05_wookieepedia" lands next to "05_wikipedia".
    if self.ui.highlight then
        self.ui.highlight:addToHighlightDialog("05_wookieepedia", function(this)
            return {
                text = _("Wookieepedia"),
                callback = function()
                    local text = util.cleanupSelectedText(this.selected_text.text)
                    this:onClose()
                    self:lookup(text)
                end,
            }
        end)
    end

    -- Long-pressing a single word opens the dictionary popup; add a button there too.
    if self.ui.dictionary and self.ui.dictionary.addToDictButtons then
        self.ui.dictionary:addToDictButtons{
            id = "wookieepedia",
            text = _("Wookieepedia"),
            menu_text = _("Wookieepedia"),
            callback = function(dict_popup)
                local word = dict_popup.word
                dict_popup:onClose()
                self:lookup(word)
            end,
        }
    end
end

function Wookieepedia:spoilerShield()
    return self.settings:nilOrTrue("spoiler_shield")
end

-- LEARN: KOReader sends events to every widget, plugins included; a method
-- named on<EventName> handles it. ReaderReady fires once a book is open.
function Wookieepedia:onReaderReady()
    self:runDevHook()
    local props = self.ui.doc_props or {}
    local candidates = { props.title, props.display_title }
    if self.document and self.document.file then
        table.insert(candidates, (self.document.file:match("([^/]+)$")))
    end
    for _, title in ipairs(candidates) do
        local index, entry = WookSpoiler:findEntry(title, self.settings:readSetting("horizon_auto"))
        if index then
            -- Remembered, so lookups from the file browser or a side book use it too.
            logger.info("Wookieepedia: reading-order position", index, entry.label)
            self.settings:saveSetting("horizon_auto", index)
            self.settings:flush()
            return
        end
    end
    logger.dbg("Wookieepedia: book not in the reading order:", props.display_title)
end

-- Development hook (see DEV.md): WOOK_DEV_LOOKUP="Avar Kriss" [WOOK_DEV_FULL=1]
-- [WOOK_DEV_SHOT=/path/shot.png] runs a lookup after startup and saves a screenshot.
function Wookieepedia:runDevHook()
    local term = os.getenv("WOOK_DEV_LOOKUP")
    if not term then return end
    -- WOOK_DEV_MAP="Q-16" [WOOK_DEV_MAP_TAPS=1]: open the map instead, switching views by simulated taps.
    local map_grid = os.getenv("WOOK_DEV_MAP")
    UIManager:scheduleIn(1, function()
        if map_grid then
            local map = require("wookmap"):new{ title = term, location = { grid = map_grid } }
            UIManager:show(map)
            for _ = 1, tonumber(os.getenv("WOOK_DEV_MAP_TAPS") or "0") do map:onTap() end
            return
        end
        self:lookup(term, { full = os.getenv("WOOK_DEV_FULL") == "1" })
    end)
    local shot = os.getenv("WOOK_DEV_SHOT")
    if shot then
        UIManager:scheduleIn(tonumber(os.getenv("WOOK_DEV_SHOT_DELAY") or "6"), function()
            require("device").screen:shot(shot)
            logger.info("Wookieepedia: dev screenshot saved", shot)
        end)
    end
end

--- Position in the reading order: chosen in the menu, else the last recognised book.
function Wookieepedia:horizon()
    return self.settings:readSetting("horizon_manual") or self.settings:readSetting("horizon_auto")
end

function Wookieepedia:horizonLabel(index)
    local order = WookSpoiler:order()
    local entry = index and order and order.entries[index]
    return entry and entry.label or _("not set")
end

function Wookieepedia:horizonMenu()
    local order = WookSpoiler:order()
    local items = {
        {
            text_func = function()
                return T(_("Automatic (book you open): %1"),
                    self:horizonLabel(self.settings:readSetting("horizon_auto")))
            end,
            checked_func = function() return not self.settings:has("horizon_manual") end,
            radio = true,
            callback = function()
                self.settings:delSetting("horizon_manual")
                self.settings:flush()
            end,
            separator = true,
        },
    }
    for i, entry in ipairs(order and order.entries or {}) do
        table.insert(items, {
            text = T("%1. %2", i, entry.label),
            checked_func = function() return self.settings:readSetting("horizon_manual") == i end,
            radio = true,
            callback = function()
                self.settings:saveSetting("horizon_manual", i)
                self.settings:flush()
            end,
        })
    end
    return items
end

function Wookieepedia:addToMainMenu(menu_items)
    -- LEARN: the key must match the plugin name. "search" puts us in the
    -- search menu (magnifying-glass tab), next to Wikipedia lookup.
    menu_items.wookieepedia = {
        text = _("Wookieepedia"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text = _("Search Wookieepedia…"),
                callback = function() self:showSearchInput() end,
            },
            {
                text = _("Spoiler shield"),
                help_text = _([[Intros: only the first paragraph (usually who or what it is) is shown; the rest is one tap away.
Full articles: paragraphs sourced from books, comics or audio dramas after your position in the reading order are hidden. Films and TV are always shown.]]),
                checked_func = function() return self:spoilerShield() end,
                callback = function()
                    self.settings:saveSetting("spoiler_shield", not self:spoilerShield())
                    self.settings:flush()
                end,
            },
            {
                text_func = function()
                    return T(_("Reading-order position: %1"), self:horizonLabel(self:horizon()))
                end,
                help_text = _([[Everything before this entry of the High Republic reading order counts as read. It follows the book you open automatically; pick an entry to set it by hand.]]),
                enabled_func = function() return WookSpoiler:order() ~= nil end,
                sub_item_table_func = function() return self:horizonMenu() end,
            },
            {
                text_func = function()
                    local n = self.cache:count()
                    return T(N_("Saved articles: %1", "Saved articles: %1", n), n)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    UIManager:show(ConfirmBox:new{
                        text = _("Delete all saved Wookieepedia articles?\n"
                            .. "They will be downloaded again when you look them up."),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            self.cache:clear()
                            touchmenu_instance:updateItems()
                        end,
                    })
                end,
            },
        },
    }
end

function Wookieepedia:showSearchInput()
    local dialog
    dialog = InputDialog:new{
        title = _("Search Wookieepedia"),
        input_hint = _("e.g. Avar Kriss"),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local text = dialog:getInputText()
                    UIManager:close(dialog)
                    self:lookup(text)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Entry point for every lookup. Options:
---   full:    fetch the whole article instead of the intro
---   exact:   skip the search fallback (the title came from Wookieepedia itself)
---   refresh: ignore the saved copy and download again
function Wookieepedia:lookup(term, opts)
    term = util.trim(term or "")
    if term == "" then return end
    opts = opts or {}

    -- Saved copies are shown straight away: no Wi-Fi needed, no network traffic.
    if not opts.refresh then
        local entry = self.cache:lookup(term)
        if entry and entry.kind == "disambiguation" then
            return self:showChoices(T(_("%1 may refer to:"), entry.title), entry.options)
        end
        if entry and opts.full and entry.blocks then
            -- Wrapped: the spoiler filter may need to classify new sources online.
            return Trapper:wrap(function()
                self:showFull(entry, { from_cache = true })
            end)
        end
        if entry and not opts.full and entry.intro then
            return self:showArticle(entry, { from_cache = true })
        end
    end

    -- LEARN: Trapper:wrap runs the function in a coroutine, which is what lets
    -- dismissableRunInSubprocess() below wait for the download without freezing
    -- the UI, and lets the user tap to cancel it.
    Trapper:wrap(function()
        -- Offline? This asks to turn on Wi-Fi and calls us again once connected.
        if NetworkMgr:willRerunWhenOnline(function() self:lookup(term, opts) end) then
            return
        end
        self:doLookup(term, opts)
    end)
end

-- Runs the HTTP request in a subprocess. Returns body, or nil + error code.
function Wookieepedia:fetch(url, message)
    logger.dbg("Wookieepedia: GET", url)
    local completed, ok, body
    if jit.os == "OSX" then
        -- LEARN: on macOS a forked child of a GUI app can't use the network
        -- (Apple's Network framework segfaults "on child side of fork"), so the
        -- desktop emulator downloads in-process with a plain "loading" message.
        local info = InfoMessage:new{ text = message }
        UIManager:show(info)
        UIManager:forceRePaint()
        completed = true
        ok, body = WookApi:httpGet(url, 20, 60)
        UIManager:close(info)
    else
        completed, ok, body = Trapper:dismissableRunInSubprocess(function()
            return WookApi:httpGet(url, 20, 60)
        end, message)
    end
    if not completed then
        return nil, "cancelled"
    end
    if not ok then
        -- A subprocess that died returns nothing at all.
        return nil, body or "network"
    end
    return body
end

function Wookieepedia:doLookup(term, opts, aliases)
    aliases = aliases or { term }
    local body, err = self:fetch(WookApi:parseUrl(term, opts.full),
        T(_("Looking up %1 on Wookieepedia…"), term))
    if not body then
        return self:showError(err)
    end
    local result = WookApi:interpretParse(body, opts.full)
    if result.kind == "article" then
        if not opts.full and result.text == "" then
            -- Some articles have nothing but an infobox before the first heading.
            return self:doLookup(result.title, { full = true, exact = true }, aliases)
        end
        local entry = self.cache:put({
            kind = "article",
            title = result.title,
            url = result.url,
            location = result.location,
            intro = result.text,
            blocks = result.blocks,
            sources = result.sources,
        }, aliases)
        if opts.full then
            self:showFull(entry, { redirected_from = result.redirected_from })
        else
            self:showArticle(entry, { redirected_from = result.redirected_from })
        end
    elseif result.kind == "disambiguation" then
        self.cache:put({ kind = "disambiguation", title = result.title, options = result.options }, aliases)
        self:showChoices(T(_("%1 may refer to:"), result.title), result.options)
    elseif result.kind == "missing" then
        if opts.exact then
            return self:showNotFound(term)
        end
        self:searchFallback(term)
    else
        self:showError(result.message)
    end
end

-- Selected text often isn't an exact title ("avar kriss", "Kriss's"): search instead.
function Wookieepedia:searchFallback(term)
    local body, err = self:fetch(WookApi:searchUrl(term), T(_("Searching Wookieepedia for %1…"), term))
    if not body then
        return self:showError(err)
    end
    local titles = WookApi:interpretSearch(body)
    if not titles then
        return self:showError("invalid response")
    end
    if #titles == 0 then
        return self:showNotFound(term)
    end
    if titles[1]:lower() == term:lower() then
        -- Remember the selected spelling too, so next time it's an offline hit.
        return self:doLookup(titles[1], { exact = true }, { term, titles[1] })
    end
    local options = {}
    for _, title in ipairs(titles) do
        table.insert(options, { title = title, text = title })
    end
    self:showChoices(T(_("No article named %1. Did you mean:"), term), options)
end

-- "Outer Rim Territories · Savareen sector · Grid Q-16"
local function locationLine(location)
    if not location then return end
    local parts = {}
    for _, field in ipairs{ "region", "sector", "system" } do
        if location[field] and location[field][1] then
            table.insert(parts, table.concat(location[field], ", "))
        end
    end
    if location.grid then
        table.insert(parts, T(_("Grid %1"), location.grid))
    end
    if #parts == 0 then return end
    return table.concat(parts, " · ")
end

--- opts: full, from_cache, redirected_from, whole_intro (bypass the spoiler shield once)
function Wookieepedia:showArticle(entry, opts)
    local parts = {}
    if opts.redirected_from then
        table.insert(parts, T(_("(Redirected from %1)"), opts.redirected_from))
    end
    local location = locationLine(entry.location)
    if location then
        table.insert(parts, "⌖ " .. location)
    end

    local text = opts.text or entry.intro or ""
    local shielded = false
    if not opts.full and not opts.whole_intro and self:spoilerShield() then
        local first, rest = text:match("^(.-)\n\n(.*)$")
        if first and rest ~= "" then
            text = first .. "\n\n" .. _("[More of the intro is hidden by the spoiler shield.]")
            shielded = true
        end
    end
    table.insert(parts, text)

    -- Wookieepedia text is CC BY-SA: attribution is required wherever we show it.
    table.insert(parts, "———")
    local credit = T(_("Text from Wookieepedia, licensed CC BY-SA 3.0.\n%1"), entry.url)
    if opts.from_cache and entry.saved then
        credit = credit .. "\n" .. T(_("Saved on %1."), os.date("%Y-%m-%d", entry.saved))
    end
    table.insert(parts, credit)

    local viewer
    local function reopen(new_opts)
        return function()
            UIManager:close(viewer)
            new_opts.exact = true
            self:lookup(entry.title, new_opts)
        end
    end
    local row = {}
    if shielded then
        table.insert(row, { text = _("Show more"), callback = function()
            UIManager:close(viewer)
            self:showArticle(entry, { from_cache = opts.from_cache, whole_intro = true })
        end })
    end
    if opts.hidden_count and opts.hidden_count > 0 then
        table.insert(row, { text = _("Show hidden"), callback = function()
            UIManager:show(ConfirmBox:new{
                text = T(N_("Show 1 hidden paragraph? It comes from a book later in your reading order.",
                    "Show %1 hidden paragraphs? They come from books later in your reading order.",
                    opts.hidden_count), opts.hidden_count),
                ok_text = _("Show"),
                ok_callback = function()
                    UIManager:close(viewer)
                    self:showFull(entry, { from_cache = opts.from_cache, unfiltered = true })
                end,
            })
        end })
    end
    if not opts.full then
        table.insert(row, { text = _("Full article"), callback = reopen{ full = true } })
    end
    if entry.location and entry.location.grid then
        table.insert(row, { text = _("Map"), callback = function()
            require("wookmap"):show(entry.title, entry.location)
        end })
    end
    if opts.from_cache then
        table.insert(row, { text = _("Refresh"), callback = reopen{ full = opts.full, refresh = true } })
    end
    viewer = TextViewer:new{
        title = entry.title,
        text = table.concat(parts, "\n\n"),
        buttons_table = #row > 0 and { row } or {},
        add_default_buttons = true, -- Find, go to top/bottom, Close
        justified = false,
    }
    UIManager:show(viewer)
end

--- Classifies every source the article cites (film/TV, book/comic, neutral).
--- Known titles come from the cache; the rest costs one request per 50 titles.
--- Offline, unknown sources count as books: better hide too much than spoil.
function Wookieepedia:sourceKinds(entry)
    local kinds = {}
    local known = self.cache:kinds()
    local unknown, seen = {}, {}
    for _, titles in pairs(entry.sources or {}) do
        for _, title in ipairs(titles) do
            if known[title] then
                kinds[title] = known[title]
            elseif not seen[title] then
                seen[title] = true
                table.insert(unknown, title)
            end
        end
    end
    if #unknown > 0 and NetworkMgr:isOnline() then
        local fetched = {}
        for i = 1, #unknown, 50 do
            local batch = { unpack(unknown, i, math.min(i + 49, #unknown)) }
            local body = self:fetch(WookApi:categoriesUrl(batch), _("Checking sources for spoilers…"))
            local categories = body and WookApi:interpretCategories(body)
            if not categories then break end
            for _, title in ipairs(batch) do
                if categories[title] then
                    fetched[title] = WookSpoiler:classify(categories[title])
                end
            end
        end
        self.cache:saveKinds(fetched)
        for title, kind in pairs(fetched) do kinds[title] = kind end
    end
    for _, title in ipairs(unknown) do
        kinds[title] = kinds[title] or "story"
    end
    return kinds
end

--- Full article, with the spoiler filter applied unless it's off or opts.unfiltered.
--- Must run inside Trapper:wrap (sourceKinds may download).
function Wookieepedia:showFull(entry, opts)
    opts.full = true
    local blocks = entry.blocks or {}
    if opts.unfiltered or not self:spoilerShield() then
        for _, block in ipairs(blocks) do block.hidden = nil end
        opts.text = WookSpoiler:render(blocks, function() return "" end)
        return self:showArticle(entry, opts)
    end
    local read, current = WookSpoiler:readSets(self:horizon())
    WookSpoiler:filter(blocks, entry.sources or {}, self:sourceKinds(entry), read, current)
    opts.text, opts.hidden_count = WookSpoiler:render(blocks, function(n)
        return T(N_("[1 paragraph hidden: it comes from a book later in your reading order.]",
            "[%1 paragraphs hidden: they come from books later in your reading order.]", n), n)
    end)
    if opts.hidden_count > 0 then
        opts.text = T(_("Reading-order position: %1"), self:horizonLabel(self:horizon())) .. "\n\n" .. opts.text
    end
    self:showArticle(entry, opts)
end

-- options: array of { title =, text = }
function Wookieepedia:showChoices(title, options)
    if #options == 0 then
        return self:showError("empty list")
    end
    local menu
    local items = {}
    for _, option in ipairs(options) do
        table.insert(items, {
            text = option.text,
            callback = function()
                UIManager:close(menu)
                self:lookup(option.title, { exact = true })
            end,
        })
    end
    menu = Menu:new{
        title = title,
        item_table = items,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        multilines_show_more_text = true,
    }
    UIManager:show(menu)
end

function Wookieepedia:showNotFound(term)
    UIManager:show(InfoMessage:new{
        text = T(_("No Wookieepedia article found for:\n%1"), term),
    })
end

local error_messages = {
    timeout = _("Wookieepedia didn't answer in time. Please try again."),
    network = _("Couldn't reach Wookieepedia. Check your Wi-Fi connection."),
}

function Wookieepedia:showError(err)
    if err == "cancelled" then return end
    logger.warn("Wookieepedia: lookup failed:", err)
    UIManager:show(InfoMessage:new{
        text = error_messages[err] or T(_("Wookieepedia lookup failed:\n%1"), tostring(err)),
    })
end

return Wookieepedia
