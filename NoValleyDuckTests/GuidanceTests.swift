import CoreGraphics
import Testing
@testable import NoValleyDuck

@Suite("Distance and clock direction")
struct GuidanceTests {
    @Test(arguments: [(0.0, 12), (14.0, 12), (16.0, 1), (30.0, 1), (60.0, 2), (90.0, 3),
                      (-30.0, 11), (-60.0, 10), (-90.0, 9)])
    func clockHour(deg: Double, hour: Int) {
        #expect(Guidance(distance: 4, bearingDeg: deg).clockHour == hour)
    }

    @Test func spoken() {
        #expect(Guidance(distance: 4.2, bearingDeg: 60).spoken == "4 metres, at 2 o'clock")
        #expect(Guidance(distance: 1.2, bearingDeg: 60).spoken == "right in front of you")
    }

    @Test func translationScalesWithMarkerSize() {
        let g = GuidanceEngine.measure(det(0, t: SIMD3(0, 0, 10)), markerSize: 0.23, fx: 1500, fy: 1500,
                                       imageSize: CGSize(width: 1920, height: 1080), lateralSign: 1)
        #expect(abs(g.distance - 2.3) < 1e-9)
        #expect(abs(g.bearingDeg) < 1e-9)
    }

    @Test func lateralOffsetUsesYAxisAndSign() {
        let d = det(0, t: SIMD3(0, 10, 10))                    // 45° along the frame's y axis
        let size = CGSize(width: 1920, height: 1080)
        let right = GuidanceEngine.measure(d, markerSize: 1, fx: 1, fy: 1, imageSize: size, lateralSign: 1)
        let flipped = GuidanceEngine.measure(d, markerSize: 1, fx: 1, fy: 1, imageSize: size, lateralSign: -1)
        #expect(abs(right.bearingDeg - 45) < 1e-9)
        #expect(abs(flipped.bearingDeg + 45) < 1e-9)
    }

    @Test func portraitDefaultMeansRightIsPositive() {
        // Held in portrait, a marker to the phone's right sits near the TOP of the landscape
        // frame (small y): negative t.y with pose, centre above the middle without pose.
        let size = CGSize(width: 1920, height: 1080)
        let e = GuidanceEngine()
        let withPose = e.update(det(0, cy: 200, t: SIMD3(0, -3, 10)), markerSize: 1, fx: 1500, fy: 1500, imageSize: size)
        #expect(withPose.bearingDeg > 15 && withPose.clockHour == 1)
        let noPose = GuidanceEngine.measure(det(0, cy: 200, t: nil), markerSize: 1, fx: 1500, fy: 1500,
                                            imageSize: size, lateralSign: e.lateralSign)
        #expect(noPose.bearingDeg > 0)
    }

    @Test func fallbackWithoutPose() {
        let g = GuidanceEngine.measure(det(0, side: 150, t: nil), markerSize: 0.2, fx: 1500, fy: 1500,
                                       imageSize: CGSize(width: 1920, height: 1080), lateralSign: 1)
        #expect(abs(g.distance - 2.0) < 1e-9)                  // 1500 * 0.2 / 150
    }

    @Test func smoothingDampsJumps() {
        let e = GuidanceEngine()
        let size = CGSize(width: 1920, height: 1080)
        _ = e.update(det(0, t: SIMD3(0, 0, 10)), markerSize: 1, fx: 1, fy: 1, imageSize: size)
        let g = e.update(det(0, t: SIMD3(0, 0, 20)), markerSize: 1, fx: 1, fy: 1, imageSize: size)
        #expect(abs(g.distance - 13) < 1e-9)                   // 10 + 0.3 * (20 - 10)
    }
}
