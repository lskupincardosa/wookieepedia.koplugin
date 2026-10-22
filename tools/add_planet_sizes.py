#!/usr/bin/env python3
"""Add an integer "size" field (article byte length) to every entry of data/planets.json.

Stdlib only. Queries the Wookieepedia MediaWiki API (prop=info, `length` field) in
batches of 50 titles, sleeping 1 s between requests and retrying with backoff on
429/5xx and on maxlag responses. Entries without a page get size 0 and are listed.
The file is rewritten in place, keeping order, fields and the existing formatting
(indent=2, UTF-8 without ASCII escapes, trailing newline).
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://starwars.fandom.com/api.php"
UA = "wookieepedia.koplugin-data/0.1 (+https://github.com/koreader/koreader)"
BATCH = 50
SLEEP = 1.0
MAX_TRIES = 6
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLANETS = os.path.join(REPO, "data", "planets.json")


class ApiError(Exception):
    pass


def fetch(titles):
    params = {
        "action": "query",
        "prop": "info",
        "titles": "|".join(titles),
        "format": "json",
        "formatversion": "2",
        "maxlag": "5",
    }
    url = API + "?" + urllib.parse.urlencode(params)
    delay = 2.0
    for attempt in range(1, MAX_TRIES + 1):
        retry_after = None
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=60) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            err = data.get("error")
            if err and err.get("code") == "maxlag":
                retry_after = 5.0
                raise ApiError("maxlag")
            if err:
                raise ApiError(f"API error: {err}")
            return data
        except urllib.error.HTTPError as e:
            if e.code != 429 and e.code < 500:
                raise
            ra = e.headers.get("Retry-After")
            retry_after = float(ra) if ra and ra.isdigit() else None
            reason = f"HTTP {e.code}"
        except (urllib.error.URLError, TimeoutError, ApiError) as e:
            reason = str(e)
        if attempt == MAX_TRIES:
            raise RuntimeError(f"giving up after {MAX_TRIES} tries: {reason}")
        wait = retry_after if retry_after is not None else delay
        print(f"  retry {attempt}/{MAX_TRIES - 1} after {reason}, waiting {wait:g}s",
              file=sys.stderr)
        time.sleep(wait)
        delay *= 2
    raise RuntimeError("unreachable")


def main():
    with open(PLANETS, encoding="utf-8") as f:
        planets = json.load(f)

    titles = [p["title"] for p in planets]
    unique = list(dict.fromkeys(titles))
    batches = [unique[i:i + BATCH] for i in range(0, len(unique), BATCH)]

    sizes = {}    # canonical title -> length
    missing = []  # titles the API reports as nonexistent
    requests = 0

    for n, batch in enumerate(batches):
        if requests:
            time.sleep(SLEEP)
        data = fetch(batch)
        requests += 1
        query = data.get("query", {})

        # Map normalised (requested) titles back to the canonical title.
        to_from = {}
        for norm in query.get("normalized", []) or []:
            to_from[norm["to"]] = norm["from"]

        found = set()
        for page in query.get("pages", []) or []:
            canon = page.get("title")
            if page.get("missing") or page.get("invalid") or "length" not in page:
                continue
            length = int(page["length"])
            sizes[canon] = length
            found.add(canon)
            # Also key by the originally requested title if it was normalised.
            if canon in to_from:
                sizes[to_from[canon]] = length

        for t in batch:
            canon = to_from.get(t, t)
            if canon not in found and t not in sizes:
                missing.append(t)

        print(f"batch {n + 1}/{len(batches)}: {len(batch)} titles, "
              f"{len(found)} pages found", file=sys.stderr)

    missing = sorted(set(missing))
    for p in planets:
        p["size"] = int(sizes.get(p["title"], 0))

    with open(PLANETS, "w", encoding="utf-8") as f:
        f.write(json.dumps(planets, indent=2, ensure_ascii=False) + "\n")

    with_size = sum(1 for p in planets if p["size"] > 0)
    print(f"requests: {requests}")
    print(f"entries: {len(planets)}, with size > 0: {with_size}")
    print(f"missing ({len(missing)}): {', '.join(missing) if missing else 'none'}")
    print("top 25 by size:")
    top = sorted(planets, key=lambda p: p["size"], reverse=True)[:25]
    for i, p in enumerate(top, 1):
        print(f"  {i:2d}. {p['title']}: {p['size']}")
    print("selected:")
    by_title = {p["title"]: p["size"] for p in planets}
    for name in ["Coruscant", "Hetzal Prime", "Eiram", "Elphrona", "Dalna", "Jedha"]:
        print(f"  {name}: {by_title.get(name, 'not in file')}")


if __name__ == "__main__":
    main()
