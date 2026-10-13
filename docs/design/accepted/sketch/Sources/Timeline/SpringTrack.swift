import Foundation

/// A spring driven by a piecewise-constant target, solved exactly.
///
/// Every target Timeline feeds a spring is a step function: the camera target changes at segment and
/// group boundaries, the zoom target at segment edges, the cursor target at each pointer sample
/// (sample-and-hold). Between two changes the spring obeys a linear ODE with constant coefficients,
/// which has a closed-form solution. So the track stores the exact spring state at every target
/// change ("knots"), computed once by folding the closed form forward from t = 0, and a query evaluates
/// the closed form from the nearest knot at or before t.
///
/// This replaces the observed "reset at t - 1000 ms and replay at 60 Hz" technique. Both are
/// deterministic; this one is also exact (no step-size error, no reset discontinuity for springs
/// that take longer than 1 s to settle) and O(log n) per query instead of O(replay steps).
struct SpringTrack<Value: SpringValue>: Sendable {
    struct Knot: Sendable {
        /// Seconds of media time.
        var time: Double
        var target: Value
        var position: Value
        var velocity: Value
        var response: SpringResponse
    }

    /// Sorted by time, non-empty, `knots[0].time == 0`.
    private let knots: [Knot]

    /// `changes` must be sorted by time. The spring starts at rest on `initial` at t = 0.
    init(initial: Value, changes: [TargetChange<Value>], rescaleShortIntervals: Bool) {
        // TODO:
        // var state = (position: initial, velocity: .zero), current = Knot(time: 0, target: initial, ...)
        // for (i, change) in changes.enumerated():
        //   // Advance the previous knot's solution to this change's time.
        //   (p, v) = current.response.advance(from: current, by: change.time - current.time)
        //   spring = change.spring
        //   if rescaleShortIntervals:
        //     available = (changes[i+1].time ?? .infinity) - change.time
        //     T = spring.settleTime()
        //     if available < T { r = T / available; spring.stiffness *= r * r; spring.damping *= r }
        //   current = Knot(time: change.time, target: change.target, position: p, velocity: v,
        //                  response: SpringResponse(spring))
        //   append current
        // A change at the same time as the previous knot replaces it instead of appending, so binary
        // search never sees duplicate times.
        fatalError("not implemented")
    }

    /// Exact position and velocity at `time` (seconds). Clamps to the first knot.
    func evaluate(at time: Double) -> (position: Value, velocity: Value) {
        // TODO:
        // i = index of the last knot with knot.time <= time   (binary search)
        // return knots[i].response.advance(from: knots[i], by: time - knots[i].time)
        fatalError("not implemented")
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
        /// zeta < 1: e^(-zeta w0 t) (y0 cos wd t + (v0 + zeta w0 y0) / wd sin wd t)
        case underdamped(decay: Double, dampedFrequency: Double)
        /// |zeta - 1| < 1e-6, treated as critical to avoid dividing by a near-zero wd or root gap:
        /// e^(-w0 t) (y0 + (v0 + w0 y0) t)
        case critical(naturalFrequency: Double)
        /// zeta > 1: A e^(r1 t) + B e^(r2 t)
        case overdamped(r1: Double, r2: Double)
    }

    let regime: Regime

    init(_ spring: Spring) { fatalError("not implemented") }

    func advance<Value: SpringValue>(
        from knot: SpringTrack<Value>.Knot, by dt: Double
    ) -> (position: Value, velocity: Value) {
        fatalError("not implemented")
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
}
