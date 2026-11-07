HaltMal iOS app – build spec
Nov 7, 2026 · @Master Oogway
Goal and scope
A native iPhone app that finds AprilTag markers at bus stops and on buses and guides a blind rider to the right bay by sound, vibration and speech. It speaks live stop information, sends an "I'm waiting" request to the driver, and lets drivers correct stop information with one tap. One codebase, two roles: Rider and Driver (role picker on first launch).
MVP for the demo (Sunday 10:00 freeze)
• Detect tag25h9 markers from the back camera at 10 fps, with a safety filter so a wrong ID is never spoken
• Distance and direction to the marker, given as clock directions ("2 o'clock, 4 metres") plus beeps that speed up and pan left or right, and haptics
• On arrival: speak bay, lines, next departures and current facts with their age
• "I'm waiting for line X" request with a needs choice, stored in Supabase
• Driver mode: live list of waiting riders per bay; big buttons for "ramp broken", "bay blocked", "stop moved", "all OK"
• A driver report changes what the rider hears within 2 seconds
Out of scope tonight: real-time bus positions (the challenge data has scheduled times only), accounts and login, Android, offline maps, payments.
Targets: iOS 17+, iPhone 12 or newer (pose works on any iPhone; LiDAR not needed), Xcode 16, Swift 5.10+, SwiftUI.
Architecture
Everything time-critical runs on the phone; the network only carries stop data, live facts and requests, so guidance keeps working if the connection drops.
Threading: camera frames, detection and MarkerTracker run on the frame queue; GuidanceEngine output is sent to the main thread, where Feedback and SwiftUI live. Supabase calls are async and never block the frame queue. Cache the current stop's markers, bays and facts in memory as soon as the stop is known.
Project setup
One Xcode project, the AprilTag C library compiled straight into the app target, one small C wrapper that Swift talks to, and Supabase via Swift Package Manager.
1. Create the project. Xcode → iOS App → name HaltMal, interface SwiftUI, language Swift, minimum deployment iOS 17.
2. Add the AprilTag library (BSD 2-Clause licence, credit it in the README).
    ◦ git clone https://github.com/AprilRobotics/apriltag and copy into HaltMal/ThirdParty/apriltag/ only: apriltag.c/.h, apriltag_quad_thresh.c, apriltag_pose.c/.h, apriltag_math.h, tag25h9.c/.h and the whole common/ folder.
    ◦ Add these files to the app target (Add Files → "Create groups", target ticked).
    ◦ If a common/*.c file fails to compile (for example a Windows-only threads shim), remove it from the target.
    ◦ Build Settings → Header Search Paths: $(SRCROOT)/HaltMal/ThirdParty/apriltag (recursive).
    ◦ Build Phases → Compile Sources: add the flag -w to the AprilTag .c files to silence their warnings.
3. Add the wrapper ATDetector.h and ATDetector.c (code in the next section) and a bridging header HaltMal-Bridging-Header.h containing only #include "ATDetector.h". Set Build Settings → Objective-C Bridging Header to its path.
4. Packages: File → Add Package Dependencies → https://github.com/supabase/supabase-swift (product Supabase).
5. Info.plist keys:
    ◦ NSCameraUsageDescription: "HaltMal uses the camera to find stop markers and guide you to your bus."
    ◦ NSLocationWhenInUseUsageDescription: "HaltMal uses your location to know which stop you are at."
6. Config: a Config.swift with supabaseURL and the anon key (allowed in apps per the hackathon rules only with Row Level Security on). Keep any other key in n8n.
Suggested folders
HaltMal/
  App/            HaltMalApp.swift, RolePicker.swift, Config.swift
  Camera/         CameraService.swift, TagDetector.swift
  Guidance/       MarkerTracker.swift, GuidanceEngine.swift, Feedback.swift
  Data/           Models.swift, StopRepository.swift, LocationGate.swift
  Rider/          RiderView.swift, RequestSheet.swift
  Driver/         DriverView.swift, ReportButtons.swift
  ThirdParty/apriltag/   (C sources)
  ATDetector.h / ATDetector.c, HaltMal-Bridging-Header.h
Detection pipeline
The camera delivers 1080p frames in the YUV format; the luma plane is a grayscale image, so it goes straight into AprilTag with no copy or conversion. Process at most 10 frames per second on one serial queue, and drop late frames.
Pose trick: the detector always estimates pose with a tag size of 1.0. Translation scales linearly with tag size, so Swift multiplies it by each marker's real printed size from the database. That way A3 and A4 markers can be mixed.
ATDetector.h
#ifndef AT_DETECTOR_H
#define AT_DETECTOR_H
#include <stdint.h>

typedef struct {
    int    id;
    int    hamming;          // bits corrected; only 0 is accepted for speech
    float  decision_margin;  // higher = more confident
    double center_x, center_y;
    double corners[8];       // x0,y0,...,x3,y3 in pixels
    int    has_pose;
    double tx, ty, tz;       // translation for tag size 1.0 (scale in Swift)
    double pose_error;
} at_detection;

void *at_create(double quad_decimate, int nthreads);
void  at_set_decimate(void *ctx, double quad_decimate);
int   at_detect(void *ctx, const uint8_t *gray, int width, int height, int stride,
                double fx, double fy, double cx, double cy,
                at_detection *out, int max_out);
void  at_destroy(void *ctx);
#endif
ATDetector.c
#include "ATDetector.h"
#include "apriltag.h"
#include "tag25h9.h"
#include "apriltag_pose.h"
#include "common/image_u8.h"
#include "common/zarray.h"
#include "common/matd.h"
#include <stdlib.h>

typedef struct { apriltag_detector_t *td; apriltag_family_t *tf; } at_ctx;

void *at_create(double quad_decimate, int nthreads) {
    at_ctx *c = calloc(1, sizeof(at_ctx));
    c->tf = tag25h9_create();
    c->td = apriltag_detector_create();
    apriltag_detector_add_family_bits(c->td, c->tf, 1); // correct at most 1 bit
    c->td->quad_decimate     = (float)quad_decimate;    // 1.0 = full resolution, best range
    c->td->quad_sigma        = 0.0f;
    c->td->nthreads          = nthreads;
    c->td->refine_edges      = 1;
    c->td->decode_sharpening = 0.25;
    return c;
}

void at_set_decimate(void *ctx, double q) { ((at_ctx *)ctx)->td->quad_decimate = (float)q; }

int at_detect(void *ctx, const uint8_t *gray, int width, int height, int stride,
              double fx, double fy, double cx, double cy,
              at_detection *out, int max_out) {
    at_ctx *c = (at_ctx *)ctx;
    image_u8_t im = { .width = width, .height = height, .stride = stride, .buf = (uint8_t *)gray };
    zarray_t *dets = apriltag_detector_detect(c->td, &im);
    int n = zarray_size(dets), k = 0;
    for (int i = 0; i < n && k < max_out; i++) {
        apriltag_detection_t *d;
        zarray_get(dets, i, &d);
        at_detection *o = &out[k++];
        o->id = d->id; o->hamming = d->hamming; o->decision_margin = d->decision_margin;
        o->center_x = d->c[0]; o->center_y = d->c[1];
        for (int j = 0; j < 4; j++) { o->corners[2*j] = d->p[j][0]; o->corners[2*j+1] = d->p[j][1]; }
        o->has_pose = 0;
        if (fx > 0) {
            apriltag_detection_info_t info = { .det = d, .tagsize = 1.0,
                                               .fx = fx, .fy = fy, .cx = cx, .cy = cy };
            apriltag_pose_t pose;
            o->pose_error = estimate_tag_pose(&info, &pose);
            o->tx = MATD_EL(pose.t, 0, 0); o->ty = MATD_EL(pose.t, 1, 0); o->tz = MATD_EL(pose.t, 2, 0);
            o->has_pose = 1;
            matd_destroy(pose.R); matd_destroy(pose.t);
        }
    }
    apriltag_detections_destroy(dets);
    return k;
}

void at_destroy(void *ctx) {
    at_ctx *c = (at_ctx *)ctx;
    apriltag_detector_destroy(c->td);
    tag25h9_destroy(c->tf);
    free(c);
}
TagDetector.swift
import Foundation
import CoreGraphics

struct TagDetection {
    let id: Int
    let hamming: Int
    let margin: Float
    let center: CGPoint
    let corners: [CGPoint]
    let unitTranslation: SIMD3<Double>?   // multiply by marker size in metres
    var sidePixels: Double {              // mean edge length, for the no-pose fallback
        zip(corners, Array(corners.dropFirst()) + [corners[0]])
            .map { hypot($0.x - $1.x, $0.y - $1.y) }.reduce(0, +) / 4
    }
}

final class TagDetector {
    private let ctx: UnsafeMutableRawPointer
    private var out = [at_detection](repeating: at_detection(), count: 16)

    init(decimate: Double = 1.0, threads: Int32 = 4) { ctx = at_create(decimate, threads)! }
    deinit { at_destroy(ctx) }
    func setDecimate(_ q: Double) { at_set_decimate(ctx, q) }

    func detect(gray: UnsafePointer<UInt8>, width: Int, height: Int, rowStride: Int,
                fx: Double, fy: Double, cx: Double, cy: Double) -> [TagDetection] {
        let n = out.withUnsafeMutableBufferPointer { buf in
            at_detect(ctx, gray, Int32(width), Int32(height), Int32(rowStride),
                      fx, fy, cx, cy, buf.baseAddress, Int32(buf.count))
        }
        return (0..<Int(n)).map { i in
            let d = out[i]
            let c = withUnsafeBytes(of: d.corners) { Array($0.bindMemory(to: Double.self)) }
            return TagDetection(
                id: Int(d.id), hamming: Int(d.hamming), margin: d.decision_margin,
                center: CGPoint(x: d.center_x, y: d.center_y),
                corners: stride(from: 0, to: 8, by: 2).map { CGPoint(x: c[$0], y: c[$0 + 1]) },
                unitTranslation: d.has_pose == 1 ? SIMD3(d.tx, d.ty, d.tz) : nil)
        }
    }
}
CameraService.swift
import AVFoundation
import QuartzCore
import simd

final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let frameQueue = DispatchQueue(label: "camera.frames")
    let detector = TagDetector()
    private var lastProcessed: CFTimeInterval = 0
    var minInterval: CFTimeInterval = 0.1                 // 10 fps; raise when the phone gets hot
    var onFrame: (([TagDetection], CGSize) -> Void)?      // called on frameQueue
    private var fallbackFx = 0.0

    func configure() throws {
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        else { throw NSError(domain: "camera", code: 1) }
        session.addInput(try AVCaptureDeviceInput(device: device))
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)
        session.addOutput(output)
        if let conn = output.connection(with: .video), conn.isCameraIntrinsicMatrixDeliverySupported {
            conn.isCameraIntrinsicMatrixDeliveryEnabled = true
        }
        // Fallback focal length from the horizontal field of view (degrees), for 1920 px wide frames
        let hfov = Double(device.activeFormat.videoFieldOfView) * .pi / 180
        fallbackFx = 1920 / (2 * tan(hfov / 2))
        try device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        device.unlockForConfiguration()
        session.commitConfiguration()
    }

    func start() { sessionQueue.async { self.session.startRunning() } }
    func stop()  { sessionQueue.async { self.session.stopRunning() } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastProcessed >= minInterval,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastProcessed = now

        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        var fx = fallbackFx, fy = fallbackFx, cx = Double(w) / 2, cy = Double(h) / 2
        if let data = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                      attachmentModeOut: nil) as? Data {
            let m = data.withUnsafeBytes { $0.load(as: matrix_float3x3.self) }
            fx = Double(m.columns.0.x); fy = Double(m.columns.1.y)
            cx = Double(m.columns.2.x); cy = Double(m.columns.2.y)
        }

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return }
        let dets = detector.detect(gray: base.assumingMemoryBound(to: UInt8.self),
                                   width: w, height: h,
                                   rowStride: CVPixelBufferGetBytesPerRowOfPlane(pb, 0),
                                   fx: fx, fy: fy, cx: cx, cy: cy)
        onFrame?(dets, CGSize(width: w, height: h))
    }
}
Orientation note: frames arrive in the sensor's landscape orientation even when the phone is held upright. With the phone in portrait, the rider's left/right corresponds to the camera frame's y axis, not x. Check the sign once: hold a marker to the right of the phone and see whether ty is positive or negative, then fix it in GuidanceEngine.
Thermal: watch ProcessInfo.processInfo.thermalState; at .serious, set minInterval = 0.2 and setDecimate(2.0), and announce "reduced range".
Safety filter and app states
Rule number one: the app never speaks a marker it isn't sure about. A detection only counts if all four checks pass:
1. hamming == 0 (no corrected bits)
2. decision_margin >= minMargin (start at 40; log margins in the hall test and tune)
3. The ID belongs to the current stop (from GPS, or the demo override) or to a vehicle marker
4. The same ID was accepted in 3 of the last 5 processed frames
Once locked, keep the lock while the marker reappears; release it after 1.5 s without a sighting.
ID plan for tag25h9 (35 IDs): 0–24 for bays and entrances, unique within a stop; 25–34 for bus-door markers, unique within the demo. For a real region, use a 36h11 family for vehicles, since buses move between stops.
MarkerTracker.swift
import QuartzCore

final class MarkerTracker {
    private var history: [[Int]] = []
    private(set) var locked: Int?
    private var lastSeen: CFTimeInterval = 0
    var minMargin: Float = 40
    let window = 5, needed = 3, lostAfter: CFTimeInterval = 1.5

    /// Returns the locked detection for this frame, or nil.
    func update(_ dets: [TagDetection], validIds: Set<Int>, preferred: Int?,
                now: CFTimeInterval = CACurrentMediaTime()) -> TagDetection? {
        let good = dets.filter { $0.hamming == 0 && $0.margin >= minMargin && validIds.contains($0.id) }
        history.append(good.map(\.id))
        if history.count > window { history.removeFirst() }

        if let l = locked {
            if let d = good.first(where: { $0.id == l }) { lastSeen = now; return d }
            if now - lastSeen > lostAfter { locked = nil }
            return nil
        }
        var counts: [Int: Int] = [:]
        history.joined().forEach { counts[$0, default: 0] += 1 }
        let candidates = counts.filter { $0.value >= needed }.map(\.key)
        guard !candidates.isEmpty else { return nil }
        let pick = candidates.contains(preferred ?? -1) ? preferred! :
            candidates.max { a, b in size(a, good) < size(b, good) }!   // else the biggest (nearest)
        guard let d = good.first(where: { $0.id == pick }) else { return nil }
        locked = pick; lastSeen = now
        return d
    }

    func reset() { history.removeAll(); locked = nil }
    private func size(_ id: Int, _ good: [TagDetection]) -> Double {
        good.first { $0.id == id }?.sidePixels ?? 0
    }
}
Rider states
State
Entered when
What the rider hears and feels
No stop
GPS not within 150 m of a known stop
"No stop nearby." Offer the demo override in settings
Searching
Stop known, nothing locked
"Gmunden station. Hold the phone upright and turn slowly." Soft tick every 2 s
Found
First lock on a bay marker
One announcement: "Bay B, 7 metres, at 2 o'clock." Then beeps
Approaching
Locked, distance > 1.5 m
Beeps faster as distance drops, panned left or right; light haptic pulse every 0.5 s
Arrived
Locked, distance ≤ 1.5 m
Long haptic, then full stop info (see the feedback section)
Waiting
Rider sent "I'm waiting for line X"
"The driver of line X knows you're here." Repeats only on changes
Boarding
Bus-door marker of the requested line locked
"Line X door, 3 metres, 12 o'clock." Same beeps
Lost
Lock released while Found or Approaching
"Lost the marker, turn slowly." Back to Searching
Demo override: in the hall, GPS says Messezentrum, not Gmunden. Add a hidden settings switch "Demo stop: Gmunden station" that forces the current stop.
Distance, direction and feedback
Guide with three channels at once: clock directions in speech (the convention orientation-and-mobility trainers teach blind travellers), beeps that speed up and pan towards the marker, and haptics that get stronger as you approach.
Maths
• With pose: t = unitTranslation × markerSize. Distance d = |t|. In portrait, lateral offset is t.y (sign checked once, see orientation note); forward is t.z. Bearing θ = atan2(lateral, forward).
• Without pose (no intrinsics): d ≈ fx × markerSize / sidePixels; bearing from the marker centre's offset to the image centre, divided by fy.
• Clock hour: h = round(θ in degrees / 30), spoken as (12 + h) mod 12, with 0 read as 12. So +30° is "1 o'clock", −60° is "10 o'clock".
• Smooth d and θ with an exponential average (α = 0.3) so the cues don't jitter.
GuidanceEngine.swift
import Foundation
import CoreGraphics

struct Guidance { let distance: Double; let bearingDeg: Double
    var clockHour: Int { let h = Int((bearingDeg / 30).rounded()); let c = (12 + h) % 12; return c == 0 ? 12 : c }
    var spoken: String { distance <= 1.5 ? "right in front of you"
        : "\(Int(distance.rounded())) metres, at \(clockHour) o'clock" }
}

final class GuidanceEngine {
    var lateralSign: Double = 1          // flip to -1 if left/right comes out reversed
    private var d: Double?, th: Double?
    let alpha = 0.3

    func update(_ det: TagDetection, markerSize: Double, fx: Double, fy: Double, imageSize: CGSize) -> Guidance {
        var dist: Double, bearing: Double
        if let u = det.unitTranslation {
            let t = u * markerSize
            dist = (t * t).sum().squareRoot()
            bearing = atan2(lateralSign * t.y, t.z) * 180 / .pi
        } else {
            dist = fx * markerSize / max(det.sidePixels, 1)
            bearing = atan((Double(det.center.y) - imageSize.height / 2) / fy) * 180 / .pi * lateralSign
        }
        d  = d.map  { $0 + alpha * (dist - $0) } ?? dist
        th = th.map { $0 + alpha * (bearing - $0) } ?? bearing
        return Guidance(distance: d!, bearingDeg: max(-90, min(90, th!)))
    }
    func reset() { d = nil; th = nil }
}
Feedback.swift: beeps, haptics, speech
import AVFoundation
import UIKit

final class Feedback {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var beep: AVAudioPCMBuffer!
    private var timer: Timer?
    private let synth = AVSpeechSynthesizer()
    private var lastSpoken = (text: "", at: Date.distantPast)
    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    var language = "de-DE"                          // or "en-GB"

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        beep = Feedback.tone(hz: 880, seconds: 0.06, format: format)
        try? engine.start()
    }

    private var current: Guidance?
    private var lastBeep = Date.distantPast

    /// Call on the MAIN thread for every guidance update. One fast timer checks
    /// whether the next beep is due, so changing distance never resets the rhythm.
    func guide(_ g: Guidance) {
        current = g
        player.pan = Float(max(-1, min(1, g.bearingDeg / 45)))
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        }
    }
    private func tick() {
        guard let g = current else { return }
        let interval = max(0.15, min(1.2, 0.15 + g.distance * 0.12))
        guard Date().timeIntervalSince(lastBeep) >= interval else { return }
        lastBeep = Date()
        player.scheduleBuffer(beep, at: nil)
        if !player.isPlaying { player.play() }
        haptic.impactOccurred(intensity: CGFloat(max(0.3, min(1, 3 / max(g.distance, 1)))))
    }
    func stopGuiding() { timer?.invalidate(); timer = nil; current = nil }
    func arrived() { stopGuiding(); UINotificationFeedbackGenerator().notificationOccurred(.success) }

    /// Speaks via VoiceOver if it is running, else via the synthesizer. Drops repeats within 4 s.
    func say(_ text: String, urgent: Bool = false) {
        if text == lastSpoken.text && Date().timeIntervalSince(lastSpoken.at) < 4 && !urgent { return }
        lastSpoken = (text, Date())
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: text)
        } else {
            if urgent { synth.stopSpeaking(at: .immediate) }
            let u = AVSpeechUtterance(string: text)
            u.voice = AVSpeechSynthesisVoice(language: language)
            synth.speak(u)
        }
    }

    private static func tone(hz: Double, seconds: Double, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        for ch in 0..<Int(format.channelCount) {
            let p = buf.floatChannelData![ch]
            for i in 0..<Int(frames) {
                let env = min(1, Double(i) / 200, Double(Int(frames) - i) / 200)   // soft edges, no clicks
                p[i] = Float(sin(2 * .pi * hz * Double(i) / format.sampleRate) * 0.4 * env)
            }
        }
        return buf
    }
}
What to say on arrival (built from the bay's facts; keep it under ~15 seconds):
"Bay B, Gmunden station. Line X to Bad Ischl in 4 minutes, low-floor bus. Step-free boarding, confirmed by a driver 20 minutes ago. Double-tap anywhere to tell the driver you are waiting."
Speak the age of every fact ("20 minutes ago", "3 days ago"); that is the product's core promise. If a fact is Unclear in the trust engine, say so: "Ramp status unclear, last report 2 weeks old."
Data model and backend
Five tables in the shared Supabase, Realtime on requests and facts, and departures as a static JSON file in the app bundle (scheduled times from the VVOÖ data). Trust is computed in the app with the formula from the research tab, so it's easy to show and tweak.
SQL (run in the Supabase SQL editor)
create table stops (
  id text primary key,            -- e.g. 'gmunden_bf'
  name text not null,
  lat double precision not null,  -- from the VVOÖ stop data
  lon double precision not null
);

create table bays (
  id text primary key,            -- e.g. 'gmunden_bf_B'
  stop_id text not null references stops(id),
  label text not null,            -- 'B'
  lines text[] not null default '{}'
);

create table markers (
  id bigint generated always as identity primary key,
  stop_id text references stops(id),          -- null for vehicle markers
  tag_id int not null check (tag_id between 0 and 34),
  kind text not null check (kind in ('bay','entrance','vehicle')),
  bay_id text references bays(id),
  vehicle_line text,                          -- for kind = 'vehicle'
  size_m double precision not null,           -- outer black square edge, measured after printing
  unique (stop_id, tag_id)
);

create table facts (
  id bigint generated always as identity primary key,
  subject_type text not null check (subject_type in ('stop','bay','vehicle')),
  subject_id text not null,
  key text not null,          -- step_free_boarding | ramp_working | bay_blocked | stop_moved | bay_changed
  value text not null,        -- 'true' / 'false' / short text
  source_role text not null check (source_role in ('official','driver','rider','local','host')),
  evidence text not null default 'none' check (evidence in ('photo','scan','none')),
  observed_at timestamptz not null default now(),
  valid_until timestamptz,    -- temporary barriers expire
  note text
);

create table requests (
  id uuid primary key default gen_random_uuid(),
  stop_id text not null references stops(id),
  bay_id text references bays(id),
  line text not null,
  needs text[] not null,      -- {'blind'} | {'wheelchair'} | {'pram'} | {'language'}
  status text not null default 'waiting'
         check (status in ('waiting','seen','boarded','cancelled','expired')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 minutes'
);

alter publication supabase_realtime add table requests, facts;

-- Hackathon-level Row Level Security: readable by all, limited inserts. Not production policies.
alter table stops enable row level security;   create policy r on stops   for select using (true);
alter table bays enable row level security;    create policy r on bays    for select using (true);
alter table markers enable row level security; create policy r on markers for select using (true);
alter table facts enable row level security;   create policy r on facts   for select using (true);
create policy w on facts for insert with check (source_role in ('driver','rider'));
alter table requests enable row level security;
create policy r on requests for select using (true);
create policy w on requests for insert with check (status = 'waiting');
create policy u on requests for update using (true);
Seed for the demo: one stop, two bays (A and B), markers 0 and 1 on the bays, marker 25 on a "bus door" for line X, and three official facts per bay (step_free_boarding = true, ramp_working = true, observed a week ago). Take the real stop name, coordinates and lines from the VVOÖ sample.
Models.swift and trust
import Foundation

struct Marker: Codable { let stop_id: String?; let tag_id: Int; let kind: String
    let bay_id: String?; let vehicle_line: String?; let size_m: Double }
struct Bay: Codable { let id: String; let stop_id: String; let label: String; let lines: [String] }
struct Fact: Codable { let subject_id: String; let key: String; let value: String
    let source_role: String; let evidence: String; let observed_at: Date; let valid_until: Date? }
struct NewRequest: Encodable { let stop_id: String; let bay_id: String?; let line: String; let needs: [String] }
struct Departure: Codable { let bay: String; let line: String; let destination: String
    let time: String; let low_floor: Bool }

enum TrustLabel: String { case confirmed = "confirmed", probably = "probably", unclear = "unclear" }

/// Trust per (subject, key): w = r · e · 2^(-age/h); trust = S / (S + C + 0.5)
func trust(for facts: [Fact], now: Date = .now) -> (value: String, label: TrustLabel, newest: Fact)? {
    let live = facts.filter { ($0.valid_until ?? .distantFuture) > now }
    guard let newest = live.max(by: { $0.observed_at < $1.observed_at }) else { return nil }
    let role = ["official": 0.7, "driver": 0.85, "local": 0.6, "rider": 0.6, "host": 0.7]
    let evid = ["photo": 1.0, "scan": 0.8, "none": 0.5]
    let halfLifeHours: [String: Double] = ["step_free_boarding": 24 * 365, "ramp_working": 72,
                                           "bay_blocked": 12, "stop_moved": 12, "bay_changed": 24 * 90]
    let h = halfLifeHours[newest.key] ?? 72
    func w(_ f: Fact) -> Double {
        (role[f.source_role] ?? 0.5) * (evid[f.evidence] ?? 0.5) *
        pow(2, -now.timeIntervalSince(f.observed_at) / 3600 / h)
    }
    let s = live.filter { $0.value == newest.value }.map(w).reduce(0, +)
    let c = live.filter { $0.value != newest.value }.map(w).reduce(0, +)
    let t = s / (s + c + 0.5)
    return (newest.value, t >= 0.75 ? .confirmed : t >= 0.45 ? .probably : .unclear, newest)
}
Demo note: one driver report with no photo gives 0.85 × 0.5 / (0.425 + 0.5) ≈ 0.46, so Probably. That's honest, and the jury will like that one report isn't treated as certain. If you want the driver report to read as Confirmed on stage, let the driver attach a photo, or let a rider scan confirm it.
Supabase calls (supabase-swift v2; check its README if a method name differs)
import Supabase

let supabase = SupabaseClient(supabaseURL: Config.supabaseURL, supabaseKey: Config.anonKey)

// Facts for one bay
let facts: [Fact] = try await supabase.from("facts").select()
    .eq("subject_id", value: bayId).execute().value

// Rider request
try await supabase.from("requests")
    .insert(NewRequest(stop_id: stopId, bay_id: bayId, line: "X", needs: ["blind"])).execute()

// Postgres timestamps carry fractional seconds; the default .iso8601 strategy rejects them
let isoDecoder: JSONDecoder = {
    let d = JSONDecoder()
    let frac = ISO8601DateFormatter(); frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    d.dateDecodingStrategy = .custom { dec in
        let s = try dec.singleValueContainer().decode(String.self)
        if let x = frac.date(from: s) ?? plain.date(from: s) { return x }
        throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: s))
    }
    return d
}()

// Live updates for a bay's facts (rider) or a stop's requests (driver)
let channel = supabase.channel("bay-\(bayId)")
let inserts = channel.postgresChange(InsertAction.self, schema: "public", table: "facts",
                                     filter: "subject_id=eq.\(bayId)")
await channel.subscribe()
for await change in inserts {
    let f = try change.decodeRecord(as: Fact.self, decoder: isoDecoder)
    // recompute trust, re-announce if the value or label changed (urgent if it's a barrier)
}
Driver mode
Same app, role "Driver", meant for a phone or iPad in a cab holder. Two jobs: show who is waiting, and report changes with one tap. Big targets, high contrast, sound on new requests, nothing to read while the bus moves.
Screen layout (top to bottom)
1. Line and next stop (picked once at shift start): "Line X → next: Gmunden station".
2. Waiting riders for the next stop, grouped by bay, from requests with status = 'waiting' and matching line: "Bay B: 1 waiting, blind" with large icons per need. New request: a chime plus a spoken "Bay B, one passenger waiting, blind".
3. Four report buttons, each at least 88 pt tall, in a 2×2 grid:
    ◦ "Ramp broken" → fact ramp_working = false on the vehicle, valid for 12 h
    ◦ "Bay blocked" → fact bay_blocked = true on the current bay, valid for 2 h
    ◦ "Stop moved" → fact stop_moved = true with an optional voice note, valid for 12 h
    ◦ "All OK" → confirms step_free_boarding = true and ramp_working = true (a cheap, frequent confirmation)
4. "Picked up" button on each waiting rider: sets status = 'boarded'; the rider hears "The driver has confirmed you're on board."
Rules
• Reports are only enabled when the bus is stopped (speed from CoreLocation under 3 km/h), or for the demo, always.
• Every report inserts a row in facts with source_role = 'driver'; riders subscribed to that bay, or to the requested line's vehicle, get it within about a second and hear it as urgent speech if it's a barrier.
• Optional voice note: record with AVAudioRecorder, send to an n8n webhook that transcribes it and returns {key, value, valid_hours, note}, then insert the fact. Keep this a stretch goal.
Accessibility requirements
The app is for blind users first, so treat these as acceptance criteria, not polish. Test every build with VoiceOver on.
• One-gesture main screen. While scanning, the whole rider screen is one element: double-tap = "I'm waiting for my line". Everything else via VoiceOver custom actions (swipe up/down): Repeat, Change line, Cancel request, Settings. In SwiftUI: .accessibilityElement(children: .combine), .accessibilityAction(named: "Repeat") { … }.
• Never fight VoiceOver. When UIAccessibility.isVoiceOverRunning, speak through announcements (as in Feedback.say), not the synthesizer, so speech doesn't overlap.
• Works with the screen curtain (VoiceOver three-finger triple-tap blacks out the screen). The camera keeps running; set UIApplication.shared.isIdleTimerDisabled = true while scanning.
• Every control labelled, with labels that say the result ("Send: I'm waiting for line X"), no icon-only buttons, Dynamic Type everywhere, contrast at least 4.5:1 for low-vision users.
• Sound plus vibration for every cue, since the street is noisy; never rely on sound alone.
• No time limits on any screen; no gestures that need precise aiming.
• Language: German and English speech and labels; the language follows the phone setting, with an override in Settings.
• Low battery and heat: announce "Battery low, guidance may stop" below 15%, and "Reduced range" when the app throttles for heat.
Markers: generating and printing
Use the official pre-rendered tag images, scale them up without blurring, print matte, measure, and store the measured size per marker.
1. Get the images from https://github.com/AprilRobotics/apriltag-imgs, folder tag25h9. Each tag is a tiny 9 × 9 pixel PNG: a 1-cell white margin, a 1-cell black border and the 5 × 5 data cells.
2. Scale with nearest-neighbour, never smoothing. With ImageMagick: magick tag25_09_00000.png -scale 4000% bay_A.png. Check the exact file names in the folder.
3. Print so the image fills the page width, on matte paper. On A3 (29.7 cm short side), the black square is then about 23 cm. Add a label in large text under it for sighted helpers ("Bay A, marker 0").
4. Measure the outer edge of the black square with a ruler and write it into markers.size_m (for example 0.23). That's the size the pose maths needs.
5. Mount flat at 1.3–1.6 m, facing where people come from, away from direct reflections.
Range expectation: from rough maths (a 70° wide camera at 1080p sees about 1.4 pixels per cm at 10 m, and decoding wants about 4+ pixels per cell), an A3 tag25h9 should work up to about 7–8 m standing still; for about 10 m, print 45–50 cm on a plotter or across two A3 sheets. Measure it in the test below rather than trusting these numbers.
Bus-door marker: A4 is enough (riders are close by then); stick it on the inside of the glass next to the front door, facing out.
Test plan and acceptance criteria
Run the first two tests tonight, before building UI: they decide marker size and the margin threshold.
Test
How
Pass when
Range
A4 and A3 markers; walk away in 1 m steps, standing and walking; log decision_margin per frame
You know the max distance per size; pick the size for the demo
False positives
10 minutes walking around the hall with the app scanning, no demo markers in view
Zero accepted IDs (hard requirement)
Wrong stop
Show a marker whose ID isn't in the current stop's table
Nothing spoken
Direction
Marker at 10, 12 and 2 o'clock at 4 m
Spoken clock hour correct; beeps pan the right way (fix lateralSign if not)
Driver loop
Driver taps "Bay blocked"; rider is locked on that bay
Rider hears the urgent message within 2 s
VoiceOver
Whole flow with VoiceOver on and screen curtain on
Possible without looking; no overlapping speech
Heat
15 minutes continuous scanning
No crash; throttle message if hot
Light
Marker near a window or under a spotlight
Still detected at 3 m; if not, move it or angle it
Demo acceptance (Sunday 10:00): a teammate with closed eyes walks from 6 m to bay B guided only by sound, hears the stop info with fact ages, sends "I'm waiting", the driver phone shows it, the driver taps "Bay blocked", and the rider hears it, all in under 90 seconds.
Task order for tonight
Two iOS developers in parallel plus one person on backend and markers; switch the pitch person in at midnight. Times are targets, not promises.
When
iOS dev 1 (camera)
iOS dev 2 (experience)
Backend + markers
20:00–21:00
Project setup, AprilTag compiled, ATDetector linked
Role picker, rider screen skeleton, Feedback beeps and speech
Supabase tables + RLS; print A4 and A3 markers
21:00–22:30
CameraService + TagDetector: log IDs and margins
GuidanceEngine with fake detections (slider for distance and bearing)
Seed stop, bays, markers, facts; departures JSON from VVOÖ
22:30–23:30
Range and false-positive tests with real prints
Wire guidance to the camera; first walk-to-the-marker test
Driver screen: waiting list + 4 buttons
23:30–01:00
MarkerTracker + demo stop override
Arrival speech from facts with ages; trust labels
Realtime: requests to driver, facts to rider
01:00–07:00
Sleep in shifts; thermal throttling; bus-door marker
VoiceOver pass: one-gesture screen, custom actions
Voice note to fact via n8n (stretch)
07:00–10:00
Bug fixes only
Bug fixes only
Mount markers on stage, rehearse demo, record backup video
First milestone to celebrate: the phone says a marker's ID out loud (target 22:30). Everything else builds on that.