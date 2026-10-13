import CoreMedia
import Foundation

/// Nanoseconds on the host time clock, re-based on a single sample taken before any
/// producer starts. On Apple Silicon `mach_absolute_time` ticks are not nanoseconds
/// (timebase 125/3), so every conversion goes through `mach_timebase_info` here, and
/// nowhere else.
struct HostClock: Sendable {
    let startHostNanos: UInt64

    static func start() -> HostClock {
        fatalError("not implemented")
    }

    /// Offset of "now" from `startHostNanos`.
    func now() -> Int64 {
        fatalError("not implemented")
    }

    /// `CGEvent.timestamp` is already nanoseconds since boot on the same clock.
    func offset(ofEventTimestamp timestamp: UInt64) -> Int64 {
        fatalError("not implemented")
    }

    /// SCStream sample buffers carry PTS on `CMClockGetHostTimeClock()`.
    func offset(of pts: CMTime) -> Int64 {
        fatalError("not implemented")
    }
}
