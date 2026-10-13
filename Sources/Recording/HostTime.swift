import CoreMedia
import Darwin
internal import RecordingFormat

/// A time in nanoseconds on `CLOCK_UPTIME_RAW`, the one clock every source shares: SCStream PTS,
/// `CGEvent.timestamp`, and `mach_absolute_time` converted through the timebase.
struct HostTime: Sendable, Hashable, Comparable {
    var nanoseconds: UInt64

    init(nanoseconds: UInt64) { self.nanoseconds = nanoseconds }

    /// A PTS on `CMClockGetHostTimeClock()`.
    init(_ time: CMTime) {
        let scaled = time.timescale == Self.timescale ? time : CMTimeConvertScale(time, timescale: Self.timescale, method: .default)
        self.init(nanoseconds: UInt64(max(0, scaled.value)))
    }

    /// `mach_absolute_time` units. On Apple Silicon one tick is 125/3 ns.
    init(machTicks: UInt64) {
        let timebase = Self.timebase
        self.init(nanoseconds: machTicks * UInt64(timebase.numer) / UInt64(timebase.denom))
    }

    static func now() -> HostTime { HostTime(nanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) }

    static func < (lhs: HostTime, rhs: HostTime) -> Bool { lhs.nanoseconds < rhs.nanoseconds }

    static func + (lhs: HostTime, rhs: Duration) -> HostTime {
        HostTime(nanoseconds: UInt64(Int64(lhs.nanoseconds) + rhs.nanoseconds))
    }

    /// Media time since `origin`. Nil before the origin: those events describe a state the t = 0
    /// snapshot already captures.
    func mediaTime(since origin: HostTime) -> MediaTime? {
        guard nanoseconds >= origin.nanoseconds else { return nil }
        return MediaTime(microseconds: Int64((nanoseconds - origin.nanoseconds) / 1000))
    }

    func duration(since origin: HostTime) -> Duration {
        .nanoseconds(Int64(nanoseconds) - Int64(origin.nanoseconds))
    }

    var cmTime: CMTime { CMTime(value: CMTimeValue(nanoseconds), timescale: Self.timescale) }

    private static let timescale: CMTimeScale = 1_000_000_000

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
}

extension Duration {
    var nanoseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }

    var seconds: Double { Double(nanoseconds) / 1e9 }
}

extension MediaTime {
    var duration: Duration { .microseconds(microseconds) }
}
