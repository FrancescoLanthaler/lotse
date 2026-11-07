import CoreLocation
import Foundation

// PocketBase records. Empty relations come back as "" (not null).

struct Stop: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let lat: Double
    let lon: Double

    var location: CLLocation { CLLocation(latitude: lat, longitude: lon) }
}

struct Bay: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let stop: String
    let label: String         // "A", "B", … (may be empty)
    let lines: [String]
    let lat: Double
    let lon: Double

    init(id: String, stop: String, label: String, lines: [String], lat: Double, lon: Double) {
        (self.id, self.stop, self.label, self.lines, self.lat, self.lon) = (id, stop, label, lines, lat, lon)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        stop = try c.decode(String.self, forKey: .stop)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        lines = try c.decodeIfPresent([String].self, forKey: .lines) ?? []   // json field may be null
        lat = try c.decode(Double.self, forKey: .lat)
        lon = try c.decode(Double.self, forKey: .lon)
    }
}

struct Marker: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case bay, entrance, vehicle }

    let id: String
    let stop: String          // "" for vehicle markers
    let tagId: Int            // tag25h9: 0–24 bays/entrances (unique per stop), 25–34 bus doors
    let kind: Kind
    let bay: String           // bay record id, "" if none
    let vehicleLine: String   // for kind == .vehicle
    let sizeM: Double         // outer black square edge in metres, measured after printing
    /// Where the bay's waiting spot is, seen from in front of the marker: metres to the marker's
    /// right and metres out from its face. Measured with a tape when the marker goes up.
    /// Not in PocketBase yet, so `WaitingSpot.offsets` hard-codes them for the test stop.
    var spotRightM: Double? = nil
    var spotOutM: Double? = nil

    enum CodingKeys: String, CodingKey {
        case id, stop, kind, bay
        case tagId = "tag_id", vehicleLine = "vehicle_line", sizeM = "size_m"
        case spotRightM = "spot_right_m", spotOutM = "spot_out_m"
    }
}

/// Everything the marker pipeline needs about the stop the rider is at.
/// Marker IDs are only meaningful together with a stop: the same tag id is reused at other stops.
struct StopContext: Codable, Sendable, Equatable {
    let stop: Stop
    let bays: [String: Bay]       // by bay id
    let markers: [Int: Marker]    // by tag id

    init(stop: Stop, bays: [Bay], markers: [Marker]) {
        self.stop = stop
        self.bays = Dictionary(bays.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.markers = Dictionary(markers.map { ($0.tagId, $0) }, uniquingKeysWith: { a, _ in a })
    }
}

/// The IDs the safety filter accepts right now: the current stop's markers plus the bus-door
/// markers (unique across the demo, valid at every stop).
struct MarkerCatalog: Sendable, Equatable {
    var stop: StopContext?
    var vehicles: [Int: Marker]

    static let empty = MarkerCatalog(stop: nil, vehicles: [:])

    var validIds: Set<Int> { Set(stop?.markers.keys ?? [:].keys).union(vehicles.keys) }
    func marker(for tagId: Int) -> Marker? { stop?.markers[tagId] ?? vehicles[tagId] }
    func bay(for marker: Marker) -> Bay? { stop?.bays[marker.bay] }
}

/// Bundled fallback (`DemoStop.json`, written by tools/import_osm_stops.py): the demo stop with
/// its bays and markers, plus the bus-door markers. Lets the demo run without network.
struct DemoBundle: Decodable, Sendable {
    let stop: Stop
    let bays: [Bay]
    let markers: [Marker]

    var context: StopContext { StopContext(stop: stop, bays: bays, markers: markers.filter { $0.kind != .vehicle }) }
    var vehicles: [Int: Marker] {
        Dictionary(markers.filter { $0.kind == .vehicle }.map { ($0.tagId, $0) }, uniquingKeysWith: { a, _ in a })
    }

    static let shared: DemoBundle? = {
        guard let url = Bundle.main.url(forResource: "DemoStop", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DemoBundle.self, from: data)
    }()
}
