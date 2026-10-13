import RecordingFormat

enum AutoZoom {
    /// Pure. `clicks` are button .down and .up times (the teardown counts both, which widens
    /// each click's window by the press duration). Order does not matter; the function sorts.
    static func segments(clicks: [RecordingTime], duration: RecordingTime,
                         settings: TimelineSettings.AutoZoom) -> [ZoomSegment] {
        // TODO:
        //  cutoff = duration - ignoreClicksInLast
        //  windows = clicks.filter { $0 < cutoff }
        //      .map { (max($0 - lead, minimumStart), min($0 + tail, duration - endInset)) }
        //      .sorted by start
        //  merged = []
        //  for w in windows:
        //      if let last = merged.last, w.start - last.end <= mergeGap  { last.end = max(last.end, w.end) }
        //      else { merged.append(w) }
        //  A single left-to-right pass over start-sorted windows is the fixed point of
        //  "merge repeatedly": a later window can never reach back past an earlier start.
        //  return merged.map { ZoomSegment(id: .auto(start), range:, scale:, focus: .followPointer, origin: .automatic) }
        fatalError("not implemented")
    }
}

/// Pointer samples, normalised and cleaned once at Timeline.init.
struct TimelineSource: Sendable {
    let pointer: [NormalizedSample]
    let clickTimes: [RecordingTime]
    let pressIntervals: [TimeRange]
    let keyTimes: [RecordingTime]
    let displayPixelSize: RecordingManifest.Size

    struct NormalizedSample: Sendable { var time: RecordingTime; var position: NormalizedPoint; var onDisplay: Bool }

    init(_ recording: LoadedRecording) { fatalError("not implemented") }

    /// Thin to `distance` px, then drop out-and-back jumps larger than `shakeThreshold` px
    /// (Manhattan). A point is a shake if it jumps away and the next point jumps back to
    /// within `distance` of the one before.
    func cleanedForCamera(_ s: TimelineSettings.Camera) -> [NormalizedSample] { fatalError("not implemented") }
}

enum FocusGrouping {
    struct Group: Sendable { var start: RecordingTime; var center: NormalizedPoint }

    /// Greedy in time order over `samples` inside `range`.
    static func groups(samples: [TimelineSource.NormalizedSample], range: TimeRange,
                       scale: Double, extentFraction: Double) -> [Group] {
        // TODO:
        //  maxExtent = extentFraction / scale     (normalised units, per axis)
        //  open group with first sample; for each next sample s:
        //      box' = box.union(s.position)
        //      if box'.width > maxExtent || box'.height > maxExtent  { close group, open new at s }
        //      else extend
        //  centre of a group: weighted mean of positions, weight_i = time until sample i+1
        //      (last sample of a group is weighted until the group's end = next group start or range.end)
        //  Group.start = time of its first sample, but the first group starts at range.start
        //  so the camera has a target from the first instant of the zoom.
        //  A zoom with no samples inside: one group at the last known pointer position before range.start.
        //  Centres are clamped so visibleRect (1/scale wide) stays inside 0...1.
        fatalError("not implemented")
    }
}

enum TypingActivity {
    /// Intervals during which the cursor should be faded. A burst is any run where >= minKeys
    /// keyDowns fall inside `window`. The interval runs from the earliest key of the first
    /// qualifying run to lastKey + window. Overlapping intervals merge.
    static func intervals(keys: [RecordingTime], minKeys: Int, window: RecordingTime) -> [TimeRange] {
        // TODO: sliding window of size minKeys over sorted keys: if keys[i+minKeys-1] - keys[i] <= window,
        // the run qualifies; extend through following keys while each is within `window` of the previous.
        fatalError("not implemented")
    }
}
