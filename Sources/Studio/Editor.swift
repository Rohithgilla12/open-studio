import AVFoundation
import Foundation
import Observation
import Render
import Timeline

/// What the strip has selected: a zoom block or a removed region. Delete removes the zoom or
/// restores the cut.
public enum Selection: Hashable, Sendable {
    case zoom(ZoomSegment.ID)
    case cut(Cut.ID)
}

@MainActor
@Observable
public final class Editor {
    public private(set) var project: Project
    public let preview: PreviewPlayer
    public var selection: Selection?
    public private(set) var playhead: Playhead = .start
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

    /// What one step of a drag shows: the edited take landing somewhere, or the uncut take at the
    /// handle, for a trim or cut-edge drag.
    private enum PreviewStep {
        case edited(landingAt: RecordingTime?)
        case source(at: RecordingTime)
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
                isPlaying = preview.isPlaying
            }
        }
    }

    /// The strip's axis: the whole recording.
    public var duration: RecordingTime { project.source.duration }
    /// What the viewer gets, for the transport label.
    public var outputDuration: OutputTime { project.timeline.map.duration }
    public var takeName: String { project.source.directory.deletingPathExtension().lastPathComponent }
    public var zooms: [ZoomSegment] { project.edits.zooms.segments }
    public var cuts: [Cut] { project.edits.cuts.cuts }
    /// Where the take begins and ends after trimming, for the trim handles.
    public var trimmed: ClosedRange<RecordingTime> { project.edits.cuts.trimmed(within: duration) }

    private var oneFrame: RecordingTime { .seconds(1 / Double(project.edits.format.frameRate.rawValue)) }

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
        drag(actionName, showing: .edited(landingAt: nil), change)
    }

    private func drag(_ actionName: String, showing step: PreviewStep, _ change: (inout Edits) -> Void) {
        if openDrag == nil { openDrag = (project.edits, actionName) }
        var edits = project.edits
        change(&edits)
        if edits != project.edits {
            project.edits = edits
            saveState = .pending
        }
        switch step {
        case .edited(let landing): preview.show(project, landingAt: landing)
        case .source(let t): preview.showSource(at: t)
        }
    }

    public func endDrag() {
        guard let (before, actionName) = openDrag else { return }
        openDrag = nil
        // Returns from the uncut take after a trim or cut-edge drag; a no-op for the rest.
        preview.show(project)
        guard project.edits != before else {
            if saveState == .pending, saveTask == nil { saveState = .saved }
            return
        }
        registerUndo(restoring: before, actionName: actionName)
        scheduleSave()
    }

    public func deleteZoom(_ id: ZoomSegment.ID) {
        apply("Delete Zoom") { $0.zooms = $0.zooms.removing(id) }
        if selection == .zoom(id) { selection = nil }
    }

    /// Delete key: removes the selected zoom, or restores the selected cut.
    public func deleteSelection() {
        switch selection {
        case .zoom(let id): deleteZoom(id)
        case .cut(let id): restoreCut(id)
        case nil: break
        }
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
        selection = .zoom(id)
    }

    public func regenerateZooms() {
        apply("Regenerate Zooms") { [source = project.source] in
            $0.zooms = AutoZoom.track(for: source, settings: $0.settings.autoZoom)
        }
        selection = nil
    }

    /// One step of a drag across the strip's ruler, from where it started to where the pointer is.
    /// Computed from the cuts before the drag began, so dragging back shrinks the new cut instead
    /// of leaving the union of every step. The preview shows the frame just after the cut.
    public func markCut(from start: RecordingTime, to end: RecordingTime) {
        let base = openDrag?.before.cuts ?? project.edits.cuts
        guard let range = TimeRange(start: min(start, end), end: max(start, end)),
            let (cuts, id) = base.cutting(range, within: duration)
        else { return }
        pause()
        drag("Cut", showing: .edited(landingAt: range.end)) { $0.cuts = cuts }
        selection = .cut(id)
    }

    /// One step of a trim-handle drag. The preview shows the uncut take at the new first frame
    /// (start) or last frame (end).
    public func trim(_ end: Cuts.End, to t: RecordingTime) {
        let cuts = project.edits.cuts.trimming(end, to: t, within: duration)
        let trimmed = cuts.trimmed(within: duration)
        let shown = end == .start ? trimmed.lowerBound : max(trimmed.upperBound - oneFrame, .zero)
        pause()
        drag("Trim", showing: .source(at: shown)) { $0.cuts = cuts }
    }

    /// `[` and `]`: trim the start or the end to the playhead. Every cut the trim passes is
    /// absorbed, where a handle drag stops short of the next cut.
    public func trimToPlayhead(_ end: Cuts.End) {
        let t = playhead.recording
        let removed = end == .start ? TimeRange(start: .zero, end: t) : TimeRange(start: t, end: duration)
        guard let removed, let (cuts, _) = project.edits.cuts.cutting(removed, within: duration) else { return }
        apply("Trim") { $0.cuts = cuts }
    }

    /// One step of a cut-edge drag. The preview shows the uncut take at the last kept frame before
    /// the cut for its start edge and the first kept frame after it for its end edge: the two
    /// frames the viewer sees meet.
    public func resizeCut(_ id: Cut.ID, edge: Cuts.End, to t: RecordingTime) {
        let cuts = project.edits.cuts.resizing(id, edge: edge, to: t, within: duration)
        guard let cut = cuts.cuts.first(where: { $0.id == id }) else { return }
        let shown = edge == .start ? max(cut.range.start - oneFrame, .zero) : cut.range.end
        pause()
        drag("Resize Cut", showing: .source(at: shown)) { $0.cuts = cuts }
    }

    /// Puts the cut's time back. Undo cuts it again.
    public func restoreCut(_ id: Cut.ID) {
        apply("Restore Cut") { $0.cuts = $0.cuts.restoring(id) }
        if selection == .cut(id) { selection = nil }
    }

    public func togglePlayback() {
        isPlaying ? pause() : play()
    }

    public func play() {
        if playhead.output >= outputDuration - .milliseconds(50) { scrub(to: .zero) }
        preview.play()
        isPlaying = true
    }

    public func pause() {
        preview.pause()
        isPlaying = false
    }

    /// From the strip, in recording time. Inside a cut the playhead lands on the cut's end, which
    /// is where the marker is drawn.
    public func scrub(to t: RecordingTime) {
        let clamped = min(max(t, .zero), duration)
        let map = project.timeline.map
        let output = map.output(collapsing: clamped)
        playhead = Playhead(output: output, recording: map.recording(at: output))
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
        switch selection {
        case .zoom(let id) where !edits.zooms.segments.contains(where: { $0.id == id }): selection = nil
        case .cut(let id) where !edits.cuts.cuts.contains(where: { $0.id == id }): selection = nil
        default: break
        }
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
