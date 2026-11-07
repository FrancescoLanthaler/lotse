import Testing
@testable import NoValleyDuck

@Suite("Safety filter")
struct MarkerTrackerTests {
    let valid: Set<Int> = [0, 1, 25]

    /// Feed frames 0.1 s apart; return the result of the last one.
    @discardableResult
    func run(_ t: MarkerTracker, _ frames: [[TagDetection]], start: Double = 0,
             preferred: Int? = nil, valid: Set<Int>? = nil) -> TagDetection? {
        var last: TagDetection?
        for (i, f) in frames.enumerated() {
            last = t.update(f, validIds: valid ?? self.valid, preferred: preferred, now: start + Double(i) * 0.1)
        }
        return last
    }

    @Test func locksAfterThreeOfFive() {
        let t = MarkerTracker()
        #expect(run(t, [[det(0)], [], [det(0)]]) == nil)       // 2 sightings: not yet
        #expect(t.locked == nil)
        #expect(run(t, [[], [det(0)]], start: 0.3) != nil)     // 3rd sighting within 5 frames
        #expect(t.locked == 0)
    }

    @Test func twoOfFiveIsNotEnough() {
        let t = MarkerTracker()
        run(t, [[det(0)], [], [], [det(0)], [], [], [], [det(0)]])  // never 3 within 5 frames
        #expect(t.locked == nil)
    }

    @Test func correctedBitsNeverLock() {
        let t = MarkerTracker()
        run(t, Array(repeating: [det(0, hamming: 1)], count: 10))
        #expect(t.locked == nil)
    }

    @Test func lowMarginNeverLocks() {
        let t = MarkerTracker()
        run(t, Array(repeating: [det(0, margin: 39)], count: 10))
        #expect(t.locked == nil)
        t.minMargin = 30
        run(t, Array(repeating: [det(0, margin: 39)], count: 3), start: 2)
        #expect(t.locked == 0)
    }

    @Test func idFromAnotherStopNeverLocks() {
        let t = MarkerTracker()
        run(t, Array(repeating: [det(7)], count: 10))
        #expect(t.locked == nil)
    }

    @Test func holdsLockThroughShortDropoutThenReleases() {
        let t = MarkerTracker()
        run(t, Array(repeating: [det(0)], count: 3))                 // locked at t = 0.2
        #expect(t.update([], validIds: valid, preferred: nil, now: 1.6) == nil)
        #expect(t.locked == 0)                                       // 1.4 s without sighting
        _ = t.update([], validIds: valid, preferred: nil, now: 1.8)
        #expect(t.locked == nil)                                     // > 1.5 s: released
    }

    @Test func picksNearestCandidate() {
        let t = MarkerTracker()
        run(t, Array(repeating: [det(0, side: 50), det(1, side: 120)], count: 3))
        #expect(t.locked == 1)
    }

    @Test func preferredMarkerTakesOverLock() {
        let t = MarkerTracker()
        run(t, Array(repeating: [det(0, side: 200)], count: 3))
        #expect(t.locked == 0)
        run(t, Array(repeating: [det(0, side: 200), det(25, side: 40)], count: 3), start: 1, preferred: 25)
        #expect(t.locked == 25)
    }

    @Test func lockDropsWhenStopChanges() {
        let t = MarkerTracker()
        run(t, Array(repeating: [det(0)], count: 3))
        #expect(t.update([det(0)], validIds: [5], preferred: nil, now: 1) == nil)
        #expect(t.locked == nil)
    }
}
