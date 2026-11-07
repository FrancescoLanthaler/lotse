import CoreGraphics
import QuartzCore

/// Why a detection was or wasn't accepted (shown in the debug view).
enum DetectionStatus: Sendable, Equatable {
    case notHere      // ID not valid at this stop (check 3)
    case weak         // corrected bits or low margin (checks 1–2)
    case candidate    // passes 1–3, not (yet) the lock
    case locked
}

struct ClassifiedDetection: Sendable, Equatable {
    let detection: TagDetection
    let status: DetectionStatus
    let marker: Marker?
    /// Raw (unsmoothed) distance/bearing when the marker's size is known.
    let guidance: Guidance?
}

struct FrameResult: Sendable, Equatable {
    let detections: [ClassifiedDetection]
    let frame: FrameInfo
    let lockedTag: Int?        // tracker lock, also during short dropouts
    let lock: LockedMarker?    // locked marker if visible in this frame
    var confirmed: Set<Int> = []   // IDs that passed the full safety filter (3 of 5 frames)
}


/// Safety filter + geometry for every processed frame. Confined to the camera frame queue
/// (all access goes through `CameraService.onFrameQueue` or the frame callback).
final class FrameProcessor: @unchecked Sendable {
    let tracker = MarkerTracker()
    let engine = GuidanceEngine()
    private(set) var catalog = MarkerCatalog.empty
    var preferredTag: Int?
    private var lastLocked: Int?

    func setCatalog(_ catalog: MarkerCatalog) {
        guard catalog != self.catalog else { return }
        self.catalog = catalog
        tracker.reset()
        engine.reset()
    }

    func process(_ dets: [TagDetection], frame: FrameInfo,
                 now: CFTimeInterval = CACurrentMediaTime()) -> FrameResult {
        let valid = catalog.validIds
        let visibleLock = tracker.update(dets, validIds: valid, preferred: preferredTag, now: now)
        if tracker.locked != lastLocked { engine.reset(); lastLocked = tracker.locked }

        var lock: LockedMarker?
        if let d = visibleLock, let m = catalog.marker(for: d.id) {
            let g = engine.update(d, markerSize: m.sizeM, fx: frame.fx, fy: frame.fy, imageSize: frame.size)
            lock = LockedMarker(detection: d, marker: m, bay: catalog.bay(for: m), guidance: g)
        }

        let classified = dets.map { d -> ClassifiedDetection in
            let marker = catalog.marker(for: d.id)
            let status: DetectionStatus =
                !valid.contains(d.id) ? .notHere :
                !tracker.passesQuality(d) ? .weak :
                d.id == tracker.locked ? .locked : .candidate
            let g = d.id == lock?.detection.id ? lock?.guidance : marker.map {
                GuidanceEngine.measure(d, markerSize: $0.sizeM, fx: frame.fx, fy: frame.fy,
                                       imageSize: frame.size, lateralSign: engine.lateralSign)
            }
            return ClassifiedDetection(detection: d, status: status, marker: marker, guidance: g)
        }
        return FrameResult(detections: classified, frame: frame, lockedTag: tracker.locked, lock: lock,
                           confirmed: tracker.confirmed)
    }
}
