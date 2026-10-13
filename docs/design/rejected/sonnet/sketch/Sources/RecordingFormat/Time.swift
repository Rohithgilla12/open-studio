import Foundation

/// Nanoseconds on the host clock (mach_absolute_time converted through mach_timebase_info).
/// This is the only clock the recorder reads. SCStream PTS, CGEvent timestamps and
/// mic samples are all converted to it at their capture boundary and nowhere else.
public struct HostTime: Hashable, Comparable, Sendable, Codable {
    public var nanoseconds: Int64
    public init(nanoseconds: Int64) { self.nanoseconds = nanoseconds }
    public static func < (a: Self, b: Self) -> Bool { a.nanoseconds < b.nanoseconds }

    // Encoded as a bare integer ("origin": 482913745120000), not {"nanoseconds": ...}.
    public init(from decoder: any Decoder) throws {
        nanoseconds = try decoder.singleValueContainer().decode(Int64.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(nanoseconds)
    }
}

/// Nanoseconds since the recording origin (the PTS of the first video frame).
/// Everything downstream of the file reader, including Timeline and the renderer, uses
/// this type. It is exact integer arithmetic, so equal inputs give equal outputs.
public struct RecordingTime: Hashable, Comparable, Sendable, Codable {
    public var nanoseconds: Int64
    public init(nanoseconds: Int64) { self.nanoseconds = nanoseconds }

    public init(host: HostTime, origin: HostTime) {
        self.init(nanoseconds: host.nanoseconds - origin.nanoseconds)
    }

    /// Exact conversion from a CMTime-shaped pair without importing CoreMedia.
    public init(value: Int64, timescale: Int32) { fatalError("not implemented") }

    public static func milliseconds(_ ms: Int64) -> Self { .init(nanoseconds: ms * 1_000_000) }
    public static let zero = Self(nanoseconds: 0)

    public var seconds: Double { Double(nanoseconds) / 1e9 }

    public static func < (a: Self, b: Self) -> Bool { a.nanoseconds < b.nanoseconds }
    public init(from decoder: any Decoder) throws {
        nanoseconds = try decoder.singleValueContainer().decode(Int64.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(nanoseconds)
    }

    public static func + (a: Self, b: Self) -> Self { .init(nanoseconds: a.nanoseconds + b.nanoseconds) }
    public static func - (a: Self, b: Self) -> Self { .init(nanoseconds: a.nanoseconds - b.nanoseconds) }
}

public struct TimeRange: Hashable, Sendable, Codable {
    public var start: RecordingTime
    public var end: RecordingTime
    public init(start: RecordingTime, end: RecordingTime) {
        precondition(start <= end)
        self.start = start
        self.end = end
    }
    public func contains(_ t: RecordingTime) -> Bool { start <= t && t < end }
}
