# NoValleyDuck: app spec (v2, after grilling)

## Context

Hackathon project (Tourism Hackathon 2026). The app gets a blind or visually impaired person from anywhere to a destination like Getreidegasse in Salzburg, using only an iPhone and AirPods Pro, including public transport. We know it doesn't fit the official challenge brief. One possible pitch angle: **accessible tourism**, since a visually impaired visitor can't rely on locals or memorised routes in a city they don't know.

What already exists in the repo (`novalleyduck/`): a working AprilTag **tag25h9** detector in C (`ATDetector.c`, `ThirdParty/apriltag`). It has a Swift wrapper (`Camera/TagDetector.swift`), a 10 fps back-camera pipeline (`Camera/CameraService.swift`) and a debug preview (`Camera/CameraPreview.swift`). It returns tag ID, decision margin and pose, and from those it computes **distance in metres**. `App/Scanner.swift` ties these together. This spec builds on that milestone.


---

## 1. User and setup

- **User**: blind or visually impaired, already uses VoiceOver, owns an iPhone and AirPods Pro (or any AirPods with head tracking).
- **Phone stays in the pocket** while walking. It only comes out to scan markers at stops.
- **Stops are equipped** with printed AprilTag markers, one per platform or side of the street. Each tag ID maps to one specific platform. For the field test: **A4 prints (~16.3 cm tag) taped to the stop-sign pole at ~1.4 m height**, facing the sidewalk.
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
- Status: Microsoft retired the app in 2023 and open-sourced it. Community forks continue it on iOS (e.g. [rcos/soundscape](https://github.com/rcos/soundscape), which supports head tracking). We build our own small version and use their code as a reference.

What we add for routing:
- The walking path is split into **checkpoints**, placed at turns and roughly every 20–30 m. The beacon sits on the next checkpoint.
- On course or facing it: the "on-target" tone. Facing away: the normal beacon, still placed in 3D. A chime plays when a checkpoint is reached, and the beacon moves to the next one.
- Route callouts only: "Turn left in 10 metres", distance updates, "Arriving at stop Mirabellplatz."
- A checkpoint counts as **reached within 10 m**. The user is **off route if more than 30 m from the path for 10 s**. The app then recalculates and says so.
- **Head direction**: the phone is in the pocket, so its compass can't tell where the head faces, and AirPods yaw is only relative. Approach:
  1. At the start, the user holds the phone pointing forward and taps once. AirPods yaw is aligned to the phone's compass.
  2. While walking straight (GPS speed > ~0.8 m/s, steady course), the app assumes the head faces the walking direction and re-aligns AirPods yaw to the GPS course. This corrects drift.

### Phase 3: Confirm the stop (AprilTag)
1. Near the stop, the app says: "You're at Mirabellplatz. Take out your phone and slowly scan around."
2. Scanning feedback (kept simple, the camera only has to pick up the tag, so the user never needs to walk to it):
   - A soft tick every ~2 s while scanning, so the user knows it's working.
   - The camera detects a valid tag → strong haptic + spoken result immediately.
   - 20 s without a tag → "No stop marker found. Turn slowly."
3. A tag is detected and its ID is looked up:
   - **Correct platform**: "Correct stop. Bus 2 towards Obergnigl leaves from here."
   - **Wrong platform**, for example the opposite side of the street: "This is the stop for the other direction. Your stop is across the street." The app then routes to the correct platform, and Phase 2 repeats on a short leg.
   - **Unknown tag or not a stop tag**: ignored.
4. Only tags with hamming 0 and margin ≥ 40 are accepted. The filter is already in `CameraPreview`.

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
- After getting off, the user scans the stop marker again to confirm the stop (Phase 3, without the boarding part).
- Then Phase 2 runs on the last walking leg to the destination: "You've arrived at Getreidegasse."

## 3. System components

| Component | Tech | Notes |
|---|---|---|
| Voice entry | App Intents + App Shortcuts | Siri phrases must include the app name. A free-text destination can't be part of the phrase, so Siri asks a follow-up ("Where to?"). |
| Geocoding / walk routing | MapKit `MKLocalSearch`, `MKDirections` (`.walking`) | The walking polyline is split into checkpoints. |
| Transit routing / departures | **Not MapKit**. MapKit gives transit ETAs, not step-by-step transit routes. Source: the **Salzburg mobility data zip** the team has (format to confirm, probably GTFS). | If it's GTFS, `stops.txt` usually has one `stop_id` per platform/side, which maps 1:1 to tag IDs. `stop_times.txt` and `trips.txt` give line, headsign and departure times. A simple direct-bus search (origin platform → destination platform on the same trip) is enough. No transfers. |
| Spatial audio | `AVAudioEngine` + `AVAudioEnvironmentNode` (HRTF), `CMHeadphoneMotionManager` for head yaw, `CLLocationManager` for location, GPS course and compass heading (calibration only) | Microsoft Soundscape is open source (MIT), and its audio-beacon design can serve as a reference. |
| Head gestures | `CMHeadphoneMotionManager` pitch/yaw thresholds for nod/shake | Fallbacks: voice and a full-screen button. |
| Stop confirmation | Existing tag25h9 pipeline (`Scanner`, `CameraService`, `TagDetector`) | New: tag ID → platform lookup, scan tick, haptic and spoken result. |
| Driver side | Teammate's **PocketBase** (public URL) + a **separate driver web app** built by the teammate | The app sends pickup, drop-off and complaint messages to PocketBase. Schema, access rules and the web app are **owned by the teammate and decided later**. The app only needs the PocketBase URL as one config value. No real bus integration. |
| Speech | `AVSpeechSynthesizer`, or VoiceOver announcements | Ducks the beacon audio while speaking. |

## 4. Data model (minimal)

```
Stop        { id, name, coordinate }
Platform    { id, stopId, direction/lines served, coordinate, tagIds: [Int] }
Trip        { legs: [Leg] }
Leg         = .walk(polyline, checkpoints: [Coordinate], toPlatform?)
            | .transit(line, headsign, fromPlatform, toPlatform, departure, stopsCount)
```
For the demo, the tag → platform mapping is a static JSON file in the app bundle. What gets stored in PocketBase (requests, complaints) is defined by the teammate.

## 5. Hackathon scope

**Team**: 4+ people, ~12 hours before the field test. The team splits the work by itself. The components in section 3 are natural units: spatial-audio walk, tag scan + stop logic, transit data → trip, driver side (teammate with PocketBase), and the glue (Siri, prompts, nod flow).

**One fixed route for the field test**: a short walk, then **one direct bus line** for 3–5 stops (**no transfers**), then a short walk to a landmark such as Getreidegasse. The app still plans generically, but only this route gets tags, testing and filming. The exact route gets picked once the teammate's data arrives.

**Must demo (MVP)**
1. Siri or in-app voice → destination.
2. Spatial audio beacon walking to a checkpoint with head tracking: the core "wow" moment.
3. Tag scan: right stop vs wrong stop, with the wrong one redirecting across the street.
4. Board prompt with a nod → message appears on the driver screen.
5. "Your stop is next" → exit-stop message on the driver screen.

**Goal: the whole trip works for real tomorrow on Salzburg streets and buses. Only the driver is faked.**

| Part | Real test tomorrow | Stage demo |
|---|---|---|
| Destination by voice | real | real |
| Walking route + spatial beacon | real GPS + AirPods | short staged course at the venue |
| Transit route + departures | real, from the Salzburg data (scheduled times, not live) | same data |
| Stop confirmation | printed tags **temporarily** attached at both sides of the real stop (removable tape or held by a teammate, then removed) | printed tags in the room |
| "Board bus X?" + nod | real, timed to the scheduled departure | real, with a "fast-forward" debug button |
| Driver notification | **faked**: a teammate holds the driver web app (PocketBase, public URL, so it works over mobile data) and acts as the driver | driver web app on a second device |
| Ride progress + "next stop, request it?" | real, from GPS along the trip's stop sequence | simulated ride (debug button) |
| Exit scan + last walk | real | staged |

Fallback if the data takes too long to parse: one hard-coded trip for the route we film.

**Stretch**
- Live transit data (real-time delays), street and place callouts (Soundscape-style), multi-leg transfers, complaints forwarded to the real operator.

**Out of scope**
- Real integration with bus operators, Android, indoor navigation.

## 6. Risks / feasibility notes
- **MapKit has no transit directions API.** We use the teammate's Salzburg data instead.
- **Scheduled times only**: buses run late, so prompts are timed loosely (see Phase 4).
- **GPS accuracy (5–15 m)** can't tell which side of the street the user is on. That's exactly why the tags exist, which makes it a good pitch point.
- **Head-tracking drift**: handled by the start calibration plus re-alignment to the GPS course while walking (Phase 2). It fails when the user walks with their head turned sideways, so the re-alignment only happens on a steady course.
- **Finding a tag without sight**: A4 tags are detected from roughly 4–6 m (estimate, to be checked on the street). The fixed height (~1.4 m on the pole) means the phone points there naturally. Print size is already configurable (`markerSizeCm`).
- **Siri phrase limits** (see the voice entry row in section 3).

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
1. **Salzburg data**: a teammate has the zip. Its format (GTFS?) gets checked once it's in the repo (e.g. `data/`). Until then, plan with a hard-coded trip.
2. **Exact test route**: picked from the data once it arrives (section 5).
3. **PocketBase**: schema, access rules and driver web app are owned by the teammate and decided later. The pitch says complaints "would go to the operator".

## 9. Verification (demo script)
1. Ask Siri for a route → the summary is spoken, using real Salzburg line and stop names from the data.
2. Walk the staged course with eyes closed and AirPods in → reach the checkpoints by sound alone.
3. Scan the wrong-side tag → redirected. Scan the right one → confirmed.
4. Nod at "board bus 2?" → the driver screen shows the pickup alert.
5. Simulated ride → "next stop is yours, request it?" → nod → the driver screen shows the exit stop.
6. Don't board, wait 5 minutes → "Has bus 2 come yet?" → "It didn't stop" → the complaint reaches PocketBase.
7. Nod repeatedly while walking with no question asked → nothing happens.
