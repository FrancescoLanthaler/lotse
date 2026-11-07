import AVFoundation
import QuartzCore
import simd

/// Per-frame camera geometry needed for distance/bearing maths.
struct FrameInfo: Sendable, Equatable {
    let size: CGSize      // luma plane, sensor (landscape) orientation
    let fx, fy: Double    // focal length in pixels
}

/// Back camera at 1080p, YUV. The luma plane goes straight into AprilTag.
/// Frames are throttled to `minInterval` and processed on one serial queue (`frameQueue`).
/// `detector`, `minInterval` and anything run via `onFrameQueue` are confined to that queue.
final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let frameQueue = DispatchQueue(label: "camera.frames")
    let detector = TagDetector()
    private var lastProcessed: CFTimeInterval = 0
    var minInterval: CFTimeInterval = 0.1                 // 10 fps; raise when the phone gets hot
    var onFrame: (@Sendable ([TagDetection], FrameInfo) -> Void)?   // called on frameQueue
    private var fallbackFx = 0.0

    func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        else { throw NSError(domain: "camera", code: 1, userInfo: [NSLocalizedDescriptionKey: "No back camera"]) }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw NSError(domain: "camera", code: 2) }
        session.addInput(input)
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddOutput(output) else { throw NSError(domain: "camera", code: 3) }
        session.addOutput(output)
        if let conn = output.connection(with: .video), conn.isCameraIntrinsicMatrixDeliverySupported {
            conn.isCameraIntrinsicMatrixDeliveryEnabled = true
        }
        // Fallback focal length from the horizontal field of view (degrees), for 1920 px wide frames
        let hfov = Double(device.activeFormat.videoFieldOfView) * .pi / 180
        fallbackFx = 1920 / (2 * tan(hfov / 2))

        try device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        device.unlockForConfiguration()
    }

    func start() { sessionQueue.async { self.session.startRunning() } }
    func stop()  { sessionQueue.async { self.session.stopRunning() } }

    /// Run work on the frame queue, serialised with detection.
    func onFrameQueue(_ work: @escaping @Sendable () -> Void) { frameQueue.async(execute: work) }

    /// Heat protection (spec): 5 fps and half-resolution quad detection, or back to normal.
    func setThrottled(_ throttled: Bool) {
        frameQueue.async {
            self.minInterval = throttled ? 0.2 : 0.1
            self.detector.setDecimate(throttled ? 2.0 : 1.0)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastProcessed >= minInterval,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastProcessed = now

        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        var fx = fallbackFx, fy = fallbackFx, cx = Double(w) / 2, cy = Double(h) / 2
        if let data = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                      attachmentModeOut: nil) as? Data {
            let m = data.withUnsafeBytes { $0.load(as: matrix_float3x3.self) }
            fx = Double(m.columns.0.x); fy = Double(m.columns.1.y)
            cx = Double(m.columns.2.x); cy = Double(m.columns.2.y)
        }

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return }
        let dets = detector.detect(gray: base.assumingMemoryBound(to: UInt8.self),
                                   width: w, height: h,
                                   rowStride: CVPixelBufferGetBytesPerRowOfPlane(pb, 0),
                                   fx: fx, fy: fy, cx: cx, cy: cy)
        onFrame?(dets, FrameInfo(size: CGSize(width: w, height: h), fx: fx, fy: fy))
    }
}
