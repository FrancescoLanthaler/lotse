import SwiftUI
import UIKit

/// Debug sheet: nod or shake with AirPods in and see what the detector reports. Also speaks the result,
/// so it works eyes-free.
struct HeadGestureTestView: View {
    let trip: TripController
    @Environment(\.dismiss) private var dismiss
    @State private var last: HeadGesture?
    @State private var count = 0
    @State private var previous: ((HeadGesture) -> Void)?

    var body: some View {
        VStack(spacing: 20) {
            Text("Head gesture test").font(.title2.bold())
            Text("Wear your AirPods. Nod for yes, shake your head for no.")
                .multilineTextAlignment(.center)
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let head = trip.head
                VStack(spacing: 6) {
                    Text(head.isConnected ? "AirPods connected" : "AirPods not connected").font(.headline)
                    Text("Pitch \(head.pitchDeg.map { String(format: "%.0f°", $0) } ?? "–")  Yaw \(head.yawDeg.map { String(format: "%.0f°", $0) } ?? "–")")
                        .monospacedDigit()
                }
            }
            Text(last.map { ($0 == .nod ? "Nod" : "Shake") + " detected (\(count))" } ?? "Waiting for a gesture")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.updatesFrequently)
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
        }
        .padding()
        .onAppear {
            trip.head.start()
            previous = trip.head.onGesture
            trip.head.onGesture = { g in
                previous?(g)
                last = g
                count += 1
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                UIAccessibility.post(notification: .announcement, argument: g == .nod ? "Nod" : "Shake")
            }
        }
        .onDisappear {
            trip.head.onGesture = previous
            if !trip.isRouteActive { trip.head.stop() }
        }
    }
}
