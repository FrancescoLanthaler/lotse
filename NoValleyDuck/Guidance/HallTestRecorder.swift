import Foundation
import QuartzCore

/// Writes every processed frame to a CSV for the spec's hall tests:
///  - Range: walk away in 1 m steps, see where margin drops / detection stops.
///  - False positives: walk around without demo markers; `accepted` must stay empty.
/// Frames without detections get one row with an empty id, so frame counts are honest.
/// Files land in Documents (visible in the Files app and Finder). Frame-queue only.
final class HallTestRecorder: @unchecked Sendable {
    private var handle: FileHandle?
    private var startTime: CFTimeInterval = 0
    private var frameNo = 0

    static let header = "t_s,frame,stop,id,hamming,margin,side_px,status,distance_m,bearing_deg,locked\n"

    static func newURL(now: Date = .now) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return URL.documentsDirectory.appending(path: "hall-test-\(f.string(from: now)).csv")
    }

    func begin(_ url: URL) {
        end()
        FileManager.default.createFile(atPath: url.path(), contents: Data(Self.header.utf8))
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        startTime = CACurrentMediaTime()
        frameNo = 0
    }

    func end() {
        try? handle?.close()
        handle = nil
    }

    func write(_ r: FrameResult, stop: String, now: CFTimeInterval = CACurrentMediaTime()) {
        guard let handle else { return }
        frameNo += 1
        let t = String(format: "%.3f", now - startTime)
        let locked = r.lockedTag.map(String.init) ?? ""
        let stopField = "\"" + stop.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        var out = ""
        if r.detections.isEmpty {
            out = "\(t),\(frameNo),\(stopField),,,,,,,,\(locked)\n"
        }
        for c in r.detections {
            let d = c.detection
            let g = c.guidance
            out += [t, "\(frameNo)", stopField, "\(d.id)", "\(d.hamming)", String(format: "%.1f", d.margin),
                    String(format: "%.0f", d.sidePixels), Self.name(c.status),
                    g.map { String(format: "%.2f", $0.distance) } ?? "",
                    g.map { String(format: "%.1f", $0.bearingDeg) } ?? "", locked].joined(separator: ",") + "\n"
        }
        handle.write(Data(out.utf8))
    }

    static func name(_ s: DetectionStatus) -> String {
        switch s {
        case .notHere: "not_here"
        case .weak: "weak"
        case .candidate: "candidate"
        case .locked: "locked"
        }
    }
}
