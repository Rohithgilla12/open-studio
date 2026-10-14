import AVFoundation
import Foundation
import Observation
import Project
import Render
import Timeline

/// Everything that changes the picture goes through `apply`. One way to edit, so the player, the
/// plan, the saved file and the zoom strip cannot disagree.
enum EditAction {
    case deleteZoom(ZoomSegment.ID)
    case moveZoom(ZoomSegment.ID, to: RecordingTime)
    case resizeZoom(ZoomSegment.ID, ZoomEditing.Edge, to: RecordingTime)
    case addZoom(at: RecordingTime)
    case regenerateZooms
    case setStyle(Style)
    case setOutput(OutputChoice)
    case setTimeline(TimelineSettings)
}

@MainActor @Observable
final class EditorModel {
    private(set) var project: Project
    private(set) var selection: ZoomSegment.ID?
    private(set) var playhead: RecordingTime = .zero
    private(set) var isPlaying = false
    let player: AVPlayer
    private let item: AVPlayerItem
    private let store: ProjectStore

    /// Builds the player once. After this the `AVPlayer` and `AVPlayerItem` live as long as the editor.
    init(project: Project, store: ProjectStore) { fatalError("not implemented") }

    func apply(_ action: EditAction) {
        // TODO
        //  1. next = project.with { $0 = reduce($0, action) }       // pure; ZoomEditing clamps, so always valid
        //  2. project = next; if selected zoom was deleted, clear selection
        //  3. store.scheduleSave(next.edits)                         // coalesced, atomic
        //  4. schedule a plan rebuild for the next main-loop turn (coalesces a drag into one rebuild per
        //     display refresh): plan = try next.previewPlan(); media.apply(plan, to: item)
        //     A rebuild failure is shown in the UI and leaves the last good composition on the item.
        //  5. a drag pauses playback for its duration (EditorModel.beginScrub/endScrub), because
        //     re-priming a playing item is the unmeasured cost
        fatalError("not implemented")
    }

    func select(_ id: ZoomSegment.ID?) { fatalError("not implemented") }
    func togglePlay() { fatalError("not implemented") }
    func seek(to t: RecordingTime) { fatalError("not implemented") }
    func beginScrub() { fatalError("not implemented") }
    func endScrub() { fatalError("not implemented") }

    /// The immutable thing the exporter takes. Calling it flushes the store first (async), then returns.
    func frozenPlan() async throws -> RenderPlan { fatalError("not implemented") }
}

@MainActor @Observable
final class ExportFlow {
    let editor: EditorModel
    let destination: URL
    private(set) var state: State = .running(ExportProgress(fraction: 0, speed: 0))
    enum State { case running(ExportProgress), done(ExportResult), failed(String), cancelled }

    /// Starts the export task. `cancel()` cancels it; Render removes the partial file.
    init(editor: EditorModel, plan: RenderPlan, destination: URL) { fatalError("not implemented") }
    func cancel() { fatalError("not implemented") }
    func revealInFinder() { fatalError("not implemented") }
}
