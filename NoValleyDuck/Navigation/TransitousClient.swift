import Foundation

/// Public-transport trip planning via Transitous (https://transitous.org), a community-run
/// MOTIS 2 server fed with open GTFS timetables, including all Salzburg bus lines.
///
/// Usage policy (https://transitous.org/api/): free for non-commercial, open-source apps
/// (prototype testing before publishing is fine); every request must send a User-Agent with app
/// name, version and contact; the app must link https://transitous.org/sources/ visibly.
struct TransitousClient {
    /// REQUIRED by the Transitous policy: put the team's email or project URL here.
    static let contact = "TODO-add-contact-email-or-repo-url"
    static let userAgent = "NoValleyDuck/0.1 (FH Salzburg hackathon prototype; \(contact))"
    static let attributionURL = URL(string: "https://transitous.org/sources/")!

    var baseURL = URL(string: "https://api.transitous.org/api/v5/plan")!

    struct Options {
        /// Use step-free walking paths (wheelchair profile).
        var stepFree = false
        var maxTransfers = 2
        var departure: Date = .now
        /// GTFS-style modes, "BUS" only by default since the driver flow is bus-specific.
        var transitModes = ["BUS"]
    }

    func plan(from: Coordinate, to: Coordinate, options: Options = .init()) async throws -> [Itinerary] {
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "fromPlace", value: "\(from.latitude),\(from.longitude)"),
            .init(name: "toPlace", value: "\(to.latitude),\(to.longitude)"),
            .init(name: "time", value: ISO8601DateFormatter().string(from: options.departure)),
            .init(name: "transitModes", value: options.transitModes.joined(separator: ",")),
            .init(name: "maxTransfers", value: String(options.maxTransfers)),
            .init(name: "pedestrianProfile", value: options.stepFree ? "WHEELCHAIR" : "FOOT"),
        ]
        var request = URLRequest(url: c.url!, timeoutInterval: 20)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        apiLog("Transitous GET \(c.url!.absoluteString)")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try Self.decoder.decode(PlanResponse.self, from: data).itineraries
    }

    // MARK: - Response (only the fields we use)

    struct PlanResponse: Decodable {
        let itineraries: [Itinerary]
    }

    struct Itinerary: Decodable {
        let startTime: Date
        let endTime: Date
        let transfers: Int
        let legs: [Leg]
    }

    struct Leg: Decodable {
        let mode: String               // "WALK", "BUS", …
        let from: Stop
        let to: Stop
        let startTime: Date
        let endTime: Date
        let distance: Double?          // walking legs only
        let realTime: Bool?
        let headsign: String?
        let routeShortName: String?
        let agencyName: String?
        let intermediateStops: [Stop]?
        let wheelchairAccessible: LooseValue?   // "ACCESSIBLE" / "NOT_ACCESSIBLE" / missing

        var isWalk: Bool { mode == "WALK" }
        var isWheelchairAccessible: Bool? {
            switch wheelchairAccessible?.string {
            case "ACCESSIBLE", "true": true
            case "NOT_ACCESSIBLE", "false": false
            default: nil
            }
        }
    }

    struct Stop: Decodable {
        let name: String
        let stopId: String?
        let lat: Double
        let lon: Double
        let track: String?
        let arrival: Date?
        let departure: Date?

        var coordinate: Coordinate { Coordinate(latitude: lat, longitude: lon) }
    }

    /// Accepts a string or bool, so a schema change there can't break decoding of the whole trip.
    struct LooseValue: Decodable {
        let string: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { string = s }
            else if let b = try? c.decode(Bool.self) { string = String(b) }
            else { string = nil }
        }
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = plain.date(from: s) ?? fractional.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Bad date \(s)"))
        }
        return d
    }()
}
