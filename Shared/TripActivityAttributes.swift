import ActivityKit
import Foundation

/// Live Activity data, compiled into the app and the widget extension.
struct TripActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String               // same line VoiceOver reads on the rider screen
        var symbol: String               // SF Symbol: turn arrow, walker, bus
        var headline: String             // "Turn left", "Next stop: Hauptbahnhof"
        var distanceMeters: Int? = nil   // to the next turn / target
        var totalMeters: Int? = nil      // left on the current walk
        var progress: Double? = nil      // 0...1 of the current walk or ride
        var eta: Date? = nil             // arrival at the destination
        var time: Date? = nil            // bus departure while waiting
        var timeLabel: String? = nil     // "Departs"
    }
    var destination: String
}
