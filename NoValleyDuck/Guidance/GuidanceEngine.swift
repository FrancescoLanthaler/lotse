import CoreGraphics
import Foundation

/// Distance and direction to a marker, as the rider should hear it.
struct Guidance: Sendable, Equatable {
    let distance: Double      // metres, smoothed
    let bearingDeg: Double    // + = right of the camera axis, clamped to ±90

    /// Clock hour: 0° = 12 o'clock, +30° = 1 o'clock, −60° = 10 o'clock.
    var clockHour: Int {
        let h = Int((bearingDeg / 30).rounded())
        let c = (12 + h) % 12
        return c == 0 ? 12 : c
    }

    var spoken: String {
        distance <= MarkerStateMachine.arrivalDistance ? "right in front of you"
            : "\(Int(distance.rounded())) metres, at \(clockHour) o'clock"
    }
}

/// Turns a locked detection into smoothed distance + bearing. Frame-queue only.
final class GuidanceEngine {
    /// Frames are in sensor (landscape) orientation; held in portrait, the rider's left/right
    /// is the frame's y axis. Flip to -1 if left/right comes out reversed (spec direction test).
    var lateralSign: Double = 1
    let alpha = 0.3
    private var d: Double?, th: Double?

    func update(_ det: TagDetection, markerSize: Double, fx: Double, fy: Double,
                imageSize: CGSize) -> Guidance {
        let raw = Self.measure(det, markerSize: markerSize, fx: fx, fy: fy, imageSize: imageSize,
                               lateralSign: lateralSign)
        d = d.map { $0 + alpha * (raw.distance - $0) } ?? raw.distance
        th = th.map { $0 + alpha * (raw.bearingDeg - $0) } ?? raw.bearingDeg
        return Guidance(distance: d!, bearingDeg: max(-90, min(90, th!)))
    }

    func reset() { d = nil; th = nil }

    /// Unsmoothed distance and bearing for one detection.
    static func measure(_ det: TagDetection, markerSize: Double, fx: Double, fy: Double,
                        imageSize: CGSize, lateralSign: Double) -> Guidance {
        if let u = det.unitTranslation {
            // Pose was estimated for tag size 1.0; translation scales linearly with size.
            let t = u * markerSize
            let dist = (t * t).sum().squareRoot()
            let bearing = atan2(lateralSign * t.y, t.z) * 180 / .pi
            return Guidance(distance: dist, bearingDeg: bearing)
        }
        // No pose: pinhole size estimate, bearing from the centre offset along y.
        let dist = fx * markerSize / max(det.sidePixels, 1)
        let bearing = atan((Double(det.center.y) - imageSize.height / 2) / fy) * 180 / .pi * lateralSign
        return Guidance(distance: dist, bearingDeg: bearing)
    }
}
