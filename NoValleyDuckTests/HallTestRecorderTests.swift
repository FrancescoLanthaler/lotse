import CoreGraphics
import Foundation
import Testing
@testable import NoValleyDuck

@Suite("Hall test CSV")
struct HallTestRecorderTests {
    @Test func writesOneRowPerDetectionAndEmptyFrames() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "hall-\(UUID()).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let frame = FrameInfo(size: CGSize(width: 1920, height: 1080), fx: 1500, fy: 1500)
        let r = HallTestRecorder()
        r.begin(url)
        r.write(FrameResult(detections: [], frame: frame, lockedTag: nil, lock: nil), stop: "Salzburg \"Hbf\"", now: 0)
        r.write(FrameResult(detections: [
            ClassifiedDetection(detection: det(0, margin: 87.25), status: .locked, marker: marker(0),
                                guidance: Guidance(distance: 2.345, bearingDeg: -12.34)),
            ClassifiedDetection(detection: det(7, hamming: 1), status: .notHere, marker: nil, guidance: nil),
        ], frame: frame, lockedTag: 0, lock: nil), stop: "Salzburg \"Hbf\"", now: 0)
        r.end()

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(lines[0] + "\n" == HallTestRecorder.header)
        #expect(lines[1].hasSuffix(",1,\"Salzburg \"\"Hbf\"\"\",,,,,,,,"))
        #expect(lines[2].hasSuffix(",2,\"Salzburg \"\"Hbf\"\"\",0,0,87.2,100,locked,2.35,-12.3,0")
            || lines[2].hasSuffix(",2,\"Salzburg \"\"Hbf\"\"\",0,0,87.3,100,locked,2.35,-12.3,0"))
        #expect(lines[3].contains(",7,1,") && lines[3].contains(",not_here,,,0"))
    }
}
