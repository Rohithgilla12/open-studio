import Foundation

/// One removed range of the recording. A trim is a cut that touches 0 or the duration, so there is
/// one list and one set of rules for both.
public struct Cut: Sendable, Hashable, Codable, Identifiable {
    /// Stable across edge drags, so SwiftUI keeps the dragged view (and its gesture) alive while
    /// `range.start` changes.
    public var id: UUID
    public var range: TimeRange

    public init(id: UUID = UUID(), range: TimeRange) {
        self.id = id
        self.range = range
    }
}

/// What the user removed, in recording time. Edit state, owned by `Edits`; `TimeMap` is derived
/// from it and nothing stores the map.
///
/// Invariants, held by `init(validating:within:)` and by every total edit below:
/// - cuts are sorted by start and disjoint;
/// - every kept span (before the first cut, between two cuts, after the last) that exists is at
///   least `minimumKept` long, so two cuts never touch and a sliver never survives;
/// - at least one kept span exists, so a cut that leaves nothing cannot be represented.
///
/// Like `ZoomTrack`, the duration is passed to each edit rather than stored, so the file shape is
/// the bare array and the nearest example in the codebase is the right one to copy.
public struct Cuts: Sendable, Hashable {
    public let cuts: [Cut]

    /// Long enough for the audio dip on both sides of a join (2 x 30 ms, measured as the shortest
    /// ramp that reaches silence) plus several frames at 60 fps.
    public static let minimumKept = RecordingTime.milliseconds(200)

    public static let none = Cuts(sorted: [])

    public var isEmpty: Bool { cuts.isEmpty }

    public init(validating cuts: [Cut], within duration: RecordingTime) throws(CutsError) {
        // TODO: sort by start; reject a range outside [0, duration] (.outsideRecording), an overlap
        // or a kept span shorter than minimumKept (.keptTooShort(after:)), no kept span at all
        // (.nothingKept), and a repeated id (.duplicateID).
        fatalError("not implemented")
    }

    init(sorted cuts: [Cut]) { self.cuts = cuts }

    public enum End: Sendable, Hashable {
        case start, end
    }

    /// Where the take begins and ends after trimming.
    public func trimmed(within duration: RecordingTime) -> ClosedRange<RecordingTime> {
        fatalError("not implemented")
    }

    public func cut(containing t: RecordingTime) -> Cut? {
        cuts.first { $0.range.contains(t) }
    }
}

/// Every edit is total: it clamps or merges instead of throwing, and returns the cuts unchanged
/// when it cannot keep the invariants. `init(validating:within:)` stays the only throwing door.
extension Cuts {
    /// Removes `range`. Overlapping cuts, and cuts that would leave less than `minimumKept`
    /// between them, merge into one that keeps the earliest id. The returned id is the cut that
    /// now covers `range`. Unchanged (nil) when the result would keep nothing.
    public func cutting(_ range: TimeRange, within duration: RecordingTime) -> (cuts: Cuts, id: Cut.ID)? {
        // TODO: clamp range to [0, duration]; union with every cut whose range lies within
        // minimumKept of it; also absorb a kept span at the head or tail shorter than minimumKept;
        // nil if no kept span remains.
        fatalError("not implemented")
    }

    /// Moves the take's start or end to `t`: the head cut becomes [0, t) and the tail cut
    /// [t, duration). Clamped so the first or last kept span keeps `minimumKept`. A trim back to 0
    /// or to the duration removes that cut.
    public func trimming(_ end: End, to t: RecordingTime, within duration: RecordingTime) -> Cuts {
        fatalError("not implemented")
    }

    /// Drags one edge of a cut. Clamped so the kept spans on both sides keep `minimumKept`; an edge
    /// dragged onto the recording's start or end turns the cut into a trim.
    public func resizing(_ id: Cut.ID, edge: End, to t: RecordingTime, within duration: RecordingTime) -> Cuts {
        fatalError("not implemented")
    }

    /// Puts the cut's range back. Unchanged when `id` is absent.
    public func restoring(_ id: Cut.ID) -> Cuts {
        Cuts(sorted: cuts.filter { $0.id != id })
    }
}

public enum CutsError: Error, Sendable, Equatable {
    case outsideRecording(UUID)
    /// The kept span after this cut (or before the first cut, when nil) is shorter than `minimumKept`.
    case keptTooShort(after: UUID?)
    case nothingKept
    case duplicateID(UUID)
}
