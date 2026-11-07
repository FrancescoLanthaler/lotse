import Foundation

/// Where the bay's waiting spot is relative to the phone (SPEC Phase 3), from every confirmed
/// marker of that bay in view. Each marker knows the spot's offset in its own frame, so any one
/// of them locates the user, and several are averaged.
enum WaitingSpot {
    static let arrivalDistance = 0.5      // SPEC: "within ~0.5 m of the waiting spot"

    /// HACK: tape-measured offsets for the test stop's markers, by marker record id
    /// (`right` = metres to the marker's right seen from in front, `out` = metres out from it).
    /// Fill in on site; markers without an entry use their PocketBase fields, else `defaultOut`.
    /// Example entry: `"m997428af72b242": (right: 1.2, out: 0.6)` (Hauptbahnhof bay A, tag 0).
    static let offsets: [String: (right: Double, out: Double)] = [:]
    /// Unmeasured marker: assume the spot is straight out in front of it.
    static let defaultOut = 0.5

    static func offset(for m: Marker) -> (right: Double, out: Double) {
        offsets[m.id] ?? (m.spotRightM ?? 0, m.spotOutM ?? defaultOut)
    }

    /// The spot in camera coordinates (metres), from one detection. nil without a pose.
    static func spotInCamera(_ d: TagDetection, marker: Marker) -> SIMD3<Double>? {
        guard let u = d.unitTranslation, let r = d.rotation, r.count == 9 else { return nil }
        let o = offset(for: marker)
        // Tag frame: x to the right (seen from in front), z into the tag, so "out" is -z.
        let p = SIMD3(o.right, 0, -o.out)
        let row0 = SIMD3(r[0], r[1], r[2]), row1 = SIMD3(r[3], r[4], r[5]), row2 = SIMD3(r[6], r[7], r[8])
        let rotated = SIMD3((row0 * p).sum(), (row1 * p).sum(), (row2 * p).sum())
        return rotated + u * marker.sizeM
    }

    /// Mean spot over all confirmed markers of `bayId` in this frame, nearer markers weighted more.
    static func estimate(_ frame: FrameResult, bayId: String?) -> SIMD3<Double>? {
        var sum = SIMD3<Double>(repeating: 0), weights = 0.0
        for c in frame.detections where frame.confirmed.contains(c.detection.id) {
            guard c.status == .locked || c.status == .candidate, let m = c.marker, m.kind != .vehicle,
                  bayId == nil || m.bay == bayId, let u = c.detection.unitTranslation,
                  let spot = spotInCamera(c.detection, marker: m) else { continue }
            let d = max(0.3, (u * u).sum().squareRoot() * m.sizeM)
            sum += spot / (d * d)
            weights += 1 / (d * d)
        }
        return weights > 0 ? sum / weights : nil
    }

    /// Horizontal distance and bearing (+ = right) with the phone held upright in portrait:
    /// the sensor's x axis is vertical then, y is left/right (see `GuidanceEngine`).
    static func guidance(_ spot: SIMD3<Double>, lateralSign: Double) -> Guidance {
        Guidance(distance: hypot(spot.y, spot.z),
                 bearingDeg: atan2(lateralSign * spot.y, spot.z) * 180 / .pi)
    }
}
