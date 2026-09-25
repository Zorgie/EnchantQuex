#!/usr/bin/env python3
"""
Builds EnchantQuex/Data.lua from Wowhead's Classic database.

Wowhead's Forever database shows Classic disenchant observations but Forever
item levels / rarities, so the two disagree for items that changed. The Classic
database is self-consistent, so the addon's tables are built from it and keyed
by (rarity, class, item level) only; in game the item's Forever rarity and item
level select the table. No per-item data is exported.

Data sources (all on https://www.wowhead.com/classic):
  * Each enchanting material's page has a "disenchanted-from" list with, per
    source item, drop counts and quantity distribution (pctstack). These lists
    are truncated for popular materials.
  * The item filter "Disenchants into <mat>" (filter=163;<mat>;0) lists every
    item known to disenchant into a material, but without drop statistics.
  * Individual item pages carry a full "disenchanting" table. They are fetched
    only for groups that don't yet have enough complete items.

Usage:
  py tools/scrape_wowhead.py              # uses cached pages where available
  py tools/scrape_wowhead.py --refresh    # re-download everything
  py tools/scrape_wowhead.py --no-items   # skip per-item page fetches
  py tools/scrape_wowhead.py --delay 8    # seconds between requests (default 5)

Wowhead rate-limits aggressive clients with HTTP 403. When that happens the
script stops fetching, writes Data.lua from what it has, and a later run
resumes from the page cache.

Standard library only.
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from collections import defaultdict
from datetime import date

BASE = "https://www.wowhead.com/classic"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE_DIR = os.path.join(ROOT, "tools", "cache", "classic")
OUT_FILE = os.path.join(ROOT, "EnchantQuex", "Data.lua")
USER_AGENT = "Mozilla/5.0 (EnchantQuex data builder)"
REQUEST_DELAY = 5.0  # seconds between uncached requests; be polite

# Materials obtainable through disenchanting (Wowhead filter 163 options).
MATS = {
    10940: "Strange Dust", 11083: "Soul Dust", 11137: "Vision Dust",
    11176: "Dream Dust", 16204: "Illusion Dust",
    10938: "Lesser Magic Essence", 10939: "Greater Magic Essence",
    10998: "Lesser Astral Essence", 11082: "Greater Astral Essence",
    11134: "Lesser Mystic Essence", 11135: "Greater Mystic Essence",
    11174: "Lesser Nether Essence", 11175: "Greater Nether Essence",
    16202: "Lesser Eternal Essence", 16203: "Greater Eternal Essence",
    10978: "Small Glimmering Shard", 11084: "Large Glimmering Shard",
    11138: "Small Glowing Shard", 11139: "Large Glowing Shard",
    11177: "Small Radiant Shard", 11178: "Large Radiant Shard",
    14343: "Small Brilliant Shard", 14344: "Large Brilliant Shard",
    20725: "Nexus Crystal",
}

QUALITIES = (2, 3, 4)  # uncommon, rare, epic
CLASS_PATHS = {"armor": 4, "weapons": 2}
LIST_CAP = 1000

# Items with fewer observed disenchants than this are ignored (too noisy).
MIN_ITEM_SAMPLES = 5
# Item pages are fetched for a group until it has this many disenchants and items.
TARGET_SAMPLES = 300
TARGET_ITEMS = 3

_last_request = 0.0


class Blocked(Exception):
    """Wowhead refused the request (rate limit); stop and try again later."""


def fetch(url, cache_name, refresh):
    global _last_request
    path = os.path.join(CACHE_DIR, cache_name)
    if not refresh and os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            return f.read()
    wait = REQUEST_DELAY - (time.time() - _last_request)
    if wait > 0:
        time.sleep(wait)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                html = resp.read().decode("utf-8", errors="replace")
            break
        except urllib.error.HTTPError as e:
            if e.code in (403, 429):
                raise Blocked(f"HTTP {e.code} for {url}")
            if attempt == 3:
                raise
            print(f"  retry {url}: {e}", file=sys.stderr)
            time.sleep(5 * (attempt + 1))
        except Exception as e:  # network hiccup
            if attempt == 3:
                raise
            print(f"  retry {url}: {e}", file=sys.stderr)
            time.sleep(5 * (attempt + 1))
    _last_request = time.time()
    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(html)
    return html


def listview_data(html, lv_id):
    """Returns the JSON `data` array of the Listview with the given id, or []."""
    m = re.search(r"id: '%s',.*?\n\s*data: (\[.*?\]),\n\}\);" % re.escape(lv_id), html, re.S)
    if not m:
        return []
    return json.loads(m.group(1))


def filter_item_ids(html):
    """Item ids and metadata from an item filter results page."""
    m = re.search(r"var listviewitems = (\[.*?\]);\n", html, re.S)
    if not m:
        return {}
    # The array is not strict JSON (unquoted keys like firstseenpatch/popularity),
    # so pull the fields we need with regexes per top-level item.
    out = {}
    for im in re.finditer(r'"classs":(\d+),.*?"id":(\d+),"level":(\d+),"name":"((?:[^"\\]|\\.)*)","quality":(\d+)',
                          m.group(1)):
        cls, iid, lvl, name, q = im.groups()
        out[int(iid)] = {"classs": int(cls), "level": int(lvl), "quality": int(q),
                         "name": json.loads('"%s"' % name)}
    return out


def avg_stack(entry):
    """Expected quantity per successful drop."""
    pct = entry.get("pctstack")
    if pct:
        pairs = re.findall(r"(\d+)\s*:\s*([\d.]+)", pct)
        total = sum(float(p) for _, p in pairs)
        if total > 0:
            return sum(int(n) * float(p) for n, p in pairs) / total
    stack = entry.get("stack")
    if stack and len(stack) == 2:
        return (stack[0] + stack[1]) / 2.0
    return 1.0


def drop_row(entry):
    """{count, outof, qty} from a loot table row, or None if it only covers part of the data.

    Rows carry per-phase breakdowns in itemSeasonPhaseData; ["0"]["0"]["0"] is
    the all-time total. Material pages sometimes list an item with only one
    phase slice (e.g. 6/13 instead of 14/302) and then the row's top-level
    count/outof/pctstack describe just that slice, so such rows are rejected.
    """
    total = (entry.get("itemSeasonPhaseData") or {}).get("0", {}).get("0", {}).get("0")
    if not total or not total.get("outof"):
        return None
    return {"count": total["count"], "outof": total["outof"], "qty": avg_stack(entry)}


def group_key(m):
    return (m["quality"], m["classs"], m["level"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--refresh", action="store_true", help="ignore cached pages")
    ap.add_argument("--no-items", action="store_true", help="skip per-item page fetches")
    ap.add_argument("--delay", type=float, default=5.0, help="seconds between requests")
    args = ap.parse_args()
    global REQUEST_DELAY
    REQUEST_DELAY = args.delay

    meta = {}                       # itemId -> {classs, level, quality, name}
    drops = defaultdict(dict)       # itemId -> matId -> {count, outof, qty}
    listed = defaultdict(set)       # itemId -> set(matId) per filter pages

    # 1) material pages + filter listings. Only the filter pages define which
    #    items count (disenchantable armor/weapons of uncommon+ quality).
    for mat, mat_name in MATS.items():
        print(f"[mat] {mat_name} ({mat})")
        html = fetch(f"{BASE}/item={mat}", f"mat_{mat}.html", args.refresh)
        for e in listview_data(html, "disenchanted-from"):
            row = drop_row(e)
            if row:
                drops[e["id"]][mat] = row
        for cpath in CLASS_PATHS:
            for q in QUALITIES:
                url = f"{BASE}/items/{cpath}/quality:{q}?filter=163;{mat};0"
                fhtml = fetch(url, f"filter_{mat}_{cpath}_{q}.html", args.refresh)
                ids = filter_item_ids(fhtml)
                if len(ids) >= LIST_CAP:
                    print(f"  WARNING: {url} hit the {LIST_CAP} result cap; data may be incomplete",
                          file=sys.stderr)
                for iid, m in ids.items():
                    meta[iid] = m
                    listed[iid].add(mat)

    # An item is complete when every material it is listed under has a
    # full-total row and all rows agree on how often it was disenchanted.
    def complete(iid):
        per_mat = drops.get(iid, {})
        return listed[iid] <= set(per_mat) and len({d["outof"] for d in per_mat.values()}) == 1

    done = {i for i in listed if complete(i)}
    groups = defaultdict(lambda: {"samples": 0, "items": 0, "todo": []})
    for iid in listed:
        g = groups[group_key(meta[iid])]
        if iid in done:
            samples = next(iter(drops[iid].values()))["outof"]
            if samples >= MIN_ITEM_SAMPLES:
                g["samples"] += samples
                g["items"] += 1
        else:
            g["todo"].append(iid)
    # Most-disenchanted candidates first; partial rows hint at the sample size.
    for g in groups.values():
        g["todo"].sort(key=lambda i: -max([d["outof"] for d in drops.get(i, {}).values()] or [0]))

    def satisfied(g):
        return g["samples"] >= TARGET_SAMPLES and g["items"] >= TARGET_ITEMS

    todo_total = sum(len(g["todo"]) for g in groups.values() if not satisfied(g))
    print(f"{len(listed)} items, {len(done)} complete from material pages, "
          f"{len(groups)} groups, up to {todo_total} item pages needed")

    # 2) item pages, round-robin over unsatisfied groups
    blocked, fetched = None, 0
    while True:
        pending = [g for g in groups.values() if g["todo"] and not satisfied(g)]
        if not pending:
            break
        for g in pending:
            iid = g["todo"].pop(0)
            cached = os.path.exists(os.path.join(CACHE_DIR, f"item_{iid}.html"))
            if (args.no_items or blocked) and (args.refresh or not cached):
                continue
            try:
                html = fetch(f"{BASE}/item={iid}", f"item_{iid}.html", args.refresh and not blocked)
            except Blocked as e:
                blocked = e
                print(f"  STOPPED: {e}. Writing partial data; re-run later to resume.", file=sys.stderr)
                continue
            fetched += 1
            if fetched % 50 == 0:
                print(f"[item] {fetched} pages read")
            drops[iid] = {}
            for e in listview_data(html, "disenchanting"):
                row = drop_row(e) if e["id"] in MATS else None
                if row:
                    drops[iid][e["id"]] = row
            if drops[iid]:
                done.add(iid)
                samples = max(d["outof"] for d in drops[iid].values())
                if samples >= MIN_ITEM_SAMPLES:
                    g["samples"] += samples
                    g["items"] += 1

    # 3) sample-weighted groups: chance and average quantity per material
    acc = defaultdict(lambda: [0, 0, defaultdict(float), defaultdict(float)])
    for iid in done:
        per_mat = drops[iid]
        samples = max(d["outof"] for d in per_mat.values())
        if samples < MIN_ITEM_SAMPLES:
            continue
        a = acc[group_key(meta[iid])]
        a[0] += samples
        a[1] += 1
        for mat, d in per_mat.items():
            chance = d["count"] / d["outof"]
            a[2][mat] += chance * samples             # -> weighted chance
            a[3][mat] += chance * d["qty"] * samples  # -> weighted expected quantity
    buckets = {}
    for key, (samples, n, chance_acc, ev_acc) in acc.items():
        mats = {}
        for mat in chance_acc:
            chance = chance_acc[mat] / samples
            if chance > 0:
                mats[mat] = (chance, ev_acc[mat] / chance_acc[mat])
        buckets[key] = (samples, n, mats)

    write_lua(buckets)
    thin = sum(1 for g in groups.values() if not satisfied(g))
    print(f"Wrote {OUT_FILE}: {len(buckets)} groups from {len(done)} items "
          f"({fetched} item pages read); {thin} groups below target")


def write_lua(buckets):
    lines = [
        "-- GENERATED by tools/scrape_wowhead.py from wowhead.com/classic. Do not edit by hand;",
        "-- use the in-game override editor instead.",
        "-- buckets[\"quality:classID:itemLevel\"] = { disenchants, itemCount, matID, chance, avgQty, ... }",
        "local _, ns = ...",
        "ns.Data = {",
        f'  generated = "{date.today().isoformat()}",',
        "  mats = {",
    ]
    for mat, name in sorted(MATS.items()):
        lines.append(f'    [{mat}] = "{name}",')
    lines.append("  },")
    lines.append("  buckets = {")
    for key in sorted(buckets):
        samples, n, mats = buckets[key]
        body = ", ".join(f"{mat}, {c:.4f}, {q:.3f}" for mat, (c, q) in sorted(mats.items()) if c >= 0.00005)
        lines.append(f'    ["{key[0]}:{key[1]}:{key[2]}"] = {{ {samples}, {n}, {body} }},')
    lines.append("  },")
    lines.append("}")
    with open(OUT_FILE, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
