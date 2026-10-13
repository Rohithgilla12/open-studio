import Foundation

/// A span of the recording during which the camera is zoomed in.
///
/// Zoom segments are edit state: generated once when a project is created, then owned and edited by
/// the editor. `Timeline` takes them as input and never generates them itself, so a user's edits are
/// never silently replaced.
public struct ZoomSegment: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var range: TimeRange
    /// Camera scale while the segment is active. 2 for generated segments.
    public var scale: Double
    public var focus: Focus

    public enum Focus: Sendable, Hashable, Codable {
        /// Follow the time-weighted centroid of pointer groups inside the segment.
        case followPointer
        /// Hold on a fixed point, normalized to the frame (0...1, origin top-left).
        case fixed(x: Double, y: Double)
    }

    public init(id: UUID = UUID(), range: TimeRange, scale: Double, focus: Focus) {
        self.id = id; self.range = range; self.scale = scale; self.focus = focus
    }
}

public enum AutoZoom {
    /// The automatic segments for a recording, sorted and non-overlapping.
    public static func segments(
        for source: SourceRecording,
        settings: AutoZoomSettings = AutoZoomSettings()
    ) -> [ZoomSegment] {
        segments(clickTimes: source.buttons.map(\.time), duration: source.duration, settings: settings)
    }

    /// Pure core, exposed for tests and for the editor's "regenerate zooms" action.
    ///
    /// Generated ids are derived from the segment's range (a UUID built from start and end), not
    /// random, so generating twice from the same input yields equal arrays.
    public static func segments(
        clickTimes: [RecordingTime],
        duration: RecordingTime,
        settings: AutoZoomSettings
    ) -> [ZoomSegment] {
        // TODO:
        // let lastAllowed = duration - settings.ignoreClicksInFinal
        // let latestEnd = duration - settings.endMargin
        // windows = clickTimes
        //   .filter { $0 < lastAllowed }
        //   .compactMap { t in TimeRange(start: max(t - before, 1 ms), end: min(t + after, latestEnd)) }
        //   // compactMap: a click near the end can clamp to an empty window; TimeRange's failable init
        //   // drops it without a special case.
        //   .sorted { $0.start < $1.start }
        //
        // Merge in one pass. After sorting by start, a window can only merge with the most recent
        // merged segment: any earlier merged segment ends before the most recent one starts minus
        // mergeGap (otherwise they would already have merged), and starts only grow. So the observed
        // "merge repeatedly until stable" reaches the same fixed point as this single sweep.
        //
        // var merged: [TimeRange] = []
        // for w in windows {
        //   if let last = merged.last, w.start - last.end <= mergeGap {
        //     merged[merged.count - 1] = TimeRange(start: last.start, end: max(last.end, w.end))!
        //   } else {
        //     merged.append(w)
        //   }
        // }
        // return merged.map { ZoomSegment(id: stableID($0), range: $0, scale: settings.scale, focus: .followPointer) }
        fatalError("not implemented")
    }
}
