import Foundation

/// A spring driven by a piecewise-constant target, solved exactly.
///
/// Every target Timeline feeds a spring is a step function: the camera target changes at segment and
/// group boundaries, the zoom target at segment edges, the cursor target at each pointer sample
/// (sample-and-hold). Between two changes the spring obeys a linear ODE with constant coefficients,
/// which has a closed-form solution. So the track stores the exact spring state at every target
/// change ("knots"), computed once by folding the closed form forward from t = 0, and a query evaluates
/// the closed form from the nearest knot at or before t.
struct SpringTrack<Value: SpringValue>: Sendable {
    struct Knot: Sendable {
        /// Seconds of media time.
        var time: Double
        var target: Value
        var position: Value
        var velocity: Value
        var response: SpringResponse
    }

    /// Sorted by strictly increasing time, non-empty, `knots[0].time == 0`.
    let knots: [Knot]

    /// `changes` must be sorted by time. The spring starts at rest on `initial` at t = 0. Several
    /// changes at one time collapse to the last, so binary search never sees duplicate times.
    init(initial: Value, changes: [TargetChange<Value>], rescaleShortIntervals: Bool) {
        var distinct: [TargetChange<Value>] = []
        distinct.reserveCapacity(changes.count)
        for change in changes {
            if let last = distinct.last, last.time == change.time {
                distinct[distinct.count - 1] = change
            } else {
                distinct.append(change)
            }
        }

        let restSpring = distinct.first?.spring ?? .camera
        var current = Knot(time: 0, target: initial, position: initial, velocity: .zero, response: SpringResponse(restSpring))
        var knots = [current]
        knots.reserveCapacity(distinct.count + 1)
        for (index, change) in distinct.enumerated() {
            let (position, velocity) = current.response.advance(from: current, by: change.time - current.time)
            var spring = change.spring
            if rescaleShortIntervals, index + 1 < distinct.count {
                spring = spring.rescaled(toSettleWithin: distinct[index + 1].time - change.time)
            }
            current = Knot(
                time: change.time, target: change.target, position: position, velocity: velocity,
                response: SpringResponse(spring))
            if knots.last!.time == change.time {
                knots[knots.count - 1] = current
            } else {
                knots.append(current)
            }
        }
        self.knots = knots
    }

    /// Exact position and velocity at `time` (seconds). Clamps to the first knot.
    func evaluate(at time: Double) -> (position: Value, velocity: Value) {
        let knot = knots[knots.lastIndex(keyedBy: \.time, atOrBefore: time)]
        return knot.response.advance(from: knot, by: max(0, time - knot.time))
    }
}

struct TargetChange<Value: SpringValue>: Sendable {
    var time: Double
    var target: Value
    var spring: Spring
}

/// The closed-form step response of one spring, with everything that does not depend on dt
/// precomputed so `advance` is one `exp` and at most one `sin`/`cos` pair.
///
/// For displacement y = x - target, the solution is linear in the initial state:
///     y(dt) = a(dt) y0 + b(dt) v0
///     v(dt) = c(dt) y0 + d(dt) v0
/// with scalar a, b, c, d. Because they are scalars, the same coefficients apply to each axis of a 2-D
/// value, which is why `SpringValue` needs only addition and scaling.
struct SpringResponse: Sendable, Hashable {
    enum Regime: Sendable, Hashable {
        /// zeta < 1: e^(-decay t) (y0 cos wd t + (v0 + decay y0) / wd sin wd t)
        case underdamped(decay: Double, dampedFrequency: Double, naturalFrequencySquared: Double)
        /// |zeta - 1| < 1e-6, treated as critical to avoid dividing by a near-zero wd or root gap:
        /// e^(-w0 t) (y0 + (v0 + w0 y0) t)
        case critical(naturalFrequency: Double)
        /// zeta > 1: A e^(r1 t) + B e^(r2 t)
        case overdamped(r1: Double, r2: Double)
    }

    let regime: Regime

    init(_ spring: Spring) {
        let w0 = spring.naturalFrequency
        let zeta = spring.dampingRatio
        if abs(zeta - 1) < 1e-6 {
            regime = .critical(naturalFrequency: w0)
        } else if zeta < 1 {
            regime = .underdamped(
                decay: zeta * w0, dampedFrequency: w0 * (1 - zeta * zeta).squareRoot(), naturalFrequencySquared: w0 * w0)
        } else {
            let spread = w0 * (zeta * zeta - 1).squareRoot()
            regime = .overdamped(r1: -zeta * w0 + spread, r2: -zeta * w0 - spread)
        }
    }

    struct Coefficients {
        var a, b, c, d: Double
    }

    func coefficients(dt: Double) -> Coefficients {
        switch regime {
        case .underdamped(let decay, let wd, let w0Squared):
            let envelope = exp(-decay * dt)
            let cosine = cos(wd * dt)
            let sine = sin(wd * dt)
            return Coefficients(
                a: envelope * (cosine + decay / wd * sine),
                b: envelope * sine / wd,
                c: -envelope * sine * w0Squared / wd,
                d: envelope * (cosine - decay / wd * sine))
        case .critical(let w0):
            let envelope = exp(-w0 * dt)
            return Coefficients(
                a: envelope * (1 + w0 * dt),
                b: envelope * dt,
                c: -envelope * w0 * w0 * dt,
                d: envelope * (1 - w0 * dt))
        case .overdamped(let r1, let r2):
            let e1 = exp(r1 * dt)
            let e2 = exp(r2 * dt)
            let gap = r1 - r2
            return Coefficients(
                a: (r1 * e2 - r2 * e1) / gap,
                b: (e1 - e2) / gap,
                c: r1 * r2 * (e2 - e1) / gap,
                d: (r1 * e1 - r2 * e2) / gap)
        }
    }

    func advance<Value: SpringValue>(
        from knot: SpringTrack<Value>.Knot, by dt: Double
    ) -> (position: Value, velocity: Value) {
        let k = coefficients(dt: dt)
        let displacement = knot.position - knot.target
        return (
            position: knot.target + k.a * displacement + k.b * knot.velocity,
            velocity: k.c * displacement + k.d * knot.velocity)
    }
}

/// What a spring can animate: a vector space over Double. Double (zoom scale) and Vector2 (positions).
protocol SpringValue: Sendable {
    static var zero: Self { get }
    static func + (lhs: Self, rhs: Self) -> Self
    static func - (lhs: Self, rhs: Self) -> Self
    static func * (lhs: Double, rhs: Self) -> Self
}

extension Double: SpringValue {}

struct Vector2: SpringValue, Hashable {
    var x: Double
    var y: Double

    static let zero = Vector2(x: 0, y: 0)
    static func + (lhs: Vector2, rhs: Vector2) -> Vector2 { Vector2(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
    static func - (lhs: Vector2, rhs: Vector2) -> Vector2 { Vector2(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
    static func * (lhs: Double, rhs: Vector2) -> Vector2 { Vector2(x: lhs * rhs.x, y: lhs * rhs.y) }

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(_ point: Point) { self.init(x: point.x, y: point.y) }

    var point: Point { Point(x: x, y: y) }
    var velocity: Velocity { Velocity(dx: x, dy: y) }
}

extension RandomAccessCollection {
    /// Binary search over a collection sorted by `key`: the index of the last element whose key is
    /// at most `time`, or `startIndex` when every key is greater. The collection must be non-empty.
    func lastIndex(keyedBy key: (Element) -> Double, atOrBefore time: Double) -> Index {
        let next = firstIndex(keyedBy: key, after: time)
        return next == startIndex ? startIndex : index(before: next)
    }

    /// The index of the first element whose key is greater than `time`, or `endIndex`.
    func firstIndex(keyedBy key: (Element) -> Double, after time: Double) -> Index {
        var low = startIndex
        var high = endIndex
        while low < high {
            let mid = index(low, offsetBy: distance(from: low, to: high) / 2)
            if key(self[mid]) <= time {
                low = index(after: mid)
            } else {
                high = mid
            }
        }
        return low
    }
}
