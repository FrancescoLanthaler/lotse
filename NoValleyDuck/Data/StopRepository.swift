import CoreLocation
import Foundation

/// Loads stops, bays and markers from PocketBase and keeps an on-disk copy of everything it
/// fetched, so guidance keeps working when the connection drops (spec: network is not
/// time-critical). Falls back to the bundled demo stop.
actor StopRepository {
    private let client: PocketBaseClient
    private let cacheDir: URL
    private var vehicleCache: [Int: Marker]?

    init(client: PocketBaseClient = PocketBaseClient(baseURL: Config.pocketBaseURL),
         cacheDir: URL = URL.applicationSupportDirectory.appending(path: "StopCache")) {
        self.client = client
        self.cacheDir = cacheDir
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Stops inside a square of ±`radius` metres around `coordinate`.
    func stops(near coordinate: CLLocationCoordinate2D, radius: Double) async -> [Stop] {
        let dLat = radius / 111_320
        let dLon = radius / (111_320 * max(0.1, cos(coordinate.latitude * .pi / 180)))
        let f = String(format: "lat >= %.6f && lat <= %.6f && lon >= %.6f && lon <= %.6f",
                       coordinate.latitude - dLat, coordinate.latitude + dLat,
                       coordinate.longitude - dLon, coordinate.longitude + dLon)
        do {
            let stops: [Stop] = try await client.list("stops", filter: f)
            save(stops, as: "nearby.json")
            return stops
        } catch {
            // Offline: whatever we saw last time, plus the demo stop.
            var cached: [Stop] = load("nearby.json") ?? []
            if let demo = DemoBundle.shared?.stop, !cached.contains(demo) { cached.append(demo) }
            return cached
        }
    }

    /// Bays and markers of one stop: network first, then disk cache, then bundled demo data.
    func context(for stop: Stop) async -> StopContext {
        let file = "stop_\(stop.id).json"
        do {
            async let bays: [Bay] = client.list("bays", filter: "stop = \(stop.id.pbQuoted)")
            async let markers: [Marker] = client.list("markers", filter: "stop = \(stop.id.pbQuoted)")
            let ctx = StopContext(stop: stop, bays: try await bays, markers: try await markers)
            save(ctx, as: file)
            return ctx
        } catch {
            if let cached: StopContext = load(file) { return cached }
            if let demo = DemoBundle.shared, demo.stop.id == stop.id { return demo.context }
            return StopContext(stop: stop, bays: [], markers: [])
        }
    }

    /// The stop's timetable: network, then disk cache, then the bundled demo timetable.
    /// A cached copy older than its window is still returned (better than nothing offline).
    func timetable(for stop: Stop) async -> Timetable? {
        let file = "timetable_\(stop.id).json"
        do {
            let t: [Timetable] = try await client.list("timetables", filter: "stop = \(stop.id.pbQuoted)", perPage: 1)
            if let t = t.first {
                save(t, as: file)
                return t
            }
        } catch {}
        if let cached: Timetable = load(file) { return cached }
        if let demo = Timetable.demo, demo.stop == stop.id { return demo }
        return nil
    }

    /// Bus-door markers (kind = vehicle). Fetched once per launch.
    func vehicleMarkers() async -> [Int: Marker] {
        if let vehicleCache { return vehicleCache }
        let result: [Int: Marker]
        do {
            let markers: [Marker] = try await client.list("markers", filter: "kind = \"vehicle\"")
            result = Dictionary(markers.map { ($0.tagId, $0) }, uniquingKeysWith: { a, _ in a })
            save(Array(result.values), as: "vehicles.json")
        } catch {
            let cached: [Marker]? = load("vehicles.json")
            result = cached.map { Dictionary($0.map { ($0.tagId, $0) }, uniquingKeysWith: { a, _ in a }) }
                ?? DemoBundle.shared?.vehicles ?? [:]
        }
        vehicleCache = result
        return result
    }

    private func save<T: Encodable>(_ value: T, as name: String) {
        try? JSONEncoder().encode(value).write(to: cacheDir.appending(path: name), options: .atomic)
    }

    private func load<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: cacheDir.appending(path: name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
