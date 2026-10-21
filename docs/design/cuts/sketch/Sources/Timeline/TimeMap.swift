/// The one conversion between the two clocks. Derived from `Cuts` (and, later, speed ranges) by
/// `Timeline`; every other module reads `timeline.map`.
///
/// Piecewise linear and monotone: output time runs through the kept spans in order. Exact integer
/// arithmetic at rate 1, so `recording(at: output(at: r)!) == r` for every kept r.
///
///     recording  0 ----[ kept A )====cut====[ kept B )==tail==| d
///     output     0 ----[ kept A )[ kept B )| duration
///                                ^ join
public struct TimeMap: Sendable, Hashable {
    public struct Segment: Sendable, Hashable {
        /// Half-open, in recording time.
        public let source: TimeRange
        /// Where `source.start` lands in output time.
        public let outputStart: OutputTime
        // A speed change adds `rate` here, defaulting to 1. `recording(at:)`, `output(at:)`, and
        // `output(collapsing:)` absorb it; no caller changes, and the composition builder scales
        // each segment it inserts.
        public var outputEnd: OutputTime { outputStart + OutputTime(microseconds: source.duration.microseconds) }
    }

    /// Non-empty (Cuts keeps at least one span), sorted, increasing in both clocks.
    public let segments: [Segment]

    public var duration: OutputTime { segments.last!.outputEnd }

    /// The whole recording, unchanged: composition time equals recording time.
    public static func identity(duration: RecordingTime) -> TimeMap {
        TimeMap(cuts: .none, duration: duration)
    }

    init(cuts: Cuts, duration: RecordingTime) {
        // TODO: the kept spans are the complement of cuts in [0, duration); outputStart is the
        // running sum of the spans before. This is the only place "kept" is derived from "cut".
        fatalError("not implemented")
    }

    /// The recording instant shown at output time `o`. Total: `o` is clamped to [0, duration]. At
    /// a join it returns the later span's start, because spans are half-open.
    public func recording(at o: OutputTime) -> RecordingTime {
        fatalError("not implemented")
    }

    /// Where recording instant `r` is shown, or nil when it was cut.
    public func output(at r: RecordingTime) -> OutputTime? {
        fatalError("not implemented")
    }

    /// Where recording instant `r` is shown, or, inside a cut, the join where the cut was (0 inside
    /// the head trim, `duration` inside the tail trim). Monotone non-decreasing in `r`, which is
    /// what lets the springs retime a sorted change list without re-sorting it.
    public func output(collapsing r: RecordingTime) -> OutputTime {
        fatalError("not implemented")
    }

    /// Output times where one kept span meets the next. The audio dips here.
    public var joins: [OutputTime] { segments.dropFirst().map(\.outputStart) }

    /// Whether the output starts later or ends earlier than the recording, so the audio fades in at
    /// 0 or out at `duration` instead of starting or stopping mid-waveform.
    public func trims(within recording: RecordingTime) -> (start: Bool, end: Bool) {
        (segments.first!.source.start > .zero, segments.last!.source.end < recording)
    }
}
