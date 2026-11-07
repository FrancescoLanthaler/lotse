#!/usr/bin/env python3
"""Import stops, bays (platforms), lines and timetables from the Salzburg Verkehr GTFS feed into
PocketBase, add community accessibility facts from OpenStreetMap, seed the demo markers, and
export the demo stop for the app bundle.

    PB_EMAIL=... PB_PASSWORD=... python3 tools/import_stops.py /path/to/gtfs_dir \\
        [--days 14] [--osm-cache osm.json] [--reset] [--dry-run]

Re-run regularly (e.g. weekly): timetables cover --days days from today. Record ids are
deterministic, so re-runs upsert. --reset first wipes stops/bays/markers/timetables and the
imported facts (driver/rider facts are kept).

Sources:
  * Timetable data: Mobilitätsverbünde Österreich OG (data.mobilitaetsverbuende.at), under the
    licence accepted at download.
  * Accessibility tags: © OpenStreetMap contributors, ODbL 1.0.

Timetable record format (`timetables.data`), compact on purpose:
  {"bays": [bay record ids], "lines": [...], "headsigns": [...],
   "services": ["0110…"],   # one char per day of the window: 1 = service runs that day
   "deps": [[bay, line, headsign, minutes, service, accessible], ...]}   # sorted by minutes
  `minutes` is minutes after midnight of the service day and can exceed 1440 (GTFS 25:10).
  `accessible` is GTFS wheelchair_accessible: 0 unknown, 1 yes (low floor), 2 no.
"""
import argparse
import collections
import csv
import datetime as dt
import hashlib
import json
import math
import os
import subprocess
import urllib.parse
import sys
from zoneinfo import ZoneInfo

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # works under python3 -I too
from pb_common import PocketBase  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.path.join(REPO, "NoValleyDuck", "Data")
TZ = ZoneInfo("Europe/Vienna")

# Demo: the hackathon hall (Messezentrum) is in Salzburg, so the demo stop is the Hauptbahnhof.
DEMO_AREA = "at:45:50002"
DEMO_BAY_TAGS = {"A": 0, "B": 1}          # platform code -> tag25h9 id
DEMO_VEHICLE_TAG = 25                     # bus-door marker
DEMO_MARKER_SIZE_M = 0.145                # tools/make_markers.py on A4; measure + assign_marker.py

OSM_MATCH_M = 20
OVERPASS = "https://overpass-api.de/api/interpreter"
OSM_QUERY = """
[out:json][timeout:300];
area["ISO3166-2"="AT-5"]->.a;
(
  node["highway"="bus_stop"](area.a);
  node["public_transport"="platform"](area.a);
)->.p;
.p out meta;
"""


def pb_id(prefix, key):
    """Deterministic 15-char PocketBase id ([a-z0-9])."""
    return prefix + hashlib.sha1(key.encode()).hexdigest()[:15 - len(prefix)]


def metres(lat1, lon1, lat2, lon2):
    x = math.radians(lon2 - lon1) * math.cos(math.radians((lat1 + lat2) / 2))
    return 6371000 * math.hypot(x, math.radians(lat2 - lat1))


def rows(gtfs, name):
    with open(os.path.join(gtfs, name), encoding="utf-8-sig", newline="") as f:
        yield from csv.DictReader(f)


def area_of(stop_id):
    return ":".join(stop_id.split(":")[:3])


def line_key(ref):
    digits = "".join(c for c in ref if c.isdigit())
    return (0, int(digits), ref) if digits and ref[0].isdigit() else (1, 0, ref)


# ---------------------------------------------------------------------------------------------
# GTFS

def load_stops(gtfs):
    all_stops = {s["stop_id"]: s for s in rows(gtfs, "stops.txt")}
    platforms = [s for s in all_stops.values() if s["location_type"] in ("", "0")]
    by_area = collections.defaultdict(list)
    for p in platforms:
        by_area[area_of(p["stop_id"])].append(p)

    stops, bays, bay_of_platform = [], [], {}
    for area, plats in by_area.items():
        parent = next((all_stops[p["parent_station"]] for p in plats
                       if p["parent_station"] in all_stops), None)
        if parent:
            name, lat, lon = parent["stop_name"], float(parent["stop_lat"]), float(parent["stop_lon"])
        else:
            # Platform names inside a station can be "Gleis 1" etc.; prefer the common name.
            names = collections.Counter(p["stop_name"] for p in plats
                                        if not p["stop_name"].startswith("Gleis"))
            name = (names or collections.Counter(p["stop_name"] for p in plats)).most_common(1)[0][0]
            lat = sum(float(p["stop_lat"]) for p in plats) / len(plats)
            lon = sum(float(p["stop_lon"]) for p in plats) / len(plats)
        sid = pb_id("s", area)
        stops.append({"id": sid, "name": name.strip(), "lat": round(lat, 7), "lon": round(lon, 7),
                      "gtfs_id": area})
        for p in plats:
            bid = pb_id("b", p["stop_id"])
            label = p["platform_code"].strip()
            if not label and p["stop_name"].startswith("Gleis"):
                label = p["stop_name"]
            bays.append({"id": bid, "stop": sid, "label": label, "lines": [],
                         "lat": float(p["stop_lat"]), "lon": float(p["stop_lon"]),
                         "gtfs_id": p["stop_id"], "osm_id": ""})
            bay_of_platform[p["stop_id"]] = bid
    return stops, bays, bay_of_platform


def service_masks(gtfs, start, days):
    dates = [start + dt.timedelta(d) for d in range(days)]
    active = collections.defaultdict(set)
    for c in rows(gtfs, "calendar.txt"):
        a = dt.datetime.strptime(c["start_date"], "%Y%m%d").date()
        b = dt.datetime.strptime(c["end_date"], "%Y%m%d").date()
        wd = [c[k] == "1" for k in ("monday", "tuesday", "wednesday", "thursday", "friday",
                                     "saturday", "sunday")]
        for i, d in enumerate(dates):
            if a <= d <= b and wd[d.weekday()]:
                active[c["service_id"]].add(i)
    index = {d.strftime("%Y%m%d"): i for i, d in enumerate(dates)}
    for e in rows(gtfs, "calendar_dates.txt"):
        i = index.get(e["date"])
        if i is None:
            continue
        if e["exception_type"] == "1":
            active[e["service_id"]].add(i)
        else:
            active[e["service_id"]].discard(i)
    return {sid: "".join("1" if i in on else "0" for i in range(days))
            for sid, on in active.items() if on}


def load_timetables(gtfs, bay_of_platform, masks):
    routes = {r["route_id"]: r["route_short_name"].strip() or r["route_long_name"].strip()
              for r in rows(gtfs, "routes.txt")}
    trips = {t["trip_id"]: (routes.get(t["route_id"], "?"), t["trip_headsign"].strip(),
                            t["service_id"], int(t["wheelchair_accessible"] or 0))
             for t in rows(gtfs, "trips.txt")}
    last_seq = collections.defaultdict(int)
    for st in rows(gtfs, "stop_times.txt"):
        s = int(st["stop_sequence"])
        if s > last_seq[st["trip_id"]]:
            last_seq[st["trip_id"]] = s

    lines_of_bay = collections.defaultdict(set)
    per_area = collections.defaultdict(list)
    for st in rows(gtfs, "stop_times.txt"):
        trip = trips.get(st["trip_id"])
        bay = bay_of_platform.get(st["stop_id"])
        if not trip or not bay:
            continue
        line, headsign, service, accessible = trip
        lines_of_bay[bay].add(line)
        # Departures only: not the last stop, and boarding allowed.
        if int(st["stop_sequence"]) == last_seq[st["trip_id"]] or st["pickup_type"] == "1":
            continue
        if service not in masks:
            continue
        h, m, _ = (int(x) for x in st["departure_time"].split(":"))
        per_area[area_of(st["stop_id"])].append(
            (bay, line, st["stop_headsign"].strip() or headsign, h * 60 + m, service, accessible))
    return lines_of_bay, per_area


def compact(deps, masks):
    deps.sort(key=lambda d: (d[3], d[1]))
    tables = {k: [] for k in ("bays", "lines", "headsigns", "services")}
    idx = {k: {} for k in tables}

    def ref(kind, value):
        if value not in idx[kind]:
            idx[kind][value] = len(tables[kind])
            tables[kind].append(value)
        return idx[kind][value]

    out = [[ref("bays", b), ref("lines", l), ref("headsigns", h), minutes, ref("services", s), a]
           for b, l, h, minutes, s, a in deps]
    tables["services"] = [masks[s] for s in tables["services"]]
    return {**tables, "deps": out}


# ---------------------------------------------------------------------------------------------
# OSM accessibility facts

def fetch_osm(cache):
    if cache and os.path.exists(cache):
        return json.load(open(cache))
    print("querying Overpass…")
    out = subprocess.run(["curl", "-sf", "-m", "400", "-A", "haltmal-hackathon-import/1.0",
                          "--data-binary", "@-", OVERPASS],
                         input=urllib.parse.urlencode({"data": OSM_QUERY}).encode(),
                         capture_output=True, check=True).stdout
    data = json.loads(out)
    if cache:
        json.dump(data, open(cache, "w"))
    return data


def osm_facts(osm, bays):
    grid = collections.defaultdict(list)
    for b in bays:
        grid[(round(b["lat"], 3), round(b["lon"], 3))].append(b)
    facts = []
    for n in osm["elements"]:
        t = n.get("tags", {})
        keys = [k for k in ("tactile_paving", "wheelchair") if k in t]
        if n["type"] != "node" or not keys or not n.get("timestamp"):
            continue
        near = [b for dy in (-0.001, 0, 0.001) for dx in (-0.001, 0, 0.001)
                for b in grid[(round(n["lat"] + dy, 3), round(n["lon"] + dx, 3))]]
        best = min(near, key=lambda b: metres(n["lat"], n["lon"], b["lat"], b["lon"]), default=None)
        if not best or metres(n["lat"], n["lon"], best["lat"], best["lon"]) > OSM_MATCH_M:
            continue
        best["osm_id"] = str(n["id"])
        for k in keys:
            facts.append({
                "id": pb_id("fo", f"{n['id']}:{k}"), "subject_type": "bay", "subject_id": best["id"],
                "key": k, "value": {"yes": "true", "no": "false"}.get(t[k], t[k]),
                "source_role": "local", "evidence": "none",
                "observed_at": n["timestamp"].replace("T", " "), "note": "OpenStreetMap",
            })
    return facts


# ---------------------------------------------------------------------------------------------
# Demo seed

def demo_seed(stops, bays):
    stop = next(s for s in stops if s["gtfs_id"] == DEMO_AREA)
    stop_bays = [b for b in bays if b["stop"] == stop["id"]]
    by_label = {}
    for b in sorted(stop_bays, key=lambda b: b["gtfs_id"]):
        by_label.setdefault(b["label"], b)
    markers, facts = [], []
    week_ago = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=7)).strftime(
        "%Y-%m-%d %H:%M:%S.000Z")
    for label, tag in DEMO_BAY_TAGS.items():
        bay = by_label[label]
        markers.append({"id": pb_id("m", f"{stop['id']}:{tag}"), "stop": stop["id"], "tag_id": tag,
                        "kind": "bay", "bay": bay["id"], "vehicle_line": "",
                        "size_m": DEMO_MARKER_SIZE_M, "note": f"Bay {label}, A4 print"})
        for key in ("step_free_boarding", "ramp_working"):
            facts.append({"id": pb_id("fd", f"{bay['id']}:{key}"), "subject_type": "bay",
                          "subject_id": bay["id"], "key": key, "value": "true",
                          "source_role": "official", "evidence": "none",
                          "observed_at": week_ago, "note": "demo seed"})
    line = (by_label["A"]["lines"] or ["X"])[0]
    markers.append({"id": pb_id("m", f"vehicle:{DEMO_VEHICLE_TAG}"), "stop": "",
                    "tag_id": DEMO_VEHICLE_TAG, "kind": "vehicle", "bay": "", "vehicle_line": line,
                    "size_m": DEMO_MARKER_SIZE_M, "note": f"Bus door, line {line}, A4 print"})
    return stop, stop_bays, markers, facts


def reset(pb):
    """Wipe imported data. Returns the markers that existed, so they can be restored: marker
    assignments and measured sizes are hand-made and must survive a re-import."""
    saved = pb.list_all("markers")
    for name in ("timetables", "markers", "bays", "stops"):
        pb.request("DELETE", f"/api/collections/{name}/truncate")
        print(f"truncated {name}")
    while True:
        r = pb.request("GET", "/api/collections/facts/records?perPage=500&skipTotal=1&filter="
                       + urllib.parse.quote('note = "OpenStreetMap" || note = "demo seed"'))
        if not r["items"]:
            break
        for i in range(0, len(r["items"]), 100):
            pb.request("POST", "/api/batch", {"requests": [
                {"method": "DELETE", "url": f"/api/collections/facts/records/{f['id']}"}
                for f in r["items"][i:i + 100]]})
    print("deleted imported facts")
    keep = ("id", "stop", "tag_id", "kind", "bay", "vehicle_line", "size_m", "note")
    return [{k: m[k] for k in keep} for m in saved]


def write_demo_files(stop, bays, markers, timetable=None):
    """Bundled offline fallback for the demo stop (NoValleyDuck/Data/*.json)."""
    with open(os.path.join(DATA_DIR, "DemoStop.json"), "w") as f:
        json.dump({"stop": stop, "bays": bays, "markers": markers}, f, indent=1, ensure_ascii=False)
    if timetable is not None:
        with open(os.path.join(DATA_DIR, "DemoTimetable.json"), "w") as f:
            json.dump(timetable, f, ensure_ascii=False, separators=(",", ":"))


def demo_markers_from_server(pb, stop_id):
    keep = ("id", "stop", "tag_id", "kind", "bay", "vehicle_line", "size_m", "note")
    ms = pb.list_all("markers", filter=f'stop = "{stop_id}" || kind = "vehicle"')
    return [{k: m[k] for k in keep} for m in sorted(ms, key=lambda m: m["tag_id"])]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("gtfs", help="unzipped GTFS directory")
    ap.add_argument("--days", type=int, default=14)
    ap.add_argument("--osm-cache")
    ap.add_argument("--reset", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    start = dt.datetime.now(TZ).date()
    stops, bays, bay_of_platform = load_stops(args.gtfs)
    masks = service_masks(args.gtfs, start, args.days)
    lines_of_bay, per_area = load_timetables(args.gtfs, bay_of_platform, masks)
    for b in bays:
        b["lines"] = sorted(lines_of_bay.get(b["id"], ()), key=line_key)
    stop_of_area = {s["gtfs_id"]: s["id"] for s in stops}
    timetables = [{"id": pb_id("t", area), "stop": stop_of_area[area],
                   "start_date": start.strftime("%Y%m%d"), "days": args.days,
                   "data": compact(deps, masks)}
                  for area, deps in per_area.items()]
    facts = osm_facts(fetch_osm(args.osm_cache), bays)
    demo_stop, demo_bays, markers, demo_facts = demo_seed(stops, bays)

    biggest = max(timetables, key=lambda t: len(t["data"]["deps"]))
    print(f"{len(stops)} stops, {len(bays)} bays, {len(timetables)} timetables "
          f"({sum(len(t['data']['deps']) for t in timetables)} departures in {args.days} days, "
          f"largest {len(json.dumps(biggest['data'])) // 1024} KB), {len(facts)} OSM facts")
    print(f"demo stop {demo_stop['name']}: " + ", ".join(
        f"{b['label'] or '?'} [{' '.join(b['lines'][:6])}]" for b in demo_bays))

    demo_tt = next((t for t in timetables if t["stop"] == demo_stop["id"]), None)
    if args.dry_run:
        write_demo_files(demo_stop, demo_bays, markers, demo_tt)
        print("dry run: wrote NoValleyDuck/Data/DemoStop.json and DemoTimetable.json")
        return

    pb = PocketBase().login()
    restored = reset(pb) if args.reset else []
    pb.batch_upsert("stops", stops)
    pb.batch_upsert("bays", bays)
    # Markers are assigned and measured by hand (tools/assign_marker.py): restore them after a
    # reset, and only create demo markers that don't exist yet — never overwrite a measured size.
    stop_ids, bay_ids = {s["id"] for s in stops}, {b["id"] for b in bays}
    restored = [m for m in restored if (m["stop"] in stop_ids or m["kind"] == "vehicle")
                and (not m["bay"] or m["bay"] in bay_ids)]
    pb.batch_upsert("markers", restored)
    existing = {m["id"] for m in pb.list_all("markers")}
    pb.batch_upsert("markers", [m for m in markers if m["id"] not in existing])
    pb.batch_upsert("facts", facts + demo_facts)
    pb.batch_upsert("timetables", timetables, chunk=10)
    write_demo_files(demo_stop, demo_bays, demo_markers_from_server(pb, demo_stop["id"]), demo_tt)
    print(f"restored {len(restored)} markers; wrote NoValleyDuck/Data/DemoStop.json and DemoTimetable.json")
    print("done")


if __name__ == "__main__":
    main()
