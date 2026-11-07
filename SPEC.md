# NoValleyDuck: app spec (v2, after grilling)

## Context

Hackathon project (Tourism Hackathon 2026). The app gets a blind or visually impaired person from anywhere to a destination like Getreidegasse in Salzburg, using only an iPhone and AirPods Pro, including public transport. We know it doesn't fit the official challenge brief. One possible pitch angle: **accessible tourism**, since a visually impaired visitor can't rely on locals or memorised routes in a city they don't know.

What already exists in the repo (`novalleyduck/`): a working AprilTag **tag25h9** detector in C (`ATDetector.c`, `ThirdParty/apriltag`). It has a Swift wrapper (`Camera/TagDetector.swift`), a 10 fps back-camera pipeline (`Camera/CameraService.swift`) and a debug preview (`Camera/CameraPreview.swift`). It returns tag ID, decision margin and pose, and from those it computes **distance in metres**. `App/Scanner.swift` ties these together. This spec builds on that milestone.


---

## 1. User and setup

- **User**: blind or visually impaired, already uses VoiceOver, owns an iPhone and AirPods Pro (or any AirPods with head tracking).
- **Phone stays in the pocket** while walking. It only comes out to scan markers at stops.
- **Screen locked, app keeps working**: after starting a route, the user can lock the phone. Beacon audio, speech, head tracking, nod/shake prompts, GPS progress and driver messages all continue in the background. The only step that needs the screen on is the tag scan (the camera doesn't run in the background). See section 3, "Background operation".
- **Stops are equipped** with printed AprilTag markers: **several per bay** (side of the street), as many as needed. Together they locate the user and guide them to the bay's waiting spot (Phase 3). For the field test: **A4 prints** at ~1.4 m height (stop pole, shelter, lamp post), facing the sidewalk.
- **Language**: the app speaks **English**. Stop and street names stay German.

## 2. User journey

### Phase 1: Set destination
1. "Hey Siri, navigate with NoValleyDuck." Siri: "Where to?" User: "Getreidegasse." (Two steps, because Siri can't take a free-text place inside the phrase.) Fallback: a big "Where to?" voice button in the app.
2. The app geocodes the destination (MapKit `MKLocalSearch`) and reads back the match: "Getreidegasse, Salzburg old town. Starting route."
3. The app plans the trip: walk, bus line, walk.
4. The app announces a summary: "Walk 4 minutes to Mirabellplatz, bus 2 towards Obergnigl, 3 stops, then walk 2 minutes."

### Phase 2: Walk with spatial audio (Soundscape-style)
How Microsoft Soundscape did it, and what we copy:
- **Audio beacon**: a steady, bell- or drum-like rhythm placed in 3D at the target's real-world position, so you hear *where* it is.
- **Facing feedback**: AirPods Pro head tracking keeps the beacon fixed in the world while you turn your head. When you face the target, the **beacon's tone changes**, so you can stand still, turn your head, and hear "that way". This is the key feature: you know you're *facing* the right way, not only walking it.
- **Distance updates**: regular spoken updates on the distance to the beacon.
- **Callouts**: spoken names of streets, intersections and places, played from their direction (a street to the right is heard in the right ear). They add awareness and are *not* turn-by-turn instructions. **We skip these (stretch goal)** and only do route callouts.
- Status: Microsoft retired the app in 2023 and open-sourced it. Community forks continue it on iOS (e.g. [rcos/soundscape](https://github.com/rcos/soundscape), which supports head tracking). **We haven't used the public repo so far.** Our audio is our own code (e.g. the marker beacon on branch `feature/marker-audio-guidance`, sounds in `NoValleyDuck/Sounds/`). The repo remains an optional reference.

What we add for routing:
- The walking path is split into **checkpoints**, placed at turns and roughly every 20–30 m. The beacon sits on the next checkpoint.
- On course or facing it: the "on-target" tone. Facing away: the normal beacon, still placed in 3D. A chime plays when a checkpoint is reached, and the beacon moves to the next one.
- Route callouts only: "Turn left in 10 metres", distance updates, "Arriving at stop Mirabellplatz."
- A checkpoint counts as **reached within 10 m**. The user is **off route if more than 30 m from the path for 10 s**. The app then recalculates and says so.
- **Head direction**: the phone is in the pocket, so its compass can't tell where the head faces, and AirPods yaw is only relative. Approach:
  1. At the start, the user holds the phone pointing forward and taps once. AirPods yaw is aligned to the phone's compass.
  2. While walking straight (GPS speed > ~0.8 m/s, steady course), the app assumes the head faces the walking direction and re-aligns AirPods yaw to the GPS course. This corrects drift.

### Phase 3: Find the stop and the waiting spot (AprilTag markers)
GPS gets the user to the stop. Markers do the last few metres: they confirm the right bay (side of the street) and guide the user to the **waiting spot**, the best place to wait at that bay (e.g. where the bus's front door stops, next to the stop sign).

**Markers at a stop**
- Each bay has **several markers** (as many as needed to cover it from where people approach), e.g. on the stop pole, the shelter and a lamp post.
- Each marker knows where it is relative to its bay's waiting spot (offset + which way it faces, measured when it's put up). So **any one marker the camera picks up tells the app where the user is**. When several are in view, their estimates are combined for a better position.
- **Marker IDs are reused between stops**, since tag25h9 only has 35 IDs. An ID only means something together with the stop the user is at, which comes from GPS. IDs must be **unique within a stop**, so the two sides of the same street never share an ID: GPS can't tell them apart.
- ID scheme (already on branch `feat/marker-detection`): **0–24** = bay and entrance markers, unique per stop. **25–34** = bus-door markers, unique across the demo.

**Flow**
1. Near the stop, the app says: "You're at Mirabellplatz. Take out your phone, hold it up and turn slowly."
2. Until a marker is picked up: a soft tick every ~2 s, so the user knows it's working. After 20 s with nothing: "No stop marker found. Turn slowly."
3. First valid marker → strong haptic, then the app checks which bay it belongs to:
   - **Correct bay**: "Bus 2 towards Obergnigl stops here. The waiting spot is 2 o'clock, 4 metres."
   - **Wrong bay**, e.g. the opposite side of the street: "This is the stop for the other direction. Your stop is across the street." The app routes to the correct bay, and Phase 2 repeats on a short leg.
   - **ID not at this stop**: ignored (the safety filter drops it).
4. **Guidance to the waiting spot**: the phone stays up while the user walks the last metres. Direction as a clock position plus distance ("2 o'clock, 4 metres"), and beeps that speed up as the user gets closer and pan left or right. Whenever another marker comes into view, the position updates.
5. Within ~0.5 m of the waiting spot: "You're at the waiting spot. Bus 2 stops right here." The phone can go back into the pocket, and Phase 4 starts.

**Safety filter** (on `feat/marker-detection`): a marker is only accepted with no corrected bits (hamming 0), margin ≥ 40, an ID that belongs to the current stop (or is a bus door), and seen in 3 of the last 5 frames. A wrong ID must never be spoken.

### Phase 4: Board the bus
1. A few minutes before the **scheduled** departure (no live data): "Bus 2 is due in 3 minutes. Do you want to board it?"
2. The user answers by **nodding** (yes) or **shaking the head** (no). Voice and a large on-screen button are fallbacks.
   - **Gestures only count in an ~8 s window right after a spoken question.** An earcon (short sound cue) closes the window. With no answer, the question repeats once. Nods while walking are ignored.
3. On yes, the **driver gets a pickup message** (via the teammate's PocketBase + driver web app, see section 3): "Stop at Mirabellplatz. A visually impaired passenger is waiting to board." The exit stop is **not** sent yet (see Phase 5).
4. **Boarding detection**: GPS speed > ~15 km/h for 20 s after the scheduled departure, moving along the line → the app asks "Are you on bus 2?" → nod → ride mode: "You're on bus 2, 4 stops to go."
5. **Bus didn't come or didn't stop**: 5 minutes after the scheduled departure, if the user hasn't moved: "Has bus 2 come yet?" Three answers:
   - *Not yet*: wait, and ask again 5 minutes later (buses are often late).
   - *It didn't stop*: a complaint is filed (line, stop, scheduled time, timestamp), and the app offers the next bus.
   - *I'm on it*: ride mode.
   A complaint is only ever filed on an explicit "it didn't stop".

### Phase 5: Ride
- Ride progress uses GPS along the trip's stop sequence.
- One stop before the exit: "Next stop is Hanuschplatz, that's yours. Request the stop?" The user **nods** to send the stop request to the driver, or **shakes the head** to decline and press the bus button themselves.
- **Autonomy (decided)**: the app never requests a stop without asking. It asks on every ride, and a nod is a single, eyes-free action.

### Phase 6: Get off and repeat
- After getting off, the user scans for a marker again to confirm the stop (Phase 3 steps 1–3, without the waiting-spot guidance and boarding part).
- Then Phase 2 runs on the last walking leg to the destination: "You've arrived at Getreidegasse."

## 3. System components

| Component | Tech | Notes |
|---|---|---|
| Voice entry | App Intents + App Shortcuts | Siri phrases must include the app name. A free-text destination can't be part of the phrase, so Siri asks a follow-up ("Where to?"). |
| Geocoding / walk routing | MapKit `MKLocalSearch`, `MKDirections` (`.walking`) | The walking polyline is split into checkpoints. Already in `Navigation/NavigationService.swift`. |
| Transit routing | **Transitous** plan API (`api.transitous.org/api/v5/plan`, JSON), a community MOTIS server fed with open GTFS including all Salzburg bus lines. It gives line, direction, stops, platform and times. Already in `Navigation/TransitousClient.swift` (on `main`). | Fallback when Transitous fails: MapKit only, which gives an ETA but **no line number** and guesses stops as the nearest transit POIs. Transitous policy: non-commercial use, a User-Agent with a **contact** (still `TODO` in `TransitousClient.contact`), and a visible link to transitous.org/sources. Bus only, so the driver flow fits. |
| Stops, bays, markers, timetables | PocketBase collections `stops`, `bays`, `markers`, `timetables` (+ `facts`, `requests`), imported from the Salzburg Verkehr GTFS feed by `tools/import_stops.py` (branch `feat/marker-detection`) | `DemoStop.json` / `DemoTimetable.json` in the app bundle are the offline fallback for the demo stop. |
| Spatial audio | `AVAudioEngine` + `AVAudioEnvironmentNode` (HRTF), `CMHeadphoneMotionManager` for head yaw, `CLLocationManager` for location, GPS course and compass heading (calibration only) | Microsoft Soundscape is open source (MIT), and its audio-beacon design can serve as a reference. |
| Head gestures | `CMHeadphoneMotionManager` pitch/yaw thresholds for nod/shake | Fallbacks: voice and a full-screen button. |
| Stop + waiting spot | tag25h9 pipeline (`CameraService`, `TagDetector`) + `MarkerPipeline` / `MarkerTracker` / `LocationGate` (branch `feat/marker-detection`) | New: marker offsets → user position relative to the waiting spot, combining several markers when visible. |
| Driver side | Teammate's **PocketBase** (public URL) + a **separate driver web app** built by the teammate | The app sends pickup, drop-off and complaint messages to PocketBase. Schema, access rules and the web app are **owned by the teammate and decided later**. The app only needs the PocketBase URL as one config value. No real bus integration. |
| Speech | `AVSpeechSynthesizer`, or VoiceOver announcements | Ducks the beacon audio while speaking. |
| Background operation | `UIBackgroundModes`: `audio` + `location`. `AVAudioSession` category `.playback`. `CLLocationManager.allowsBackgroundLocationUpdates = true` | See "Background operation" below. |

### Background operation (screen locked)
- **Keep the app alive**: from the moment a route starts until arrival, the audio session stays active and the `AVAudioEngine` keeps running (the beacon plays continuously, with silence between pings rendered by the engine, not by stopping it). Location updates run in the background too. Together these stop iOS from suspending the app.
- **Audio session**: category `.playback`, so sound keeps playing with the screen locked and the silent switch on. Speech uses the same engine/session and ducks the beacon. Other apps' audio (music, podcasts) gets ducked, not stopped.
- **Location**: "When In Use" permission is enough, as long as the route was started in the foreground or by Siri. iOS shows the blue location indicator while the app runs in the background. `pausesLocationUpdatesAutomatically = false`, `activityType = .otherNavigation`.
- **Head tracking + gestures**: `CMHeadphoneMotionManager` updates must keep arriving with the screen locked. **Verify this on a device first** (see section 6).
- **Timers and prompts** (bus due, "has bus 2 come yet?", next-stop question) run from location and audio callbacks while in the background, not from UI code.
- **Driver messages** to PocketBase are plain HTTPS requests, which work in the background while the app is kept alive.
- **Tag scan needs the screen**: when the user reaches the stop, the app says "Unlock your phone to scan the stop marker." If the app was in front when the phone was locked, unlocking returns straight to it and the camera starts automatically. If not, the app posts a local notification that opens the scan screen when tapped.
- **Siri start**: the App Intent must be able to start a route without the user handling the screen (it opens the app in the foreground briefly if iOS requires that, then the phone can be locked again).

## 4. Data model (minimal)

```
Stop        { id, name, coordinate }                       // PocketBase `stops`
Bay         { id, stop, label ("A", "B"), lines, coordinate, // PocketBase `bays` (= one side / platform)
              waitingSpot }                                  // NEW: where to wait, see below
Marker      { id, stop, tagId, kind (bay|entrance|vehicle), bay, vehicleLine, sizeM,   // PocketBase `markers`
              offsetToWaitingSpot, facing }                  // NEW: measured when the marker is put up
Trip        { legs: [Leg] }
Leg         = .walk(polyline, checkpoints: [Coordinate], toBay?)
            | .transit(line, headsign, fromBay, toBay, departure, stopsCount)
```
- `Stop`, `Bay` and `Marker` exist already on branch `feat/marker-detection` (`Data/Models.swift`). A tag ID is looked up **within the current stop** (`StopContext.markers[tagId]`).
- **New fields needed for the waiting spot**: each marker stores its offset to the waiting spot in its own frame, e.g. "1.2 m to the marker's left, 0.6 m out from it", plus which way it faces. Measured with a tape measure when the marker goes up, and stored with `tools/assign_marker.py`. Hack for tonight: hard-code the offsets for the test stop's markers.
- Requests and complaints in PocketBase are defined by the teammate.

## 5. Hackathon scope

**Team**: 4+ people, ~12 hours before the field test. The team splits the work by itself. The components in section 3 are natural units: spatial-audio walk, tag scan + stop logic, transit data → trip, driver side (teammate with PocketBase), and the glue (Siri, prompts, nod flow).

**One fixed route for the field test**: a short walk, then **one direct bus line** for 3–5 stops (**no transfers**), then a short walk to a landmark such as Getreidegasse. The app still plans generically, but only this route gets tags, testing and filming. The exact route is still to be picked (Transitous and the GTFS import in PocketBase are both available now).

**Must demo (MVP)**
1. Siri or in-app voice → destination.
2. Spatial audio beacon walking to a checkpoint with head tracking: the core "wow" moment.
3. Marker scan: right bay vs wrong bay (the wrong one redirects across the street), then guidance to the waiting spot.
4. Board prompt with a nod → message appears on the driver screen.
5. "Your stop is next" → exit-stop message on the driver screen.

**Goal: the whole trip works for real tomorrow on Salzburg streets and buses. Only the driver is faked.**

| Part | Real test tomorrow | Stage demo |
|---|---|---|
| Destination by voice | real | real |
| Walking route + spatial beacon | real GPS + AirPods | short staged course at the venue |
| Transit route + departures | real, from Transitous / the Salzburg GTFS (scheduled times, not live) | same data |
| Stop + waiting spot | several printed markers **temporarily** attached at both bays of the real stop (removable tape or held by a teammate, then removed), offsets measured on site | printed markers in the room |
| "Board bus X?" + nod | real, timed to the scheduled departure | real, with a "fast-forward" debug button |
| Driver notification | **faked**: a teammate holds the driver web app (PocketBase, public URL, so it works over mobile data) and acts as the driver | driver web app on a second device |
| Ride progress + "next stop, request it?" | real, from GPS along the trip's stop sequence | simulated ride (debug button) |
| Exit scan + last walk | real | staged |

Fallback if Transitous is down: the MapKit-only mode (no line numbers), or one hard-coded trip for the route we film.

**Stretch**
- Live transit data (real-time delays), street and place callouts (Soundscape-style), multi-leg transfers, complaints forwarded to the real operator.

**Out of scope**
- Real integration with bus operators, Android, indoor navigation.

## 6. Risks / feasibility notes
- **MapKit has no transit directions API** (only ETAs). We use Transitous for bus routes. It's a free community server with no uptime guarantee, so keep the MapKit-only fallback and the bundled demo data working.
- **Scheduled times only**: buses run late, so prompts are timed loosely (see Phase 4).
- **GPS accuracy (5–15 m)** can't tell which side of the street the user is on. That's exactly why the tags exist, which makes it a good pitch point.
- **Head-tracking drift**: handled by the start calibration plus re-alignment to the GPS course while walking (Phase 2). It fails when the user walks with their head turned sideways, so the re-alignment only happens on a steady course.
- **Finding a marker without sight**: A4 tags are detected from roughly 4–6 m (estimate, to be checked with the hall-test recorder). Several markers per bay at ~1.4 m make it likely that one is in view. Each marker's printed size is stored per marker (`sizeM`), since the distance is only as accurate as that number.
- **Waiting-spot accuracy** depends on the measured marker offsets and the pose estimate. Expect roughly ±0.5 m, which is enough to stand at the right door position, not more.
- **Siri phrase limits** (see the voice entry row in section 3).
- **Background head tracking is unverified**: whether AirPods motion updates keep arriving with the screen locked hasn't been tested yet. Build a tiny test first (lock the phone, nod, check the log). Fallback if it doesn't work: background audio and GPS still guide the user, with the beacon placed relative to the walking direction instead of the head, and voice or an AirPods stem press answering prompts.
- **Battery**: continuous GPS + audio + head tracking drains the battery. Bring a power bank for the field test.

## 7. Filming tomorrow: a field test, not a skit
**Approach: the team appears as itself, sighted developers field-testing their app.** There are no blindfolds and nobody plays a blind person. That's honest, and it can't come across as mocking.
- **Frame it as a test run**: "We built this for blind and visually impaired travellers. Here we are testing it on a real trip through Salzburg."
- **Make the invisible visible**: the audio is the product, so the viewer needs to *hear and see* it.
  - Record the AirPods audio (screen recording with audio, or a mic in an earbud) and lay it over the footage.
  - Add an on-screen overlay: arrow or beacon direction, "on target" flashes, "Tag 12: wrong side → cross the street", the driver card popping up.
  - A split screen of the phone and the street works well for the tag scan and the nod prompt.
- **Eyes-closed moments are fine if they're framed as testing** ("can I find the stop by sound alone?"). Keep them short, with a teammate spotting, and never near traffic.
- **The bus-driver scenes use a teammate as the driver**, holding the driver web page. Never show a real driver "failing" to stop. Real Salzburg drivers and passengers shouldn't be identifiable without asking.
- **Be honest in the pitch**: "Not yet tested with visually impaired users. That's the next step." Better still, contact the Blinden- und Sehbehindertenverband Salzburg for feedback and quote them if they reply.
- Remove all temporary tags from the stops after filming.

## 8. Still open
1. **Exact test route** (section 5).
2. **PocketBase**: requests, complaints and the driver web app are owned by the teammate and decided later. The pitch says complaints "would go to the operator".
3. **Two specs**: branch `feat/marker-detection` has its own `_specs/spec.md` ("HaltMal", Supabase, driver mode inside the iOS app). Parts of it are outdated (the branch itself uses PocketBase now). Decide which spec wins where they differ. This file is meant to be the source of truth.
4. **Transitous contact**: `TransitousClient.contact` is still a TODO. The usage policy requires a real contact.

## 9. Verification (demo script)
1. Ask Siri for a route → the summary is spoken, using real Salzburg line and stop names from the data.
2. Walk the staged course with eyes closed and AirPods in → reach the checkpoints by sound alone.
3. Scan a wrong-side marker → redirected. Scan a right-side marker → confirmed, then guided to the waiting spot. Cover that marker so another one is picked up → the guidance continues without a jump.
4. Nod at "board bus 2?" → the driver screen shows the pickup alert.
5. Simulated ride → "next stop is yours, request it?" → nod → the driver screen shows the exit stop.
6. Don't board, wait 5 minutes → "Has bus 2 come yet?" → "It didn't stop" → the complaint reaches PocketBase.
7. Nod repeatedly while walking with no question asked → nothing happens.
8. Start a route, lock the phone, put it in the pocket → the beacon, speech, nod prompts and driver messages all keep working until the next tag scan.
