import QuartzCore

/// Safety filter (spec rule number one: never speak a marker we aren't sure about).
/// A detection only counts if all four checks pass:
///  1. hamming == 0 (no corrected bits)
///  2. decision margin >= minMargin
///  3. the ID is valid here (current stop's markers or a bus-door marker)
///  4. the same ID was accepted in `needed` of the last `window` processed frames
/// Once locked, the lock holds while the marker keeps reappearing and is released after
/// `lostAfter` seconds without a sighting. Not thread-safe: use from the frame queue only.
final class MarkerTracker {
    private var history: [[Int]] = []
    private(set) var locked: Int?
    private var lastSeen: CFTimeInterval = 0
    var minMargin: Float = 40
    let window = 5, needed = 3, lostAfter: CFTimeInterval = 1.5

    func passesQuality(_ d: TagDetection) -> Bool { d.hamming == 0 && d.margin >= minMargin }

    /// Returns the locked detection if it is visible in this frame, else nil.
    /// `locked` stays set during short dropouts (< `lostAfter`).
    func update(_ dets: [TagDetection], validIds: Set<Int>, preferred: Int?,
                now: CFTimeInterval = CACurrentMediaTime()) -> TagDetection? {
        let good = dets.filter { passesQuality($0) && validIds.contains($0.id) }
        history.append(good.map(\.id))
        if history.count > window { history.removeFirst() }
        let confirmed = confirmedIds()

        // Switch to the preferred marker (e.g. the requested line's bus door) once it is
        // confirmed, even while locked on something else.
        if let p = preferred, locked != p, confirmed.contains(p), let d = good.first(where: { $0.id == p }) {
            locked = p; lastSeen = now
            return d
        }
        if let l = locked {
            if !validIds.contains(l) { locked = nil; return nil }      // stop changed under us
            if let d = good.first(where: { $0.id == l }) { lastSeen = now; return d }
            if now - lastSeen > lostAfter { locked = nil }
            return nil
        }
        // Nearest (largest in the image) of the confirmed candidates visible now.
        guard let d = good.filter({ confirmed.contains($0.id) }).max(by: { $0.sidePixels < $1.sidePixels })
        else { return nil }
        locked = d.id; lastSeen = now
        return d
    }

    func reset() { history.removeAll(); locked = nil }

    private func confirmedIds() -> Set<Int> {
        var counts: [Int: Int] = [:]
        // Count each ID at most once per frame.
        history.forEach { Set($0).forEach { counts[$0, default: 0] += 1 } }
        return Set(counts.filter { $0.value >= needed }.keys)
    }
}
