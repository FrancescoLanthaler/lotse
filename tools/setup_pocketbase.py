#!/usr/bin/env python3
"""Create or update the HaltMal collections in PocketBase. Safe to re-run.

    PB_EMAIL=... PB_PASSWORD=... python3 tools/setup_pocketbase.py

Schema follows _specs/spec.md (originally written for Supabase), adapted to PocketBase:
relations instead of foreign keys, record ids are PocketBase ids.

Hackathon-level access rules: everything is publicly readable, stop data is admin-only to
write, riders/drivers may insert facts and requests without logging in. Not production rules.
"""
from pb_common import PocketBase


def text(name, required=False, **kw):
    return {"name": name, "type": "text", "required": required, **kw}


def number(name, required=False, **kw):
    return {"name": name, "type": "number", "required": required, **kw}


def select(name, values, required=False, max_select=1):
    return {"name": name, "type": "select", "values": values, "maxSelect": max_select,
            "required": required}


def relation(name, collection_id, required=False, cascade=False):
    return {"name": name, "type": "relation", "collectionId": collection_id, "maxSelect": 1,
            "required": required, "cascadeDelete": cascade}


def date(name, required=False):
    return {"name": name, "type": "date", "required": required}


def json_field(name):
    return {"name": name, "type": "json", "maxSize": 0}


AUTODATES = [
    {"name": "created", "type": "autodate", "onCreate": True, "onUpdate": False},
    {"name": "updated", "type": "autodate", "onCreate": True, "onUpdate": True},
]

PUBLIC_READ_ADMIN_WRITE = dict(listRule="", viewRule="", createRule=None, updateRule=None,
                               deleteRule=None)


def upsert(pb, name, fields, indexes, **rules):
    existing = pb.collection(name)
    fields = fields + AUTODATES
    if existing:
        # Keep existing field ids so PocketBase updates columns instead of recreating them.
        ids = {f["name"]: f["id"] for f in existing["fields"]}
        system = [f for f in existing["fields"] if f.get("system")]
        fields = system + [dict(f, id=ids[f["name"]]) if f["name"] in ids else f
                           for f in fields if f["name"] not in {s["name"] for s in system}]
        body = {"fields": fields, "indexes": indexes, **rules}
        c = pb.request("PATCH", f"/api/collections/{existing['id']}", body)
        print(f"updated {name}")
    else:
        body = {"name": name, "type": "base", "fields": fields, "indexes": indexes, **rules}
        c = pb.request("POST", "/api/collections", body)
        print(f"created {name}")
    return c["id"]


def main():
    pb = PocketBase().login()

    stops = upsert(pb, "stops", [
        text("name", True),
        number("lat", True), number("lon", True),
        text("gtfs_id"),                # GTFS stop area, e.g. 'at:45:50002'
    ], [
        "CREATE INDEX idx_stops_lat ON stops (lat)",
        "CREATE INDEX idx_stops_lon ON stops (lon)",
        "CREATE UNIQUE INDEX idx_stops_gtfs ON stops (gtfs_id) WHERE gtfs_id != ''",
    ], **PUBLIC_READ_ADMIN_WRITE)

    bays = upsert(pb, "bays", [
        relation("stop", stops, required=True, cascade=True),
        text("label"),                  # GTFS platform_code: 'A', 'B', ...; may be empty
        json_field("lines"),            # ["150", "170"], from the GTFS timetable
        number("lat", True), number("lon", True),
        text("gtfs_id"),                # GTFS platform stop_id, e.g. 'at:45:50002:0:22'
        text("osm_id"),                 # matched OSM platform node, if any
    ], [
        "CREATE INDEX idx_bays_stop ON bays (stop)",
    ], **PUBLIC_READ_ADMIN_WRITE)

    upsert(pb, "markers", [
        relation("stop", stops, cascade=True),    # empty for vehicle markers
        # Not "required": PocketBase rejects 0 for required numbers, and 0 is a valid tag id.
        number("tag_id", min=0, max=34, onlyInt=True),
        select("kind", ["bay", "entrance", "vehicle"], required=True),
        relation("bay", bays),
        text("vehicle_line"),
        number("size_m", True, min=0.01),          # outer black square edge, measured
        text("note"),
    ], [
        "CREATE UNIQUE INDEX idx_markers_stop_tag ON markers (stop, tag_id)",
    ], **PUBLIC_READ_ADMIN_WRITE)

    upsert(pb, "facts", [
        select("subject_type", ["stop", "bay", "vehicle"], required=True),
        text("subject_id", True),      # stop/bay record id, or line name for vehicles
        # step_free_boarding | ramp_working | bay_blocked | stop_moved | bay_changed |
        # tactile_paving | wheelchair
        text("key", True),
        text("value", True),           # 'true' / 'false' / short text
        select("source_role", ["official", "driver", "rider", "local", "host"], required=True),
        select("evidence", ["photo", "scan", "none"]),
        date("observed_at", True),
        date("valid_until"),
        text("note"),
    ], [
        "CREATE INDEX idx_facts_subject ON facts (subject_id)",
    ], listRule="", viewRule="",
        createRule='@request.body.source_role = "driver" || @request.body.source_role = "rider"',
        updateRule=None, deleteRule=None)

    upsert(pb, "requests", [
        relation("stop", stops, required=True),
        relation("bay", bays),
        text("line", True),
        select("needs", ["blind", "wheelchair", "pram", "language"], required=True, max_select=4),
        select("status", ["waiting", "seen", "boarded", "cancelled", "expired"], required=True),
        date("expires_at", True),
    ], [
        "CREATE INDEX idx_requests_stop_status ON requests (stop, status)",
    ], listRule="", viewRule="", createRule='@request.body.status = "waiting"',
        # No accounts yet, so updates stay anonymous, but only `status` may change (rider
        # cancels, driver marks seen/boarded). Stop, bay, line, needs and expiry are fixed.
        updateRule=" && ".join(f"@request.body.{f}:isset = false"
                               for f in ("stop", "bay", "line", "needs", "expires_at")),
        deleteRule=None)

    # One record per stop: departures for the next days in a compact form (see
    # tools/import_stops.py for the format). The app caches it, so guidance works offline.
    upsert(pb, "timetables", [
        relation("stop", stops, required=True, cascade=True),
        text("start_date", True),       # yyyymmdd, first day of the window
        number("days", True, min=1),
        {"name": "data", "type": "json", "maxSize": 20_000_000},
    ], [
        "CREATE UNIQUE INDEX idx_timetables_stop ON timetables (stop)",
    ], **PUBLIC_READ_ADMIN_WRITE)

    # The import upserts thousands of records; the batch API is off by default.
    pb.request("PATCH", "/api/settings",
               {"batch": {"enabled": True, "maxRequests": 100, "timeout": 30}})
    print("batch API enabled")


if __name__ == "__main__":
    main()
