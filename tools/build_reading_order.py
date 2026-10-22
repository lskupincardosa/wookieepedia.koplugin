#!/usr/bin/env python3
"""Build data/reading_order.lua: the High Republic main-story reading order,
resolved to Wookieepedia page titles (plus title variants to recognise the
open ebook, including German Jedipedia titles).

Usage: tools/build_reading_order.py [path/to/hr_reading_order.js]

Input is the `const DATA = [...]` literal from the r/Highrepublic wiki
reading order (treated as data only, parsed with a regex transform to JSON).
Every resolved title is verified against the Wookieepedia API; anything
unresolved is reported on stderr and the script exits non-zero.
"""
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

API = "https://starwars.fandom.com/api.php"
DE_API = "https://www.jedipedia.net/w/api.php"
UA = "wookieepedia.koplugin-data/0.1 (+https://github.com/koreader/koreader)"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "data", "reading_order.lua")
DEFAULT_IN = ("/private/tmp/claude-501/-Users-lucas-Downloads/442fa01e-a774-4207-"
              "be97-7b7b76d342ec/scratchpad/hr_reading_order.js")

# Comic series -> (issue page pattern, series page, issue count or None for ongoing)
ONGOING = {
    "The High Republic (2021)": ("The High Republic (2021) {n}", "Star Wars: The High Republic (2021)"),
    "The High Republic (2022)": ("The High Republic (2022) {n}", "Star Wars: The High Republic (2022)"),
    "The High Republic (2023)": ("The High Republic (2023) {n}", "Star Wars: The High Republic (2023)"),
}
# Miniseries: input title -> (issue pattern, series page, number of issues)
MINI = {
    "Trail of Shadows": ("The High Republic: Trail of Shadows {n}",
                         "Star Wars: The High Republic: Trail of Shadows", 5),
    "Eye of the Storm": ("The High Republic: Eye of the Storm {n}",
                         "Star Wars: The High Republic: Eye of the Storm", 2),
    "The Blade": ("The High Republic — The Blade {n}",
                  "Star Wars: The High Republic — The Blade", 4),
    "Shadows of Starlight": ("The High Republic – Shadows of Starlight {n}",
                             "Star Wars: The High Republic – Shadows of Starlight", 4),
    "Echoes of Fear": ("The High Republic Adventures – Echoes of Fear {n}",
                       "Star Wars: The High Republic Adventures – Echoes of Fear", 4),
    "Fear of the Jedi": ("The High Republic – Fear of the Jedi {n}",
                         "Star Wars: The High Republic – Fear of the Jedi", 5),
}
# Collected volumes (trade paperbacks) named in the input: Marvel Vol. N -> page
TPB = {
    "Marvel's The High Republic Vol. 1: There Is No Fear": "Star Wars: The High Republic Vol. 1 – There is No Fear",
    "Marvel's The High Republic Vol. 2: Heart of the Drengir": "Star Wars: The High Republic Vol. 2 – The Heart of Drengir",
    "Marvel's The High Republic Vol. 2: Shadow of the Nihil": "Star Wars: The High Republic Vol. 2 – The Heart of Drengir",
    "Marvel's The High Republic Vol. 3: Jedi's End": "Star Wars: The High Republic Vol. 3 – Jedi's End",
    "The High Republic (2023) Vol. 1: Children of the Storm": "Star Wars: The High Republic Phase III Vol. 1 – Children of the Storm",
    "The High Republic (2023) Vol. 2: The Hunted": "Star Wars: The High Republic Phase III Vol. 2 – The Hunted",
}
# German Jedipedia pages whose English interlanguage link is missing; they are
# accepted only if the page's infobox "Originaltitel" equals the English title.
DE_HINT = {
    "Shadows of Starlight": "Im Schatten der Starlight",
    "Path of Vengeance": "Der Pfad der Rache",
}
DE_CATS = ["Kategorie:Die Hohe Republik", "Kategorie:Die Hohe Republik (Marvel)",
           "Kategorie:Die Hohe Republik - Abenteuer"]
ONGOING_ONLY = {"The High Republic (2022)"}
SERIES_NAMES = ["The High Republic", "Die Hohe Republik", "High Republic"]
MARVEL_VOL = re.compile(r"^Marvel's The High Republic Vol\. \d+:")

requests_made = 0
problems = []


def api(_base=API, **params):
    """One API request (1 s politeness delay), following continuation."""
    global requests_made
    params.update(format="json", formatversion=2, redirects=1)
    merged = {"pages": {}, "redirects": [], "members": [], "wikitext": ""}
    cont = {}
    while True:
        time.sleep(1)
        url = _base + "?" + urllib.parse.urlencode({**params, **cont})
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        requests_made += 1
        with urllib.request.urlopen(req, timeout=60) as r:
            data = json.load(r)
        q = data.get("query", {})
        merged["redirects"] += q.get("redirects", [])
        merged["members"] += q.get("categorymembers", [])
        if "parse" in data:
            merged["wikitext"] = data["parse"]["wikitext"]
        for p in q.get("pages", []):
            m = merged["pages"].setdefault(p["title"], {"title": p["title"], "missing": p.get("missing", False),
                                                        "categories": [], "langlinks": []})
            m["categories"] += [c["title"] for c in p.get("categories", [])]
            m["langlinks"] += [(l["lang"], l["title"]) for l in p.get("langlinks", [])]
        if "continue" not in data:
            return merged
        cont = data["continue"]


def lookup(titles, langlinks=False):
    """Batch (<=50) lookup. Returns {requested title: page dict or None}."""
    titles = list(dict.fromkeys(titles))
    out = {}
    for i in range(0, len(titles), 50):
        chunk = titles[i:i + 50]
        extra = {"prop": "categories|langlinks", "lllang": "de", "lllimit": "max"} if langlinks \
            else {"prop": "categories"}
        res = api(action="query", titles="|".join(chunk), cllimit="max", clshow="!hidden", **extra)
        redir = {r["from"]: r["to"] for r in res["redirects"]}
        for t in chunk:
            tgt = t
            seen = 0
            while tgt in redir and seen < 5:
                tgt = redir[tgt]
                seen += 1
            p = res["pages"].get(tgt)
            out[t] = None if (p is None or p["missing"]) else p
    return out


def norm_en(t):
    """Wookieepedia title -> bare work name for comparison (series prefixes stripped)."""
    t = re.sub(r"^(Star Wars: )?The High Republic( Adventures)?( Phase III Vol\. \d+| Vol\. \d+)?\s*[:\u2013\u2014-]\s*",
               "", t)
    return re.sub(r"^the ", "", t.strip().lower())


def german_titles(rows):
    """Map entries to German Jedipedia pages, verified via the English langlink
    (or, for DE_HINT pages, via the infobox Originaltitel)."""
    members = []
    for c in DE_CATS:
        res = api(_base=DE_API, action="query", list="categorymembers", cmtitle=c, cmlimit=500, cmtype="page")
        members += [m["title"] for m in res["members"]]
    members = list(dict.fromkeys(members))
    de_en = {}
    for i in range(0, len(members), 50):
        res = api(_base=DE_API, action="query", titles="|".join(members[i:i + 50]),
                  prop="langlinks", lllang="en", lllimit="max")
        for t, pg in res["pages"].items():
            de_en[t] = [l[1] for l in pg["langlinks"]]
    for r in rows:
        r["de"] = []
        r["de_how"] = ""
        names = {norm_en(w) for w in r["wook"] if norm_en(w)}
        names.add(norm_en(r["title"]))
        if ":" in r["title"] and r["format"] == "comic":
            names.add(norm_en(r["title"].split(":", 1)[1]))
        if r["format"] == "comic" and r["title"] in ONGOING_ONLY:
            continue  # volume ranges of the 2022 series don't map to a German title
        hits = [de for de, ens in de_en.items() if any(norm_en(e) in names for e in ens)
                and not de.startswith("Die Hohe Republik")]
        if hits:
            r["de"] = hits
            r["de_how"] = "langlink en -> " + ", ".join(
                e for de in hits for e in de_en[de])
        elif r["title"] in DE_HINT:
            de = DE_HINT[r["title"]]
            res = api(_base=DE_API, action="parse", page=de, prop="wikitext", section=0)
            wt = res["wikitext"]
            m = re.search(r"Originaltitel=''?([^'\n|]+)''?", wt)
            if m and m.group(1).strip().lower() == r["title"].lower():
                r["de"] = [de]
                r["de_how"] = f"infobox Originaltitel = {m.group(1).strip()!r}"
            else:
                problems.append(f"German candidate {de!r} for {r['title']!r} not verified")
        elif r["format"] != "comic" or r["title"] in MINI or r["title"] in TPB:
            problems.append(f"no German title verified for {r['title']!r}")


def parse_data(path):
    text = open(path, encoding="utf-8").read()
    m = re.search(r"DATA\s*=\s*(\[.*\])\s*;", text, re.S)
    lit = m.group(1)
    # Quote bare object keys, but never touch text inside strings.
    lit = re.sub(r'("(?:[^"\\]|\\.)*")|([{,]\s*)([A-Za-z_]\w*)\s*:',
                 lambda mo: mo.group(1) or f'{mo.group(2)}"{mo.group(3)}":', lit)
    return json.loads(lit)


def flatten(data):
    rows = []
    for ph in data:
        for _wave, entries in ph["waves"]:
            for e in entries:
                e = list(e) + [""] * (6 - len(e))
                rows.append({"phase": ph["num"], "title": e[0], "issues": e[1], "author": e[2],
                             "format": e[3], "note": e[4], "fixed": e[5]})
    return rows


def parse_issues(s):
    m = re.match(r"#(\d+)(?:\s*[–-]\s*(\d+))?$", s)
    if not m:
        return None
    a = int(m.group(1))
    return list(range(a, int(m.group(2) or a) + 1))


def lq(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_IN
    rows = flatten(parse_data(src))

    # ---- comics: issue pages + series pages
    for r in rows:
        r["wook"] = []
        r["de"] = []
        if r["format"] != "comic":
            continue
        t = r["title"]
        series_key = "The High Republic (2021)" if MARVEL_VOL.match(t) else (
            re.sub(r" Vol\. \d+:.*$", "", t))
        if series_key in ONGOING:
            pat, series = ONGOING[series_key]
            nums = parse_issues(r["issues"])
            if not nums:
                problems.append(f"{t}: cannot parse issues {r['issues']!r}")
                continue
            r["series_page"] = series
        elif t in MINI:
            pat, series, count = MINI[t]
            nums = parse_issues(r["issues"]) if r["issues"] else list(range(1, count + 1))
            if not nums:
                problems.append(f"{t}: cannot parse issues {r['issues']!r}")
                continue
            r["series_page"] = series
        else:
            problems.append(f"comic {t!r}: unknown series")
            continue
        r["wook"] = [pat.format(n=n) for n in nums] + [r["series_page"]]
        if t in TPB:
            r["wook"].append(TPB[t])

    # ---- prose/audio/anthology: find the page
    prose = [r for r in rows if r["format"] != "comic"]
    cand = {}
    for r in prose:
        t = r["title"]
        cand[t] = [f"The High Republic: {t}", t, f"Star Wars: The High Republic: {t}"]
    res = lookup([c for cs in cand.values() for c in cs], langlinks=True)
    for r in prose:
        chosen = None
        for c in cand[r["title"]]:
            p = res[c]
            if not p:
                continue
            cats = " ".join(p["categories"]).lower()
            if "high republic" in cats and ("novel" in cats or "audio" in cats or "short stor" in cats
                                            or "anthology" in cats or "anthologies" in cats):
                chosen = p
                break
        if not chosen:
            problems.append(f"{r['title']!r}: no media page found among {cand[r['title']]}")
            continue
        r["wook"] = [chosen["title"]]
        r["cats"] = [c for c in chosen["categories"] if "High Republic" in c]

    # ---- German Jedipedia titles
    german_titles(rows)

    # ---- verify every comic title exists (and miniseries have no extra issue)
    comic_titles = [w for r in rows if r["format"] == "comic" for w in r["wook"]]
    extra = [MINI[k][0].format(n=MINI[k][2] + 1) for k in MINI]
    ver = lookup(comic_titles + extra)
    for t in comic_titles:
        p = ver[t]
        if not p:
            problems.append(f"comic page missing: {t}")
        elif p["title"] != t:
            problems.append(f"comic page {t!r} is a redirect to {p['title']!r}")
    for t in extra:
        if ver[t]:
            problems.append(f"miniseries has more issues than assumed: {t} exists")

    # ---- match variants
    generic = []
    for r in rows:
        base = r["title"]
        m = [base]
        if r["format"] == "comic":
            if ":" in base:
                m.append(base.split(":", 1)[1].strip())
            m.append(base.replace("Marvel's ", ""))
            if base in MINI:
                m += [w for w in r["wook"] if not re.search(r" \d+$", w)]
            elif base in TPB:
                m.append(TPB[base])
        else:
            m += r["wook"]
            m += [w.split("The High Republic: ", 1)[1] for w in r["wook"] if "The High Republic: " in w]
        for d in r["de"]:
            m += [d, re.sub(r" \((Roman|Comic)\)$", "", d)]
        seen, out = set(), []
        for x in m:
            if x and x.lower() not in seen:
                seen.add(x.lower())
                out.append(x)
        r["match"] = out
        for x in out:
            if len(x.split()) <= 2:
                generic.append((r["title"], x))

    # ---- write Lua
    def label(r):
        return r["title"] + (" " + r["issues"] if r["issues"] else "")

    lines = ["-- Generated by tools/build_reading_order.py from the High Republic main-story reading order "
             "(r/Highrepublic wiki). Do not edit.",
             "return {", '    name = "The High Republic",',
             "    series_names = { " + ", ".join(lq(x) for x in SERIES_NAMES) + " },", "    entries = {"]
    for r in rows:
        if not r["wook"]:
            continue
        lines.append(f'        {{ label = {lq(label(r))}, phase = {lq(r["phase"])}, format = {lq(r["format"])},')
        lines.append("          match = { " + ", ".join(lq(x) for x in r["match"]) + " },")
        if r["de"]:
            lines.append(f'          de = {lq(r["de"][0])},')
        lines.append("          wook = { " + ", ".join(lq(x) for x in r["wook"]) + " } },")
    lines += ["    },", "}", ""]
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

    # ---- report
    wook = {w for r in rows for w in r["wook"]}
    de = {d for r in rows for d in r["de"]}
    print(f"entries: {len(rows)}  distinct wook titles: {len(wook)}  German titles: {len(de)}  "
          f"requests: {requests_made}")
    for r in rows:
        if r["format"] != "comic":
            print(f"  {r['title']!r} -> {r['wook']} cats={r.get('cats')}")
    for r in rows:
        print(f"  DE {r['title']} {r['issues']} -> {r['de']} ({r['de_how']})")
    print("short (<=2 words) match variants:")
    for t, x in generic:
        print(f"  {t!r}: {x!r}")
    if problems:
        print("PROBLEMS:", file=sys.stderr)
        for p in problems:
            print("  " + p, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
