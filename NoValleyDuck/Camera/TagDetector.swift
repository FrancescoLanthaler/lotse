import Foundation
import CoreGraphics

struct TagDetection: Sendable, Equatable {
    let id: Int
    let hamming: Int
    let margin: Float
    let center: CGPoint
    let corners: [CGPoint]
    let unitTranslation: SIMD3<Double>?   // multiply by marker size in metres
    let poseError: Double?
    /// Straight-line distance camera → marker centre in metres, from the pose.
    func distance(markerSize: Double) -> Double? {
        unitTranslation.map { ($0 * $0).sum().squareRoot() * markerSize }
    }
    var sidePixels: Double {              // mean edge length, for the no-pose fallback
        zip(corners, Array(corners.dropFirst()) + [corners[0]])
            .map { hypot($0.x - $1.x, $0.y - $1.y) }.reduce(0, +) / 4
    }
}

/// Thin Swift wrapper around the C AprilTag detector (tag25h9). Not thread-safe:
/// use one instance per serial queue.
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
                unitTranslation: d.has_pose == 1 ? SIMD3(d.tx, d.ty, d.tz) : nil,
                poseError: d.has_pose == 1 ? d.pose_error : nil)
        }
    }
}
