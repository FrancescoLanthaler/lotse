import SwiftUI

/// Temporary test screen: type a destination, get the NavigationPlan as readable text + JSON.
struct NavigationDebugView: View {
    @State private var service = NavigationService()
    @State private var query = "Mirabellplatz"
    @State private var output = "Enter a destination and tap Plan."
    @State private var busy = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack {
                    TextField("Destination", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.go)
                        .onSubmit(run)
                    Button("Plan", action: run)
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || query.isEmpty)
                }
                Toggle("Bus lines from Transitous (off = MapKit only)", isOn: $service.useTransitous)
                    .font(.footnote)
                if busy { ProgressView("Planning…") }
                ScrollView {
                    Text(output)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                // Required attribution for Transitous data.
                Link("Transit data: Transitous & sources", destination: TransitousClient.attributionURL)
                    .font(.caption)
            }
            .padding()
            .navigationTitle("Route test")
        }
    }

    private func run() {
        busy = true
        Task {
            output = await NavigationDebug.describe(query, using: service)
            busy = false
        }
    }
}

@MainActor
enum NavigationDebug {
    /// Runs the planner and returns a human-readable summary followed by the full JSON.
    static func describe(_ query: String, using service: NavigationService) async -> String {
        do {
            let plan = try await service.plan(to: query)
            return summary(plan) + "\n\n--- JSON ---\n" + ((try? plan.json()) ?? "")
        } catch {
            return "ERROR: \(error.localizedDescription)"
        }
    }

    static func summary(_ plan: NavigationPlan) -> String {
        var lines = ["From: \(fmt(plan.origin))  [iPhone location]",
                     "To:   \(fmt(plan.destination))  [appleMaps search]", ""]
        for (i, leg) in plan.legs.enumerated() {
            switch leg {
            case .walk(let w):
                lines.append("\(i + 1). WALK \(Int(w.distanceMeters)) m, ~\(Int(w.expectedTravelTimeSeconds / 60)) min → \(w.to.name)  [appleMaps]")
                for s in w.steps { lines.append("     • \(s.instruction) (\(Int(s.distanceMeters)) m)") }
            case .bus(let b):
                lines.append("\(i + 1). BUS \(b.line ?? "?") → \(b.direction ?? "?")  [\(b.source.rawValue)]")
                lines.append("     🔊 \(b.announcement)")
                if let e = b.estimate {
                    lines.append("     ~\(Int(e.travelTimeSeconds / 60)) min, departs \(e.expectedDeparture.formatted(date: .omitted, time: .shortened)), arrives \(e.expectedArrival.formatted(date: .omitted, time: .shortened))\(b.isRealtime ? " (live)" : " (timetable)")")
                } else {
                    lines.append("     (no transit times available)")
                }
                if b.source == .transitous {
                    let wc = b.wheelchairAccessible.map { $0 ? "yes" : "NO" } ?? "unknown"
                    lines.append("     stops: \(b.stopsToRide), wheelchair accessible: \(wc), operator: \(b.operatorName ?? "?")")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func fmt(_ p: Place) -> String {
        String(format: "%@ (%.5f, %.5f)", p.name, p.coordinate.latitude, p.coordinate.longitude)
    }
}
