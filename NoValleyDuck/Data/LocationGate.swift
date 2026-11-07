import CoreLocation
import Foundation
import Observation

/// Decides which stop the rider is at. Marker IDs are reused between stops, so this is what
/// gives a detected ID its meaning.
enum StopSelector {
    static let enterRadius: CLLocationDistance = 150   // spec: "within 150 m of a known stop"
    static let exitRadius: CLLocationDistance = 200    // hysteresis, so the stop doesn't flap
    static let switchMargin: CLLocationDistance = 50   // another stop must be this much closer

    static func select(current: Stop?, candidates: [Stop], at location: CLLocation) -> Stop? {
        let ranked = candidates
            .map { ($0, $0.location.distance(from: location)) }
            .filter { $0.1 <= enterRadius }
            .sorted { $0.1 < $1.1 }
        if let current {
            let d = current.location.distance(from: location)
            if d <= exitRadius {
                // Stay, unless a different stop is clearly closer (adjacent stops are common).
                if let best = ranked.first, best.0.id != current.id, best.1 + switchMargin < d { return best.0 }
                return current
            }
        }
        return ranked.first?.0
    }
}

@Observable
@MainActor
final class LocationGate {
    enum Source: String, Sendable { case none, gps, demo }

    private(set) var context: StopContext?
    private(set) var source: Source = .none
    private(set) var location: CLLocation?
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// Hidden demo switch: in the hall GPS says Messezentrum, so force the demo stop.
    private(set) var demoOverride = UserDefaults.standard.bool(forKey: "demoStopOverride")

    /// Called whenever `context` changes.
    @ObservationIgnored var onChange: ((StopContext?) -> Void)?

    @ObservationIgnored private let repository: StopRepository
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var candidates: [Stop] = []
    @ObservationIgnored private var lastFetch: CLLocation?
    @ObservationIgnored private var gpsStop: Stop?
    @ObservationIgnored private var updates: Task<Void, Never>?

    static let fetchRadius: CLLocationDistance = 400
    static let refetchAfter: CLLocationDistance = 100

    init(repository: StopRepository) { self.repository = repository }

    var distanceToStop: CLLocationDistance? {
        guard let location, let stop = context?.stop else { return nil }
        return stop.location.distance(from: location)
    }

    func start() {
        guard updates == nil else { return }
        manager.requestWhenInUseAuthorization()
        authorization = manager.authorizationStatus
        if demoOverride { Task { await apply() } }
        updates = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    guard let self else { return }
                    self.authorization = self.manager.authorizationStatus
                    if let loc = update.location { await self.handle(loc) }
                }
            } catch {}
        }
    }

    func setDemoOverride(_ on: Bool) {
        demoOverride = on
        UserDefaults.standard.set(on, forKey: "demoStopOverride")
        Task { await apply() }
    }

    private func handle(_ loc: CLLocation) async {
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 100 else { return }
        location = loc
        if lastFetch.map({ $0.distance(from: loc) > Self.refetchAfter }) ?? true {
            lastFetch = loc
            candidates = await repository.stops(near: loc.coordinate, radius: Self.fetchRadius)
        }
        let selected = StopSelector.select(current: gpsStop, candidates: candidates, at: loc)
        if selected?.id != gpsStop?.id {
            gpsStop = selected
            await apply()
        }
    }

    /// Resolve the active stop (demo override wins) and load its markers.
    private func apply() async {
        let target: (Stop, Source)?
        if demoOverride, let demo = DemoBundle.shared?.stop {
            target = (demo, .demo)
        } else {
            target = gpsStop.map { ($0, .gps) }
        }
        guard let (stop, src) = target else {
            if context != nil { context = nil; source = .none; onChange?(nil) }
            return
        }
        let ctx = await repository.context(for: stop)
        // A newer selection may have happened while we were loading.
        let still = demoOverride ? (src == .demo) : (src == .gps && gpsStop?.id == stop.id)
        guard still, ctx != context || source != src else { return }
        context = ctx
        source = src
        onChange?(ctx)
    }
}
