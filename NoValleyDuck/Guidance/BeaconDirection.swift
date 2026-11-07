import Foundation

/// Direction relative to the phone, in AVAudioEnvironmentNode coordinates.
struct BeaconDirection {
    let x: Float
    let z: Float

    static func beaconInterval(distance: Double) -> TimeInterval {
        min(2.0, max(0.65, 0.65 + distance * 0.3))
    }

    static func marker(cameraX: Double, cameraY: Double, cameraZ: Double) -> Self? {
        guard cameraX.isFinite, cameraY.isFinite, cameraZ.isFinite, cameraZ > 0 else { return nil }
        // The unrotated rear-camera image is landscape; in portrait its vertical axis points left.
        let horizontal = -cameraY
        let length = hypot(horizontal, cameraZ)
        guard length > 0 else { return nil }
        return Self(x: Float(horizontal / length), z: Float(-cameraZ / length))
    }
}
