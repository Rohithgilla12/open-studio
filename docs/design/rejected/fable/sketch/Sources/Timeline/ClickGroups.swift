/// Where the camera looks while a `followClicks` segment is active. Computed once per
/// segment when a `Sampler` is built; the per-frame camera target is then a binary
/// search over `ClickGroup.range`.
struct ClickGroup: Sendable, Equatable {
    var range: Range<Duration>
    /// Time-weighted centroid: each sample weighs the time until the next sample, so a
    /// cursor that rests somewhere pulls the camera there.
    var centroid: Point
    var bounds: Rect
}

enum ClickGroups {
    /// Samples considered are mouse moves and click positions inside `segment.range`,
    /// merged in time order.
    static func build(
        samples: [MouseSample],
        in segment: ZoomSegment,
        displaySize: Size,
        settings: CameraSettings
    ) -> [ClickGroup] {
        // TODO:
        // viewport = displaySize / segment.scale
        // limit = viewport * settings.groupBoundsFraction
        // kept = thin(shakeFiltered(samples), settings.thinningDistance)
        // groups = []; current = nil
        // for (i, s) in kept.enumerated():
        //   weight = (kept[i+1]?.time ?? segment.range.upperBound) - s.time
        //   if current == nil: current = open(at: s)
        //   else if current.bounds.union(s.position) exceeds limit in either axis:
        //        close current (range ends at s.time); groups.append; current = open(at: s)
        //   accumulate weighted centroid
        // close last at segment.range.upperBound
        // if groups.isEmpty: one group covering the segment, centroid = last known mouse
        //   position before the segment (or display centre)
        fatalError("not implemented")
    }

    /// Drops any sample whose Manhattan distance from both neighbours exceeds `threshold`:
    /// a jump that immediately returns is a glitch. Also applied to the cursor track.
    static func shakeFiltered(_ samples: [MouseSample], threshold: Double) -> [MouseSample] {
        fatalError("not implemented")
    }

    static func thin(_ samples: [MouseSample], minimumDistance: Double) -> [MouseSample] {
        fatalError("not implemented")
    }
}
