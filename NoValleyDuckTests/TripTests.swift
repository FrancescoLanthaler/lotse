import CoreGraphics
import Foundation
import Testing
@testable import NoValleyDuck

@Suite("Head gestures")
struct HeadGestureTests {
    /// Feeds `(pitch, yaw)` samples at 50 Hz, returns the first gesture.
    private func run(_ samples: [(Double, Double)]) -> HeadGesture? {
        var d = HeadGestureDetector()
        for (i, s) in samples.enumerated() {
            if let g = d.add(t: Double(i) * 0.02, pitch: s.0, yaw: s.1) { return g }
        }
        return nil
    }

    private func ramp(_ from: Double, _ to: Double, _ n: Int) -> [Double] {
        (0..<n).map { from + (to - from) * Double($0) / Double(n) }
    }

    @Test func nod() {
        let pitch = ramp(0, -0.35, 12) + ramp(-0.35, 0, 12)
        #expect(run(pitch.map { ($0, 0.01) }) == .nod)
    }

    @Test func shake() {
        let yaw = ramp(0, 0.3, 10) + ramp(0.3, -0.3, 15) + ramp(-0.3, 0.2, 12)
        #expect(run(yaw.map { (0.01, $0) }) == .shake)
    }

    @Test func turningTheHeadOnceIsNotAShake() {
        #expect(run(ramp(0, 1.2, 50).map { (0, $0) }) == nil)
    }

    @Test func lookingDownAndStayingIsNotANod() {
        #expect(run((ramp(0, -0.4, 15) + Array(repeating: -0.4, count: 40)).map { ($0, 0) }) == nil)
    }

    @Test func yawWrapAroundIsNotAShake() {
        #expect(run([3.1, 3.13, -3.13, -3.1, 3.12, -3.12].map { (0, $0) }) == nil)
    }
}

@Suite("Spoken answers")
@MainActor
struct PromptMatchTests {
    let notYet = PromptOption(id: "notYet", label: "Not yet", gesture: .shake, words: ["not yet", "no"])
    let didntStop = PromptOption(id: "didntStop", label: "It didn't stop", gesture: nil, words: ["didn't stop", "didn't"])

    @Test func yesNo() {
        #expect(Prompter.match("Yes please", [.yes, .no])?.id == "yes")
        #expect(Prompter.match("No.", [.yes, .no])?.id == "no")
        #expect(Prompter.match("maybe later", [.yes, .no]) == nil)
        #expect(Prompter.match("know", [.yes, .no]) == nil)        // whole words only
    }

    @Test func longerPhraseWins() {
        #expect(Prompter.match("It didn't stop", [notYet, didntStop])?.id == "didntStop")
        #expect(Prompter.match("not yet", [notYet, didntStop])?.id == "notYet")
    }
}

@Suite("Walking route geometry")
struct RouteGeometryTests {
    let origin = Coordinate(latitude: 47.8, longitude: 13.04)

    private func north(_ m: Double, east e: Double = 0) -> Coordinate {
        Coordinate(latitude: origin.latitude + m / 111_195,
                   longitude: origin.longitude + e / (111_195 * cos(origin.latitude * .pi / 180)))
    }

    private func leg(_ path: [Coordinate], turnAt: Coordinate? = nil) -> WalkingLeg {
        let steps = turnAt.map {
            [NavigationStep(index: 0, instruction: "Turn", notice: nil, distanceMeters: 0,
                            maneuverCoordinate: $0, endCoordinate: path.last!, path: [$0, path.last!])]
        } ?? []
        return WalkingLeg(from: Place(name: "A", coordinate: path[0]), to: Place(name: "B", coordinate: path.last!),
                          distanceMeters: 0, expectedTravelTimeSeconds: 60, steps: steps, path: path)
    }

    @Test func straightPathEvery25m() {
        let cps = RouteGeometry.checkpoints(for: leg([origin, north(100)]))
        #expect(cps.count == 4)                                   // 25, 50, 75, end
        #expect(cps.allSatisfy { $0.turn == nil })
        #expect(abs(cps[0].coordinate.distance(to: origin) - 25) < 0.5)
        #expect(cps.last!.coordinate == north(100))
    }

    @Test func turnGetsACheckpointWithDirection() {
        let corner = north(40)
        let cps = RouteGeometry.checkpoints(for: leg([origin, corner, north(40, east: 40)], turnAt: corner))
        let turn = cps.first { $0.turn != nil }
        #expect(turn?.turn == "right")                            // north, then east
        #expect(turn.map { $0.coordinate.distance(to: corner) < 1 } == true)
    }

    @Test func distanceToPath() {
        let d = RouteGeometry.distance(from: north(50, east: 30), toPath: [origin, north(100)])
        #expect(abs(d - 30) < 0.5)
    }

    @Test(arguments: [(90.0, "right"), (-90.0, "left"), (10.0, nil), (45.0, "slight right"), (160.0, "sharp right")])
    func turnDirection(deg: Double, expected: String?) {
        let a = deg * .pi / 180
        let after = north(10 * cos(a), east: 10 * sin(a))
        #expect(RouteGeometry.turnDirection(before: north(-10), at: origin, after: after) == expected)
    }
}

@Suite("Waiting spot")
struct WaitingSpotTests {
    /// Portrait phone: the tag's x axis (its right) lies along the sensor's y axis.
    let portrait = [0.0, -1, 0, 1, 0, 0, 0, 0, 1]

    @Test func spotStraightOutInFront() {
        var d = det(0, t: SIMD3(0, 0, 20))
        d.rotation = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        let m = marker(0, bay: "b1", size: 0.2)                   // 4 m away, spot 0.5 m out
        let g = WaitingSpot.guidance(WaitingSpot.spotInCamera(d, marker: m)!, lateralSign: -1)
        #expect(abs(g.distance - 3.5) < 1e-9)
        #expect(abs(g.bearingDeg) < 1e-9)
    }

    @Test func rightOffsetMovesTheSpotSideways() {
        var d = det(0, t: SIMD3(0, 0, 20))
        d.rotation = portrait
        var m = marker(0, bay: "b1", size: 0.2)
        m.spotRightM = 1
        let g = WaitingSpot.guidance(WaitingSpot.spotInCamera(d, marker: m)!, lateralSign: -1)
        #expect(abs(g.distance - hypot(1, 3.5)) < 1e-9)
        #expect(g.bearingDeg < -10)                               // tag's right = viewer's left when facing it
    }

    @Test func noPoseNoSpot() {
        #expect(WaitingSpot.spotInCamera(det(0, t: nil), marker: marker(0)) == nil)
    }

    @Test func averagesConfirmedMarkersOfTheBayOnly() {
        var a = det(0, t: SIMD3(0, 0, 20)); a.rotation = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        var b = det(1, t: SIMD3(0, 0, 20)); b.rotation = a.rotation
        var c = det(2, t: SIMD3(0, 5, 10)); c.rotation = a.rotation
        let ma = marker(0, bay: "b1"), mb = marker(1, bay: "b1"), mc = marker(2, bay: "other")
        func cd(_ d: TagDetection, _ m: Marker) -> ClassifiedDetection {
            ClassifiedDetection(detection: d, status: .candidate, marker: m, guidance: nil)
        }
        let frame = FrameResult(detections: [cd(a, ma), cd(b, mb), cd(c, mc)],
                                frame: FrameInfo(size: CGSize(width: 1920, height: 1080), fx: 1500, fy: 1500),
                                lockedTag: 0, lock: nil, confirmed: [0, 1, 2])
        let spot = WaitingSpot.estimate(frame, bayId: "b1")!
        #expect(abs(spot.z - 3.5) < 1e-9 && abs(spot.y) < 1e-9)

        let unconfirmed = FrameResult(detections: frame.detections, frame: frame.frame, lockedTag: nil,
                                      lock: nil, confirmed: [])
        #expect(WaitingSpot.estimate(unconfirmed, bayId: "b1") == nil)
    }
}

@Suite("Trip wording")
@MainActor
struct TripWordingTests {
    @Test func summary() {
        let a = Place(name: "Current location", coordinate: Coordinate(latitude: 47.80, longitude: 13.04))
        let s1 = Place(name: "Salzburg Mirabellplatz", coordinate: Coordinate(latitude: 47.805, longitude: 13.04))
        let s2 = Place(name: "Salzburg Hanuschplatz", coordinate: Coordinate(latitude: 47.80, longitude: 13.045))
        let dest = Place(name: "Getreidegasse", coordinate: Coordinate(latitude: 47.799, longitude: 13.044))
        let walk1 = WalkingLeg(from: a, to: s1, distanceMeters: 300, expectedTravelTimeSeconds: 240, steps: [], path: [])
        let walk2 = WalkingLeg(from: s2, to: dest, distanceMeters: 150, expectedTravelTimeSeconds: 120, steps: [], path: [])
        var bus = BusLeg(boardingStop: s1, alightingStop: s2, line: "2", direction: "Salzburg Obergnigl", source: .transitous)
        bus.intermediateStops = [StopCall(stop: s1, arrival: nil), StopCall(stop: s2, arrival: nil)]
        let plan = NavigationPlan(createdAt: .now, origin: a, destination: dest,
                                  legs: [.walk(leg: walk1), .bus(leg: bus), .walk(leg: walk2)])
        #expect(TripController.summary(plan)
                == "Walk 4 minutes to Mirabellplatz, bus 2 towards Obergnigl, 3 stops, then walk 2 minutes.")
    }

    @Test func sameDirection() {
        #expect(TripController.sameDirection("Salzburg Obergnigl", "Obergnigl"))
        #expect(!TripController.sameDirection("Salzburg Süd", "Obergnigl"))
        #expect(!TripController.sameDirection("Salzburg Süd", nil))
    }
}

@Suite("Place name matching")
@MainActor
struct PlaceMatchTests {
    @Test(arguments: [("Oilpark", "Europark"), ("Euro park", "Europark"), ("take me to Europark", "Europark"),
                      ("Ferdinand Hanusch Platz", "Ferdinand-Hanusch-Platz"), ("Mirabell Platz", "Mirabellplatz"),
                      ("Mozartplatz", "Mozartplatz"), ("Makartplatz", "Makartplatz"), ("gnigl", "Gnigl")])
    func matches(heard: String, place: String) {
        #expect(TripController.matchPlace([heard]) == place)
    }

    @Test(arguments: ["the mall", "Spar", "London Bridge", "Ikea"])
    func unknownStaysUnmatched(heard: String) {
        #expect(TripController.matchPlace([heard]) == nil)
    }

    @Test func laterAlternativeCanMatch() {
        #expect(TripController.matchPlace(["oil bark yes", "Euro Park"]) == "Europark")
    }
}
