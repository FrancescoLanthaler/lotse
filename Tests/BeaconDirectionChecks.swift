import Foundation

@main
struct BeaconDirectionChecks {
    static func main() {
        let straight = BeaconDirection.marker(cameraX: 0, cameraY: 0, cameraZ: 2)!
        assert(abs(straight.x) < 0.001 && abs(straight.z + 1) < 0.001)
        let right = BeaconDirection.marker(cameraX: 0, cameraY: -1, cameraZ: 1)!
        assert(right.x > 0 && right.z < 0)
        let left = BeaconDirection.marker(cameraX: 0, cameraY: 1, cameraZ: 1)!
        assert(left.x < 0 && left.z < 0)
        assert(BeaconDirection.marker(cameraX: .nan, cameraY: 0, cameraZ: 1) == nil)
        assert(BeaconDirection.marker(cameraX: 0, cameraY: 0, cameraZ: 0) == nil)
        assert(BeaconDirection.beaconInterval(distance: 1) < BeaconDirection.beaconInterval(distance: 4))
        assert(BeaconDirection.beaconInterval(distance: 0) >= 0.6)
        assert(BeaconDirection.beaconInterval(distance: 100) <= 2.0)
    }
}
