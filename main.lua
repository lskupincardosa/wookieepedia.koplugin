--[[--
Wookieepedia lookup for KOReader.

LEARN: A plugin's main.lua returns a WidgetContainer subclass. KOReader
creates one instance per opened document (and one for the file browser),
and passes `self.ui` (ReaderUI or FileManager) to it.
]]

local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local WookApi = require("wookapi")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Wookieepedia = WidgetContainer:extend{
    name = "wookieepedia",
    is_doc_only = false, -- also load in the file browser, not only in an open book
}

function Wookieepedia:init()
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

function Wookieepedia:addToMainMenu(menu_items)
    -- LEARN: the key must match the plugin name. "search" puts us in the
    -- search menu (magnifying-glass tab), next to Wikipedia lookup.
    menu_items.wookieepedia = {
        text = _("Wookieepedia lookup"),
        sorting_hint = "search",
        callback = function()
            self:showSearchInput()
        end,
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

--- Entry point for every lookup. `opts.full` fetches the whole article,
--- `opts.exact` skips the search fallback (the title came from Wookieepedia itself).
function Wookieepedia:lookup(term, opts)
    term = util.trim(term or "")
    if term == "" then return end
    opts = opts or {}
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
    local completed, ok, body = Trapper:dismissableRunInSubprocess(function()
        return WookApi:httpGet(url, 20, 60)
    end, message)
    if not completed then
        return nil, "cancelled"
    end
    if not ok then
        return nil, body
    end
    return body
end

function Wookieepedia:doLookup(term, opts)
    local body, err = self:fetch(WookApi:parseUrl(term, opts.full),
        T(_("Looking up %1 on Wookieepedia…"), term))
    if not body then
        return self:showError(err)
    end
    local result = WookApi:interpretParse(body)
    if result.kind == "article" then
        if not opts.full and result.text == "" then
            -- Some articles have nothing but an infobox before the first heading.
            return self:doLookup(result.title, { full = true, exact = true })
        end
        self:showArticle(result, opts.full)
    elseif result.kind == "disambiguation" then
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
        return self:doLookup(titles[1], { exact = true })
    end
    local options = {}
    for _, title in ipairs(titles) do
        table.insert(options, { title = title, text = title })
    end
    self:showChoices(T(_("No article named %1. Did you mean:"), term), options)
end

function Wookieepedia:showArticle(result, full)
    local parts = {}
    if result.redirected_from then
        table.insert(parts, T(_("(Redirected from %1)"), result.redirected_from))
    end
    table.insert(parts, result.text)
    -- Wookieepedia text is CC BY-SA: attribution is required wherever we show it.
    table.insert(parts, "———")
    table.insert(parts, T(_("Text from Wookieepedia, licensed CC BY-SA 3.0.\n%1"), result.url))

    local viewer
    local buttons = {}
    if not full then
        table.insert(buttons, {{
            text = _("Full article"),
            callback = function()
                UIManager:close(viewer)
                self:lookup(result.title, { full = true, exact = true })
            end,
        }})
    end
    viewer = TextViewer:new{
        title = result.title,
        text = table.concat(parts, "\n\n"),
        buttons_table = buttons,
        add_default_buttons = true, -- Find, go to top/bottom, Close
        justified = false,
    }
    UIManager:show(viewer)
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
