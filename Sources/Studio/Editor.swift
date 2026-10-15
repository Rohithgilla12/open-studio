import AVFoundation
import Foundation
import Observation
import Render
import Timeline

@MainActor
@Observable
public final class Editor {
    public private(set) var project: Project
    public let preview: PreviewPlayer
    public var selection: ZoomSegment.ID?
    public private(set) var playhead: RecordingTime = .zero
    public private(set) var isPlaying = false
    public private(set) var saveState: SaveState = .saved
    public private(set) var hasSavedEdits: Bool
    @ObservationIgnored public weak var undoManager: UndoManager?

    @ObservationIgnored private var openDrag: (before: Edits, actionName: String)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var playheadTask: Task<Void, Never>?

    static let saveDelay: Duration = .seconds(1)
    static let newZoomLength = RecordingTime.seconds(3)
    static let newZoomScale = 2.0

    public enum SaveState: Equatable {
        case saved
        case pending
        case failed(String)
    }

    init(project: Project) async throws(RenderError) {
        self.project = project
        hasSavedEdits = project.origin == .saved
        preview = try await PreviewPlayer(project: project)
        let ticks = preview.playhead()
        playheadTask = Task { [weak self] in
            for await t in ticks {
                guard let self else { return }
                playhead = t
                // The periodic observer also fires when playback starts or stops, including at the end.
                isPlaying = preview.player.rate != 0
            }
        }
    }

    public var duration: RecordingTime { project.source.duration }
    public var takeName: String { project.source.directory.deletingPathExtension().lastPathComponent }
    public var zooms: [ZoomSegment] { project.edits.zooms.segments }

    public func apply(_ actionName: String, _ change: (inout Edits) -> Void) {
        endDrag()
        var edits = project.edits
        change(&edits)
        guard edits != project.edits else { return }
        let before = project.edits
        project.edits = edits
        registerUndo(restoring: before, actionName: actionName)
        preview.show(project)
        scheduleSave()
    }

    /// One step of a continuous gesture (dragging a zoom, its edge, or a slider). Updates the
    /// preview live and records nothing until `endDrag`.
    public func drag(_ actionName: String, _ change: (inout Edits) -> Void) {
        var edits = project.edits
        change(&edits)
        guard edits != project.edits else { return }
        if openDrag == nil { openDrag = (project.edits, actionName) }
        project.edits = edits
        saveState = .pending
        preview.show(project)
    }

    public func endDrag() {
        guard let (before, actionName) = openDrag else { return }
        openDrag = nil
        guard project.edits != before else { return }
        registerUndo(restoring: before, actionName: actionName)
        scheduleSave()
    }

    public func deleteZoom(_ id: ZoomSegment.ID) {
        apply("Delete Zoom") { $0.zooms = $0.zooms.removing(id) }
        if selection == id { selection = nil }
    }

    public func deleteSelection() {
        if let selection { deleteZoom(selection) }
    }

    public func moveZoom(_ id: ZoomSegment.ID, toStart start: RecordingTime) {
        let duration = duration
        drag("Move Zoom") { $0.zooms = $0.zooms.moving(id, toStart: start, within: duration) }
    }

    public func resizeZoom(_ id: ZoomSegment.ID, edge: ZoomTrack.Edge, to t: RecordingTime) {
        let duration = duration
        drag("Resize Zoom") { $0.zooms = $0.zooms.resizing(id, edge: edge, to: t, within: duration) }
    }

    public func setZoomScale(_ id: ZoomSegment.ID, scale: Double) {
        drag("Change Zoom Scale") { $0.zooms = $0.zooms.updating(id, scale: scale) }
    }

    public func canAddZoom(at t: RecordingTime) -> Bool {
        project.edits.zooms.inserting(around: t, length: Self.newZoomLength, scale: Self.newZoomScale, within: duration) != nil
    }

    public func addZoom(at t: RecordingTime) {
        guard let (track, id) = project.edits.zooms.inserting(
            around: t, length: Self.newZoomLength, scale: Self.newZoomScale, within: duration)
        else { return }
        apply("Add Zoom") { $0.zooms = track }
        selection = id
    }

    public func regenerateZooms() {
        apply("Regenerate Zooms") { [source = project.source] in
            $0.zooms = AutoZoom.track(for: source, settings: $0.settings.autoZoom)
        }
        selection = nil
    }

    public func togglePlayback() {
        isPlaying ? pause() : play()
    }

    public func play() {
        if playhead >= duration - .milliseconds(50) { scrub(to: .zero) }
        preview.play()
        isPlaying = true
    }

    public func pause() {
        preview.pause()
        isPlaying = false
    }

    public func scrub(to t: RecordingTime) {
        let clamped = min(max(t, .zero), duration)
        playhead = clamped
        preview.scrub(to: clamped)
    }

    public func flush() {
        endDrag()
        guard saveState != .saved else { return }
        saveTask?.cancel()
        save()
    }

    func close() {
        flush()
        preview.pause()
        playheadTask?.cancel()
        playheadTask = nil
        undoManager?.removeAllActions(withTarget: self)
    }

    private func registerUndo(restoring before: Edits, actionName: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { editor in
            MainActor.assumeIsolated { editor.restore(before, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
    }

    private func restore(_ edits: Edits, actionName: String) {
        openDrag = nil
        let current = project.edits
        project.edits = edits
        if let selection, !edits.zooms.segments.contains(where: { $0.id == selection }) { self.selection = nil }
        registerUndo(restoring: current, actionName: actionName)
        preview.show(project)
        scheduleSave()
    }

    private func scheduleSave() {
        saveState = .pending
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        saveTask = nil
        do {
            try project.save()
            saveState = .saved
            hasSavedEdits = true
        } catch {
            saveState = .failed(StudioAlert.describe(error))
        }
    }
}
