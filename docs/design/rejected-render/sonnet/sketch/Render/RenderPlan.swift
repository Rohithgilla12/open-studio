public import AVFoundation
public import Timeline

/// Everything one frame depends on besides the source pixels and the time: an immutable value.
///
/// A frame is `render(plan, t, sourceBuffer) -> pixels`, a pure function. The plan travels inside the
/// `AVVideoCompositionInstruction`, so a request carries its own edit state. An edit builds a new plan
/// and a new composition; frames already in flight finish with the old plan and nothing is shared or
/// locked. See "Edits reach a playing preview" in the rationale.
public struct RenderPlan: Sendable {
    public let timeline: Timeline
    public let style: Style
    public let output: OutputSpec
    let sprites: CursorSprites

    /// Decodes the cursor PNGs (the only I/O besides media). Throws on an undecodable declared cursor,
    /// since a take whose manifest points at a corrupt PNG is corrupt.
    public init(timeline: Timeline, style: Style, output: OutputSpec) throws(RenderError) {
        fatalError("not implemented")
    }

    /// The one mapping between AVFoundation's clock and ours. Identity today (no trims or speed). A
    /// future time map lands here and nowhere else.
    func recordingTime(for compositionTime: CMTime) -> RecordingTime { fatalError("not implemented") }

    /// Pure and CPU-only. The compositor and the CPU-side tests both call this.
    func layout(at t: RecordingTime, canvas: PixelSize) -> FrameLayout {
        FrameLayout.make(
            frame: timeline.frame(at: t), source: timeline.source, settings: timeline.settings,
            sprites: sprites, style: style, canvas: canvas)
    }
}

public enum RenderError: Error, Sendable {
    case noGPU
    case cursorImageUnreadable(CursorImageID, underlying: String)
    case sourceUnreadable(String)
    case exportFailed(String)
    case cancelled
}
