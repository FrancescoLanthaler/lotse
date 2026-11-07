import CoreLocation
import Foundation

// Plain, Codable navigation data. Everything here can be encoded to JSON and sent
// to a backend / driver app, or consumed by the audio-guidance layer.

struct Coordinate: Codable, Hashable {
    var latitude: Double
    var longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ c: CLLocationCoordinate2D) {
        self.init(latitude: c.latitude, longitude: c.longitude)
    }

    var clCoordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var clLocation: CLLocation { .init(latitude: latitude, longitude: longitude) }

    /// Straight-line distance in meters.
    func distance(to other: Coordinate) -> CLLocationDistance {
        clLocation.distance(from: other.clLocation)
    }

    /// Compass bearing to `other` in degrees (0 = north, 90 = east).
    func bearing(to other: Coordinate) -> Double {
        let lat1 = latitude * .pi / 180, lat2 = other.latitude * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Angle of `other` relative to where the user is facing, in -180...180
    /// (negative = to the left, positive = to the right). Feed this to spatial audio.
    func relativeAngle(to other: Coordinate, userHeading: Double) -> Double {
        var a = bearing(to: other) - userHeading
        a = (a + 540).truncatingRemainder(dividingBy: 360) - 180
        return a
    }
}

struct Place: Codable, Hashable {
    var name: String
    var address: String?
    var coordinate: Coordinate
}

/// One turn-by-turn instruction of a walking route.
struct NavigationStep: Codable, Hashable {
    var index: Int
    /// Localized instruction from Apple Maps, e.g. "Turn right onto Getreidegasse".
    var instruction: String
    /// Optional extra notice from Apple Maps (e.g. "Crosses a busy road").
    var notice: String?
    var distanceMeters: Double
    /// Where the maneuver happens (start of this step).
    var maneuverCoordinate: Coordinate
    /// Where this step ends (start of the next maneuver).
    var endCoordinate: Coordinate
    /// Full geometry of this step.
    var path: [Coordinate]
}

struct WalkingLeg: Codable, Hashable {
    var from: Place
    var to: Place
    var distanceMeters: Double
    var expectedTravelTimeSeconds: TimeInterval
    var steps: [NavigationStep]
    /// Full geometry of the whole leg.
    var path: [Coordinate]
}

/// Departure / arrival of a ride.
struct TransitEstimate: Codable, Hashable {
    var expectedDeparture: Date
    var expectedArrival: Date
    var travelTimeSeconds: TimeInterval
    /// Only known for Apple Maps estimates.
    var distanceMeters: Double?
}

/// A stop the bus passes, with its scheduled time. Used for "your stop is next" alerts.
struct StopCall: Codable, Hashable {
    var stop: Place
    var arrival: Date?
}

enum TransitDataSource: String, Codable, Hashable {
    /// Timetable data with line numbers (transitous.org, GTFS from Austrian transport operators).
    case transitous
    /// Apple Maps ETA only: no line number, stops guessed as nearest transit POIs.
    case appleMaps
}

struct BusLeg: Codable, Hashable {
    var boardingStop: Place
    var alightingStop: Place
    /// Departure / arrival times. nil if no transit data is available.
    var estimate: TransitEstimate?
    /// Bus line, e.g. "1". nil when only Apple Maps data is available.
    var line: String? = nil
    /// Direction shown on the bus, e.g. "Kleßheim".
    var direction: String? = nil
    var operatorName: String? = nil
    /// Platform / bay letter at the stop, e.g. "A".
    var boardingPlatform: String? = nil
    var alightingPlatform: String? = nil
    /// Stops between boarding and alighting (both excluded).
    var intermediateStops: [StopCall] = []
    /// Whether this trip is run with a wheelchair-accessible vehicle (nil = unknown).
    var wheelchairAccessible: Bool? = nil
    /// true if times include live delays, false = timetable only.
    var isRealtime: Bool = false
    var source: TransitDataSource = .appleMaps

    /// Number of stops the user rides (getting off at the last one).
    var stopsToRide: Int { intermediateStops.count + 1 }

    /// Sentence for text-to-speech, e.g.
    /// "Take bus 1 towards Kleßheim from Ferdinand-Hanusch-Platz, platform A, at 22:04. Ride 10 stops and get off at Europark."
    var announcement: String {
        var s: String
        if let line {
            s = "Take bus \(line)"
            if let direction { s += " towards \(direction)" }
        } else {
            s = "Take a bus"
        }
        s += " from \(boardingStop.spokenName)"
        if let boardingPlatform, !boardingPlatform.isEmpty { s += ", platform \(boardingPlatform)" }
        if let estimate { s += ", at \(estimate.expectedDeparture.formatted(date: .omitted, time: .shortened))" }
        s += "."
        if source == .transitous {
            s += stopsToRide == 1 ? " Get off at the next stop," : " Ride \(stopsToRide) stops and get off at"
            s += " \(alightingStop.spokenName)."
        } else {
            s += " Get off at \(alightingStop.spokenName)."
        }
        return s
    }
}

extension Place {
    /// Stop names in the timetable data are prefixed with the town ("Salzburg Europark"); drop it for speech.
    var spokenName: String {
        name.hasPrefix("Salzburg ") ? String(name.dropFirst("Salzburg ".count)) : name
    }
}

enum Leg: Codable, Hashable {
    // Labels give readable JSON: {"walk": {"leg": {...}}} instead of {"walk": {"_0": {...}}}.
    case walk(leg: WalkingLeg)
    case bus(leg: BusLeg)
}

struct NavigationPlan: Codable, Hashable {
    var createdAt: Date
    var origin: Place
    var destination: Place
    /// Ordered legs: usually walk → bus → walk, or a single walk when the destination is close.
    var legs: [Leg]

    var totalWalkingMeters: Double {
        legs.reduce(0) { sum, leg in
            if case .walk(let w) = leg { return sum + w.distanceMeters }
            return sum
        }
    }

    func json(pretty: Bool = true) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : []
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

enum NavigationError: LocalizedError {
    case locationDenied
    case locationUnavailable
    case destinationNotFound(String)
    case noStopNearOrigin
    case noStopNearDestination
    case noWalkingRoute
    case noBusConnection

    var errorDescription: String? {
        switch self {
        case .locationDenied: "Location access denied. Enable it in Settings."
        case .locationUnavailable: "Could not determine your location."
        case .destinationNotFound(let q): "Could not find \"\(q)\"."
        case .noStopNearOrigin: "No public transport stop found near you."
        case .noStopNearDestination: "No public transport stop found near the destination."
        case .noWalkingRoute: "No walking route found."
        case .noBusConnection: "No bus connection found."
        }
    }
}
