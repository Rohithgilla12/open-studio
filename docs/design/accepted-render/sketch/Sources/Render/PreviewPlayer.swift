import AVFoundation
import Foundation
import Timeline

/// Plays a project with its edits applied. Owns the rule for getting an edit onto the screen, so
/// no view has to know it: build a new scene, swap the item's video composition, and redraw the
/// current frame if paused. The player and item are never rebuilt.
@MainActor
public final class PreviewPlayer {
    /// For an `AVPlayerLayer`. Callers drive transport through the methods below, not this.
    public let player: AVPlayer

    private let item: AVPlayerItem
    private let movie: MovieComposition
    private var scene: RenderScene
    private var pending: Project?
    private var applyTask: Task<Void, Never>?

    /// Edits arriving faster than this are coalesced, latest wins. A zoom drag emits an edit per
    /// mouse event; each swap makes AVFoundation drop its rendered-ahead frames.
    static let editInterval: Duration = .milliseconds(33)

    public init(project: Project) async throws(RenderError) {
        // TODO:
        //   movie = try await MovieComposition.load(project.source)
        //   scene = try RenderScene.make(project: project, format: project.edits.format, reusing: nil)
        //   item = AVPlayerItem(asset: movie.asset)
        //   item.videoComposition = movie.videoComposition(scene: scene, frameRate: project.edits.format.frameRate)
        //   player = AVPlayer(playerItem: item); player.actionAtItemEnd = .pause
        fatalError("not implemented")
    }

    /// Shows `project`'s current edits. Cheap to call on every change.
    public func show(_ project: Project) {
        // TODO (edit propagation):
        //   pending = project
        //   guard applyTask == nil else { return }               // one apply loop at a time
        //   applyTask = Task {
        //     while let next = pending {
        //       pending = nil
        //       scene = try RenderScene.make(project: next, format: next.edits.format, reusing: scene)
        //       item.videoComposition = movie.videoComposition(scene: scene, frameRate: next.edits.format.frameRate)
        //       if player.rate == 0 { refreshCurrentFrame() }
        //       try? await Task.sleep(for: Self.editInterval)
        //     }
        //     applyTask = nil
        //   }
        // A scene build failure (an unreadable background image) keeps the previous scene and
        // surfaces through `lastError`; the preview never goes blank.
        fatalError("not implemented")
    }

    public private(set) var lastError: RenderError?

    public func play() { player.play() }
    public func pause() { player.pause() }

    /// Frame-accurate scrubbing with seek chasing: while a seek is in flight, only the latest
    /// requested time is kept and issued when it lands (the Apple QA1820 pattern), so dragging
    /// the playhead never queues a backlog of seeks.
    public func scrub(to t: RecordingTime) {
        fatalError("not implemented")
    }

    /// Playhead updates for the transport and the zoom strip, at display rate while playing.
    public func playhead() -> AsyncStream<RecordingTime> {
        fatalError("not implemented")
    }

    private func refreshCurrentFrame() {
        // Open question 1: whether a paused AVPlayer recomposes on a videoComposition swap by
        // itself. If it does, this exact zero-tolerance seek to the current time is deleted.
        fatalError("not implemented")
    }
}
