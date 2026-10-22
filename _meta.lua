-- LEARN: _meta.lua is read by KOReader's plugin loader *before* main.lua.
-- It only describes the plugin (shown in Tools > Plugin management).
local _ = require("gettext")
return {
    fullname = _("Wookieepedia"),
    description = _([[Look up Star Wars characters, planets and terms on Wookieepedia while reading.]]),
}
