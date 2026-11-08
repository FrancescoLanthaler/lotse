#!/usr/bin/env python3
"""Assign a printed tag25h9 marker to a bay or bus door, with its measured size.

    export PB_EMAIL=... PB_PASSWORD=...
    python3 tools/assign_marker.py list [--stop "Salzburg Hauptbahnhof"]
    python3 tools/assign_marker.py bays "Salzburg Mirabellplatz"         # bay labels/ids + directions
    python3 tools/assign_marker.py bay  "Salzburg Hauptbahnhof" A 0 --size 0.145
    python3 tools/assign_marker.py bay  "Salzburg Messe" b09a9cc04f09183 0 --size 0.145   # unlabelled bay: id
    python3 tools/assign_marker.py bay  "Salzburg Hauptbahnhof" A 0 --size 0.145 --entrance
    python3 tools/assign_marker.py door 120 25 --size 0.145
    python3 tools/assign_marker.py size 0 0.148 --stop "Salzburg Hauptbahnhof"   # re-measured
    python3 tools/assign_marker.py remove 0 --stop "Salzburg Hauptbahnhof"

ID plan (spec): 0–24 bays/entrances, unique within a stop (reused across stops);
25–34 bus doors, unique across the whole demo. Size = outer edge of the black square in metres.
Changes to the demo stop or to bus doors also refresh NoValleyDuck/Data/DemoStop.json.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from import_stops import DATA_DIR, demo_markers_from_server, pb_id, write_demo_files  # noqa: E402
from pb_common import PocketBase  # noqa: E402

BAY_TAGS, DOOR_TAGS = range(0, 25), range(25, 35)


def q(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def find_stop(pb, name):
    stops = pb.list_all("stops", filter=f"name = {q(name)} || gtfs_id = {q(name)}")
    if not stops:
        word = max(name.split(), key=len)
        near = pb.list_all("stops", filter=f"name ~ {q(word)}")[:10]
        sys.exit(f"no stop named {name!r}. Similar: " + "; ".join(s["name"] for s in near))
    if len(stops) > 1:
        sys.exit(f"{len(stops)} stops named {name!r}; use the GTFS id instead: "
                 + ", ".join(s["gtfs_id"] for s in stops))
    return stops[0]


def check_size(size):
    if not 0.03 <= size <= 1.5:
        sys.exit(f"size {size} m looks wrong: give the black square edge in METRES (e.g. 0.145)")
    return size


def refresh_demo(pb, changed_stop_id=None):
    path = os.path.join(DATA_DIR, "DemoStop.json")
    demo = json.load(open(path))
    if changed_stop_id not in (None, demo["stop"]["id"]):
        return
    write_demo_files(demo["stop"], demo["bays"], demo_markers_from_server(pb, demo["stop"]["id"]))
    print("refreshed NoValleyDuck/Data/DemoStop.json (rebuild the app to bundle it)")


def directions(pb, stop_id):
    """Most frequent headsigns per bay id, from the stop's timetable: tells unlabelled bays apart."""
    tts = pb.list_all("timetables", filter=f'stop = "{stop_id}"')
    if not tts:
        return {}
    d, counts = tts[0]["data"], {}
    for dep in d["deps"]:
        key = f"{d['lines'][dep[1]]} {d['headsigns'][dep[2]]}"
        per_bay = counts.setdefault(d["bays"][dep[0]], {})
        per_bay[key] = per_bay.get(key, 0) + 1
    return {bay: sorted(c, key=c.get, reverse=True)[:5] for bay, c in counts.items()}


def describe(m):
    e = m.get("expand", {})
    if m["kind"] == "vehicle":
        where = f"bus door line {m['vehicle_line']}"
    else:
        bay = e.get("bay", {})
        where = f"{e.get('stop', {}).get('name', '?')} {m['kind']} {bay.get('label') or bay.get('id', '?')}"
    return f"ID {m['tag_id']:>2}  {m['size_m'] * 100:5.1f} cm  {where}"


def find_marker(pb, tag, stop_name):
    if tag in DOOR_TAGS:
        ms = pb.list_all("markers", filter=f'kind = "vehicle" && tag_id = {tag}')
    else:
        if not stop_name:
            sys.exit("bay markers are per stop: add --stop")
        ms = pb.list_all("markers", filter=f'stop = "{find_stop(pb, stop_name)["id"]}" && tag_id = {tag}')
    if not ms:
        sys.exit(f"no marker {tag} found")
    return ms[0]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("list"); p.add_argument("--stop")
    p = sub.add_parser("bays"); p.add_argument("stop")
    p = sub.add_parser("bay"); p.add_argument("stop"); p.add_argument("label"); p.add_argument("tag", type=int)
    p.add_argument("--size", type=float, required=True); p.add_argument("--entrance", action="store_true")
    p = sub.add_parser("door"); p.add_argument("line"); p.add_argument("tag", type=int)
    p.add_argument("--size", type=float, required=True)
    p = sub.add_parser("size"); p.add_argument("tag", type=int); p.add_argument("size", type=float)
    p.add_argument("--stop")
    p = sub.add_parser("remove"); p.add_argument("tag", type=int); p.add_argument("--stop")
    a = ap.parse_args()
    pb = PocketBase().login()

    if a.cmd == "list":
        f = f'stop = "{find_stop(pb, a.stop)["id"]}" || kind = "vehicle"' if a.stop else None
        for m in sorted(pb.list_all("markers", filter=f, expand="stop,bay"), key=lambda m: m["tag_id"]):
            print(describe(m))

    elif a.cmd == "bays":
        stop = find_stop(pb, a.stop)
        towards = directions(pb, stop["id"])
        for b in sorted(pb.list_all("bays", filter=f'stop = "{stop["id"]}"'), key=lambda b: b["label"]):
            print(f"{b['label'] or '(no label)':>10}  {b['id']}  lines {' '.join(b['lines'] or []) or '-'}")
            if towards.get(b["id"]):
                print(f"{'':>12}towards {', '.join(towards[b['id']])}")

    elif a.cmd == "bay":
        if a.tag not in BAY_TAGS:
            sys.exit("bay/entrance markers use IDs 0–24 (25–34 are bus doors)")
        stop = find_stop(pb, a.stop)
        bays = [b for b in pb.list_all("bays", filter=f'stop = "{stop["id"]}"') if a.label in (b["label"], b["id"])]
        if not bays:
            sys.exit(f"no bay {a.label!r} at {stop['name']}; see: assign_marker.py bays {q(stop['name'])}")
        if len(bays) > 1 and not bays[0]["label"]:
            sys.exit("several unlabelled bays: give the bay id instead (see the bays command)")
        bay = sorted(bays, key=lambda b: b["gtfs_id"])[0]   # same label twice (e.g. two "F"): first platform
        m = {"id": pb_id("m", f"{stop['id']}:{a.tag}"), "stop": stop["id"], "tag_id": a.tag,
             "kind": "entrance" if a.entrance else "bay", "bay": bay["id"], "vehicle_line": "",
             "size_m": check_size(a.size), "note": f"Bay {bay['label'] or bay['id']}"}
        clash = pb.list_all("markers", filter=f'stop = "{stop["id"]}" && tag_id = {a.tag}')
        if clash and clash[0]["id"] != m["id"]:
            pb.request("DELETE", f"/api/collections/markers/records/{clash[0]['id']}")
        pb.batch_upsert("markers", [m])
        print(f"ID {a.tag} → {stop['name']} bay {bay['label'] or bay['id']}, {a.size * 100:.1f} cm")
        refresh_demo(pb, stop["id"])

    elif a.cmd == "door":
        if a.tag not in DOOR_TAGS:
            sys.exit("bus-door markers use IDs 25–34")
        m = {"id": pb_id("m", f"vehicle:{a.tag}"), "stop": "", "tag_id": a.tag, "kind": "vehicle",
             "bay": "", "vehicle_line": a.line, "size_m": check_size(a.size), "note": f"Bus door, line {a.line}"}
        pb.batch_upsert("markers", [m])
        print(f"ID {a.tag} → bus door line {a.line}, {a.size * 100:.1f} cm")
        refresh_demo(pb)

    elif a.cmd == "size":
        m = find_marker(pb, a.tag, a.stop)
        pb.request("PATCH", f"/api/collections/markers/records/{m['id']}", {"size_m": check_size(a.size)})
        print(f"ID {a.tag}: {m['size_m'] * 100:.1f} cm → {a.size * 100:.1f} cm")
        refresh_demo(pb, m["stop"] or None)

    elif a.cmd == "remove":
        m = find_marker(pb, a.tag, a.stop)
        pb.request("DELETE", f"/api/collections/markers/records/{m['id']}")
        print(f"removed ID {a.tag}")
        refresh_demo(pb, m["stop"] or None)


if __name__ == "__main__":
    main()
