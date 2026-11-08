# AGENTS.md

NoValleyDuck is an iOS app that guides blind and visually impaired people door to door through Salzburg, including the bus. It uses spatial audio through AirPods Pro, AprilTag markers at bus stops, and nod/shake head gestures.

**Read [SPEC.md](SPEC.md) first.** It holds the product spec, every decision taken so far and what is still open. If the code and the spec disagree, ask before changing either.

## Hackathon mode

This is a hackathon project (Tourism Hackathon 2026), with a real field test on Salzburg streets and buses planned for 2026-11-08.

- Quick and dirty is fine. Hard-coded values, a debug button, a TODO or a fake are all acceptable if they get the demo working. Mark shortcuts with `// HACK: <what is faked>` so they can be found later.
- Working on a real iPhone with real AirPods beats clean architecture. Don't add layers, protocols or abstractions "for later".
- No test suite is required. Do verify on a device when you touch camera, audio, motion or location code (see Running).
- Don't refactor code you weren't asked to touch. Several people are working in parallel.
- Never cut accessibility, though: every user-facing feature must work eyes-free, by voice, sound, haptics or head gesture (see Wording and accessibility).

## Repo layout

```
AGENTS.md / CLAUDE.md           agent instructions (CLAUDE.md just imports this file)
SPEC.md                         product spec (source of truth)
NoValleyDuck.xcodeproj          Xcode project, app target + NoValleyDuckTests (Swift Testing), scheme NoValleyDuck
NoValleyDuck-Info.plist         extra Info.plist keys (background modes audio + location, file sharing)
NoValleyDuck/
  App/                          app entry, RiderView (main screen), Siri intents ("Guide me with NoValleyDuck"), DebugView (marker dev screen), Config (PocketBase URL)
  Trip/                         TripController (the whole journey, SPEC §2), Prompter (questions + 8 s answer window),
                                RouteGeometry (checkpoints, off-route), WaitingSpot (marker offsets → waiting spot)
  Audio/                        AudioGuide (one engine: HRTF beacon, earcons, speech), HeadTracker (AirPods yaw, nod/shake), VoiceInput
  Navigation/                   NavigationService (MapKit + Transitous plan), TransitousClient, models, route test screen
  Guidance/                     MarkerPipeline (camera → safety filter → lock/events), MarkerTracker, GuidanceEngine, hall-test recorder
  Data/                         PocketBase client, stops/bays/markers/timetables, DriverClient (pickup, stop request, complaint)
  Camera/                       CameraService (AVFoundation, 1080p, 10 fps), TagDetector (Swift wrapper), CameraPreview (debug overlay)
  Sounds/                       beacon and cue sounds
  ATDetector.c/.h               C glue around the AprilTag library (tag25h9 + pose incl. rotation)
  ThirdParty/apriltag/          vendored AprilTag C library: do not modify
  NoValleyDuck-Bridging-Header.h
NoValleyDuckTests/              unit tests (run on a simulator)
tools/                          PocketBase setup, GTFS import, marker PDFs and assignment (see README.md)
_specs/spec.md                  older "HaltMal" spec from feat/marker-detection (SPEC.md wins)
```

Debug launch arguments: `-startDestination "Getreidegasse"` starts a route without voice, `-navTestDestination "Mirabellplatz"` logs a plan. The rider screen's Debug menu has fast-forward (bus time), simulate ride, skip marker scan and the demo-stop switch.

The Xcode project uses **file-system synchronized groups**. A new file inside `NoValleyDuck/` gets picked up automatically, so don't edit `project.pbxproj` to add files.

## Tech and conventions

- Swift 6.4 compiler (Xcode 27), but the target builds in **Swift 5 language mode** (`SWIFT_VERSION = 5.0`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`), so strict data-race checking is off. SwiftUI, iOS 17+. Bundle ID `com.novalleyduck.NoValleyDuck`.
- State lives in `@Observable @MainActor` classes (see `Trip/TripController.swift`). Camera frames are processed on a serial background queue and handed to the main actor.
- Logging uses `os.Logger` with subsystem `com.novalleyduck.NoValleyDuck` and a category per area (`tags`, `audio`, `route`, …).
- Apple frameworks first: MapKit (geocoding, walking routes), AVAudioEngine + `AVAudioEnvironmentNode` (spatial audio), `CMHeadphoneMotionManager` (AirPods head tracking and gestures), CoreLocation, AVSpeechSynthesizer, App Intents (Siri). Ask before adding a dependency.
- MapKit has **no** public-transport directions. Bus routes come from Transitous (`Navigation/TransitousClient.swift`, JSON API), with a MapKit-only fallback (SPEC §3).
- AprilTag family is **tag25h9**. Only accept detections with `hamming == 0 && margin >= 40`. Marker size is stored per marker (`Marker.sizeM`, measured after printing, SPEC §6), so don't hard-code it elsewhere.
- Any new permission (location, motion, microphone, speech) needs its `INFOPLIST_KEY_NS…UsageDescription` build setting. Write it in plain English and say why the app needs it.
- Driver side and complaints go to a teammate's **PocketBase** (public URL). Its schema and the driver web app belong to that teammate. Keep the URL in one config constant and don't invent collections without checking with them.
- Comments explain *why*, briefly. Match the style already in `Camera/`.

## Wording and accessibility

The users are blind or visually impaired. This affects code, copy and docs.

- Never phrase anything as if the user can see: no "look at", "see the sign", "watch for". Write "hold your phone up and turn slowly", "the camera found the stop marker", "face the beacon".
- All spoken text is **English**. Stop and street names stay German.
- Every prompt must be answerable without the screen: nod/shake (only inside the ~8 s window after a question), voice, or one large on-screen button as a fallback.
- Support VoiceOver on every screen: labels on all controls, no information carried by colour alone.
- Speech ducks the beacon audio. Never play two spoken messages over each other.
- Respectful framing in demos and docs: the user is competent and in control, and the app supports them. See SPEC §7.

## Running

Camera, AirPods head tracking, GPS and haptics need a **real iPhone**. The simulator only helps for UI and logic.

Compile check from the command line (signing is off, so it works on any machine; it does not install anything):

```bash
xcodebuild -project NoValleyDuck.xcodeproj -scheme NoValleyDuck -destination 'generic/platform=iOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

To run on a device, open `NoValleyDuck.xcodeproj` in Xcode, pick the phone and press Run. Signing uses the team already set in the project. Tag detections are logged under the `tags` category, so filter the Xcode console or Console.app by `com.novalleyduck.NoValleyDuck`.

## Git

Repo: `github.com/FrancescoLanthaler/novalleyduck`, default branch `main`.

- Several people push to the same repo tonight: pull before you start, keep commits small (one feature per commit) and push often to keep merge conflicts small.
- Commit messages follow the existing style: `feat: …`, `fix: …`, short and in English.
- `project.pbxproj` conflicts are the most painful kind. Avoid touching build settings unless needed, and tell the team when you do.
- Never commit `DerivedData/`, `xcuserdata/` (already in `.gitignore`) or secrets. PocketBase admin credentials stay out of the repo.
