import Testing
@testable import NoValleyDuck

@Suite("Rider marker states")
struct MarkerStateMachineTests {
    func locked(_ tag: Int, distance: Double, kind: Marker.Kind = .bay) -> LockedMarker {
        LockedMarker(detection: det(tag), marker: marker(tag, kind: kind), bay: nil,
                     guidance: Guidance(distance: distance, bearingDeg: 0))
    }

    @Test func fullApproach() {
        var m = MarkerStateMachine()
        #expect(m.update(hasStop: false, lockedTag: nil, visible: nil).isEmpty)
        #expect(m.state == .noStop)
        _ = m.update(hasStop: true, lockedTag: nil, visible: nil)
        #expect(m.state == .searching)

        let far = locked(0, distance: 7)
        #expect(m.update(hasStop: true, lockedTag: 0, visible: far) == [.found(far)])
        #expect(m.state == .approaching(tag: 0))

        // Dropout: locked but not visible keeps the state, no events.
        #expect(m.update(hasStop: true, lockedTag: 0, visible: nil).isEmpty)
        #expect(m.state == .approaching(tag: 0))

        let near = locked(0, distance: 1.4)
        #expect(m.update(hasStop: true, lockedTag: 0, visible: near) == [.arrived(near)])
        #expect(m.state == .arrived(tag: 0))
        #expect(m.update(hasStop: true, lockedTag: 0, visible: locked(0, distance: 1.0)).isEmpty)  // once

        #expect(m.update(hasStop: true, lockedTag: nil, visible: nil) == [.lost(marker(0))])
        #expect(m.state == .searching)
    }

    @Test func busDoorMeansBoarding() {
        var m = MarkerStateMachine()
        let door = locked(25, distance: 3, kind: .vehicle)
        #expect(m.update(hasStop: true, lockedTag: 25, visible: door) == [.found(door)])
        #expect(m.state == .boarding(tag: 25))
        let close = locked(25, distance: 1, kind: .vehicle)
        #expect(m.update(hasStop: true, lockedTag: 25, visible: close) == [.arrived(close)])
        #expect(m.state == .boarding(tag: 25))
    }

    @Test func switchingLockEmitsLostThenFound() {
        var m = MarkerStateMachine()
        _ = m.update(hasStop: true, lockedTag: 0, visible: locked(0, distance: 5))
        let door = locked(25, distance: 4, kind: .vehicle)
        #expect(m.update(hasStop: true, lockedTag: 25, visible: door) == [.lost(marker(0)), .found(door)])
    }
}
