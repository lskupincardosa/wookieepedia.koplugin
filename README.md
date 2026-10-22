# Wookieepedia for KOReader

A [KOReader](https://github.com/koreader/koreader) plugin that looks up Star Wars characters, planets and terms on [Wookieepedia](https://starwars.fandom.com) while you read. It works like KOReader's built-in Wikipedia lookup. It was made for *The High Republic*, which introduces a lot of new names.

> Status: **v0.1, early development.** Expect rough edges.

## Features

- **Wookieepedia** button in the text-selection popup. Select a name such as "Avar Kriss" and tap it.
- **Wookieepedia** button in the dictionary popup. Long-press a single word.
- **Search → Wookieepedia lookup** in the menu, for typing a name by hand.
- Shows the article's **intro only** by default, which is quick and keeps spoilers down. **Full article** is one tap away.
- Follows redirects (*Rey* → *Rey Skywalker*).
- Offers a pick list for disambiguation pages (*Mace*) and for selections that don't match a title exactly (*avar kriss*).
- Shows plain text for e-ink, without the infobox tables, citation marks, notice boxes or the *Behind the scenes*, *Appearances* and *Sources* sections.
- Downloads can be cancelled with a tap. If Wi-Fi is off, KOReader offers to turn it on.

**An internet connection is needed for every lookup.** Offline caching is planned (see the roadmap).

## Install

1. Download or clone this repository. The folder must be named `wookieepedia.koplugin`.
2. Copy the folder into KOReader's `plugins/` directory on your device:
   - Kobo: `.adds/koreader/plugins/`
   - Kindle: `koreader/plugins/`
   - Desktop (macOS): `~/Library/Application Support/koreader/plugins/`
3. Restart KOReader.

Only the `*.lua` files are needed on the device. `spec/`, `tools/` and `samples/` are for development.

## Development

See [DEV.md](DEV.md) for the emulator setup on macOS, the edit/restart loop, logs and tests.

```sh
tools/run.sh       # launch the KOReader emulator with the test book
spec/run.sh        # run the unit tests
luacheck .         # lint
```

| File | Purpose |
|---|---|
| `_meta.lua` | Plugin name and description shown in KOReader |
| `main.lua` | UI: popup buttons, menu entry, result viewer, error messages |
| `wookapi.lua` | Requests to the Wookieepedia MediaWiki API and interpretation of responses |
| `wookhtml.lua` | Fast HTML → plain-text conversion for article content |

## Roadmap

- **Lookup cache:** store fetched articles on the device so lookups also work offline.
- **Spoiler shield:** use an article's appearance list and your reading order to hide content from books you haven't read yet.
- **Per-book codex:** collect every name you looked up in a book into a cast list.
- **Era tag:** show labels such as "High Republic" in the result header.
- **Galaxy map:** for planets, show the grid square (for example Coruscant, L-9) on a self-made galaxy grid.
- **Offline dictionary:** a StarDict dictionary generated from a Wookieepedia dump, for instant long-press lookups without Wi-Fi.

## License and attribution

- Plugin code: [GNU AGPL-3.0](LICENSE), the same license as KOReader.
- Article text comes from [Wookieepedia](https://starwars.fandom.com) and is licensed [CC BY-SA 3.0](https://creativecommons.org/licenses/by-sa/3.0/). The plugin shows the source and a link under every article.
- *A Princess of Mars* in `samples/` is in the public domain (Project Gutenberg).

This is a fan project, not affiliated with Lucasfilm, Disney or Fandom. Star Wars is a trademark of Lucasfilm Ltd.
