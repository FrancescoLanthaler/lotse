import Foundation

/// A point the walking beacon sits on. `turn` is set at the walking route's turns.
struct Checkpoint: Equatable {
    let coordinate: Coordinate
    let turn: String?          // "left", "slight right", "sharp left", …
}

/// Pure geometry for the walking legs (SPEC Phase 2). Distances are small (< a few km), so a
/// local flat projection is accurate enough.
enum RouteGeometry {
    static let spacing = 25.0             // SPEC: checkpoints at turns and roughly every 20–30 m

    /// Checkpoints at the turns of `leg` and every `spacing` metres, always ending at the leg's target.
    static func checkpoints(for leg: WalkingLeg, spacing: Double = spacing) -> [Checkpoint] {
        let path = leg.path.count >= 2 ? leg.path : [leg.from.coordinate, leg.to.coordinate]
        let cum = cumulative(path)
        let total = cum.last ?? 0
        guard total > 1 else { return [Checkpoint(coordinate: leg.to.coordinate, turn: nil)] }

        // Turns: MapKit steps start at their manoeuvre.
        var turns: [(s: Double, turn: String)] = []
        for step in leg.steps {
            let s = along(step.maneuverCoordinate, path: path, cum: cum)
            guard s > 5, s < total - 5,
                  let turn = turnDirection(before: point(at: s - 10, path: path, cum: cum),
                                           at: point(at: s, path: path, cum: cum),
                                           after: point(at: s + 10, path: path, cum: cum))
            else { continue }
            turns.append((s, turn))
        }

        var stations = turns.map { (s: $0.s, turn: Optional($0.turn)) }
        var s = spacing
        while s < total - spacing / 2 {
            if !turns.contains(where: { abs($0.s - s) < 8 }) { stations.append((s, nil)) }
            s += spacing
        }
        stations.sort { $0.s < $1.s }
        return stations.map { Checkpoint(coordinate: point(at: $0.s, path: path, cum: cum), turn: $0.turn) }
            // The real target (stop, bay or destination), not the end of MapKit's road-snapped line.
            + [Checkpoint(coordinate: leg.to.coordinate, turn: nil)]
    }

    /// "left" / "right" with "slight" or "sharp", nil when the path goes on roughly straight.
    static func turnDirection(before: Coordinate, at: Coordinate, after: Coordinate) -> String? {
        var delta = at.bearing(to: after) - before.bearing(to: at)
        delta = (delta + 540).truncatingRemainder(dividingBy: 360) - 180   // + = right
        let side = delta > 0 ? "right" : "left"
        switch abs(delta) {
        case ..<30: return nil
        case ..<55: return "slight \(side)"
        case ..<130: return side
        default: return "sharp \(side)"
        }
    }

    /// Shortest distance in metres from `p` to the polyline.
    static func distance(from p: Coordinate, toPath path: [Coordinate]) -> Double {
        guard path.count >= 2 else { return path.first.map { p.distance(to: $0) } ?? .infinity }
        let o = p
        func xy(_ c: Coordinate) -> SIMD2<Double> {
            SIMD2((c.longitude - o.longitude) * 111_320 * cos(o.latitude * .pi / 180),
                  (c.latitude - o.latitude) * 110_540)
        }
        var best = Double.infinity
        for (a, b) in zip(path, path.dropFirst()) {
            let pa = xy(a), pb = xy(b), ab = pb - pa
            let len2 = (ab * ab).sum()
            let t = len2 > 0 ? max(0, min(1, (-pa * ab).sum() / len2)) : 0
            let q = pa + t * ab
            best = min(best, (q * q).sum().squareRoot())
        }
        return best
    }

    /// The checkpoint the beacon should aim at, judged by where `p` projects onto the checkpoint
    /// line: more than 3 m past checkpoint k means k is behind, even if the fix never came within
    /// 10 m of it. Looks only a few checkpoints ahead (a route can loop back near itself) and
    /// only when `p` is within 25 m of the line.
    static func nextIndex(after p: Coordinate, checkpoints: [Checkpoint], from index: Int) -> Int {
        guard index < checkpoints.count - 1 else { return index }
        func xy(_ c: Coordinate) -> SIMD2<Double> {
            SIMD2((c.longitude - p.longitude) * 111_320 * cos(p.latitude * .pi / 180),
                  (c.latitude - p.latitude) * 110_540)
        }
        var best = (d: Double.infinity, next: index)
        for k in index..<min(index + 4, checkpoints.count - 1) {
            let a = xy(checkpoints[k].coordinate), ab = xy(checkpoints[k + 1].coordinate) - a
            let len = (ab * ab).sum().squareRoot()
            guard len > 0 else { continue }
            let along = (-a * ab).sum() / len             // p's position along k→k+1, from k
            let q = a + ab * (max(0, min(len, along)) / len)
            let d = (q * q).sum().squareRoot()
            if d < best.d { best = (d, along > 3 ? k + 1 : k) }
        }
        return best.d <= 25 ? max(index, best.next) : index
    }

    /// Path length from checkpoint `index` to the end, plus the straight line to it from `p`.
    static func remaining(from p: Coordinate, checkpoints: [Checkpoint], index: Int) -> Double {
        guard index < checkpoints.count else { return 0 }
        var d = p.distance(to: checkpoints[index].coordinate)
        for i in index..<(checkpoints.count - 1) {
            d += checkpoints[i].coordinate.distance(to: checkpoints[i + 1].coordinate)
        }
        return d
    }

    // MARK: - Polyline helpers

    private static func cumulative(_ path: [Coordinate]) -> [Double] {
        var cum = [0.0]
        for (a, b) in zip(path, path.dropFirst()) { cum.append(cum.last! + a.distance(to: b)) }
        return cum
    }

    /// Distance along the path of the vertex nearest to `c`.
    private static func along(_ c: Coordinate, path: [Coordinate], cum: [Double]) -> Double {
        let i = path.indices.min { path[$0].distance(to: c) < path[$1].distance(to: c) } ?? 0
        return cum[i]
    }

    private static func point(at s: Double, path: [Coordinate], cum: [Double]) -> Coordinate {
        let s = max(0, min(cum.last!, s))
        guard let i = cum.lastIndex(where: { $0 <= s }), i < path.count - 1 else { return path.last! }
        let seg = cum[i + 1] - cum[i]
        let t = seg > 0 ? (s - cum[i]) / seg : 0
        return Coordinate(latitude: path[i].latitude + t * (path[i + 1].latitude - path[i].latitude),
                          longitude: path[i].longitude + t * (path[i + 1].longitude - path[i].longitude))
    }
}
