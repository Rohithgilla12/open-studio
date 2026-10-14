import Foundation

/// Every edit the zoom strip can make. Each is total: it clamps instead of throwing, so the editor
/// never holds a rejected edit, and `init(validating:)` stays the only throwing door.
///
/// A segment keeps at least `minimumSegmentDuration` and stays between its neighbours and inside
/// `[0, duration]`. An edit that cannot satisfy that returns the track unchanged.
extension ZoomTrack {
    public static let minimumSegmentDuration = RecordingTime.milliseconds(200)

    public enum Edge: Sendable, Hashable {
        case start, end
    }

    /// Unchanged when `id` is absent.
    public func removing(_ id: ZoomSegment.ID) -> ZoomTrack {
        ZoomTrack(sorted: segments.filter { $0.id != id })
    }

    /// Moves the segment so it starts at `start`, keeping its duration. Clamped to the gap between
    /// its neighbours and to `[0, duration]`.
    public func moving(_ id: ZoomSegment.ID, toStart start: RecordingTime, within duration: RecordingTime) -> ZoomTrack {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return self }
        let gap = gap(around: index, within: duration)
        let length = segments[index].range.duration
        guard gap.upperBound - gap.lowerBound >= length else { return self }
        let newStart = start.clamped(to: gap.lowerBound...(gap.upperBound - length))
        return replacing(index, range: TimeRange(start: newStart, end: newStart + length)!)
    }

    /// Drags one edge to `t`. The other edge stays put.
    public func resizing(_ id: ZoomSegment.ID, edge: Edge, to t: RecordingTime, within duration: RecordingTime) -> ZoomTrack {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return self }
        let gap = gap(around: index, within: duration)
        let range = segments[index].range
        let minimum = Self.minimumSegmentDuration
        switch edge {
        case .start:
            guard range.end - minimum >= gap.lowerBound else { return self }
            let start = t.clamped(to: gap.lowerBound...(range.end - minimum))
            return replacing(index, range: TimeRange(start: start, end: range.end)!)
        case .end:
            guard range.start + minimum <= gap.upperBound else { return self }
            let end = t.clamped(to: (range.start + minimum)...gap.upperBound)
            return replacing(index, range: TimeRange(start: range.start, end: end)!)
        }
    }

    /// Inserts a segment of `length` centred on `t`, shrunk to fit the gap `t` lands in. Returns
    /// nil when `t` is inside an existing segment or the gap is shorter than
    /// `minimumSegmentDuration`.
    public func inserting(around t: RecordingTime, length: RecordingTime, scale: Double, within duration: RecordingTime)
        -> (track: ZoomTrack, id: ZoomSegment.ID)?
    {
        guard duration > .zero else { return nil }
        let t = t.clamped(to: .zero...duration)
        guard !segments.contains(where: { $0.range.contains(t) }) else { return nil }
        let lower = segments.last(where: { $0.range.end <= t })?.range.end ?? .zero
        let upper = segments.first(where: { $0.range.start > t })?.range.start ?? duration
        let fitted = min(max(length, Self.minimumSegmentDuration), upper - lower)
        guard fitted >= Self.minimumSegmentDuration else { return nil }
        let half = RecordingTime(microseconds: fitted.microseconds / 2)
        let start = (t - half).clamped(to: lower...(upper - fitted))
        let segment = ZoomSegment(
            range: TimeRange(start: start, end: start + fitted)!, scale: scale >= 1 ? scale : 1, focus: .followPointer)
        var all = segments
        all.insert(segment, at: all.firstIndex(where: { $0.range.start > start }) ?? all.count)
        return (ZoomTrack(sorted: all), segment.id)
    }

    /// Scale is clamped to at least 1, so the `scaleBelowOne` invariant holds without a throw.
    public func updating(_ id: ZoomSegment.ID, scale: Double? = nil, focus: ZoomSegment.Focus? = nil) -> ZoomTrack {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return self }
        var all = segments
        if let scale { all[index].scale = scale >= 1 ? scale : 1 }
        if let focus { all[index].focus = focus }
        return ZoomTrack(sorted: all)
    }

    /// The times the segment at `index` may occupy: from its predecessor's end to its successor's
    /// start, inside `[0, duration]`.
    private func gap(around index: Int, within duration: RecordingTime) -> ClosedRange<RecordingTime> {
        let lower = index > 0 ? segments[index - 1].range.end : .zero
        let upper = index + 1 < segments.count ? segments[index + 1].range.start : max(duration, lower)
        return lower...upper
    }

    /// Order is unchanged, because the new range stays inside the same gap, so `sorted` still holds.
    private func replacing(_ index: Int, range: TimeRange) -> ZoomTrack {
        var all = segments
        all[index].range = range
        return ZoomTrack(sorted: all)
    }
}
