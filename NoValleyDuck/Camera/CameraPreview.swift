import AVFoundation
import SwiftUI
import UIKit

/// Debug view: live camera feed with an outline, ID and decision margin drawn on every detection.
/// Green = would pass the speech filter (hamming 0, margin >= minMargin), orange = rejected.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let detections: [TagDetection]
    let frameSize: CGSize
    let markerSize: Double          // outer black square edge in metres
    var minMargin: Float = 40

    func makeUIView(context: Context) -> PreviewView { PreviewView(session: session) }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.show(detections, frameSize: frameSize, markerSize: markerSize, minMargin: minMargin)
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    private var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    private var marks: [CALayer] = []

    init(session: AVCaptureSession) {
        super.init(frame: .zero)
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ dets: [TagDetection], frameSize: CGSize, markerSize: Double, minMargin: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        marks.forEach { $0.removeFromSuperlayer() }
        marks.removeAll()
        guard frameSize.width > 0, frameSize.height > 0 else { return }

        // Frame pixels are in the sensor's landscape orientation, which is exactly the
        // capture-device coordinate space; the preview layer handles rotation and cropping.
        func map(_ p: CGPoint) -> CGPoint {
            previewLayer.layerPointConverted(fromCaptureDevicePoint:
                CGPoint(x: p.x / frameSize.width, y: p.y / frameSize.height))
        }

        for d in dets {
            let accepted = d.hamming == 0 && d.margin >= minMargin
            let color = (accepted ? UIColor.systemGreen : UIColor.systemOrange).cgColor
            let pts = d.corners.map(map)

            let path = UIBezierPath()
            path.move(to: pts[0])
            pts.dropFirst().forEach { path.addLine(to: $0) }
            path.close()
            let outline = CAShapeLayer()
            outline.path = path.cgPath
            outline.strokeColor = color
            outline.fillColor = nil
            outline.lineWidth = 4

            let label = CATextLayer()
            let distance = d.distance(markerSize: markerSize).map { String(format: "%.2f m", $0) } ?? "– m"
            label.string = "ID \(d.id) · \(distance) · m\(Int(d.margin))" + (d.hamming > 0 ? " h\(d.hamming)" : "")
            label.fontSize = 17
            label.alignmentMode = .center
            label.foregroundColor = UIColor.white.cgColor
            label.backgroundColor = color
            label.cornerRadius = 6
            label.contentsScale = traitCollection.displayScale
            let c = map(d.center)
            label.frame = CGRect(x: c.x - 95, y: c.y - 13, width: 190, height: 26)

            layer.addSublayer(outline)
            layer.addSublayer(label)
            marks += [outline, label]
        }
    }
}
