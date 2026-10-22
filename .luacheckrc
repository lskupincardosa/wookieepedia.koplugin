-- Lint config. Run: luacheck .
std = "luajit"
unused_args = false
self = false
-- Globals that KOReader defines at runtime.
read_globals = {
    "G_reader_settings",
    "G_defaults",
}
exclude_files = { "tools/", "samples/" }
