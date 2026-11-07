import AVFoundation
import SwiftUI
import UIKit

/// Debug view: live camera feed with an outline and label on every detection, coloured by the
/// safety filter: green = locked, yellow = candidate, orange = weak (bits corrected / low
/// margin), red = ID not valid at this stop.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let frame: FrameResult?

    func makeUIView(context: Context) -> PreviewView { PreviewView(session: session) }

    func updateUIView(_ view: PreviewView, context: Context) { view.show(frame) }
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

    func show(_ result: FrameResult?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        marks.forEach { $0.removeFromSuperlayer() }
        marks.removeAll()
        guard let result, result.frame.size.width > 0 else { return }
        let size = result.frame.size

        // Frame pixels are in the sensor's landscape orientation, which is exactly the
        // capture-device coordinate space; the preview layer handles rotation and cropping.
        func map(_ p: CGPoint) -> CGPoint {
            previewLayer.layerPointConverted(fromCaptureDevicePoint:
                CGPoint(x: p.x / size.width, y: p.y / size.height))
        }

        for c in result.detections {
            let d = c.detection
            let color: UIColor = switch c.status {
            case .locked: .systemGreen
            case .candidate: .systemYellow
            case .weak: .systemOrange
            case .notHere: .systemRed
            }
            let pts = d.corners.map(map)
            let path = UIBezierPath()
            path.move(to: pts[0])
            pts.dropFirst().forEach { path.addLine(to: $0) }
            path.close()
            let outline = CAShapeLayer()
            outline.path = path.cgPath
            outline.strokeColor = color.cgColor
            outline.fillColor = nil
            outline.lineWidth = 4

            var text = "ID \(d.id)"
            if let m = c.marker { text += m.kind == .vehicle ? " door \(m.vehicleLine)" : "" }
            if let g = c.guidance { text += String(format: " · %.1f m · %d h", g.distance, g.clockHour) }
            text += " · m\(Int(d.margin))" + (d.hamming > 0 ? " h\(d.hamming)" : "")

            let label = CATextLayer()
            label.string = text
            label.fontSize = 15
            label.alignmentMode = .center
            label.foregroundColor = (c.status == .candidate ? UIColor.black : .white).cgColor
            label.backgroundColor = color.cgColor
            label.cornerRadius = 6
            label.contentsScale = traitCollection.displayScale
            let center = map(d.center)
            label.frame = CGRect(x: center.x - 120, y: center.y - 12, width: 240, height: 24)

            layer.addSublayer(outline)
            layer.addSublayer(label)
            marks += [outline, label]
        }
    }
}
