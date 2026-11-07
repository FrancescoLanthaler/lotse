import CoreGraphics
import Testing
@testable import NoValleyDuck

@Suite("Frame classification")
struct FrameProcessorTests {
    @Test func classifiesEveryDetection() {
        let bay = Bay(id: "bA", stop: "s1", label: "A", lines: ["150"], lat: 0, lon: 0)
        let ctx = StopContext(stop: stop("s1", lat: 0, lon: 0), bays: [bay], markers: [marker(0, bay: "bA"), marker(1)])
        let p = FrameProcessor()
        p.setCatalog(MarkerCatalog(stop: ctx, vehicles: [25: marker(25, kind: .vehicle, line: "150")]))
        let frame = FrameInfo(size: CGSize(width: 1920, height: 1080), fx: 1500, fy: 1500)
        let dets = [det(0, side: 200), det(1, margin: 10), det(9), det(25, side: 50)]

        var r = p.process(dets, frame: frame, now: 0)
        r = p.process(dets, frame: frame, now: 0.1)
        r = p.process(dets, frame: frame, now: 0.2)

        let status = Dictionary(uniqueKeysWithValues: r.detections.map { ($0.detection.id, $0.status) })
        #expect(status == [0: .locked, 1: .weak, 9: .notHere, 25: .candidate])
        #expect(r.lockedTag == 0)
        #expect(r.lock?.bay?.label == "A")
        #expect(abs((r.lock?.guidance.distance ?? 0) - 2.0) < 1e-9)    // 10 × 0.2 m
    }
}
