import ActivityKit
import Foundation
import os

private let log = Logger(subsystem: "com.novalleyduck.NoValleyDuck", category: "route")

/// Lock screen / Dynamic Island card for the running trip. The trip itself is driven by
/// TripController; this only mirrors its status line.
@MainActor
enum TripLiveActivity {
    private static var activity: Activity<TripActivityAttributes>?

    static func update(phase: TripController.Phase, destination: String?, state: TripActivityAttributes.ContentState) {
        if phase == .idle {
            activity = nil
            endAll()
            return
        }
        let title = destination ?? "your destination"
        // The title is fixed per activity, so a new destination (or one left over from a killed app)
        // gets a fresh card.
        if let activity, activity.attributes.destination != title {
            self.activity = nil
            endAll()
        } else if activity == nil {
            endAll()
        }
        if let activity {
            Task { await activity.update(.init(state: state, staleDate: nil)) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                activity = try Activity.request(
                    attributes: TripActivityAttributes(destination: title),
                    content: .init(state: state, staleDate: nil))
            } catch {
                log.error("live activity failed: \(error.localizedDescription)")
            }
        }
    }

    static func endAll() {
        for old in Activity<TripActivityAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
    }

    static func symbol(_ phase: TripController.Phase) -> String {
        switch phase {
        case .idle, .planning: "magnifyingglass"
        case .walking, .toSpot: "figure.walk"
        case .scanning: "camera.viewfinder"
        case .waiting, .riding: "bus"
        case .arrived: "checkmark.circle"
        }
    }
}
