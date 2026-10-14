import Foundation
import Timeline

/// Everything the user can change about a take. A value: the editor applies an `EditAction` to get
/// the next document, so undo is "keep the previous value" and persistence is "encode this".
///
/// `zooms` is stored as the validated `ZoomTrack`, never a bare array, so a document in memory is
/// always one `Timeline.init` can run (per type-system-discipline).
public struct EditDocument: Sendable, Hashable, Codable {
    public var zooms: ZoomTrack
    public var settings: TimelineSettings
    public var style: Style
    public var output: OutputFormat

    public init(zooms: ZoomTrack, settings: TimelineSettings = .default, style: Style = .default, output: OutputFormat = .default) {
        self.zooms = zooms
        self.settings = settings
        self.style = style
        self.output = output
    }

    /// The document a take gets before anyone edits it: auto-zoom with the default settings.
    public static func initial(for source: SourceRecording) -> EditDocument {
        fatalError("not implemented")
    }

    /// Pure. Throws only when the result would be an invalid `ZoomTrack`; the view clamps drags to
    /// the neighbours so this is a programming error surfacing, not a user-facing path.
    public func applying(_ action: EditAction, source: SourceRecording) throws(EditError) -> EditDocument {
        // TODO: switch action
        //   .deleteZoom(id): filter the segment out; ZoomTrack(validating:) cannot fail
        //   .moveZoom(id, by): shift range by delta, clamp to [0, duration] and to the neighbours' edges
        //   .resizeZoom(id, start, end): TimeRange(start:end:) nil -> .emptyRange; then validate
        //   .setZoomFocus(id, focus), .setZoomScale(id, scale): scale < 1 -> ZoomTrackError.scaleBelowOne
        //   .regenerateZooms: AutoZoom.track(for: source, settings: settings.autoZoom)
        //   .setSettings, .setStyle, .setOutput: replace the field
        fatalError("not implemented")
    }
}

public enum EditAction: Sendable, Hashable {
    case deleteZoom(ZoomSegment.ID)
    case moveZoom(ZoomSegment.ID, by: RecordingTime)
    case resizeZoom(ZoomSegment.ID, start: RecordingTime, end: RecordingTime)
    case setZoomFocus(ZoomSegment.ID, ZoomSegment.Focus)
    case setZoomScale(ZoomSegment.ID, Double)
    case regenerateZooms
    case setSettings(TimelineSettings)
    case setStyle(Style)
    case setOutput(OutputFormat)
}

public enum EditError: Error, Sendable, Equatable {
    case unknownZoom(ZoomSegment.ID)
    case emptyRange
    case invalidZooms(ZoomTrackError)
}

/// `edit.json` on disk. The wire shape is private to this file; `EditDocument` is the API.
///
/// Version 1. Unknown top-level keys are ignored; an unknown version is refused so an older app
/// never rewrites a newer document with fields dropped.
struct EditFile: Codable {
    static let currentVersion = 1
    var version: Int
    var document: EditDocument

    static func decode(_ data: Data) throws(EditStoreError) -> EditDocument { fatalError("not implemented") }
    static func encode(_ document: EditDocument) throws(EditStoreError) -> Data { fatalError("not implemented") }
}

public enum EditStoreError: Error, Sendable {
    case unsupportedVersion(found: Int, supported: Int)
    case corrupt(String)
    case unwritable(URL, String)
}
