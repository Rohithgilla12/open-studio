import CoreMedia
import Darwin
internal import RecordingFormat

/// A time in nanoseconds on `CLOCK_UPTIME_RAW`, the one clock every source shares: SCStream PTS
/// and `CGEvent.timestamp` are already on it (measured in `Experiments/README.md`).
struct HostTime: Sendable, Hashable, Comparable {
    var nanoseconds: UInt64

    init(nanoseconds: UInt64) { self.nanoseconds = nanoseconds }

    init(_ time: CMTime) {
        let scaled = time.timescale == Self.timescale ? time : CMTimeConvertScale(time, timescale: Self.timescale, method: .default)
        self.init(nanoseconds: UInt64(max(0, scaled.value)))
    }

    static func now() -> HostTime { HostTime(nanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) }

    static func < (lhs: HostTime, rhs: HostTime) -> Bool { lhs.nanoseconds < rhs.nanoseconds }

    static func + (lhs: HostTime, rhs: Duration) -> HostTime {
        HostTime(nanoseconds: UInt64(Int64(lhs.nanoseconds) + rhs.nanoseconds))
    }

    func mediaTime(since origin: HostTime) -> MediaTime? {
        guard nanoseconds >= origin.nanoseconds else { return nil }
        return MediaTime(microseconds: Int64((nanoseconds - origin.nanoseconds) / 1000))
    }

    func duration(since origin: HostTime) -> Duration {
        .nanoseconds(Int64(nanoseconds) - Int64(origin.nanoseconds))
    }

    var cmTime: CMTime { CMTime(value: CMTimeValue(nanoseconds), timescale: Self.timescale) }

    private static let timescale: CMTimeScale = 1_000_000_000
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
