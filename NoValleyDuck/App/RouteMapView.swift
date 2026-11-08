import MapKit
import SwiftUI

/// Debug map: the route the trip is following, the walking checkpoints and the GPS fix the app
/// uses (with its accuracy circle). Redraws every second because the trip state isn't observed.
struct RouteMapView: View {
    let trip: TripController
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Map(position: $position) {
                UserAnnotation()
                ForEach(trip.legs.indices, id: \.self) { i in legContent(trip.legs[i], current: i == trip.legIndex) }
                if trip.phase == .walking {
                    ForEach(trip.checkpointIndex..<trip.checkpoints.count, id: \.self) { i in checkpoint(i) }
                }
                if let dest = trip.plan?.destination {
                    pin(dest.name, "flag.checkered", dest.coordinate.clCoordinate, .green)
                }
                if let info = trip.directionInfo {
                    // Red: towards the beacon target. Purple: where the app thinks you're facing.
                    MapPolyline(coordinates: [info.location.coordinate, info.target.clCoordinate])
                        .stroke(.red, lineWidth: 2)
                    if let h = info.heading {
                        MapPolyline(coordinates: [info.location.coordinate, Self.point(from: info.location.coordinate, bearing: h, metres: 25)])
                            .stroke(.purple, lineWidth: 4)
                    }
                }
                if let loc = trip.location {
                    MapCircle(center: loc.coordinate, radius: loc.horizontalAccuracy)
                        .foregroundStyle(.purple.opacity(0.2))
                    Annotation("App GPS ±\(Int(loc.horizontalAccuracy)) m", coordinate: loc.coordinate) {
                        Circle().fill(.purple).stroke(.white, lineWidth: 2).frame(width: 12)
                    }
                }
            }
            .mapControls { MapUserLocationButton(); MapCompass(); MapScaleView() }
            .overlay(alignment: .bottom) {
                if let text = trip.directionInfo?.text {
                    Text(text).font(.caption.monospacedDigit()).foregroundStyle(.white)
                        .padding(6).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                        .padding(6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary)
        }
    }

    @MapContentBuilder
    private func legContent(_ leg: Leg, current: Bool) -> some MapContent {
        let current = current && trip.isRouteActive
        switch leg {
        case .walk(let w):
            MapPolyline(coordinates: w.path.map(\.clCoordinate))
                .stroke(.blue.opacity(current ? 1 : 0.5), lineWidth: current ? 6 : 3)
        case .bus(let b):
            let stops = [b.boardingStop] + b.intermediateStops.map(\.stop) + [b.alightingStop]
            MapPolyline(coordinates: stops.map(\.coordinate.clCoordinate))
                .stroke(.orange.opacity(current ? 1 : 0.6), style: StrokeStyle(lineWidth: current ? 6 : 3, dash: [8, 6]))
            pin("Board \(b.line ?? "bus")", "bus", b.boardingStop.coordinate.clCoordinate, .orange)
            pin("Get off", "figure.walk", b.alightingStop.coordinate.clCoordinate, .orange)
        }
    }

    /// A labelled pin (MapKit's `Marker` is shadowed by the app's stop-marker model).
    private func pin(_ title: String, _ icon: String, _ c: CLLocationCoordinate2D, _ color: Color) -> some MapContent {
        Annotation(title, coordinate: c) {
            Image(systemName: icon).font(.caption.bold()).foregroundStyle(.white)
                .padding(6).background(color, in: Circle())
        }
    }

    /// Red = the checkpoint the beacon points at, yellow = a turn.
    private func checkpoint(_ i: Int) -> some MapContent {
        let cp = trip.checkpoints[i], next = i == trip.checkpointIndex
        return Annotation("", coordinate: cp.coordinate.clCoordinate) {
            Circle()
                .fill(next ? .red : (cp.turn == nil ? .white : .yellow))
                .stroke(.black, lineWidth: 1)
                .frame(width: next ? 16 : 9)
        }
    }

    static func point(from c: CLLocationCoordinate2D, bearing: Double, metres: Double) -> CLLocationCoordinate2D {
        let b = bearing * .pi / 180
        return CLLocationCoordinate2D(latitude: c.latitude + metres * cos(b) / 111_195,
                                      longitude: c.longitude + metres * sin(b) / (111_195 * cos(c.latitude * .pi / 180)))
    }

    private var summary: String {
        guard !trip.legs.isEmpty else { return "Route map. No route." }
        var s = "Route map. Leg \(trip.legIndex + 1) of \(trip.legs.count), \(trip.statusTitle)."
        if trip.phase == .walking { s += " Checkpoint \(trip.checkpointIndex + 1) of \(trip.checkpoints.count)." }
        if let text = trip.directionInfo?.text { s += " \(text)." }
        if let loc = trip.location { s += " GPS accuracy \(Int(loc.horizontalAccuracy)) metres." }
        return s
    }
}
