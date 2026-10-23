import AVFoundation
import Foundation
import QuartzCore
import Timeline

/// Plays a project with its edits applied. Owns the rule for getting any edit onto the screen,
/// including one that changes the composition's timeline, so no view knows it.
///
/// The player is never rebuilt. The item is replaced when the cuts change, and only then. Every
/// item is paired with the map it was built for (`movie.map`), and every conversion between the
/// clocks uses that pair and the current item's own time, so a tick from one item is never read
/// with another item's map.
@MainActor
public final class PreviewPlayer {
    /// Hosts the picture. A layer rather than the `AVPlayer`, so callers cannot drive transport
    /// around these methods, and so a second, double-buffered player could sit behind it without
    /// a caller change if replacing the item ever shows a blank frame.
    public var surface: CALayer { playerLayer }

    public var isPlaying: Bool { player.rate != 0 }

    /// A scene build failure (an unreadable background image) keeps the previous scene and
    /// surfaces here; the preview never goes blank.
    public private(set) var lastError: RenderError?

    let player: AVPlayer
    private(set) var item: AVPlayerItem
    private let playerLayer = AVPlayerLayer()
    private let media: SourceMedia
    private var movie: MovieComposition
    private var scene: RenderScene
    private var project: Project
    private var shown = Shown.edited
    private var pending: (project: Project, landing: RecordingTime?)?
    private(set) var applyTask: Task<Void, Never>?
    /// The target of the seek the current item is performing, and the latest target requested
    /// while it was, issued when it lands.
    private var inFlight: OutputTime?
    private var queued: OutputTime?

    /// Where the current item is, or is heading. A seek's target counts from the moment it is
    /// requested, so an edit or a tick during a landing never reads the new item's unseeked 0, and
    /// a tick the replaced item queued is never read with the new map.
    private var now: OutputTime { queued ?? inFlight ?? OutputTime(compositionTime: item.currentTime()) }

    /// Which item is up. `source` is the uncut take, shown only during a trim or cut-edge drag so
    /// each step is a seek instead of an item swap; `show` always returns to `edited`.
    private enum Shown {
        case edited
        case source
    }

    /// Edits arriving faster than this are coalesced, latest wins. A zoom drag emits an edit per
    /// mouse event; each swap makes AVFoundation drop its rendered-ahead frames. Tests set it to
    /// zero to land an edit inside the previous swap's landing seek.
    var editInterval: Duration = .milliseconds(33)

    public init(project: Project) async throws(RenderError) {
        media = try await SourceMedia.load(project.source)
        movie = MovieComposition(media: media, map: project.timeline.map)
        scene = try RenderScene.make(project: project, format: project.edits.format, reusing: nil)
        self.project = project
        item = Self.item(movie, scene: scene, edits: project.edits)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
    }

    private static func item(_ movie: MovieComposition, scene: RenderScene, edits: Edits) -> AVPlayerItem {
        let item = AVPlayerItem(asset: movie.asset)
        item.videoComposition = movie.videoComposition(scene: scene, frameRate: edits.format.frameRate)
        item.audioMix = movie.audioMix(edits.audio)
        return item
    }

    /// Shows `project`'s current edits. Cheap to call on every change; coalesced, latest wins.
    ///
    /// - When only picture or audio edits changed: swap `videoComposition` or `audioMix` on the
    ///   same item.
    /// - When the cuts changed, or the uncut item is up: build `MovieComposition(media:map:)`, a
    ///   new item with its video composition and audio mix, `replaceCurrentItem`, seek with zero
    ///   tolerance, and restore the rate. Measured on the real 5 s 3456x2234 HEVC take, build to
    ///   first decoded frame through `AVPlayerItemVideoOutput`: 55 ms median paused, 62 ms median
    ///   playing, 230 ms for the first replacement in the process. A zero-tolerance seek inside
    ///   one item costs 25 ms median on the same take, so the replacement adds about 30 ms.
    ///
    /// The seek lands on `landing` when given (the editor passes the edge being dragged), else on
    /// the recording instant under the playhead: `new.output(collapsing: old.recording(at: now))`.
    /// A playhead whose frame was just cut lands on the join, the first frame after the cut.
    public func show(_ project: Project, landingAt landing: RecordingTime? = nil) {
        pending = (project, landing)
        guard applyTask == nil else { return }
        applyTask = Task { [self] in
            while let (next, landing) = pending {
                pending = nil
                await apply(next, landing: landing)
                try? await Task.sleep(for: editInterval)
            }
            applyTask = nil
        }
    }

    private func apply(_ next: Project, landing: RecordingTime?) async {
        let audioChanged = next.edits.audio != project.edits.audio
        let pictureChanged = Self.picture(of: next.edits) != Self.picture(of: project.edits)
        project = next
        guard needsItem(for: next) || pictureChanged || audioChanged else { return }
        if !needsItem(for: next), !pictureChanged {
            item.audioMix = movie.audioMix(next.edits.audio)
            return
        }
        let before = shown
        guard let scene = await build(next) else { return }
        // A drag that began during the build owns the uncut item until its own `show`, which
        // carries the latest project; swapping it out here would undo the drag's scrub.
        guard shown == before else { return }
        self.scene = scene
        guard needsItem(for: next) else {
            // Measured (accepted-render rationale, open question 1): a paused item composes its
            // current frame again on its own within 300 ms of the swap, so no seek is needed to
            // show the edit.
            item.videoComposition = movie.videoComposition(scene: scene, frameRate: next.edits.format.frameRate)
            if audioChanged { item.audioMix = movie.audioMix(next.edits.audio) }
            return
        }
        let edited = MovieComposition(media: media, map: next.timeline.map)
        let under = landing ?? movie.map.recording(at: now)
        replace(with: edited, scene: scene, landingAt: edited.map.output(collapsing: under))
        shown = .edited
    }

    /// Whether showing `next` takes a new item: its cuts differ from the current item's, or the
    /// uncut item is up.
    private func needsItem(for next: Project) -> Bool {
        shown == .source || next.timeline.map != movie.map
    }

    /// A style change re-renders and dithers the backdrop (about 8 million pixels at 4K), so the
    /// scene is built off the main actor.
    private func build(_ project: Project) async -> RenderScene? {
        let previous = scene
        let built = await Task.detached {
            Result { () throws(RenderError) -> RenderScene in
                try RenderScene.make(project: project, format: project.edits.format, reusing: previous)
            }
        }.value
        switch built {
        case .success(let scene):
            lastError = nil
            return scene
        case .failure(let error):
            lastError = error
            return nil
        }
    }

    private func replace(with movie: MovieComposition, scene: RenderScene, landingAt target: OutputTime) {
        let rate = player.rate
        let next = Self.item(movie, scene: scene, edits: project.edits)
        self.movie = movie
        item = next
        player.replaceCurrentItem(with: next)
        inFlight = nil
        queued = target
        issuePendingSeek()
        if rate != 0 { player.rate = rate }
    }

    /// The uncut take, seeked to `t`, for a trim-handle or cut-edge drag. The first step swaps the
    /// item once and pauses; every step after that is a chased zero-tolerance seek (7 to 48 ms a
    /// frame on the real take, against 55 ms per item swap), so the user watches the exact frames
    /// they are removing or keeping. The next `show` returns to the edited item.
    public func showSource(at t: RecordingTime) {
        if shown == .edited {
            player.pause()
            var uncut = project
            uncut.edits.cuts = .none
            guard let scene = try? RenderScene.make(project: uncut, format: uncut.edits.format, reusing: scene) else { return }
            self.scene = scene
            replace(with: MovieComposition(media: media, map: .identity(duration: project.source.duration)), scene: scene, landingAt: .zero)
            shown = .source
        }
        scrub(to: t)
    }

    private static func picture(of edits: Edits) -> Edits {
        var picture = edits
        picture.audio = .default
        picture.cuts = .none
        return picture
    }

    public func play() { player.play() }
    public func pause() { player.pause() }

    /// Frame-accurate scrubbing with seek chasing: while a seek is in flight, only the latest
    /// requested time is kept and issued when it lands (the Apple QA1820 pattern), so dragging
    /// the playhead never queues a backlog of seeks. `t` is a strip position; inside a cut it
    /// lands on the join.
    public func scrub(to t: RecordingTime) {
        queued = movie.map.output(collapsing: t)
        if inFlight == nil { issuePendingSeek() }
    }

    private func issuePendingSeek() {
        guard let target = queued else { return }
        queued = nil
        inFlight = target
        let item = item
        item.seek(to: target.compositionTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A seek on an item that was replaced meanwhile reports back too; the new item's
                // own seek owns `inFlight`.
                guard item === self.item else { return }
                inFlight = nil
                issuePendingSeek()
            }
        }
    }

    /// Playhead updates for the transport and the strip, at display rate while playing, in both
    /// clocks. Each tick reads `now` from the current item, not the time the observer delivered,
    /// and converts it with that item's map.
    public func playhead() -> AsyncStream<Playhead> {
        AsyncStream { continuation in
            let observer = Observer(token: player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 60), queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.player.currentItem === self.item else { return }
                    let output = self.now
                    continuation.yield(Playhead(output: output, recording: self.movie.map.recording(at: output)))
                }
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
