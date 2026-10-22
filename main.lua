-- LEARN: A plugin's main.lua returns a WidgetContainer subclass. KOReader
-- creates one instance per opened document (and one for the file browser),
-- and passes `self.ui` (ReaderUI or FileManager) to it.
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local Wookieepedia = WidgetContainer:extend{
    name = "wookieepedia",
    is_doc_only = false, -- also load in the file browser, not only in an open book
}

function Wookieepedia:init()
    -- LEARN: registering lets the menu call our addToMainMenu() below.
    self.ui.menu:registerToMainMenu(self)
end

function Wookieepedia:addToMainMenu(menu_items)
    -- LEARN: the key must match the plugin name; without an entry in
    -- KOReader's menu_order files the item lands under "More tools".
    menu_items.wookieepedia = {
        text = _("Wookieepedia"),
        sorting_hint = "search",
        callback = function()
            UIManager:show(InfoMessage:new{
                text = _("Hello from Wookieepedia!"),
            })
        end,
    }
end

return Wookieepedia
