import Foundation
import Testing
@testable import NoValleyDuck

@Suite("Timetable")
struct TimetableTests {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = Timetable.timeZone
        return c
    }

    func at(_ day: Int, _ h: Int, _ m: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!
    }

    /// Window starts 7 Nov 2026 (Saturday), 3 days. Service 0 runs every day, service 1 only day 1.
    let t = Timetable(stop: "s1", startDate: "20261107", days: 3, data: .init(
        bays: ["bA", "bB"], lines: ["150", "25"], headsigns: ["Bad Ischl", "Grödig"],
        services: ["111", "010"],
        deps: [[0, 0, 0, 8 * 60, 0, 1], [1, 1, 1, 8 * 60 + 5, 1, 0], [0, 0, 0, 9 * 60, 0, 2],
               [1, 1, 1, 24 * 60 + 30, 0, 0]]))   // 24:30 = 00:30 next calendar day

    @Test func nextDeparturesInOrder() {
        let d = t.departures(after: at(8, 7, 0), limit: 3)
        #expect(d.map(\.line) == ["150", "25", "150"])
        #expect(d.map(\.time) == [at(8, 8, 0), at(8, 8, 5), at(8, 9, 0)])
        #expect(d[0].lowFloor == true && d[1].lowFloor == nil && d[2].lowFloor == false)
    }

    @Test func serviceCalendarIsRespected() {
        // Service 1 only runs on day 1 (8 Nov), so on 7 Nov line 25's 08:05 is absent.
        #expect(!t.departures(after: at(7, 7, 0), limit: 10).contains { $0.time == at(7, 8, 5) })
    }

    @Test func pastMidnightTimesBelongToPreviousServiceDay() {
        let d = t.departures(after: at(8, 0, 0), bay: "bB", limit: 1)
        #expect(d.first?.time == at(8, 0, 30))                 // from the 7 Nov service day
    }

    @Test func bayFilter() {
        #expect(t.departures(after: at(8, 7, 0), bay: "bA", limit: 5).allSatisfy { $0.bayId == "bA" })
        #expect(t.departures(after: at(8, 7, 0), bay: "nope").isEmpty)
    }

    @Test func spokenText() {
        let d = Departure(bayId: "bA", line: "150", headsign: "Bad Ischl", time: at(8, 8, 4), lowFloor: true)
        #expect(d.spoken(now: at(8, 8, 0)) == "Line 150 to Bad Ischl in 4 minutes, low-floor bus")
    }
}

@Suite("Bundled demo data")
struct DemoDataTests {
    @Test func demoStopHasMarkersAndBusDoor() throws {
        let demo = try #require(DemoBundle.shared)
        #expect(demo.stop.name == "Salzburg Hauptbahnhof")
        #expect(Set(demo.context.markers.keys) == [0, 1])
        #expect(demo.context.markers.values.allSatisfy { demo.context.bays[$0.bay] != nil })
        #expect(demo.vehicles[25]?.kind == .vehicle)
        #expect(demo.context.bays[demo.context.markers[0]!.bay]?.label == "A")
    }

    @Test func demoTimetableDecodesAndMatchesStop() throws {
        let t = try #require(Timetable.demo)
        let demo = try #require(DemoBundle.shared)
        #expect(t.stop == demo.stop.id)
        #expect(t.data.deps.count > 100)
        #expect(t.data.deps.allSatisfy { $0.count == 6 && $0[0] < t.data.bays.count })
    }
}
