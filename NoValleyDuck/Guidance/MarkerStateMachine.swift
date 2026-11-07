import Foundation

/// A locked marker in one frame, resolved against the current stop's data.
struct LockedMarker: Sendable, Equatable {
    let detection: TagDetection
    let marker: Marker
    let bay: Bay?             // nil for bus-door markers
    let guidance: Guidance
}

/// Where the rider is in the marker flow (spec "Rider states", marker-related part).
/// "Found" and "Lost" are moments, so they are events, not states.
enum MarkerState: Sendable, Equatable {
    case noStop                 // no known stop within 150 m (and no demo override)
    case searching              // stop known, nothing locked
    case approaching(tag: Int)  // locked on a bay/entrance marker, distance > 1.5 m
    case arrived(tag: Int)      // locked, came within 1.5 m (sticky until the lock is lost)
    case boarding(tag: Int)     // locked on a bus-door marker

    var lockedTag: Int? {
        switch self {
        case .approaching(let t), .arrived(let t), .boarding(let t): t
        case .noStop, .searching: nil
        }
    }
}

/// What the soundscape/speech side reacts to.
enum MarkerEvent: Sendable, Equatable {
    case stopChanged(Stop?)
    case found(LockedMarker)      // first lock: "Bay B, 7 metres, at 2 o'clock"
    case arrived(LockedMarker)    // within 1.5 m: long haptic + stop info
    case lost(Marker)             // lock released: "Lost the marker, turn slowly"
    case reducedRange(Bool)       // heat throttling on/off
}

/// Pure state machine: easy to unit-test, runs on the main actor in the pipeline.
struct MarkerStateMachine {
    static let arrivalDistance = 1.5

    private(set) var state: MarkerState = .noStop
    private var lockedMarker: Marker?
    private var hasArrived = false

    /// - Parameters:
    ///   - hasStop: a stop is known (GPS or demo override)
    ///   - lockedTag: the tracker's current lock, also during short dropouts
    ///   - visible: the locked marker as seen in this frame, if it is visible
    mutating func update(hasStop: Bool, lockedTag: Int?, visible: LockedMarker?) -> [MarkerEvent] {
        var events: [MarkerEvent] = []

        if let current = lockedMarker, lockedTag != current.tagId {
            events.append(.lost(current))
            lockedMarker = nil
            hasArrived = false
        }

        guard let tag = lockedTag else {
            state = hasStop ? .searching : .noStop
            return events
        }
        guard let v = visible, v.marker.tagId == tag else {
            // Locked but not visible this frame: hold the state (or wait for first sighting).
            if lockedMarker == nil { state = hasStop ? .searching : .noStop }
            return events
        }

        if lockedMarker == nil {
            lockedMarker = v.marker
            events.append(.found(v))
            state = v.marker.kind == .vehicle ? .boarding(tag: tag) : .approaching(tag: tag)
        }
        // Arrival fires once per lock, for bays and bus doors alike; the state only changes
        // for bays (at a bus door the rider stays in .boarding).
        if v.guidance.distance <= Self.arrivalDistance, !hasArrived {
            hasArrived = true
            if case .approaching = state { state = .arrived(tag: tag) }
            events.append(.arrived(v))
        }
        return events
    }

    mutating func reset(hasStop: Bool) -> [MarkerEvent] {
        var events: [MarkerEvent] = []
        if let m = lockedMarker { events.append(.lost(m)) }
        lockedMarker = nil
        hasArrived = false
        state = hasStop ? .searching : .noStop
        return events
    }
}
