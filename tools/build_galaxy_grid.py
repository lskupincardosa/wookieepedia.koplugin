#!/usr/bin/env python3
"""Turn data/planets.json (from tools/build_planet_grid.py) into
data/galaxy_grid.lua, the small table the map widget draws.

Everything is derived from the grid squares and regions Wookieepedia lists
for canon planets; no official map is used:

- raster: each grid square is split into SUB x SUB subcells. A subcell gets
  the region with the most planets nearby (Gaussian-weighted), so regions
  become smooth shapes instead of blocky squares. Subcells with too few
  planets nearby stay empty (unexplored / no data).
- labels: for each region, the point deepest inside it, for its name.
- landmarks: well-known planets drawn as dots for orientation.
- planets: per square, the planet names with the longest articles, for the
  zoomed-in view.

Run after build_planet_grid.py (and add_planet_sizes.py, for better ranking)."""
import collections, json, math, pathlib

DATA = pathlib.Path(__file__).resolve().parent.parent / "data"
SUB = 8             # subcells per grid square, per axis
SIGMA = 0.85        # smoothing radius, in grid squares
MIN_WEIGHT = 0.30   # below this much nearby planet weight, a subcell stays empty
PLANETS_PER_SQUARE = 6

MAIN = {  # Wookieepedia spelling -> map region (the concentric rings)
    "Deep Core": "Deep Core", "Core Worlds": "Core Worlds", "Colonies": "Colonies",
    "Inner Rim": "Inner Rim", "Inner Rim Territories": "Inner Rim",
    "Expansion Region": "Expansion Region",
    "Mid Rim": "Mid Rim", "Mid Rim Territories": "Mid Rim",
    "Outer Rim": "Outer Rim Territories", "Outer Rim Territories": "Outer Rim Territories",
}
ORDER = ["Deep Core", "Core Worlds", "Colonies", "Inner Rim", "Expansion Region", "Mid Rim",
         "Outer Rim Territories"]
SHORT = {"Outer Rim Territories": "Outer Rim", "Expansion Region": "Expansion Reg."}
LANDMARKS = ["Coruscant", "Tatooine", "Naboo", "Hoth", "Kashyyyk", "Mustafar", "Jakku",
             "Mandalore", "Lothal", "Scarif", "Kessel", "Dathomir", "Exegol", "Dagobah"]

planets = json.loads((DATA / "planets.json").read_text())
cols = [chr(c) for c in range(ord(min(p["col"] for p in planets)), ord(max(p["col"] for p in planets)) + 1)]
rmin, rmax = min(p["row"] for p in planets), max(p["row"] for p in planets)
ncols, nrows = len(cols), rmax - rmin + 1

# Region votes per square (first listed main region of each planet).
votes = collections.defaultdict(collections.Counter)
by_square = collections.defaultdict(list)
for p in planets:
    ci, ri = ord(p["col"]) - ord(cols[0]), p["row"] - rmin
    by_square[(ci, ri)].append(p)
    for r in p["region"]:
        if r in MAIN:
            votes[(ci, ri)][MAIN[r]] += 1
            break

# Smooth raster.
W, H = ncols * SUB, nrows * SUB
reach = int(math.ceil(3 * SIGMA))
grid = [[None] * W for _ in range(H)]
for y in range(H):
    for x in range(W):
        cx, cy = (x + 0.5) / SUB, (y + 0.5) / SUB  # position in square units
        score = collections.Counter()
        total = 0.0
        for ci in range(int(cx) - reach, int(cx) + reach + 1):
            for ri in range(int(cy) - reach, int(cy) + reach + 1):
                v = votes.get((ci, ri))
                if not v:
                    continue
                d2 = (ci + 0.5 - cx) ** 2 + (ri + 0.5 - cy) ** 2
                w = math.exp(-d2 / (2 * SIGMA * SIGMA))
                for region, n in v.items():
                    score[region] += w * n
                    total += w * n
        if total >= MIN_WEIGHT:
            grid[y][x] = score.most_common(1)[0][0]

codes = {r: str(i + 1) for i, r in enumerate(ORDER)}
raster = ["".join(codes[c] if c else "." for c in row) for row in grid]

# Label anchor per region: the subcell deepest inside it, i.e. farthest from any
# other region, via a breadth-first distance transform. Horizontal steps cost
# half, since labels are wide.
labels = []
for region in ORDER:
    INF = float("inf")
    dist = [[0 if grid[y][x] != region else INF for x in range(W)] for y in range(H)]
    if not any(d == INF for row in dist for d in row):
        continue
    # Two-pass chamfer distance (cheap, good enough for picking a label spot).
    for y in range(H):
        for x in range(W):
            if dist[y][x]:
                if x > 0: dist[y][x] = min(dist[y][x], dist[y][x - 1] + 0.5)
                if y > 0: dist[y][x] = min(dist[y][x], dist[y - 1][x] + 1)
            if dist[y][x] == INF and (x == 0 or y == 0): dist[y][x] = 1
    for y in range(H - 1, -1, -1):
        for x in range(W - 1, -1, -1):
            if dist[y][x]:
                if x < W - 1: dist[y][x] = min(dist[y][x], dist[y][x + 1] + 0.5)
                if y < H - 1: dist[y][x] = min(dist[y][x], dist[y + 1][x] + 1)
    best = max(((dist[y][x], x, y) for y in range(H) for x in range(W) if grid[y][x] == region))
    labels.append((region, best[1] + 0.5, best[2] + 0.5))

by_title = {p["title"]: p for p in planets}
landmarks = [(n, by_title[n]["grid"]) for n in LANDMARKS if n in by_title]

def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

out = ["-- Generated by tools/build_galaxy_grid.py from Wookieepedia planet infoboxes. Do not edit.",
       "return {",
       "    cols = { " + ", ".join(lua_str(c) for c in cols) + " },",
       f"    rows_min = {rmin},", f"    rows_max = {rmax},",
       f"    sub = {SUB}, -- raster subcells per grid square",
       "    regions = { " + ", ".join(lua_str(r) for r in ORDER) + " }, -- raster codes 1..n, '.' = no data",
       "    raster = {"]
out += [f"        {lua_str(row)}," for row in raster]
out += ["    },", "    labels = {"]
out += [f"        {{ region = {lua_str(r)}, text = {lua_str(SHORT.get(r, r))}, x = {x:g}, y = {y:g} }},"
        for r, x, y in labels]
out += ["    },", "    landmarks = {"]
out += [f"        {{ name = {lua_str(n)}, grid = {lua_str(g)} }}," for n, g in landmarks]
out += ["    },", "    planets = { -- per square, longest articles first"]
def listable(title):
    # Skip catalogue numbers and placeholder entries in the close-up lists.
    return not title.isdigit() and not title.lower().startswith("unidentified")

for (ci, ri), ps in sorted(by_square.items(), key=lambda kv: (kv[0][1], kv[0][0])):
    ps = sorted((p for p in ps if listable(p["title"])), key=lambda p: (-p.get("size", 0), p["title"]))
    if not ps:
        continue
    names = ", ".join(lua_str(p["title"]) for p in ps[:PLANETS_PER_SQUARE])
    out.append(f"        [{lua_str(cols[ci] + '-' + str(ri + rmin))}] = {{ n = {len(ps)}, {names} }},")
out += ["    },", "}", ""]
(DATA / "galaxy_grid.lua").write_text("\n".join(out))

print(f"{ncols}x{nrows} squares, raster {W}x{H}, {len(labels)} labels, {len(landmarks)} landmarks")
sym = {"1": "@", "2": "#", "3": "%", "4": "+", "5": "=", "6": "-", "7": ".", ".": " "}
for row in raster[::SUB // 2]:
    print("".join(sym[c] for c in row[::SUB // 2]))
