import SwiftUI
import CoreLocation

/// Developer screen for the marker pipeline. Not the rider UI.
struct DebugView: View {
    @Bindable var pipeline: MarkerPipeline
    @State private var log: [String] = []
    @State private var timetable: Timetable?
    @State private var departures: [Departure] = []

    var body: some View {
        ZStack {
            CameraPreview(session: pipeline.camera.session, frame: pipeline.lastFrame)
                .ignoresSafeArea()
            VStack(spacing: 8) {
                status
                Spacer()
                eventLog
                controls
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(.white)
        }
        .task { await pipeline.start() }
        .task(id: pipeline.stop?.stop.id) {
            timetable = nil
            if let stop = pipeline.stop?.stop { timetable = await pipeline.repository.timetable(for: stop) }
        }
        .task(id: "\(timetable?.stop ?? "")|\(pipeline.lock?.bay?.id ?? "")") {
            // Next departures: of the locked bay, else of the whole stop. Refresh every 30 s.
            while !Task.isCancelled {
                departures = timetable?.departures(after: .now, bay: pipeline.lock?.bay?.id, limit: 3) ?? []
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .task {
            for await e in pipeline.events() {
                log.insert("\(Date.now.formatted(date: .omitted, time: .standard))  \(describe(e))", at: 0)
                log = Array(log.prefix(5))
            }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = pipeline.cameraError { Text(error).foregroundStyle(.red) }
            Text(stopLine).font(.headline)
            Text(stateLine)
            if let l = pipeline.lock {
                Text("\(l.guidance.spoken)  (\(l.guidance.bearingDeg, specifier: "%+.0f")°)").font(.title3.bold())
            }
            ForEach(departures) { d in
                Text("\(d.time.formatted(date: .omitted, time: .shortened))  \(d.spoken())").font(.caption)
            }
            if pipeline.reducedRange { Text("Reduced range (hot)").foregroundStyle(.orange) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }

    private var eventLog: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(log, id: \.self) { Text($0).font(.caption.monospaced()) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(log.isEmpty ? 0 : 8)
        .background(.black.opacity(log.isEmpty ? 0 : 0.6), in: RoundedRectangle(cornerRadius: 12))
    }

    private var controls: some View {
        VStack(spacing: 6) {
            Toggle("Demo stop: \(DemoBundle.shared?.stop.name ?? "–")", isOn: Binding(
                get: { pipeline.location.demoOverride },
                set: { pipeline.location.setDemoOverride($0) }))
            Toggle("Flip left/right", isOn: $pipeline.lateralFlipped)
            Stepper("Min margin: \(Int(pipeline.minMargin))", value: $pipeline.minMargin, in: 0...200, step: 5)
            HStack {
                Toggle(pipeline.recordingURL == nil ? "Record hall test (CSV)"
                           : "Recording… locks: \(pipeline.recordedLocks)",
                       isOn: Binding(get: { pipeline.recordingURL != nil },
                                     set: { pipeline.setRecording($0) }))
                if pipeline.recordingURL == nil, let last = pipeline.recordings.first {
                    ShareLink(item: last) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share last hall test CSV")
                }
            }
        }
        .padding(10)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }

    private var stopLine: String {
        guard let ctx = pipeline.stop else {
            return pipeline.location.authorization == .denied ? "No stop: location denied" : "No stop nearby"
        }
        let src = pipeline.location.source == .demo ? "demo" : pipeline.location.source == .trip ? "trip" :
            pipeline.location.distanceToStop.map { "GPS \(Int($0)) m" } ?? "GPS"
        let tags = ctx.markers.keys.sorted().map(String.init).joined(separator: ",")
        return "\(ctx.stop.name) (\(src)) · IDs \(tags.isEmpty ? "none" : tags)"
    }

    private var stateLine: String {
        switch pipeline.state {
        case .noStop: "State: no stop"
        case .searching: "State: searching"
        case .approaching(let t): "State: approaching \(label(t))"
        case .arrived(let t): "State: arrived at \(label(t))"
        case .boarding(let t): "State: boarding \(label(t))"
        }
    }

    private func label(_ tag: Int) -> String {
        guard let l = pipeline.lock, l.marker.tagId == tag else { return "ID \(tag)" }
        if let bay = l.bay { return "bay \(bay.label) (ID \(tag))" }
        return "line \(l.marker.vehicleLine) door (ID \(tag))"
    }

    private func describe(_ e: MarkerEvent) -> String {
        switch e {
        case .stopChanged(let s): "stop → \(s?.name ?? "none")"
        case .found(let l): "found ID \(l.marker.tagId): \(l.guidance.spoken)"
        case .arrived(let l): "arrived ID \(l.marker.tagId)"
        case .lost(let m): "lost ID \(m.tagId)"
        case .reducedRange(let on): "reduced range \(on ? "on" : "off")"
        }
    }
}
