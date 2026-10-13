/// Answers per-frame questions about one recording plus its edit state.
///
/// Built once from (source, zooms, settings); every query afterwards is a pure function of immutable
/// precomputed tables. So `camera(at:)` and `cursor(at:)` return identical values in any query order,
/// on any thread, and a renderer can share one `Timeline` value across AVFoundation's compositor
/// threads without locks. When the user edits zooms or settings, build a new `Timeline` and swap it in.
///
/// Cost: construction is O(n) in pointer samples (a 10-minute recording builds in a few
/// milliseconds). Each query is two or three binary searches plus a closed-form spring evaluation:
/// well under a microsecond, independent of t and of the recording length.
public struct Timeline: Sendable {
    public let source: SourceRecording
    public let zooms: [ZoomSegment]
    public let settings: TimelineSettings

    private let camera: CameraTrack
    private let cursor: CursorTrack

    /// `zooms` must be sorted and non-overlapping; overlapping input is resolved by letting the later
    /// segment start where the earlier one ends (debug builds assert).
    public init(source: SourceRecording, zooms: [ZoomSegment], settings: TimelineSettings = .default) {
        fatalError("not implemented")
    }

    /// The source rectangle the renderer should scale to fill the output, and the values it came from.
    /// t is clamped to [0, duration].
    public func camera(at t: RecordingTime) -> CameraState {
        fatalError("not implemented")
    }

    /// Where to draw the cursor, with which image, how pressed, and how opaque. t is clamped.
    public func cursor(at t: RecordingTime) -> CursorState {
        fatalError("not implemented")
    }
}

public struct CameraState: Sendable, Hashable {
    /// Source pixels shown in the output frame. Always inside the frame: center is clamped so the
    /// viewport never leaves the source, and scale is clamped to >= 1 (the camera spring is
    /// underdamped and would otherwise overshoot below 1 when zooming out).
    public let viewport: Rect
    public let scale: Double
    public let center: Point
    /// Unclamped spring velocities, for motion blur.
    public let centerVelocity: Velocity
    public let scaleVelocity: Double
}

public struct CursorState: Sendable, Hashable {
    /// Hotspot position after smoothing, in source pixels.
    public let position: Point
    /// For tilt and motion blur.
    public let velocity: Velocity
    public let image: CursorImageID?
    public let isPressed: Bool
    /// 0 at rest, 1 fully pressed; eases over `pressTransition`. Draw scale is
    /// `1 - (1 - pressedScale) * pressAmount`.
    public let pressAmount: Double
    /// 0...1. Combines the typing fade and idle hide.
    public let opacity: Double
    /// False when the pointer is off this display or opacity is 0. The renderer can skip the cursor
    /// pass entirely.
    public let isVisible: Bool
}
