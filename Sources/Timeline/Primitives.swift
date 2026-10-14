/// A point on the recording's clock: microseconds of screen media time, 0 = first screen frame.
///
/// Integer so it round-trips the on-disk value exactly and compares exactly. Spring maths converts
/// to seconds internally. The renderer converts `CMTime` to this in its own module.
public struct RecordingTime: Sendable, Hashable, Comparable, Codable {
    public var microseconds: Int64

    public init(microseconds: Int64) { self.microseconds = microseconds }

    public static func seconds(_ s: Double) -> RecordingTime {
        RecordingTime(microseconds: Int64((s * 1_000_000).rounded()))
    }

    public static func milliseconds(_ ms: Int64) -> RecordingTime { RecordingTime(microseconds: ms * 1000) }

    public var seconds: Double { Double(microseconds) / 1_000_000 }

    public static let zero = RecordingTime(microseconds: 0)

    public static func < (lhs: RecordingTime, rhs: RecordingTime) -> Bool { lhs.microseconds < rhs.microseconds }

    public static func + (lhs: RecordingTime, rhs: RecordingTime) -> RecordingTime {
        RecordingTime(microseconds: lhs.microseconds + rhs.microseconds)
    }

    public static func - (lhs: RecordingTime, rhs: RecordingTime) -> RecordingTime {
        RecordingTime(microseconds: lhs.microseconds - rhs.microseconds)
    }

    func clamped(to range: ClosedRange<RecordingTime>) -> RecordingTime {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Half-open `[start, end)`. Non-empty by construction: the initializer returns nil when
/// `end <= start`, so code holding a `TimeRange` never handles a degenerate one.
public struct TimeRange: Sendable, Hashable, Codable {
    public let start: RecordingTime
    public let end: RecordingTime

    public init?(start: RecordingTime, end: RecordingTime) {
        guard start < end else { return nil }
        self.start = start
        self.end = end
    }

    public func contains(_ t: RecordingTime) -> Bool { start <= t && t < end }

    public var duration: RecordingTime { end - start }

    /// Decoding goes through `init?(start:end:)`, so a file cannot produce the empty range the type
    /// promises cannot exist.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let start = try c.decode(RecordingTime.self, forKey: .start)
        let end = try c.decode(RecordingTime.self, forKey: .end)
        guard let range = TimeRange(start: start, end: end) else {
            throw DecodingError.dataCorruptedError(
                forKey: .end, in: c, debugDescription: "range end \(end.microseconds) is not after start \(start.microseconds)")
        }
        self = range
    }

    private enum CodingKeys: String, CodingKey {
        case start, end
    }
}

/// Screen video pixels, origin top-left, y down. The same space the recording directory uses, so
/// no conversion happens between disk and renderer.
public struct Point: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Pixels per second.
public struct Velocity: Sendable, Hashable {
    public var dx: Double
    public var dy: Double

    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }

    public static let zero = Velocity(dx: 0, dy: 0)
}

public struct Size: Sendable, Hashable, Codable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// Whether a point lies on a frame of this size. The pointer is recorded on every display, so
    /// points off the recorded one have coordinates outside it.
    public func contains(_ point: Point) -> Bool {
        point.x >= 0 && point.y >= 0 && point.x < width && point.y < height
    }
}

public struct Rect: Sendable, Hashable, Codable {
    public var origin: Point
    public var size: Size

    public init(origin: Point, size: Size) {
        self.origin = origin
        self.size = size
    }

    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }
}
