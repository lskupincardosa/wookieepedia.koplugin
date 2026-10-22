#!/usr/bin/env python3
"""One-time script: collect the galactic grid square of every canon planet on Wookieepedia.

Stdlib only. Writes data/planets.json and data/grid_stats.txt in the repo.

Template: the planet infobox on Wookieepedia is Template:CelestialBody
(Template:Planet has no transclusions). CelestialBody also covers moons,
stars and so on, so planets are picked out by their planet categories
("Category:Planets in the ...", "Category:Planets with ...", "Category:Planet stubs").
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from html.parser import HTMLParser

API = "https://starwars.fandom.com/api.php"
UA = "wookieepedia.koplugin-data/0.1 (+https://github.com/koreader/koreader)"
TEMPLATE = "Template:CelestialBody"
CANON_CAT = "Category:Canon articles"  # the real name; "Canon_articles" normalises to this
REPO = "/Users/lucas/Developer/wookieepedia.koplugin"
OUT_DIR = os.path.join(REPO, "data")
GRID_RE = re.compile(r"^([A-Z])-(\d{1,2})$")
WANTED = {"grid square": "grid", "region": "region", "sector": "sector", "system": "system"}
SLEEP = 1.0
MAX_RETRIES = 6

request_count = 0  # every HTTP attempt, including retries


def api_get(params):
    """GET one API request with UA, maxlag, 1 s polite sleep, and backoff on 429/5xx."""
    global request_count
    query = dict(params)
    query.update({"format": "json", "formatversion": "2", "maxlag": "5"})
    url = API + "?" + urllib.parse.urlencode(query)
    attempt = 0
    while True:
        attempt += 1
        wait = min(2 ** attempt, 120)
        reason = None
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            request_count += 1
            with urllib.request.urlopen(req, timeout=60) as resp:
                data = json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code == 429 or e.code >= 500:
                reason = f"HTTP {e.code}"
                ra = e.headers.get("Retry-After") if e.headers else None
                if ra and ra.isdigit():
                    wait = int(ra)
            else:
                raise
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
            reason = f"network/parse error: {e}"
        else:
            err = data.get("error")
            if err and err.get("code") == "maxlag":
                reason = "maxlag"
                wait = 5
            elif err:
                raise RuntimeError(f"API error: {err}")
            else:
                time.sleep(SLEEP)
                return data

        if attempt >= MAX_RETRIES:
            raise RuntimeError(f"giving up after {attempt} attempts ({reason})")
        print(f"  retry {attempt} ({reason}), sleeping {wait}s", file=sys.stderr)
        time.sleep(wait)


class _ValueParser(HTMLParser):
    """Splits an infobox value into its list items (<li>), or into <br>-separated pieces.

    Nested lists are handled: each <li> gets its own entry, in document order.
    Entities are decoded by HTMLParser (convert_charrefs=True, same as html.unescape).
    """

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.items = []        # one slot per <li>, filled when it closes
        self.li_stack = []     # (slot index, text buffer) for currently open <li>s
        self.top = []          # text outside any <li>

    def _buf(self):
        return self.li_stack[-1][1] if self.li_stack else self.top

    def handle_starttag(self, tag, attrs):
        if tag == "li":
            self.items.append(None)
            self.li_stack.append((len(self.items) - 1, []))
        elif tag == "br":
            self._buf().append("\n")

    def handle_endtag(self, tag):
        if tag == "li" and self.li_stack:
            idx, buf = self.li_stack.pop()
            self.items[idx] = "".join(buf)

    def handle_data(self, data):
        self._buf().append(data)


def clean(s):
    s = re.sub(r"\[[^\[\]\n]{0,30}\]", "", s)  # citation marks like [4]
    return re.sub(r"\s+", " ", s).strip()


def html_to_values(raw):
    p = _ValueParser()
    p.feed(raw)
    p.close()
    for idx, buf in p.li_stack:  # unclosed <li> at end of value
        p.items[idx] = "".join(buf)
    chunks = [t for t in p.items if t is not None]
    if not chunks:
        chunks = ["".join(p.top)]
    values = []
    for chunk in chunks:
        for piece in chunk.split("\n"):
            v = clean(piece)
            if v:
                values.append(v)
    return values


def collect_fields(node, out):
    """Recursively walk portable-infobox nodes, gathering raw values per wanted label."""
    if isinstance(node, list):
        for child in node:
            collect_fields(child, out)
    elif isinstance(node, dict):
        data = node.get("data")
        if isinstance(data, list):
            collect_fields(data, out)
        elif isinstance(data, dict):
            label = data.get("label")
            value = data.get("value")
            if isinstance(label, str) and isinstance(value, str):
                key = WANTED.get(label.strip().lower())
                if key:
                    out.setdefault(key, []).append(value)
            if isinstance(value, list):  # group nodes
                collect_fields(value, out)


def is_planet(cats):
    return any(c.startswith("Category:Planets") or c == "Category:Planet stubs" for c in cats)


def dedupe(seq):
    seen, out = set(), []
    for x in seq:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out


def main():
    # 1. Enumerate all pages embedding the template, with props in the same request.
    base = {
        "action": "query",
        "generator": "embeddedin",
        "geititle": TEMPLATE,
        "geinamespace": "0",
        "geilimit": "50",
        "prop": "pageprops|categories",
        "ppprop": "infoboxes",
        "cllimit": "max",
    }
    pages = {}  # pageid -> merged entry (categories may arrive over several continuations)
    params = dict(base)
    batches = 0
    while True:
        data = api_get(params)
        batches += 1
        for pg in data.get("query", {}).get("pages", []):
            entry = pages.setdefault(pg["pageid"], {"title": pg["title"], "categories": [], "infoboxes": None})
            entry["categories"].extend(c["title"].replace("_", " ") for c in pg.get("categories", []))
            ib = pg.get("pageprops", {}).get("infoboxes")
            if ib is not None:
                entry["infoboxes"] = ib
        print(f"  batch {batches}: {len(pages)} pages so far", file=sys.stderr)
        cont = data.get("continue")
        if not cont:
            break
        params = dict(base)
        params.update(cont)
    print(f"Embedding pages (ns0) found: {len(pages)}", file=sys.stderr)

    # 2. Filter to canon, classify planets, extract fields.
    canon_total = 0
    planet_total = 0
    non_planet_canon = 0
    no_grid = 0
    json_errors = 0
    unparseable = []
    planets = []
    for pageid in sorted(pages):
        entry = pages[pageid]
        cats = dedupe(entry["categories"])
        if CANON_CAT not in cats:
            continue
        canon_total += 1
        if not is_planet(cats):
            non_planet_canon += 1
            continue
        planet_total += 1

        fields = {}
        ib_raw = entry["infoboxes"]
        if ib_raw is not None:
            try:
                ib = json.loads(ib_raw) if isinstance(ib_raw, str) else ib_raw
                collect_fields(ib, fields)
            except json.JSONDecodeError:
                json_errors += 1

        candidates = []
        for raw in fields.get("grid", []):
            candidates.extend(html_to_values(raw))
        match = None
        for cand in candidates:
            m = GRID_RE.match(cand)
            if m:
                match = (cand, m.group(1), int(m.group(2)))
                break
        if match is None:
            if candidates:
                unparseable.append(candidates[0])
            else:
                no_grid += 1
            continue

        grid, col, row = match
        lists = {}
        for key in ("region", "sector", "system"):
            vals = []
            for raw in fields.get(key, []):
                vals.extend(html_to_values(raw))
            lists[key] = dedupe(vals)
        planets.append({
            "title": entry["title"],
            "grid": grid,
            "col": col,
            "row": row,
            "region": lists["region"],
            "sector": lists["sector"],
            "system": lists["system"],
        })

    planets.sort(key=lambda p: p["title"])

    # 3. Write planets.json.
    os.makedirs(OUT_DIR, exist_ok=True)
    planets_path = os.path.join(OUT_DIR, "planets.json")
    with open(planets_path, "w", encoding="utf-8") as f:
        json.dump(planets, f, ensure_ascii=False, indent=2)
        f.write("\n")
    planets_size = os.path.getsize(planets_path)

    # 4. Stats.
    cols = Counter(p["col"] for p in planets)
    rows = Counter(p["row"] for p in planets)
    region_counter = Counter()
    for p in planets:
        region_counter.update(p["region"])
    lines = []
    lines.append(f"Template used: {TEMPLATE}")
    lines.append(f"Embedding pages (ns0) seen: {len(pages)}")
    lines.append(f"Canon pages (of those): {canon_total}")
    lines.append(f"Canon planets seen: {planet_total}")
    lines.append(f"Canon non-planet pages skipped (moons, stars, ...): {non_planet_canon}")
    lines.append(f"Canon planets with a valid grid: {len(planets)}")
    lines.append(f"Canon planets without a grid label: {no_grid}")
    lines.append(f"Canon planets with an unparseable grid: {len(unparseable)}")
    lines.append(f"Pages with an unreadable infobox JSON: {json_errors}")
    if planets:
        lines.append(f"Min column: {min(cols)}   Max column: {max(cols)}")
        lines.append(f"Min row: {min(rows)}   Max row: {max(rows)}")
    lines.append("")
    lines.append("Planets per column:")
    for c in sorted(cols):
        lines.append(f"  {c}  {cols[c]}")
    lines.append("")
    lines.append("Planets per row:")
    for r in sorted(rows):
        lines.append(f"  {r:>2}  {rows[r]}")
    lines.append("")
    lines.append("Top 20 region names:")
    for name, n in region_counter.most_common(20):
        lines.append(f"  {n:>4}  {name}")
    lines.append("")
    lines.append("Unparseable grid strings (up to 20):")
    for raw in unparseable[:20]:
        lines.append(f"  {raw!r}")
    stats_text = "\n".join(lines) + "\n"
    stats_path = os.path.join(OUT_DIR, "grid_stats.txt")
    with open(stats_path, "w", encoding="utf-8") as f:
        f.write(stats_text)

    print(stats_text)
    print(f"planets.json: {planets_size} bytes at {planets_path}")
    print(f"grid_stats.txt at {stats_path}")
    print(f"HTTP requests made (including retries): {request_count}")


if __name__ == "__main__":
    main()
