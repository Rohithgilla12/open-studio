public struct SpringParams: Sendable, Hashable {
    public var stiffness: Double
    public var damping: Double
    public var mass: Double
    /// Position and velocity both below this count as settled.
    public var precision: Double = 0.002

    public init(stiffness: Double, damping: Double, mass: Double) {
        self.stiffness = stiffness
        self.damping = damping
        self.mass = mass
    }

    public static let camera = SpringParams(stiffness: 125, damping: 12, mass: 1.5)
    public static let cursorSmooth = SpringParams(stiffness: 470, damping: 70, mass: 3)
    public static let cursorMedium = SpringParams(stiffness: 340, damping: 60, mass: 3)
    public static let cursorRapid = SpringParams(stiffness: 530, damping: 40, mass: 1)
}

/// Anything a spring can animate: 2-D positions and scalar zoom share one integrator.
public protocol SpringVector: Sendable, Equatable {
    static var zero: Self { get }
    static func + (a: Self, b: Self) -> Self
    static func - (a: Self, b: Self) -> Self
    static func * (a: Self, s: Double) -> Self
    var magnitude: Double { get }
}

extension Point: SpringVector {
    public var magnitude: Double { (x * x + y * y).squareRoot() }
}

extension Double: SpringVector {
    public static let zero: Double = 0
    public var magnitude: Double { abs(self) }
}

/// Stateless spring evaluation. The value at `t` is a pure function of `(params, target,
/// t)`: the integrator starts at `target(t - warmup)` with zero velocity and steps
/// forward with a fixed `dt`, so two callers asking for the same `t` on different threads
/// or in any order get bit-identical results. That is what lets preview and export share
/// one render path and seek freely.
///
/// Cost: `warmup / dt` steps, 60 by default, each a few multiplies plus one `target`
/// lookup (a binary search in practice). Microseconds per query.
public enum Spring {
    public static let defaultWarmup: Duration = .seconds(1)
    public static let defaultStep: Duration = .seconds(1.0 / 60.0)

    public static func value<V: SpringVector>(
        at t: Duration,
        params: SpringParams,
        warmup: Duration = defaultWarmup,
        step: Duration = defaultStep,
        target: (Duration) -> V
    ) -> V {
        // TODO: semi-implicit Euler
        // var s = t - warmup; var x = target(s); var v = V.zero; let dt = step.seconds
        // while s < t:
        //   let goal = target(s)
        //   v = v + ((goal - x) * params.stiffness - v * params.damping) * (dt / params.mass)
        //   x = x + v * dt
        //   s += step
        // (final partial step: dt = (t - s).seconds so the result is continuous in t)
        // return x
        fatalError("not implemented")
    }

    /// Time until a step from rest to a unit displacement settles within `precision`,
    /// found by simulation once per params and cached by the sampler.
    public static func settleTime(_ params: SpringParams, step: Duration = defaultStep) -> Duration {
        fatalError("not implemented")
    }

    /// When the window before the next target change is shorter than the settle time,
    /// stiffen so the spring still arrives: `k *= (settle/available)^2`,
    /// `c *= settle/available`. Keeps the damping ratio, shortens the period.
    public static func fitted(_ params: SpringParams, settleTime: Duration, available: Duration) -> SpringParams {
        fatalError("not implemented")
    }
}
