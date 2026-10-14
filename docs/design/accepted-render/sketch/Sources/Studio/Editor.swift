import Foundation
import Observation
import Render
import Timeline

/// One open take. Every edit goes through `apply` or the drag pair, which keeps undo, the
/// preview, and autosave in step without each view knowing about all three.
@MainActor
@Observable
public final class Editor {
    public private(set) var project: Project
    public let preview: PreviewPlayer
    public var selection: ZoomSegment.ID?
    public private(set) var playhead: RecordingTime = .zero
    public private(set) var saveState: SaveState = .saved
    /// Set by the editor view from `@Environment(\.undoManager)`.
    public weak var undoManager: UndoManager?

    private var editsBeforeDrag: Edits?
    private var saveTask: Task<Void, Never>?
    /// Autosave runs this long after the last committed edit.
    static let saveDelay: Duration = .seconds(1)

    init(project: Project) async throws(RenderError) {
        self.project = project
        preview = try await PreviewPlayer(project: project)
        // TODO: playhead updates: for await t in preview.playhead() { playhead = t }
    }

    public enum SaveState: Equatable {
        case saved
        case pending
        case failed(String)
    }

    // MARK: The mutation paths

    /// A discrete edit (delete, add, style change): one undo step, preview, autosave.
    public func apply(_ actionName: String, _ change: (inout Edits) -> Void) {
        let before = project.edits
        change(&project.edits)
        guard project.edits != before else { return }
        registerUndo(restoring: before, actionName: actionName)
        preview.show(project)
        scheduleSave()
    }

    /// One step of a continuous gesture (dragging a zoom or its edge). Updates the preview
    /// live, records nothing until `endDrag`.
    public func drag(_ change: (inout Edits) -> Void) {
        if editsBeforeDrag == nil { editsBeforeDrag = project.edits }
        change(&project.edits)
        preview.show(project)
    }

    /// Ends a gesture as a single undo step.
    public func endDrag(_ actionName: String) {
        guard let before = editsBeforeDrag else { return }
        editsBeforeDrag = nil
        guard project.edits != before else { return }
        registerUndo(restoring: before, actionName: actionName)
        scheduleSave()
    }

    // MARK: Zoom strip vocabulary, all total because ZoomTrack's edits clamp

    public func deleteZoom(_ id: ZoomSegment.ID) {
        apply("Delete Zoom") { $0.zooms = $0.zooms.removing(id) }
        if selection == id { selection = nil }
    }

    public func moveZoom(_ id: ZoomSegment.ID, toStart start: RecordingTime) {
        let duration = project.source.duration
        drag { $0.zooms = $0.zooms.moving(id, toStart: start, within: duration) }
    }

    public func resizeZoom(_ id: ZoomSegment.ID, edge: ZoomTrack.Edge, to t: RecordingTime) {
        let duration = project.source.duration
        drag { $0.zooms = $0.zooms.resizing(id, edge: edge, to: t, within: duration) }
    }

    public func addZoom(at t: RecordingTime) {
        // TODO: if let (track, id) = zooms.inserting(around: t, length: 3 s, scale: 2, within: duration)
        //       { apply("Add Zoom") { $0.zooms = track }; selection = id }
        fatalError("not implemented")
    }

    public func regenerateZooms() {
        apply("Regenerate Zooms") { [source = project.source] in
            $0.zooms = AutoZoom.track(for: source, settings: $0.settings.autoZoom)
        }
    }

    /// Saves now if anything is pending. Called before the editor closes or a recording starts.
    public func flush() {
        fatalError("not implemented")
    }

    private func registerUndo(restoring before: Edits, actionName: String) {
        // TODO: undoManager?.registerUndo(withTarget: self) { editor in
        //         let redo = editor.project.edits
        //         editor.project.edits = before; preview.show; scheduleSave
        //         register the inverse with `redo` }
        //       undoManager?.setActionName(actionName)
    }

    private func scheduleSave() {
        // TODO: saveState = .pending; saveTask?.cancel()
        //       saveTask = Task { try? await Task.sleep(for: Self.saveDelay); guard !cancelled; save() }
        //       save(): do { try project.save(); saveState = .saved } catch { saveState = .failed(...) }
    }
}
