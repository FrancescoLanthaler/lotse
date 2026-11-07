import SwiftUI

@main
struct NoValleyDuckApp: App {
    @State private var scanner = Scanner()
    /// Outer black square edge of the printed marker. A tag25h9 image filling an A4 width ≈ 16.3 cm,
    /// A3 ≈ 23 cm. Measure with a ruler: distance is only as accurate as this number.
    @AppStorage("markerSizeCm") private var markerSizeCm = 16.3

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .top) {
                CameraPreview(session: scanner.camera.session,
                              detections: scanner.detections,
                              frameSize: scanner.frameSize,
                              markerSize: markerSizeCm / 100)
                    .ignoresSafeArea()
                Text("\(scanner.status) · \(scanner.detections.count) tag(s)")
                    .font(.headline)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.top, 8)
            }
            .modifier(MarkerGuidance(scanner: scanner))
            .task { await scanner.start() }
        }
    }
}
