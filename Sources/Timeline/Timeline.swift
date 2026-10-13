/// Answers per-frame questions about one recording plus its edit state.
///
/// Built once from (source, zooms, settings); every query afterwards is a pure function of immutable
/// precomputed tables. So `frame(at:)` returns identical values in any query order, on any thread,
/// and a renderer can share one `Timeline` value across AVFoundation's compositor threads without
/// locks. When the user edits zooms or settings, build a new `Timeline` and swap it in.
///
/// Cost: construction is O(n) in pointer samples. Each query is a few binary searches plus a
/// closed-form spring evaluation per track, independent of t and of the recording length.
public struct Timeline: Sendable {
    public let source: SourceRecording
    public let zooms: ZoomTrack
    public let settings: TimelineSettings

    private let camera: CameraTrack
    private let cursor: CursorTrack

    public init(source: SourceRecording, zooms: ZoomTrack, settings: TimelineSettings = .default) {
        self.source = source
        self.zooms = zooms
        self.settings = settings
        camera = CameraTrack(source: source, zooms: zooms, settings: settings.camera)
        cursor = CursorTrack(source: source, settings: settings.cursor)
    }

    /// The camera and cursor for one output frame. `t` is clamped to `[0, duration]`.
    public func frame(at t: RecordingTime) -> FrameState {
        let seconds = t.clamped(to: .zero...source.duration).seconds
        return FrameState(camera: camera.state(at: seconds), cursor: cursor.state(at: seconds))
    }

    /// Knot counts per spring track, for diagnostics and the performance test.
    var knotCounts: (cameraScale: Int, cameraCenter: Int, cursorPosition: Int) {
        let cursorKnots: Int
        switch cursor.position {
        case .spring(let track): cursorKnots = track.knots.count
        case .held(let samples): cursorKnots = samples.count
        }
        return (camera.scale.knots.count, camera.center.knots.count, cursorKnots)
    }
}

public struct FrameState: Sendable, Hashable {
    public let camera: CameraState
    public let cursor: CursorState
}
