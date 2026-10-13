import Foundation

/// Generates `followClicks` zoom segments from clicks. Runs once at project creation and
/// whenever the user asks to regenerate; the result lives in `Project.zooms` and is
/// edited from there, so this never runs per frame.
public enum AutoZoom {
    public struct Settings: Sendable, Equatable {
        public var before: Duration = .milliseconds(300)
        public var after: Duration = .milliseconds(2500)
        public var mergeGap: Duration = .milliseconds(2500)
        public var scale: Double = 2
        /// Clicks this close to the end are ignored: there is no time to zoom out again.
        public var ignoreClicksWithin: Duration = .milliseconds(1000)
        /// Segments never extend past `duration - endMargin`.
        public var endMargin: Duration = .milliseconds(800)
        public init() {}
    }

    /// Pure. Output is sorted and non-overlapping by construction, so wrapping it in a
    /// `ZoomTrack` cannot fail.
    public static func segments(
        clicks: [Click],
        duration: Duration,
        settings: Settings = Settings()
    ) -> ZoomTrack {
        // TODO:
        // windows = clicks
        //   .filter { $0.time < duration - ignoreClicksWithin }
        //   .map { max($0.time - before, 1 ms) ..< min($0.time + after, duration - endMargin) }
        //   (both mouseDown time and release time count as click instants: iterate Click.time
        //    and Click.release so a held button extends the window, matching the observed behaviour)
        //   .sorted(by: lowerBound)
        // merged = []
        // for w in windows:
        //   if let last = merged.last, last.upperBound + mergeGap >= w.lowerBound:
        //       merged[last].upperBound = max(last.upperBound, w.upperBound)
        //   else: merged.append(w)
        // return ZoomTrack(validating: merged.map { ZoomSegment(id: UUID(), range: $0, scale:, target: .followClicks) })
        fatalError("not implemented")
    }
}
