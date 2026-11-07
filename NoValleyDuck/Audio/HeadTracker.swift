import CoreMotion
import Foundation
import os

private let log = Logger(subsystem: "com.novalleyduck.NoValleyDuck", category: "head")

enum HeadGesture: Equatable { case nod, shake }

/// Nod / shake from a stream of head pitch and yaw (radians). Pure, so it can be unit-tested.
/// A nod is a pitch swing that comes back (≥ 1 reversal), a shake is yaw going both ways
/// (≥ 2 reversals); the other axis must stay clearly smaller so turning while walking isn't a gesture.
struct HeadGestureDetector {
    var window = 1.3                    // seconds of history
    var nodRange = 0.20, shakeRange = 0.30, hysteresis = 0.06
    private var samples: [(t: Double, pitch: Double, yaw: Double)] = []

    mutating func add(t: Double, pitch: Double, yaw: Double) -> HeadGesture? {
        // Unwrap yaw so ±π doesn't look like a shake.
        var yaw = yaw
        if let last = samples.last {
            while yaw - last.yaw > .pi { yaw -= 2 * .pi }
            while yaw - last.yaw < -.pi { yaw += 2 * .pi }
        }
        samples.append((t, pitch, yaw))
        samples.removeAll { t - $0.t > window }
        let pitches = samples.map(\.pitch), yaws = samples.map(\.yaw)
        let pr = (pitches.max() ?? 0) - (pitches.min() ?? 0)
        let yr = (yaws.max() ?? 0) - (yaws.min() ?? 0)
        let gesture: HeadGesture?
        if pr >= nodRange, pr > 1.5 * yr, Self.reversals(pitches, hysteresis) >= 1 { gesture = .nod }
        else if yr >= shakeRange, yr > 1.5 * pr, Self.reversals(yaws, hysteresis) >= 2 { gesture = .shake }
        else { gesture = nil }
        if gesture != nil { samples.removeAll() }
        return gesture
    }

    mutating func reset() { samples.removeAll() }

    /// Direction changes larger than `h`.
    static func reversals(_ v: [Double], _ h: Double) -> Int {
        guard var extreme = v.first else { return 0 }
        var dir = 0, count = 0
        for x in v.dropFirst() {
            if dir >= 0, x > extreme { extreme = x; if dir == 0 { dir = 1 }; continue }
            if dir <= 0, x < extreme { extreme = x; if dir == 0 { dir = -1 }; continue }
            if abs(x - extreme) >= h {
                if dir != 0 { count += 1 }
                dir = x > extreme ? 1 : -1
                extreme = x
            }
        }
        return count
    }
}

/// AirPods head tracking: absolute head heading (SPEC Phase 2 "Head direction") and gestures.
/// AirPods yaw is only relative, so `offset` ties it to the compass: once by the start
/// calibration (phone held forward), then continuously to the GPS course while walking straight.
@MainActor
final class HeadTracker: NSObject, CMHeadphoneMotionManagerDelegate {
    private let manager = CMHeadphoneMotionManager()
    private var detector = HeadGestureDetector()
    private(set) var yawDeg: Double?
    private var lastSample = Date.distantPast
    private var offset: Double?
    /// Called for every detected gesture; the prompt decides whether it counts.
    var onGesture: ((HeadGesture) -> Void)?

    var isAvailable: Bool { manager.isDeviceMotionAvailable }
    var isConnected: Bool { Date().timeIntervalSince(lastSample) < 2 }
    var isAligned: Bool { offset != nil }

    /// Compass heading of the face in degrees, nil until calibrated or aligned to GPS.
    var heading: Double? {
        guard isConnected, let offset, let yawDeg else { return nil }
        return Self.normalize(offset - yawDeg)       // CoreMotion yaw grows counter-clockwise
    }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.delegate = self
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self, let motion else {
                if let error { log.error("head motion: \(error.localizedDescription)") }
                return
            }
            MainActor.assumeIsolated { self.handle(motion) }
        }
        log.info("head tracking started")
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        offset = nil
    }

    /// Start calibration: the user faces where the phone's top edge points.
    func calibrate(phoneHeading: Double) {
        guard let yawDeg else { return }
        offset = Self.normalize(phoneHeading + yawDeg)
        log.info("calibrated to phone heading \(phoneHeading, format: .fixed(precision: 0))")
    }

    /// Walking straight: assume the head faces the GPS course and pull the offset towards it.
    func align(toCourse course: Double) {
        guard let yawDeg else { return }
        let target = Self.normalize(course + yawDeg)
        guard let current = offset else { offset = target; return }
        let diff = (target - current + 540).truncatingRemainder(dividingBy: 360) - 180
        offset = Self.normalize(current + 0.15 * diff)
    }

    private func handle(_ motion: CMDeviceMotion) {
        lastSample = Date()
        yawDeg = motion.attitude.yaw * 180 / .pi
        if let g = detector.add(t: motion.timestamp, pitch: motion.attitude.pitch, yaw: motion.attitude.yaw) {
            log.info("gesture \(String(describing: g))")
            onGesture?(g)
        }
    }

    nonisolated func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        log.info("headphones connected")
    }

    nonisolated func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        log.info("headphones disconnected")
    }

    static func normalize(_ deg: Double) -> Double {
        let d = deg.truncatingRemainder(dividingBy: 360)
        return d < 0 ? d + 360 : d
    }
}
