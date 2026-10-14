import Synchronization
import Timeline

/// Everything a frame needs besides the source pixels and the time. Immutable and Sendable, so one
/// value is shared by every compositor thread without locks. Built from a `Project` plus an
/// `EditDocument`; a new edit means a new plan, never a mutated one.
struct RenderPlan: Sendable {
    let timeline: Timeline
    let style: Style
    let output: PixelSize
    let layout: CanvasLayout
    let cursors: CursorAtlas
    let pressedScale: Double

    init(project: Project, edit: EditDocument) {
        // timeline = Timeline(source: project.source, zooms: edit.zooms, settings: edit.settings)
        // output = edit.output.pixelSize(for: project.source); layout = CanvasLayout(...)
        fatalError("not implemented")
    }

    /// The two things the backdrop depends on. Keyed into `FrameRenderer`'s cache.
    var backdropKey: BackdropKey { BackdropKey(style: style, output: output) }
}

struct BackdropKey: Hashable, Sendable {
    let style: Style
    let output: PixelSize
}

/// The one mutable cell between the editor and a playing preview.
///
/// AVFoundation holds the instruction (and so this box) for the life of the player item. An edit
/// replaces the plan; the next `startRequest` reads the new one. Each request reads the box exactly
/// once, so a frame is still a pure function of (source frame, t, the plan it read). Nothing else
/// in Render is mutable while playing, and the player is never rebuilt for an edit.
///
/// The exporter creates its own box and never replaces it, so export is frozen by construction and
/// preview and export go through one mechanism.
final class PlanBox: Sendable {
    private let cell: Mutex<RenderPlan>

    init(_ plan: RenderPlan) { cell = Mutex(plan) }

    var current: RenderPlan { cell.withLock { $0 } }

    func replace(_ plan: RenderPlan) { cell.withLock { $0 = plan } }
}
