# Developing wookieepedia.koplugin

The handoff planned a WSL setup. This machine is an Apple Silicon Mac, so the emulator runs natively on macOS instead.

## Layout

| What | Where |
|---|---|
| Plugin source (this repo) | `~/Developer/wookieepedia.koplugin` |
| KOReader emulator (nightly macOS arm64 build) | `~/Developer/koreader-app/KOReader.app` |
| KOReader source, for reading reference code (tag `v2026.07.1`) | `~/Developer/koreader-src` |
| KOReader user data (settings, history, plugins) | `~/Library/Application Support/koreader/` |
| Symlink that loads this plugin | `~/Library/Application Support/koreader/plugins/wookieepedia.koplugin` → this repo |

**Why this plugin directory?** The Mac launcher sets `KO_MULTIUSER`, so `frontend/datastorage.lua` puts the data dir at `~/Library/Application Support/koreader`. `frontend/pluginloader.lua` then scans two folders: the bundle's own `plugins/` and `<datadir>/plugins/`. The second folder is stored in `settings.reader.lua` as `extra_plugin_paths`. The debug log confirms both:

```
Looking for plugins in directory: plugins
Looking for plugins in directory: /Users/lucas/Library/Application Support/koreader/plugins/
RD loaded plugin wookieepedia at /Users/lucas/Library/Application Support/koreader/plugins//wookieepedia.koplugin
```

The user folder survives app updates. Never put the plugin inside `KOReader.app`.

**Why a nightly build?** Stable releases (v2026.07.1) ship no macOS build, and the Homebrew cask is Linux-only. Nightlies are attached to the GitHub release named `ota`. To update:

```sh
cd ~/Developer/koreader-app
gh release download ota --repo koreader/koreader -p 'koreader-macos-11.0-arm64-*' --clobber
rm -rf KOReader.app && 7zz x koreader-macos-*.7z && rm koreader-macos-*.7z
```

## The loop

```sh
tools/run.sh                 # opens samples/lookup-test.epub in debug mode
tools/run.sh path/to/book.epub
```

1. Edit the Lua files.
2. Quit KOReader (close the window, or menu → Exit) and run `tools/run.sh` again. KOReader loads plugins only at startup, so there is no hot reload. The menu's *Exit → Restart KOReader* also works.
3. Read the log in the terminal or in `logs/koreader.log`. Filter with `grep -i wookieepedia logs/koreader.log`.

### Emulator controls
- Click = tap. Click and hold, then drag = select text, which opens the highlight popup with the **Wookieepedia** button.
- Long-press a single word for the dictionary popup. It also has a **Wookieepedia** button.
- Top-of-screen click or `F1` = menu. The plugin's submenu is in the 🔍 (search) tab as **Wookieepedia**.
- `PgUp`/`PgDn` or arrow keys turn pages.

## Logs and crashes

- Desktop KOReader writes the log to **stdout/stderr**. That is why `tools/run.sh` tees it into `logs/koreader.log`.
- `crash.log` only exists on e-readers, where the device launcher redirects output into `koreader/crash.log`. Look there when testing on the real device.
- `-d` enables `logger.dbg(...)` output. Without it, only `info`/`warn`/`err` show up.
- Errors raised inside plugin event handlers are caught and logged with a stack trace, as `An error occurred while executing handler wookieepedia:...`.

## Tests and lint

```sh
spec/run.sh        # unit tests for the HTML→text module, run with KOReader's bundled LuaJIT
luacheck .         # lint (brew install luacheck); config in .luacheckrc
python3 tools/make_test_epub.py   # rebuild samples/lookup-test.epub
```

The fixtures in `spec/fixtures/` are real API responses. Refresh them with `tools/fetch_fixtures.sh` if Wookieepedia's markup changes.

## Test books

- `samples/lookup-test.epub`: self-written text with names covering each lookup case: normal article, redirect (*Rey*, *Kriss*), disambiguation (*Mace*, *Ben*), lowercase selection, and not found.
- `samples/a-princess-of-mars.epub`: a public-domain novel from Project Gutenberg, for general reading and UI testing.

## How the lookup works (v0.1)

1. `action=parse&page=<selection>&section=0&prop=text|properties&redirects=1` makes one request. It returns the lead section's HTML, resolves redirects (`parse.redirects`), flags disambiguation pages (`properties.disambiguation`), and reports missing pages (`error.code = "missingtitle"`).
2. Missing pages fall back to `list=search`. If the top hit matches case-insensitively, it opens directly. Otherwise a "Did you mean" list appears.
3. `wookhtml.lua` turns the HTML into plain text. It drops infoboxes, citation marks, notices and the *Behind the scenes*/*Appearances*/*Sources* sections.
4. **Full article** repeats step 1 without `section=0`.
5. `wookcache.lua` saves every result under `<koreader data>/wookieepedia/`, together with the selected spelling as an alias. Lookups check the saved copy first, so a repeat lookup is offline and instant. **Refresh** forces a new download.
6. Planet location data (region, sector, system, grid square) comes from `properties.infoboxes` in the same response, and costs no extra request.

### Spoiler filter

- **Full articles** are stored as blocks (headings and paragraphs). Each paragraph keeps its citation note ids, and `citationSources` maps each note to the cited work titles.
- **Each cited work** is classified once through its categories (one request per 50 titles) as `screen`, `story` or `neutral`. The result is cached in `<data>/wookieepedia/source_kinds.lua`. If a source is unknown while offline, it counts as `story`, which is the strict choice.
- **A paragraph is hidden** when it cites a `story` source that is not *read*. A source counts as read when every reading-order entry that lists it comes before the current position, so a comic series page shared by several entries counts only once all of them are read.
  - A paragraph without citations takes the verdict of the paragraph before it.
  - In the uncited lead, only the first paragraph is shown.
  - Headings are hidden when anything in their section is hidden.
- **The position** is detected in `onReaderReady` from the book title or file name, and remembered in `settings/wookieepedia.lua` (`horizon_auto`), or set by hand (`horizon_manual`).
  - Short match variants ("Convergence") count only when the title also contains "Star Wars" or the series name.
  - Split entries (Trail of Shadows #1–2, #3, #4–5) resolve to the first one at or after the previous position.

```sh
python3 tools/build_reading_order.py <reading-order.js>   # → data/reading_order.lua
```

The input is the `DATA` array of the High Republic collection from the Star Wars Bookshelf page.

### Galaxy map data

```sh
python3 tools/build_planet_grid.py    # ~3 min, 180 polite API requests → data/planets.json, data/grid_stats.txt
python3 tools/build_galaxy_grid.py    # → data/galaxy_grid.lua (+ ASCII preview)
```

Planets are pages that use `Template:CelestialBody`, are in a planet category and are in `Category:Canon articles`. Re-run the crawl occasionally as Wookieepedia grows.

Why not TextExtracts? Fandom doesn't have that extension (`prop=extracts` returns "Unrecognized value"). `pageprops.fandomdescription` exists, but it is cut off at about 520 characters and contains `[12]` reference marks.

Requests run in a subprocess through `Trapper:dismissableRunInSubprocess`, so the UI stays responsive and a tap cancels them. Offline handling uses `NetworkMgr:willRerunWhenOnline`. On the emulator, KOReader always considers itself online, so test offline errors on the device, or by turning off the Mac's Wi-Fi.
