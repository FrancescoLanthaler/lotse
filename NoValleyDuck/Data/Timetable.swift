import Foundation

/// Scheduled departures of one stop for a window of days (written by tools/import_stops.py from
/// the Salzburg Verkehr GTFS feed). Compact on the wire; use `departures(after:)` to query.
struct Timetable: Codable, Sendable, Equatable {
    struct Data: Codable, Sendable, Equatable {
        let bays: [String]        // bay record ids
        let lines: [String]
        let headsigns: [String]
        let services: [String]    // per service: one char per day of the window, "1" = runs
        let deps: [[Int]]         // [bay, line, headsign, minutes, service, accessible], by minutes
    }

    let stop: String
    let startDate: String         // yyyymmdd, first day of the window (Europe/Vienna)
    let days: Int
    let data: Data

    enum CodingKeys: String, CodingKey {
        case stop, days, data
        case startDate = "start_date"
    }

    static let timeZone = TimeZone(identifier: "Europe/Vienna")!

    /// Next departures at or after `now`, optionally only from one bay, soonest first.
    func departures(after now: Date, bay: String? = nil, limit: Int = 5) -> [Departure] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.timeZone
        guard let start = Self.parse(startDate, cal) else { return [] }
        let today = cal.dateComponents([.day], from: start, to: cal.startOfDay(for: now)).day ?? 0
        let bayIndex = bay.flatMap { data.bays.firstIndex(of: $0) }
        if bay != nil && bayIndex == nil { return [] }

        var result: [Departure] = []
        // Yesterday's service day too: GTFS times can run past midnight (25:10).
        for day in max(0, today - 1)...max(0, min(days - 1, today + 1)) {
            guard let dayStart = cal.date(byAdding: .day, value: day, to: start) else { continue }
            for d in data.deps where d.count == 6 {
                if let bayIndex, d[0] != bayIndex { continue }
                let mask = data.services[d[4]]
                guard day < mask.count, mask[mask.index(mask.startIndex, offsetBy: day)] == "1",
                      let time = cal.date(byAdding: .minute, value: d[3], to: dayStart), time >= now
                else { continue }
                result.append(Departure(bayId: data.bays[d[0]], line: data.lines[d[1]],
                                        headsign: data.headsigns[d[2]], time: time,
                                        lowFloor: d[5] == 1 ? true : d[5] == 2 ? false : nil))
            }
        }
        return Array(result.sorted { ($0.time, $0.line) < ($1.time, $1.line) }.prefix(limit))
    }

    private static func parse(_ yyyymmdd: String, _ cal: Calendar) -> Date? {
        guard yyyymmdd.count == 8, let v = Int(yyyymmdd) else { return nil }
        return cal.date(from: DateComponents(year: v / 10000, month: v / 100 % 100, day: v % 100))
    }

    static let demo: Timetable? = {
        guard let url = Bundle.main.url(forResource: "DemoTimetable", withExtension: "json"),
              let data = try? Foundation.Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Timetable.self, from: data)
    }()
}

struct Departure: Sendable, Equatable, Identifiable {
    let bayId: String
    let line: String
    let headsign: String
    let time: Date
    let lowFloor: Bool?           // nil = unknown

    var id: String { "\(bayId)|\(line)|\(time.timeIntervalSince1970)" }

    /// "Line 150 to Bad Ischl in 4 minutes, low-floor bus"
    func spoken(now: Date = .now) -> String {
        let minutes = max(0, Int((time.timeIntervalSince(now) / 60).rounded(.down)))
        let when = minutes == 0 ? "now" : minutes == 1 ? "in 1 minute" : "in \(minutes) minutes"
        let floor = lowFloor == true ? ", low-floor bus" : ""
        return "Line \(line) to \(headsign) \(when)\(floor)"
    }
}
