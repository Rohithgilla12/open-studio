import Foundation
import Observation
import Render
import Timeline

// Additions and changes to Editor. Every cut edit goes through today's `apply` / `drag` /
// `endDrag`, so it is one undo step, autosaves, and reaches the preview like a zoom edit.

public enum Selection: Hashable, Sendable {
    case zoom(ZoomSegment.ID)
    case cut(Cut.ID)
}

extension Editor {
    // Stored property changes:
    //   public var selection: Selection?                 (was ZoomSegment.ID?)
    //   public private(set) var playhead: Playhead       (was RecordingTime; fed by preview.playhead())
    //   isPlaying reads preview.isPlaying                (preview.player is no longer public)

    /// The strip's axis: the whole recording.
    public var duration: RecordingTime { project.source.duration }
    /// What the viewer gets, for the transport label.
    public var outputDuration: OutputTime { project.timeline.map.duration }
    public var cuts: [Cut] { project.edits.cuts.cuts }

    /// One step of a drag across the strip's ruler, from where it started to where the pointer is.
    /// Computed from the cuts before the drag began, so dragging back shrinks the new cut instead
    /// of leaving the union of every step. The preview shows the frame just after the cut.
    public func markCut(from start: RecordingTime, to end: RecordingTime) {
        // TODO:
        // let base = openDrag?.before.cuts ?? project.edits.cuts
        // guard let range = TimeRange(start: min(start, end), end: max(start, end)),
        //       let (cuts, id) = base.cutting(range, within: duration) else { return }
        // pause()
        // drag("Cut", landingAt: range.end) { $0.cuts = cuts }
        // selection = .cut(id)
        fatalError("not implemented")
    }

    /// One step of a trim-handle drag. The preview shows the new first frame (start) or last frame
    /// (end) of the take.
    public func trim(_ end: Cuts.End, to t: RecordingTime) {
        // TODO: pause(); drag("Trim", landingAt: end == .start ? t : t - oneFrame) {
        //   $0.cuts = $0.cuts.trimming(end, to: t, within: duration) }
        fatalError("not implemented")
    }

    /// One step of a cut-edge drag. Lands on the last kept frame before the cut for its start edge
    /// and the first kept frame after it for its end edge: the two frames the viewer sees meet.
    public func resizeCut(_ id: Cut.ID, edge: Cuts.End, to t: RecordingTime) {
        fatalError("not implemented")
    }

    /// Puts the cut's time back. Undo cuts it again.
    public func restoreCut(_ id: Cut.ID) {
        // TODO: apply("Restore Cut") { $0.cuts = $0.cuts.restoring(id) }; clear the selection.
        fatalError("not implemented")
    }

    /// Delete key: removes the selected zoom, or restores the selected cut.
    public func deleteSelection() {
        fatalError("not implemented")
    }

    /// From the strip, in recording time. Inside a cut the playhead lands on the cut's end, which
    /// is where the playhead marker is drawn.
    public func scrub(to t: RecordingTime) {
        fatalError("not implemented")
    }

    /// Today's `drag`, plus where the preview should land once the edit reaches it.
    func drag(_ actionName: String, landingAt landing: RecordingTime?, _ change: (inout Edits) -> Void) {
        fatalError("not implemented")
    }
}
