# HaltMal (NoValleyDuck)

iPhone app that finds AprilTag markers at bus stops and guides a blind rider to the right bay.
Build spec: [_specs/spec.md](_specs/spec.md).

## Marker pipeline (branch `feat/marker-detection`)

```
GPS ─► LocationGate ─► current stop ─► valid marker IDs
                                          │
camera ─► AprilTag (tag25h9) ─► MarkerTracker (safety filter) ─► GuidanceEngine ─► MarkerStateMachine
                                                                                        │
                                       MarkerPipeline: state, lock, events() ◄──────────┘
```

Marker IDs are reused between stops (tag25h9 only has 35 IDs). An ID means something only together
with the stop the rider is at, which comes from GPS (or the demo switch).

* **IDs:** 0–24 are bays and entrances, unique within a stop. 25–34 are bus-door markers, unique across the demo.
* **Safety filter:** a marker is only accepted when there are no corrected bits, margin ≥ 40, the ID belongs to this stop or is a bus door, and it was seen in 3 of the last 5 frames.
* **Soundscape/speech:** consume `MarkerPipeline` on the main actor. Observe `state` / `lock` or
  `for await e in pipeline.events()` (`found`, `arrived`, `lost`, `stopChanged`, `reducedRange`).
* **Timetable:** use `StopRepository.timetable(for:)` and then `departures(after:bay:limit:)`.

## Backend (PocketBase)

`https://novalleyduck.novafox.at`: collections `stops`, `bays`, `markers`, `facts`, `requests` and `timetables`.
Everything is publicly readable, so the app ships no credentials. The scripts use superuser
credentials from the environment. Never commit them.

```sh
export PB_EMAIL=… PB_PASSWORD=…
python3 tools/setup_pocketbase.py                       # schema + access rules (idempotent)
python3 -I tools/import_stops.py /path/to/gtfs_dir      # stops, bays, lines, 14-day timetables,
                                                        # OSM accessibility facts, demo markers
```

Re-run the import weekly, because timetables cover 14 days from the import date. It also rewrites
`NoValleyDuck/Data/DemoStop.json` and `DemoTimetable.json`, the offline fallback for the demo stop.

## Credits

* [AprilTag](https://github.com/AprilRobotics/apriltag), © The Regents of the University of Michigan,
  BSD 2-Clause (`NoValleyDuck/ThirdParty/apriltag/LICENSE.md`).
* Timetable and stop data: Mobilitätsverbünde Österreich OG,
  [data.mobilitaetsverbuende.at](https://data.mobilitaetsverbuende.at/), Salzburg Verkehr GTFS feed.
* Accessibility tags (tactile paving, wheelchair): © [OpenStreetMap](https://www.openstreetmap.org/copyright)
  contributors, ODbL 1.0.
