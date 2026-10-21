import AVFoundation
import Foundation
import Timeline

/// Plays a project with its edits applied. Owns the rule for getting an edit onto the screen, so
/// no view has to know it. The player and item are never rebuilt.
@MainActor
public final class PreviewPlayer {
    /// For an `AVPlayerLayer`. Callers drive transport through the methods below, not this.
    public let player: AVPlayer

    let item: AVPlayerItem
    private let movie: MovieComposition
    private var scene: RenderScene
    private var picture: Edits
    private var audio: AudioLevels
    private var pending: Project?
    private var applyTask: Task<Void, Never>?
    private var seekInFlight = false
    private var seekTarget: RecordingTime?

    /// Edits arriving faster than this are coalesced, latest wins. A zoom drag emits an edit per
    /// mouse event; each swap makes AVFoundation drop its rendered-ahead frames.
    static let editInterval: Duration = .milliseconds(33)

    /// A scene build failure (an unreadable background image) keeps the previous scene and
    /// surfaces here; the preview never goes blank.
    public private(set) var lastError: RenderError?

    public init(project: Project) async throws(RenderError) {
        movie = MovieComposition(media: try await SourceMedia.load(project.source), map: project.timeline.map)
        scene = try RenderScene.make(project: project, format: project.edits.format, reusing: nil)
        item = AVPlayerItem(asset: movie.asset)
        item.videoComposition = movie.videoComposition(scene: scene, frameRate: project.edits.format.frameRate)
        picture = Self.picture(of: project.edits)
        audio = project.edits.audio
        item.audioMix = movie.audioMix(audio)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
    }

    /// Shows `project`'s current edits. Cheap to call on every change.
    public func show(_ project: Project) {
        pending = project
        guard applyTask == nil else { return }
        applyTask = Task { [self] in
            while let next = pending {
                pending = nil
                await apply(next)
                try? await Task.sleep(for: Self.editInterval)
            }
            applyTask = nil
        }
    }

    private func apply(_ project: Project) async {
        if project.edits.audio != audio {
            audio = project.edits.audio
            item.audioMix = movie.audioMix(audio)
        }
        let picture = Self.picture(of: project.edits)
        guard picture != self.picture else { return }
        // A style change re-renders and dithers the backdrop (about 8 million pixels at 4K), so
        // the scene is built off the main actor.
        let previous = scene
        let built = await Task.detached {
            Result { () throws(RenderError) -> RenderScene in
                try RenderScene.make(project: project, format: project.edits.format, reusing: previous)
            }
        }.value
        switch built {
        case .success(let next):
            scene = next
            self.picture = picture
            lastError = nil
        case .failure(let error):
            lastError = error
            return
        }
        // Measured (rationale, open question 1): a paused item composes its current frame again
        // on its own within 300 ms of the swap, so no seek is needed to show the edit.
        item.videoComposition = movie.videoComposition(scene: scene, frameRate: project.edits.format.frameRate)
    }

    private static func picture(of edits: Edits) -> Edits {
        var picture = edits
        picture.audio = .default
        return picture
    }

    public func play() { player.play() }
    public func pause() { player.pause() }

    /// Frame-accurate scrubbing with seek chasing: while a seek is in flight, only the latest
    /// requested time is kept and issued when it lands (the Apple QA1820 pattern), so dragging
    /// the playhead never queues a backlog of seeks.
    public func scrub(to t: RecordingTime) {
        seekTarget = t
        guard !seekInFlight else { return }
        issuePendingSeek()
    }

    private func issuePendingSeek() {
        guard let target = seekTarget else { return }
        seekTarget = nil
        seekInFlight = true
        player.seek(to: target.mediaTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                seekInFlight = false
                issuePendingSeek()
            }
        }
    }

    /// Playhead updates for the transport and the zoom strip, at display rate while playing.
    public func playhead() -> AsyncStream<RecordingTime> {
        AsyncStream { continuation in
            let observer = Observer(token: player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 60), queue: .main
            ) { time in
                continuation.yield(RecordingTime(microseconds: OutputTime(compositionTime: time).microseconds))
            })
            continuation.onTermination = { [player] _ in
                player.removeTimeObserver(observer.token)
            }
        }
    }

    /// The opaque observer token is `Any`, which the termination closure cannot capture otherwise.
    private struct Observer: @unchecked Sendable {
        let token: Any
    }
}
