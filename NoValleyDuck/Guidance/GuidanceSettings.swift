import SwiftUI

struct GuidanceSettings: View {
    @Bindable var beacon: MarkerBeacon
    @AppStorage("spokenCuesEnabled") private var spokenCuesEnabled = false
    @AppStorage("markerSizeCm") private var markerSizeCm = 16.3
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Audio") {
                    Toggle("Marker audio guidance", isOn: $beacon.enabled)
                    Toggle("Spoken cues", isOn: $spokenCuesEnabled)
                    if #available(iOS 18, *) {
                        Toggle("AirPods head tracking", isOn: $beacon.headTracking)
                    }
                }
                Section {
                    Stepper(value: $markerSizeCm, in: 1...100, step: 0.5) {
                        Text("Marker size: \(markerSizeCm, specifier: "%.1f") cm")
                    }
                } header: {
                    Text("Marker")
                } footer: {
                    Text("Measure the marker’s black square for a better distance estimate.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
