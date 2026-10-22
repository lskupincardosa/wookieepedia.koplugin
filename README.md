# Wookieepedia for KOReader

A [KOReader](https://github.com/koreader/koreader) plugin that looks up Star Wars characters, planets and terms on [Wookieepedia](https://starwars.fandom.com) while you read. It works like KOReader's built-in Wikipedia lookup. It was made for *The High Republic*, which introduces a lot of new names.

> Status: **v0.1, early development.** Expect rough edges.

## Features

- **Wookieepedia** button in the text-selection popup. Select a name such as "Avar Kriss" and tap it.
- **Wookieepedia** button in the dictionary popup. Long-press a single word.
- **Search (🔍) → Wookieepedia** menu: search by typing, open the **Galaxy map**, toggle the spoiler shield, and manage saved articles.
- Shows the article's **intro only** by default, which is quick and keeps spoilers down. **Full article** is one tap away.
- Follows redirects (*Rey* → *Rey Skywalker*).
- Offers a pick list for disambiguation pages (*Mace*) and for selections that don't match a title exactly (*avar kriss*).
- Shows plain text for e-ink, without the infobox tables, citation marks, notice boxes or the *Behind the scenes*, *Appearances* and *Sources* sections.
- **Saved articles:** every article you open is stored on the device. Looking it up again works offline and uses no network. Use **Refresh** to update an article, and clear the saved articles in the menu.
- **Spoiler shield** (on by default), in two layers:
  - **Intros** show only their first paragraph, which usually says who or what it is. Wookieepedia intros often summarize a character's whole story, so the rest stays behind **Show more**.
  - **Full articles** hide every paragraph sourced from a book, comic or audio drama that comes later in your reading order. Wookieepedia cites the source of nearly every paragraph. Films and TV are always shown, and reference works (Databank, encyclopedias, magazines) don't count either way. The reading position follows the book you open (the High Republic main-story order from the r/Highrepublic wiki), or you can set it in the menu. Hidden parts appear as "[3 paragraphs hidden…]", and **Show hidden** reveals them after you confirm.
- **Location line and galaxy map** for planets: region, sector, system and grid square, plus a **Map** button. Tap the map to switch views:
  - **Galaxy:** the whole grid with region names, landmark planets and the planet ringed. The Unknown Regions in the west are dotted, because they are not one of the rings around the core.
  - **Close-up:** the 5×5 squares around the planet, with the best-known planets in each.
  - **Atlas** (optional): your own map image with the square marked (see DEV.md).
- Downloads can be cancelled with a tap. If Wi-Fi is off, KOReader offers to turn it on.

You need Wi-Fi only the first time you look something up. After that the article is saved on the device.

<img src="docs/map-example.png" width="45%" alt="Galaxy view for Hetzal Prime"> <img src="docs/map-closeup-example.png" width="45%" alt="Close-up view for Hetzal Prime">

The galaxy and close-up views are generated entirely from data: the grid squares and regions Wookieepedia lists for about 1,400 canon planets. Region shapes are smoothed from where their planets lie, and close-up lists rank planets by article length. No official map artwork is included. `tools/build_planet_grid.py` and `tools/add_planet_sizes.py` collect the data, and `tools/build_galaxy_grid.py` turns it into `data/galaxy_grid.lua`.

## Install

1. Download or clone this repository. The folder must be named `wookieepedia.koplugin`.
2. Copy the folder into KOReader's `plugins/` directory on your device:
   - Kobo: `.adds/koreader/plugins/`
   - Kindle: `koreader/plugins/`
   - Desktop (macOS): `~/Library/Application Support/koreader/plugins/`
3. Restart KOReader.

The device needs only the `*.lua` files and `data/galaxy_grid.lua` and `data/reading_order.lua`. `spec/`, `tools/`, `samples/`, `docs/` and `data/planets.json` are for development.

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
| `wookcache.lua` | Saved articles for offline lookups |
| `wookmap.lua` | Galaxy map screen |
| `wookspoiler.lua` | Spoiler filter: reading position, source classification, paragraph hiding |
| `data/reading_order.lua` | Generated High Republic reading order with Wookieepedia titles |
| `data/galaxy_grid.lua` | Generated region shading per grid square |

## Roadmap

- **More reading orders** for the spoiler shield (other eras, Legends).
- **Per-book codex:** collect every name you looked up in a book into a cast list.
- **Era tag:** show labels such as "High Republic" in the result header.
- **Galaxy map, level 2:** show nearby planets, and mark every planet that appears in the current book.
- **Offline dictionary:** a StarDict dictionary generated from a Wookieepedia dump, for instant long-press lookups without Wi-Fi.

## License and attribution

- Plugin code: [GNU AGPL-3.0](LICENSE), the same license as KOReader.
- Article text comes from [Wookieepedia](https://starwars.fandom.com) and is licensed [CC BY-SA 3.0](https://creativecommons.org/licenses/by-sa/3.0/). The plugin shows the source and a link under every article.
- *A Princess of Mars* in `samples/` is in the public domain (Project Gutenberg).

This is a fan project, not affiliated with Lucasfilm, Disney or Fandom. Star Wars is a trademark of Lucasfilm Ltd.
