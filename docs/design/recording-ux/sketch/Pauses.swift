// Sources/Timeline/SourceRecording.swift, Cuts.swift, TimeMap.swift, Timeline.swift (changed).
//
// Pauses are facts of the recording, read from recording.json at load. They never enter `Edits`
// or project.json, so there is nothing to restore and no second copy to keep in step. `Cuts`
// treats them as fixed neighbours: every rule it already enforces between cuts (sorted, kept
// spans of at least `minimumKept`, something kept) now holds across cuts and pauses together, in
// the one place that derives "kept".

/// The recording's length and the ranges the recorder removed. What `Cuts` edits are made within.
public struct TakeExtent: Sendable, Hashable {
    public let duration: RecordingTime
    /// Sorted, disjoint, inside `[0, duration)`, and normalized at load: two pauses less than
    /// `Cuts.minimumKept` apart merge, and a sliver before the first or after the last is absorbed,
    /// unless absorbing it would leave nothing kept. A pause may be shorter than `minimumKept`;
    /// the minimum is on what is kept, not on what is removed.
    public let pauses: [TimeRange]

    /// The extent of a take with no pauses. Every caller that passed `within: duration` and has
    /// no recording at hand (tests, fixtures) uses this.
    public static func unpaused(_ duration: RecordingTime) -> TakeExtent { fatalError("not implemented") }

    init(validating pauses: [TimeRange], duration: RecordingTime) throws(SourceLoadError) { fatalError("not implemented") }
}

extension SourceRecording {
    // public let extent: TakeExtent        // built in init(_ metadata:) from manifest.pauses
    // public var duration: RecordingTime { extent.duration }
}

/// Everything removed from the output: user cuts and pauses, merged. Derived by `Cuts` for a
/// `Timeline`; `TimeMap` and `Retiming` read it instead of `Cuts`, so a change inside a pause
/// collapses onto the join exactly as one inside a cut does.
public struct Removals: Sendable, Hashable {
    public let ranges: [TimeRange]
    public func contains(_ t: RecordingTime) -> Bool { fatalError("not implemented") }
    func keptSpans(within duration: RecordingTime) -> [TimeRange] { fatalError("not implemented") }
}

extension Cuts {
    // Every `within duration: RecordingTime` parameter becomes `within extent: TakeExtent`:
    //
    // public init(validating cuts: [Cut], within extent: TakeExtent) throws(CutsError)
    // public func cutting(_ range: TimeRange, within extent: TakeExtent) -> (cuts: Cuts, id: Cut.ID)?
    // public func trimming(_ end: End, to t: RecordingTime, within extent: TakeExtent) -> Cuts
    // public func resizing(_ id: Cut.ID, edge: End, to t: RecordingTime, within extent: TakeExtent) -> Cuts
    // public func trimmed(within extent: TakeExtent) -> ClosedRange<RecordingTime>
    //
    // Pauses act as immovable neighbours in the clamps: an edge stops `minimumKept` short of a
    // pause, or snaps onto it, as it does against another cut. A user cut may cover a pause
    // whole; restoring that cut leaves the pause removed. A user cut never merges with a pause,
    // so the stored cut keeps the range the person made.

    public func removals(within extent: TakeExtent) -> Removals { fatalError("not implemented") }
}

// Timeline.init: `map = TimeMap(removals: cuts.removals(within: source.extent), duration:)`, and
// Retiming asks `removals.contains(r)` where it asked `cuts.cut(containing: r)`. The editor's
// strip draws `source.extent.pauses` hatched with no handles and no Restore item; its cut gestures
// pass `source.extent`. project.json is unchanged (version 2): it still stores user cuts only.
