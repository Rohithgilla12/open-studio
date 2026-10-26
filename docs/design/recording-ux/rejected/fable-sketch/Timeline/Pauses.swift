// Sketch. Module Timeline (and the Render/Studio callers). How a pause becomes a cut nobody can
// restore.
//
//   SourceRecording.pauses   [TimeRange]      facts of the take, read from the manifest
//   Edits.cuts               Cuts             the user's intent, read from project.json
//            └──────────┬──────────┘
//                       ▼
//   Timeline.init: removed = edits.cuts.merging(pauses: source.pauses, within: duration)
//                  map     = TimeMap(cuts: removed, duration)         ◀── one map, as today
//                  Retiming(map, cuts: removed)
//
// Nothing stores the union. `project.json` keeps only user cuts (version 2 as today), so a saved
// project never duplicates a fact the manifest owns, and a hand-edited file cannot "restore" a
// pause. Derive, don't sync.

import Foundation

extension SourceRecording {
    /// Sorted, disjoint, inside `[0, duration]`, from the manifest. Empty for takes recorded before
    /// pauses existed. A finalized manifest with an open pause is `.corrupt`.
    public var pauses: [TimeRange] { fatalError("not implemented") }
}

extension Cuts {
    /// The user's cuts with the pauses folded in through `cutting`, one pause at a time. That is
    /// the one total edit the type already has, so every rule holds by construction:
    /// - a user cut overlapping or within 200 ms of a pause merges with it (the user's id survives,
    ///   so their selection and drag keep working; the drawn user cut is unchanged in `Edits`);
    /// - a pause closer than 200 ms to the take's start or end absorbs the sliver, becoming a trim;
    /// - a pause shorter than any length is fine: the 200 ms rule is about kept spans, not cuts;
    /// - a pause that would leave nothing kept (the whole take paused) is skipped, so the take
    ///   shows everything rather than nothing, and `inspect` reports it.
    /// Pause ids are the range's bytes, like generated zoom ids, so the result is stable.
    public func merging(pauses: [TimeRange], within duration: RecordingTime) -> Cuts {
        fatalError("not implemented")
    }
}

extension Timeline {
    /// `init(source:zooms:settings:cuts:)` is unchanged in signature. Internally the map and the
    /// retiming are built from `cuts.merging(pauses: source.pauses, within: source.duration)`.
    /// With no pauses the union is the input, so today's tracks and the pinned no-cuts hash are
    /// unchanged.
    public var removed: Cuts { fatalError("not implemented") }
}

extension Editor {
    /// For the strip: the pauses, drawn with their own hatch and a "paused" caption, not
    /// selectable, not resizable, not restorable. `cuts` stays the user's list. `Selection` gains
    /// no case, so Delete cannot reach a pause.
    public var pauses: [TimeRange] { fatalError("not implemented") }
}

// What the user sees:
// - The strip shows the pause as a removed region in a second style. Dragging a cut across it
//   works and the union merges; restoring that cut leaves the pause.
// - Scrubbing into a pause lands on its end, as for a cut (the map collapses it).
// - The transport label's duration excludes pauses, matching the clock they saw while recording.
// - `osrec inspect --timeline` lists pauses beside cuts.
