import AVFoundation
import Timeline

/// A playing, scrubbable preview of a project. Wraps `AVPlayer` so the app never touches
/// AVFoundation: it binds `player` to a `VideoPlayer` view, calls `seek`, and calls `apply(edit:)`.
///
/// Built once per (project, output format). An edit that keeps the output format is a box swap and
/// reaches the next rendered frame without touching the player. A change of output size or frame
/// rate changes the composition's render size, which AVFoundation treats as a new composition, so
/// the app builds a new `Preview` for that one (rare) action.
@MainActor
public final class Preview {
    public let player: AVPlayer
    public let duration: RecordingTime
    private let box: PlanBox
    private let project: Project
    private let item: AVPlayerItem

    public init(project: Project) throws(PreviewError) {
        // TODO: plan = RenderPlan(project, project.edit); box = PlanBox(plan)
        //   item = AVPlayerItem(asset: project.asset.composition)
        //   item.videoComposition = RenderComposition.make(plan: box, asset:, frameRate: edit.output.frameRate)
        //   player = AVPlayer(playerItem: item); player.automaticallyWaitsToMinimizeStalling = false
        fatalError("not implemented")
    }

    /// Replaces the plan the compositor reads. Returns false when `edit.output` differs from the
    /// one this preview was built for, in which case the caller builds a new `Preview`.
    @discardableResult
    public func apply(edit: EditDocument) -> Bool { fatalError("not implemented") }

    /// Exact seek (zero tolerance) so the strip's playhead and the picture agree.
    public func seek(to t: RecordingTime) { fatalError("not implemented") }

    public func play() { player.play() }
    public func pause() { player.pause() }

    /// Current playhead on the recording clock, for the strip. Driven by a periodic time observer.
    public var playhead: AsyncStream<RecordingTime> { fatalError("not implemented") }
}

public enum PreviewError: Error, Sendable {
    case invalidZooms(ZoomTrackError)
}
