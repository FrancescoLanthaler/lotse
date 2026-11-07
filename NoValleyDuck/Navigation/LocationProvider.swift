import CoreLocation

/// One-shot access to the user's current location.
@MainActor
final class LocationProvider {
    private let manager = CLLocationManager()

    /// Returns a location with accuracy ≤ `desiredAccuracy` meters, or the best one after `maxUpdates` fixes.
    func currentLocation(desiredAccuracy: CLLocationAccuracy = 50, maxUpdates: Int = 8) async throws -> CLLocation {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            throw NavigationError.locationDenied
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }

        var best: CLLocation?
        var count = 0
        for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
            guard let loc = update.location, loc.horizontalAccuracy >= 0 else { continue }
            if best == nil || loc.horizontalAccuracy < best!.horizontalAccuracy { best = loc }
            count += 1
            if loc.horizontalAccuracy <= desiredAccuracy || count >= maxUpdates { break }
        }
        guard let best else { throw NavigationError.locationUnavailable }
        return best
    }
}
