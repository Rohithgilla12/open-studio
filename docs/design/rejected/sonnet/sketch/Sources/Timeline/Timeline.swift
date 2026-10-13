import RecordingFormat

/// Immutable and Sendable. Every query is a pure function of (self, t): the same answer
/// for any call order and any thread. There is no spring state between calls because the
/// springs were integrated once, in `init`, into checkpoints (see SpringTrack).
///
///     let recording = try RecordingReader.read(url)
///     let timeline = Timeline(recording)
///     let camera = timeline.camera(at: t)   // O(log n), no allocation
///     let cursor = timeline.cursor(at: t)
public struct Timeline: Sendable {
    public let duration: RecordingTime
    public let displaySize: RecordingManifest.Size
    public let cursorImages: [CursorImageID: CursorImage]
    public private(set) var zoomSegments: [ZoomSegment]
    public let settings: TimelineSettings

    private let cameraTrack: CameraTrack
    private let cursorTrack: CursorTrack
    private let source: TimelineSource

    /// Generates automatic zooms from clicks, then builds the camera and cursor tracks.
    public init(_ recording: LoadedRecording, settings: TimelineSettings = .default, edits: TimelineEdits = .none) {
        // TODO:
        //  source = TimelineSource(recording)              // normalised, thinned, shake-filtered once
        //  auto = AutoZoom.segments(clicks: source.clickTimes, duration:, settings.autoZoom)
        //  zoomSegments = edits.apply(to: auto)            // manual segments win over overlapping auto
        //  cameraTrack = CameraTrack.build(zoomSegments, source, settings.camera)
        //  cursorTrack = CursorTrack.build(source, settings.cursor)
        fatalError("not implemented")
    }

    public func camera(at t: RecordingTime) -> CameraState { fatalError("not implemented") }
    public func cursor(at t: RecordingTime) -> CursorState { fatalError("not implemented") }

    /// An edit returns a new Timeline. Tracks rebuild; nothing mutates in place.
    public func replacingZoomSegments(_ segments: [ZoomSegment]) -> Timeline { fatalError("not implemented") }
}

/// User changes on top of the immutable recording. Persisted by the editor in project.json,
/// never inside the recording directory.
public struct TimelineEdits: Hashable, Sendable, Codable {
    public var manualZooms: [ZoomSegment] = []
    public var removedAutomaticZooms: Set<ZoomSegment.ID> = []
    public static let none = TimelineEdits()
    func apply(to automatic: [ZoomSegment]) -> [ZoomSegment] { fatalError("not implemented") }
}
