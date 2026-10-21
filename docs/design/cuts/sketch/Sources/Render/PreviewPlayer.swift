import AVFoundation
import QuartzCore
import Timeline

/// Plays a project with its edits applied. Owns the rule for getting any edit onto the screen,
/// including one that changes the composition's timeline, so no view knows it.
///
/// The player is never rebuilt; the item is replaced when the cuts change, and only then. Every
/// item is paired with the map it was built for (`movie.map`), and every conversion between the
/// clocks the player does uses that pair, so a playhead tick from the old item is never read with
/// the new map during the 33 ms coalescing window.
@MainActor
public final class PreviewPlayer {
    /// Hosts the picture. A layer rather than the `AVPlayer`, so callers cannot drive transport
    /// around these methods, and so a second, double-buffered player can be added behind it
    /// without a caller change if replacing the item shows a blank frame (open question 1).
    public let surface: CALayer

    public private(set) var isPlaying = false
    public private(set) var lastError: RenderError?

    private let player: AVPlayer
    private let playerLayer: AVPlayerLayer
    private let media: SourceMedia
    private var movie: MovieComposition
    private var item: AVPlayerItem
    private var scene: RenderScene
    private var pending: (project: Project, landing: RecordingTime?)?
    private var applyTask: Task<Void, Never>?

    static let editInterval: Duration = .milliseconds(33)

    public init(project: Project) async throws(RenderError) {
        fatalError("not implemented")
    }

    /// Shows `project`'s current edits. Cheap to call on every change; coalesced, latest wins.
    ///
    /// - When only picture or audio edits changed: today's path, swap `videoComposition` or
    ///   `audioMix` on the same item.
    /// - When the cuts changed: build `MovieComposition(media:map:)`, a new item with its video
    ///   composition and audio mix, `replaceCurrentItem`, seek with zero tolerance, and restore the
    ///   rate. Measured on the real 5 s 3456x2234 HEVC take, build to first decoded frame through
    ///   `AVPlayerItemVideoOutput`: 55 ms median, 56 ms p90 paused; 62 ms median, 106 ms p90
    ///   playing; 230 ms for the first replacement in the process. A zero-tolerance seek inside one
    ///   item costs 25 ms median on the same take, so the replacement adds about 30 ms.
    ///
    /// The seek lands on `landing` when given (the editor passes the edge being dragged), else on
    /// the recording instant under the playhead: `new.output(collapsing: old.recording(at: now))`.
    /// A playhead whose frame was just cut lands on the join, the first frame after the cut.
    public func show(_ project: Project, landingAt landing: RecordingTime? = nil) {
        fatalError("not implemented")
    }

    public func play() { fatalError("not implemented") }
    public func pause() { fatalError("not implemented") }

    /// Seek chasing as today. `t` is a strip position; inside a cut it lands on the join.
    public func scrub(to t: RecordingTime) {
        // TODO: target = movie.map.output(collapsing: t); today's QA1820 chase on target.
        fatalError("not implemented")
    }

    /// Playhead in both clocks, at display rate while playing, converted with the map of the item
    /// that is playing.
    public func playhead() -> AsyncStream<Playhead> {
        fatalError("not implemented")
    }
}
