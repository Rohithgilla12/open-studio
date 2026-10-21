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
/// the bare array.
public struct Cuts: Sendable, Hashable {
    public let cuts: [Cut]

    /// Long enough for the audio dip on both sides of a join (2 x 30 ms, measured as the shortest
    /// ramp that reaches silence) plus several frames at 60 fps.
    public static let minimumKept = RecordingTime.milliseconds(200)

    public static let none = Cuts(sorted: [])

    public var isEmpty: Bool { cuts.isEmpty }

    public init(validating cuts: [Cut], within duration: RecordingTime) throws(CutsError) {
        let sorted = cuts.sorted { $0.range.start < $1.range.start }
        for cut in sorted where cut.range.start < .zero || cut.range.end > duration {
            throw .outsideRecording(cut.id)
        }
        for (earlier, later) in zip(sorted, sorted.dropFirst()) where later.range.start < earlier.range.end {
            throw .overlap(earlier.id, later.id)
        }
        var ids: Set<UUID> = []
        for cut in sorted where !ids.insert(cut.id).inserted {
            throw .duplicateID(cut.id)
        }
        guard !Self.keptSpans(of: sorted, within: duration).isEmpty else { throw .nothingKept }
        if let first = sorted.first, first.range.start > .zero, first.range.start < Self.minimumKept {
            throw .keptTooShort(after: nil)
        }
        for (earlier, later) in zip(sorted, sorted.dropFirst()) where later.range.start - earlier.range.end < Self.minimumKept {
            throw .keptTooShort(after: earlier.id)
        }
        if let last = sorted.last, last.range.end < duration, duration - last.range.end < Self.minimumKept {
            throw .keptTooShort(after: last.id)
        }
        self.init(sorted: sorted)
    }

    init(sorted cuts: [Cut]) { self.cuts = cuts }

    public enum End: Sendable, Hashable {
        case start, end
    }

    /// Where the take begins and ends after trimming.
    public func trimmed(within duration: RecordingTime) -> ClosedRange<RecordingTime> {
        let start = cuts.first.map { $0.range.start == .zero ? $0.range.end : .zero } ?? .zero
        let end = cuts.last.map { $0.range.end == duration ? $0.range.start : duration } ?? duration
        return start...max(start, end)
    }

    public func cut(containing t: RecordingTime) -> Cut? {
        cuts.first { $0.range.contains(t) }
    }

    /// The complement of the cuts in `[0, duration)`, in order. The only place "kept" is derived
    /// from "cut"; `TimeMap` reads it.
    static func keptSpans(of sorted: [Cut], within duration: RecordingTime) -> [TimeRange] {
        var spans: [TimeRange] = []
        var start = RecordingTime.zero
        for cut in sorted {
            if let span = TimeRange(start: start, end: cut.range.start) { spans.append(span) }
            start = cut.range.end
        }
        if let span = TimeRange(start: start, end: duration) { spans.append(span) }
        return spans
    }

    func keptSpans(within duration: RecordingTime) -> [TimeRange] { Self.keptSpans(of: cuts, within: duration) }
}

/// Every edit is total: it clamps or merges instead of throwing, and returns the cuts unchanged
/// when it cannot keep the invariants. `init(validating:within:)` stays the only throwing door.
extension Cuts {
    /// Removes `range`. Overlapping cuts, and cuts that would leave less than `minimumKept`
    /// between them, merge into one that keeps the earliest id. A kept sliver at the head or tail
    /// is absorbed. The returned id is the cut that now covers `range`. nil when the result would
    /// keep nothing.
    public func cutting(_ range: TimeRange, within duration: RecordingTime) -> (cuts: Cuts, id: Cut.ID)? {
        guard let clamped = TimeRange(start: max(range.start, .zero), end: min(range.end, duration)) else { return nil }
        var start = clamped.start
        var end = clamped.end
        var id: Cut.ID?
        var remaining: [Cut] = []
        for cut in cuts {
            if cut.range.end + Self.minimumKept > start, cut.range.start - Self.minimumKept < end {
                start = min(start, cut.range.start)
                end = max(end, cut.range.end)
                if id == nil { id = cut.id }
            } else {
                remaining.append(cut)
            }
        }
        if start < Self.minimumKept { start = .zero }
        if duration - end < Self.minimumKept { end = duration }
        guard start > .zero || end < duration else { return nil }
        let merged = Cut(id: id ?? UUID(), range: TimeRange(start: start, end: end)!)
        remaining.insert(merged, at: remaining.firstIndex { $0.range.start > start } ?? remaining.count)
        return (Cuts(sorted: remaining), merged.id)
    }

    /// Moves the take's start or end to `t`: the head cut becomes [0, t) and the tail cut
    /// [t, duration). Clamped so the first or last kept span keeps `minimumKept` before the next
    /// cut. A trim back to 0 or to the duration removes that cut.
    public func trimming(_ end: End, to t: RecordingTime, within duration: RecordingTime) -> Cuts {
        switch end {
        case .start:
            let others = cuts.filter { $0.range.start != .zero }
            let limit = (others.first?.range.start ?? duration) - Self.minimumKept
            let t = t.clamped(to: .zero...max(limit, .zero))
            guard let range = TimeRange(start: .zero, end: t) else { return Cuts(sorted: others) }
            let id = cuts.first { $0.range.start == .zero }?.id ?? UUID()
            return Cuts(sorted: [Cut(id: id, range: range)] + others)
        case .end:
            let others = cuts.filter { $0.range.end != duration }
            let limit = (others.last?.range.end ?? .zero) + Self.minimumKept
            let t = t.clamped(to: min(limit, duration)...duration)
            guard let range = TimeRange(start: t, end: duration) else { return Cuts(sorted: others) }
            let id = cuts.last { $0.range.end == duration }?.id ?? UUID()
            return Cuts(sorted: others + [Cut(id: id, range: range)])
        }
    }

    /// Drags one edge of a cut. Clamped so the kept spans on both sides keep `minimumKept`; an edge
    /// dragged within `minimumKept` of the recording's start or end snaps to it, turning the cut
    /// into a trim.
    public func resizing(_ id: Cut.ID, edge: End, to t: RecordingTime, within duration: RecordingTime) -> Cuts {
        guard let index = cuts.firstIndex(where: { $0.id == id }) else { return self }
        let range = cuts[index].range
        let previous = index > 0 ? cuts[index - 1] : nil
        let next = index + 1 < cuts.count ? cuts[index + 1] : nil
        let resized: TimeRange?
        switch edge {
        case .start:
            let lower = previous.map { $0.range.end + Self.minimumKept } ?? .zero
            let start = previous == nil && t < Self.minimumKept ? .zero : max(t, lower)
            resized = TimeRange(start: start, end: range.end)
        case .end:
            let upper = next.map { $0.range.start - Self.minimumKept } ?? duration
            let end = next == nil && duration - t < Self.minimumKept ? duration : min(t, upper)
            resized = TimeRange(start: range.start, end: end)
        }
        guard let resized, resized.start > .zero || resized.end < duration else { return self }
        var all = cuts
        all[index].range = resized
        return Cuts(sorted: all)
    }

    /// Puts the cut's range back. Unchanged when `id` is absent.
    public func restoring(_ id: Cut.ID) -> Cuts {
        Cuts(sorted: cuts.filter { $0.id != id })
    }
}

public enum CutsError: Error, Sendable, Equatable {
    case outsideRecording(UUID)
    /// `second` starts before `first` ends.
    case overlap(UUID, UUID)
    /// The kept span after this cut (or before the first cut, when nil) is shorter than `minimumKept`.
    case keptTooShort(after: UUID?)
    case nothingKept
    case duplicateID(UUID)
}
