import CoreLocation
import MapKit
import os

private let navLog = Logger(subsystem: "com.novalleyduck.NoValleyDuck", category: "navigation")

/// Builds a `NavigationPlan` (walk → bus → walk) from a spoken destination.
///
/// Data sources:
/// - Apple Maps (MapKit): location search and turn-by-turn walking directions.
/// - Transitous: which bus to take (line, direction, stops, platform, times).
/// - Fallback if Transitous fails: Apple Maps only. MapKit gives no in-app transit routes or line
///   numbers, just an ETA, so stops are the nearest transit POIs and `BusLeg.line` stays nil.
@MainActor
final class NavigationService {
    let location = LocationProvider()
    let transitous = TransitousClient()

    /// Destinations closer than this are walked directly, no bus.
    var walkOnlyThreshold: CLLocationDistance = 600
    /// How far to look for stops around origin / destination (Apple Maps fallback).
    var stopSearchRadius: CLLocationDistance = 800
    /// User needs step-free routes and wheelchair-accessible buses.
    var needsStepFreeAccess = false
    /// Extra minutes a transfer "costs" when choosing between trips. Changing buses is hard for our users.
    var transferPenaltyMinutes: Double = 10
    /// Extra seconds per walked meter when choosing between trips (1.0 ≈ walking counts double).
    /// Prefers stops close to the destination over a slightly earlier arrival with a long walk.
    var walkPenaltySecondsPerMeter: Double = 1.0
    /// false = use Apple Maps (MapKit) only, e.g. to compare or demo the MapKit data.
    var useTransitous = true

    // MARK: - Public API

    /// Main entry point: `query` is the transcribed voice input, e.g. "Mirabellplatz".
    func plan(to query: String) async throws -> NavigationPlan {
        let here = try await location.currentLocation()
        let origin = Place(name: "Current location", address: nil, coordinate: Coordinate(here.coordinate))
        let destination = try await findDestination(query, near: origin.coordinate)
        return try await plan(from: origin, to: destination)
    }

    func plan(from origin: Place, to destination: Place) async throws -> NavigationPlan {
        navLog.info("Planning \(origin.name) → \(destination.name)")
        let direct = origin.coordinate.distance(to: destination.coordinate)

        if direct <= walkOnlyThreshold {
            let walk = try await walkingLeg(from: origin, to: destination)
            return NavigationPlan(createdAt: .now, origin: origin, destination: destination, legs: [.walk(leg: walk)])
        }

        guard useTransitous else { return try await appleMapsPlan(from: origin, to: destination) }
        do {
            let plan = try await transitousPlan(from: origin, to: destination)
            if let json = try? plan.json(pretty: false) { navLog.debug("Plan: \(json, privacy: .public)") }
            return plan
        } catch {
            navLog.error("Transitous failed, falling back to Apple Maps: \(error.localizedDescription)")
            return try await appleMapsPlan(from: origin, to: destination)
        }
    }

    // MARK: - Transitous (bus line data)

    private func transitousPlan(from origin: Place, to destination: Place) async throws -> NavigationPlan {
        var options = TransitousClient.Options()
        options.stepFree = needsStepFreeAccess
        let itineraries = try await transitous.plan(from: origin.coordinate, to: destination.coordinate, options: options)
        guard let best = chooseItinerary(itineraries) else { throw NavigationError.noBusConnection }

        var legs: [Leg] = []
        for (i, leg) in best.legs.enumerated() {
            // START / END placeholders → our own named places.
            let from = i == 0 && leg.isWalk ? origin : Place(stop: leg.from)
            let to = i == best.legs.count - 1 && leg.isWalk ? destination : Place(stop: leg.to)

            if leg.isWalk {
                // Skip same-stop transfers ("walk 3 m").
                if (leg.distance ?? from.coordinate.distance(to: to.coordinate)) < 25 { continue }
                legs.append(.walk(leg: await walkingLegOrStraightLine(from: from, to: to)))
            } else {
                let bus = BusLeg(
                    boardingStop: from,
                    alightingStop: to,
                    estimate: TransitEstimate(expectedDeparture: leg.startTime,
                                              expectedArrival: leg.endTime,
                                              travelTimeSeconds: leg.endTime.timeIntervalSince(leg.startTime),
                                              distanceMeters: nil),
                    line: leg.routeShortName,
                    direction: leg.headsign,
                    operatorName: leg.agencyName,
                    boardingPlatform: leg.from.track,
                    alightingPlatform: leg.to.track,
                    intermediateStops: (leg.intermediateStops ?? []).map {
                        StopCall(stop: Place(stop: $0), arrival: $0.arrival)
                    },
                    wheelchairAccessible: leg.isWheelchairAccessible,
                    isRealtime: leg.realTime ?? false,
                    source: .transitous)
                legs.append(.bus(leg: bus))
            }
        }
        return NavigationPlan(createdAt: .now, origin: origin, destination: destination, legs: legs)
    }

    /// Earliest arrival, with penalties for transfers and walking; with step-free needs, avoid non-accessible buses.
    private func chooseItinerary(_ list: [TransitousClient.Itinerary]) -> TransitousClient.Itinerary? {
        var candidates = list.filter { $0.legs.contains { !$0.isWalk } }
        if needsStepFreeAccess {
            let accessible = candidates.filter { !$0.legs.contains { $0.isWheelchairAccessible == false } }
            if !accessible.isEmpty { candidates = accessible }
        }
        return candidates.min { score($0) < score($1) }
    }

    private func score(_ it: TransitousClient.Itinerary) -> Double {
        let walked = it.legs.filter(\.isWalk).reduce(0) { $0 + ($1.distance ?? 0) }
        return it.endTime.timeIntervalSinceReferenceDate
            + Double(it.transfers) * transferPenaltyMinutes * 60
            + walked * walkPenaltySecondsPerMeter
    }

    func walkingLegOrStraightLine(from: Place, to: Place) async -> WalkingLeg {
        if let leg = try? await walkingLeg(from: from, to: to) { return leg }
        let d = from.coordinate.distance(to: to.coordinate)
        let step = NavigationStep(index: 0, instruction: "Walk to \(to.spokenName)", notice: nil,
                                  distanceMeters: d, maneuverCoordinate: from.coordinate,
                                  endCoordinate: to.coordinate, path: [from.coordinate, to.coordinate])
        return WalkingLeg(from: from, to: to, distanceMeters: d, expectedTravelTimeSeconds: d / 1.2,
                          steps: [step], path: step.path)
    }

    // MARK: - Apple Maps only (fallback)

    private func appleMapsPlan(from origin: Place, to destination: Place) async throws -> NavigationPlan {
        async let originStops = nearbyStops(around: origin.coordinate)
        async let destinationStops = nearbyStops(around: destination.coordinate)
        guard let boarding = try await originStops.first else { throw NavigationError.noStopNearOrigin }
        guard let alighting = try await destinationStops.first else { throw NavigationError.noStopNearDestination }

        if boarding.coordinate.distance(to: alighting.coordinate) < 50 {
            // Same stop at both ends → bus makes no sense.
            let walk = try await walkingLeg(from: origin, to: destination)
            return NavigationPlan(createdAt: .now, origin: origin, destination: destination, legs: [.walk(leg: walk)])
        }

        async let walkTo = walkingLeg(from: origin, to: boarding)
        async let walkFrom = walkingLeg(from: alighting, to: destination)
        let toStop = try await walkTo
        // Depart from the stop once the user has walked there.
        let departure = Date.now.addingTimeInterval(toStop.expectedTravelTimeSeconds)
        let estimate = await transitEstimate(from: boarding, to: alighting, departure: departure)
        let fromStop = try await walkFrom

        let bus = BusLeg(boardingStop: boarding, alightingStop: alighting, estimate: estimate, source: .appleMaps)
        return NavigationPlan(createdAt: .now, origin: origin, destination: destination,
                              legs: [.walk(leg: toStop), .bus(leg: bus), .walk(leg: fromStop)])
    }

    // MARK: - Destination search

    func findDestination(_ query: String, near center: Coordinate) async throws -> Place {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        request.region = MKCoordinateRegion(center: center.clCoordinate,
                                            latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        let response: MKLocalSearch.Response
        do {
            apiLog("MapKit MKLocalSearch: \"\(query)\"")
            response = try await MKLocalSearch(request: request).start()
        } catch {
            throw NavigationError.destinationNotFound(query)
        }
        // The region is only a hint: a misheard name can match a place in London. Stay near the rider.
        guard let item = response.mapItems.first(where: {
            Coordinate($0.placemark.coordinate).distance(to: center) <= 50_000
        }) else { throw NavigationError.destinationNotFound(query) }
        return Place(item, fallbackName: query)
    }

    // MARK: - Stops

    /// Public-transport POIs (bus stops, stations) around a point, nearest first.
    func nearbyStops(around center: Coordinate) async throws -> [Place] {
        let request = MKLocalPointsOfInterestRequest(center: center.clCoordinate, radius: stopSearchRadius)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.publicTransport])
        apiLog("MapKit MKLocalPointsOfInterestRequest: transit stops near \(center.latitude),\(center.longitude)")
        var items = (try? await MKLocalSearch(request: request).start().mapItems) ?? []

        if items.isEmpty {
            // Fallback: text search, sometimes finds stops the POI index misses.
            let text = MKLocalSearch.Request()
            text.naturalLanguageQuery = "Bushaltestelle"
            text.region = MKCoordinateRegion(center: center.clCoordinate,
                                             latitudinalMeters: stopSearchRadius * 2,
                                             longitudinalMeters: stopSearchRadius * 2)
            items = (try? await MKLocalSearch(request: text).start().mapItems) ?? []
        }

        return items
            .map { Place($0, fallbackName: "Stop") }
            .filter { $0.coordinate.distance(to: center) <= stopSearchRadius }
            .sorted { $0.coordinate.distance(to: center) < $1.coordinate.distance(to: center) }
    }

    // MARK: - Routing

    func walkingLeg(from: Place, to: Place) async throws -> WalkingLeg {
        let request = MKDirections.Request()
        request.source = from.mapItem
        request.destination = to.mapItem
        request.transportType = .walking
        apiLog("MapKit MKDirections (walking): \(from.name) → \(to.name)")
        guard let route = try await MKDirections(request: request).calculate().routes.first else {
            throw NavigationError.noWalkingRoute
        }

        var steps: [NavigationStep] = []
        for step in route.steps where !step.instructions.isEmpty {
            let path = step.polyline.coordinates.map(Coordinate.init)
            guard let first = path.first, let last = path.last else { continue }
            steps.append(NavigationStep(index: steps.count,
                                        instruction: step.instructions,
                                        notice: step.notice,
                                        distanceMeters: step.distance,
                                        maneuverCoordinate: first,
                                        endCoordinate: last,
                                        path: path))
        }

        return WalkingLeg(from: from, to: to,
                          distanceMeters: route.distance,
                          expectedTravelTimeSeconds: route.expectedTravelTime,
                          steps: steps,
                          path: route.polyline.coordinates.map(Coordinate.init))
    }

    /// Transit ETA between two stops, nil if Apple Maps has no transit data here.
    func transitEstimate(from: Place, to: Place, departure: Date) async -> TransitEstimate? {
        let request = MKDirections.Request()
        request.source = from.mapItem
        request.destination = to.mapItem
        request.transportType = .transit
        request.departureDate = departure
        do {
            apiLog("MapKit MKDirections.calculateETA (transit): \(from.name) → \(to.name)")
            let eta = try await MKDirections(request: request).calculateETA()
            return TransitEstimate(expectedDeparture: eta.expectedDepartureDate,
                                   expectedArrival: eta.expectedArrivalDate,
                                   travelTimeSeconds: eta.expectedTravelTime,
                                   distanceMeters: eta.distance)
        } catch {
            navLog.notice("No transit ETA: \(error.localizedDescription)")
            return nil
        }
    }
}

/// Prints every external API call to the Xcode console, so you can see which service delivered what.
func apiLog(_ message: String) {
    print("[API] \(message)")
}

// MARK: - MapKit bridging

private extension Place {
    init(stop: TransitousClient.Stop) {
        self.init(name: stop.name, address: nil, coordinate: stop.coordinate)
    }

    init(_ item: MKMapItem, fallbackName: String) {
        self.init(name: item.name ?? fallbackName,
                  address: item.placemark.title,
                  coordinate: Coordinate(item.placemark.coordinate))
    }

    var mapItem: MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate.clCoordinate))
        item.name = name
        return item
    }
}

private extension MKMultiPoint {
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}
