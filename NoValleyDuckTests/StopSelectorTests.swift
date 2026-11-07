import Testing
@testable import NoValleyDuck

@Suite("Stop from GPS")
struct StopSelectorTests {
    let a = stop("a", lat: 47.8, lon: 13.0)
    let b = stop("b", lat: 47.8 + 300 / 111_195.0, lon: 13.0)   // 300 m north of a

    @Test func entersWithin150m() {
        #expect(StopSelector.select(current: nil, candidates: [a, b], at: location(north: 140, of: 47.8, 13.0))?.id == "a")
        #expect(StopSelector.select(current: nil, candidates: [a], at: location(north: 160, of: 47.8, 13.0)) == nil)
    }

    @Test func staysUntil200m() {
        #expect(StopSelector.select(current: a, candidates: [a], at: location(north: 190, of: 47.8, 13.0))?.id == "a")
        #expect(StopSelector.select(current: a, candidates: [a], at: location(north: 210, of: 47.8, 13.0)) == nil)
    }

    @Test func switchesOnlyWhenClearlyCloser() {
        // 140 m from a, 160 m from b: b is not within 150 m, stay at a.
        #expect(StopSelector.select(current: a, candidates: [a, b], at: location(north: 140, of: 47.8, 13.0))?.id == "a")
        // 180 m from a, 120 m from b: b is 60 m closer (> 50 m margin), switch.
        #expect(StopSelector.select(current: a, candidates: [a, b], at: location(north: 180, of: 47.8, 13.0))?.id == "b")
    }
}
