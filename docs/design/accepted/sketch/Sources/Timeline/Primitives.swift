/// A point on the recording's clock: microseconds of screen media time, 0 = first screen frame.
///
/// Integer so it round-trips the on-disk value exactly and compares exactly; spring maths converts to
/// seconds internally. The renderer converts `CMTime` to this in its own module (Timeline does not
/// import CoreMedia).
public struct RecordingTime: Sendable, Hashable, Comparable, Codable {
    public var microseconds: Int64

    public init(microseconds: Int64) { self.microseconds = microseconds }

    public static func seconds(_ s: Double) -> RecordingTime { fatalError("not implemented") }
    public static func milliseconds(_ ms: Int64) -> RecordingTime { fatalError("not implemented") }
    public var seconds: Double { fatalError("not implemented") }

    public static func < (lhs: RecordingTime, rhs: RecordingTime) -> Bool { lhs.microseconds < rhs.microseconds }
    public static func + (lhs: RecordingTime, rhs: RecordingTime) -> RecordingTime { fatalError("not implemented") }
    public static func - (lhs: RecordingTime, rhs: RecordingTime) -> RecordingTime { fatalError("not implemented") }
    public static let zero = RecordingTime(microseconds: 0)
}

/// Half-open `[start, end)`. Non-empty by construction: the initializer returns nil when
/// `end <= start`, so code holding a `TimeRange` never handles a degenerate one.
public struct TimeRange: Sendable, Hashable, Codable {
    public let start: RecordingTime
    public let end: RecordingTime

    public init?(start: RecordingTime, end: RecordingTime) { fatalError("not implemented") }
    public func contains(_ t: RecordingTime) -> Bool { fatalError("not implemented") }
    public var duration: RecordingTime { fatalError("not implemented") }
}

/// Screen video pixels, origin top-left, y down. The same space the recording directory uses, so
/// no conversion happens between disk and renderer.
public struct Point: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// Pixels per second.
public struct Velocity: Sendable, Hashable {
    public var dx: Double
    public var dy: Double
}

public struct Size: Sendable, Hashable, Codable {
    public var width: Double
    public var height: Double
}

public struct Rect: Sendable, Hashable, Codable {
    public var origin: Point
    public var size: Size
}
