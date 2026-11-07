import CoreGraphics
import CoreLocation
@testable import NoValleyDuck

/// A square detection of `side` pixels centred at (cx, cy). `t` is the unit-size translation.
func det(_ id: Int, hamming: Int = 0, margin: Float = 100, side: Double = 100,
         cx: Double = 960, cy: Double = 540, t: SIMD3<Double>? = SIMD3(0, 0, 10)) -> TagDetection {
    let h = side / 2
    return TagDetection(
        id: id, hamming: hamming, margin: margin, center: CGPoint(x: cx, y: cy),
        corners: [CGPoint(x: cx - h, y: cy - h), CGPoint(x: cx + h, y: cy - h),
                  CGPoint(x: cx + h, y: cy + h), CGPoint(x: cx - h, y: cy + h)],
        unitTranslation: t, poseError: t == nil ? nil : 1e-6)
}

func marker(_ tag: Int, kind: Marker.Kind = .bay, bay: String = "", line: String = "",
            size: Double = 0.2, stop: String = "s1") -> Marker {
    Marker(id: "m\(tag)", stop: kind == .vehicle ? "" : stop, tagId: tag, kind: kind, bay: bay,
           vehicleLine: line, sizeM: size)
}

func stop(_ id: String, lat: Double, lon: Double) -> Stop { Stop(id: id, name: id, lat: lat, lon: lon) }

/// A location `metres` north of (lat, lon).
func location(north metres: Double, of lat: Double, _ lon: Double) -> CLLocation {
    CLLocation(latitude: lat + metres / 111_195, longitude: lon)
}
