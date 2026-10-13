import Foundation
import Testing
@testable import Timeline

/// Semi-implicit Euler at a fine step, the independent reference for the closed form.
enum ReferenceSpring {
    static func integrate(
        initial: Double, changes: [TargetChange<Double>], until end: Double, dt: Double = 1e-5
    ) -> [(time: Double, position: Double, velocity: Double)] {
        var x = initial
        var v = 0.0
        var t = 0.0
        var index = 0
        var target = initial
        var spring = changes.first?.spring ?? .camera
        var out: [(Double, Double, Double)] = []
        while t <= end {
            while index < changes.count, changes[index].time <= t + dt / 2 {
                target = changes[index].target
                spring = changes[index].spring
                index += 1
            }
            out.append((t, x, v))
            v += (-(x - target) * spring.stiffness - v * spring.damping) / spring.mass * dt
            x += v * dt
            t += dt
        }
        return out
    }
}

struct SpringSpec {
    static let critical = Spring(stiffness: 100, damping: 20, mass: 1)
    static let overdamped = Spring(stiffness: 100, damping: 40, mass: 1)

    @Test(arguments: [Spring.camera, .cursorSmooth, .cursorMedium, .cursorRapid, critical, overdamped])
    func closedFormMatchesFineIntegration(spring: Spring) {
        let changes = [TargetChange(time: 0, target: 100.0, spring: spring)]
        let track = SpringTrack(initial: 0, changes: changes, rescaleShortIntervals: false)
        let reference = ReferenceSpring.integrate(initial: 0, changes: changes, until: 3)
        var worstPosition = 0.0
        var worstVelocity = 0.0
        for sample in reference where Int((sample.time * 1e5).rounded()) % 1000 == 0 {
            let (p, v) = track.evaluate(at: sample.time)
            worstPosition = max(worstPosition, abs(p - sample.position))
            worstVelocity = max(worstVelocity, abs(v - sample.velocity))
        }
        #expect(worstPosition < 0.01, "position error \(worstPosition) px")
        #expect(worstVelocity < 0.5, "velocity error \(worstVelocity) px/s")
        let (settled, _) = track.evaluate(at: 10)
        #expect(abs(settled - 100) < 1e-6)
    }

    @Test func regimesAreClassifiedFromTheDampingRatio() {
        #expect(SpringResponse(.camera).regime.name == "underdamped")
        #expect(SpringResponse(Self.critical).regime.name == "critical")
        #expect(SpringResponse(Self.overdamped).regime.name == "overdamped")
        #expect(SpringResponse(Spring(stiffness: 100, damping: 20 * (1 + 5e-7), mass: 1)).regime.name == "critical")
        #expect(SpringResponse(Spring(stiffness: 100, damping: 20 * (1 + 5e-5), mass: 1)).regime.name == "overdamped")
    }

    @Test func chainOfTargetChangesMatchesFineIntegration() {
        let changes = [
            TargetChange(time: 0, target: 100.0, spring: .camera),
            TargetChange(time: 0.3, target: -40.0, spring: Self.overdamped),
            TargetChange(time: 0.45, target: 250.0, spring: .cursorRapid),
            TargetChange(time: 1.2, target: 0.0, spring: Self.critical),
            TargetChange(time: 2.0, target: 60.0, spring: .cursorMedium),
        ]
        let track = SpringTrack(initial: 0, changes: changes, rescaleShortIntervals: false)
        #expect(track.knots.count == 5)
        let reference = ReferenceSpring.integrate(initial: 0, changes: changes, until: 3)
        var worst = 0.0
        for sample in reference where Int((sample.time * 1e5).rounded()) % 500 == 0 {
            worst = max(worst, abs(track.evaluate(at: sample.time).position - sample.position))
        }
        #expect(worst < 0.02, "position error \(worst) px across five target changes")
    }

    @Test func positionAndVelocityAreContinuousAcrossKnots() {
        let changes = (1...20).map { TargetChange(time: Double($0) * 0.137, target: Double($0 % 3) * 100, spring: .camera) }
        let track = SpringTrack(initial: 0, changes: changes, rescaleShortIntervals: true)
        for knot in track.knots.dropFirst() {
            let before = track.evaluate(at: knot.time - 1e-9)
            let at = track.evaluate(at: knot.time)
            #expect(abs(before.position - at.position) < 1e-4)
            #expect(abs(before.velocity - at.velocity) < 1e-2)
        }
    }

    @Test func shortIntervalRescaleArrivesBeforeTheNextChange() {
        let changes = [
            TargetChange(time: 0, target: 100.0, spring: .camera),
            TargetChange(time: 0.2, target: 0.0, spring: .camera),
        ]
        let rescaled = SpringTrack(initial: 0, changes: changes, rescaleShortIntervals: true)
        let plain = SpringTrack(initial: 0, changes: changes, rescaleShortIntervals: false)
        #expect(abs(rescaled.evaluate(at: 0.2 - 1e-6).position - 100) < 1)
        #expect(abs(plain.evaluate(at: 0.2 - 1e-6).position - 100) > 10)
        #expect(rescaled.knots[0].response == SpringResponse(Spring.camera.rescaled(toSettleWithin: 0.2)))
        #expect(rescaled.knots[0].response != plain.knots[0].response)
        #expect(rescaled.knots[1].response == plain.knots[1].response, "the last interval is open-ended and not rescaled")
    }

    @Test func rescalePreservesTheDampingRatio() {
        let scaled = Spring.camera.rescaled(toSettleWithin: 0.1)
        #expect(abs(scaled.dampingRatio - Spring.camera.dampingRatio) < 1e-12)
        #expect(abs(scaled.settleTime() - 0.1) < 1e-9)
        #expect(Spring.camera.rescaled(toSettleWithin: 100) == .camera)
    }

    @Test func changesAtTheSameTimeCollapseToTheLast() {
        let changes = [
            TargetChange(time: 0.5, target: 10.0, spring: .camera),
            TargetChange(time: 0.5, target: 20.0, spring: .camera),
            TargetChange(time: 0.5, target: 30.0, spring: .camera),
        ]
        let track = SpringTrack(initial: 0, changes: changes, rescaleShortIntervals: true)
        #expect(track.knots.map(\.time) == [0, 0.5])
        #expect(track.knots[1].target == 30)
        #expect(track.evaluate(at: 5).position.isApproximately(30))
    }

    @Test func aChangeAtTimeZeroReplacesTheRestKnot() {
        let track = SpringTrack(initial: 0, changes: [TargetChange(time: 0, target: 50.0, spring: .camera)], rescaleShortIntervals: false)
        #expect(track.knots.count == 1)
        #expect(track.evaluate(at: 0).position == 0)
        #expect(track.evaluate(at: 0).velocity == 0)
        #expect(track.evaluate(at: 3).position.isApproximately(50, within: 1e-3))
    }

    @Test func queriesBeforeTheFirstKnotClampToRest() {
        let track = SpringTrack(initial: 7, changes: [TargetChange(time: 1, target: 50.0, spring: .camera)], rescaleShortIntervals: false)
        #expect(track.evaluate(at: -3).position == 7)
        #expect(track.evaluate(at: 0.999).position == 7)
        #expect(track.evaluate(at: -3).velocity == 0)
    }

    @Test func vectorTrackMatchesPerAxisScalarTracks() {
        let xs = [TargetChange(time: 0.1, target: 300.0, spring: .cursorMedium), TargetChange(time: 0.7, target: -20.0, spring: .cursorRapid)]
        let ys = [TargetChange(time: 0.1, target: 40.0, spring: .cursorMedium), TargetChange(time: 0.7, target: 900.0, spring: .cursorRapid)]
        let vectors = zip(xs, ys).map { TargetChange(time: $0.time, target: Vector2(x: $0.target, y: $1.target), spring: $0.spring) }
        let x = SpringTrack(initial: 0, changes: xs, rescaleShortIntervals: false)
        let y = SpringTrack(initial: 0, changes: ys, rescaleShortIntervals: false)
        let v = SpringTrack(initial: .zero, changes: vectors, rescaleShortIntervals: false)
        for t in stride(from: 0.0, through: 2, by: 0.013) {
            let (p, vel) = v.evaluate(at: t)
            #expect(p.x.bitPattern == x.evaluate(at: t).position.bitPattern)
            #expect(p.y.bitPattern == y.evaluate(at: t).position.bitPattern)
            #expect(vel.x.bitPattern == x.evaluate(at: t).velocity.bitPattern)
        }
    }
}

extension Double {
    func isApproximately(_ other: Double, within tolerance: Double = 1e-6) -> Bool { abs(self - other) < tolerance }
}

extension SpringResponse.Regime {
    var name: String {
        switch self {
        case .underdamped: "underdamped"
        case .critical: "critical"
        case .overdamped: "overdamped"
        }
    }
}
