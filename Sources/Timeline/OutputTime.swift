/// A point on the edited take's clock: microseconds from the first kept frame. The player, the
/// export, stills, the transport label, and `Timeline.frame(at:)` speak it.
///
/// A separate type from `RecordingTime` with no initializer from it, so the only way to turn one
/// into the other is through a `TimeMap`. Not `Codable`, so an output time cannot reach
/// `project.json`. Zooms, events, and cuts stay in `RecordingTime`.
public struct OutputTime: Sendable, Hashable, Comparable {
    public var microseconds: Int64

    public init(microseconds: Int64) { self.microseconds = microseconds }

    public static func seconds(_ s: Double) -> OutputTime { OutputTime(microseconds: Int64((s * 1_000_000).rounded())) }
    public static func milliseconds(_ ms: Int64) -> OutputTime { OutputTime(microseconds: ms * 1000) }

    public var seconds: Double { Double(microseconds) / 1_000_000 }

    public static let zero = OutputTime(microseconds: 0)

    public static func < (lhs: OutputTime, rhs: OutputTime) -> Bool { lhs.microseconds < rhs.microseconds }

    /// Differences and offsets on one clock. There is deliberately no `+` between the two clocks.
    public static func + (lhs: OutputTime, rhs: OutputTime) -> OutputTime { OutputTime(microseconds: lhs.microseconds + rhs.microseconds) }
    public static func - (lhs: OutputTime, rhs: OutputTime) -> OutputTime { OutputTime(microseconds: lhs.microseconds - rhs.microseconds) }

    public func clamped(to range: ClosedRange<OutputTime>) -> OutputTime { min(max(self, range.lowerBound), range.upperBound) }
}

/// The playhead in both clocks, converted by the map of the player item that produced it. The
/// strip draws `recording`; the transport label prints `output`.
public struct Playhead: Sendable, Hashable {
    public let output: OutputTime
    public let recording: RecordingTime

    public init(output: OutputTime, recording: RecordingTime) {
        self.output = output
        self.recording = recording
    }

    public static let start = Playhead(output: .zero, recording: .zero)
}
