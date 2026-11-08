import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct NoValleyDuckWidgets: WidgetBundle {
    var body: some Widget { TripLiveActivity() }
}

struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            let state = context.state
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    Image(systemName: state.symbol)
                        .font(.system(size: 34, weight: .bold))
                        .frame(width: 60, height: 60)
                        .background(.green, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        if let m = state.distanceMeters { Text(distance(m)).font(.system(size: 32, weight: .bold)) }
                        else if let t = state.time { Text(t, style: .time).font(.system(size: 32, weight: .bold)) }
                        Text(state.headline).font(.headline).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                if let p = state.progress { ProgressView(value: p).tint(.green) }
                HStack {
                    Text("To \(context.attributes.destination)").lineLimit(1)
                    Spacer()
                    if let eta = state.eta { Text("Arrive \(eta.formatted(date: .omitted, time: .shortened))") }
                    if let t = state.totalMeters { Text("· \(distance(t))") }
                }
                .font(.subheadline).foregroundStyle(.secondary)
                Button(intent: StopTripLiveActivityIntent()) {
                    Label("Stop guiding", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .tint(.red)
            }
            .padding()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label(context))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: state.symbol).font(.title).foregroundStyle(.green)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let m = state.distanceMeters { Text(distance(m)).font(.title2.bold()) }
                    else if let t = state.time { Text(t, style: .time).font(.title2.bold()) }
                }
                DynamicIslandExpandedRegion(.center) { Text(state.headline).font(.headline).lineLimit(1) }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading) {
                        if let p = state.progress { ProgressView(value: p).tint(.green) }
                        HStack {
                            Text("To \(context.attributes.destination)").lineLimit(1)
                            Spacer()
                            if let eta = state.eta { Text("Arrive \(eta.formatted(date: .omitted, time: .shortened))") }
                        }.font(.caption)
                        Button(intent: StopTripLiveActivityIntent()) {
                            Label("Stop guiding", systemImage: "stop.fill").frame(maxWidth: .infinity)
                        }
                        .tint(.red)
                    }
                }
            } compactLeading: {
                Image(systemName: state.symbol).foregroundStyle(.green)
            } compactTrailing: {
                if let m = state.distanceMeters { Text(distance(m)) }
                else if let t = state.time { Text(t, style: .time).frame(maxWidth: 56) }
            } minimal: {
                Image(systemName: state.symbol).foregroundStyle(.green)
            }
        }
    }

    private func distance(_ m: Int) -> String {
        m >= 1000 ? String(format: "%.1f km", Double(m) / 1000) : "\(m) m"
    }

    private func label(_ context: ActivityViewContext<TripActivityAttributes>) -> String {
        let s = context.state
        var parts = [s.headline]
        if let m = s.distanceMeters { parts.append("in \(m) metres") }
        if let t = s.time { parts.append("\(s.timeLabel ?? "") \(t.formatted(date: .omitted, time: .shortened))") }
        parts.append(s.status)
        parts.append("To \(context.attributes.destination)")
        if let eta = s.eta { parts.append("Arrive \(eta.formatted(date: .omitted, time: .shortened))") }
        return parts.joined(separator: ". ")
    }
}
