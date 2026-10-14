public import Foundation
public import Render
public import Timeline

/// A take plus its edits: the one way to get from a directory to pixels. The app and `osrec export`
/// both start here, so "which zooms and style does this take have" has one answer.
///
/// `Project` is a value. An edit returns a new `Project`; nothing mutates in place. The expensive part,
/// the media composition, is shared by reference between versions (`TakeMedia` never changes).
public struct Project: Sendable {
    public let source: SourceRecording
    public let media: TakeMedia
    public let edits: EditState

    /// Loads the take, reads `studio.json` if present (else `EditState.initial`), prepares media.
    /// Never writes. Throws `.needsRecovery` and `.stillRecording` untouched from `SourceLoadError`.
    public static func open(_ directory: URL) async throws(ProjectError) -> Project { fatalError("not implemented") }

    /// Same take, different edits.
    public func with(_ change: (inout EditState) -> Void) -> Project { fatalError("not implemented") }

    /// Builds the Timeline (milliseconds even for a long take) and the plan.
    public func plan() throws(ProjectError) -> RenderPlan {
        // TODO
        //  guard let timeline = Timeline(source: source, zooms: edits.zooms, settings: edits.timeline)
        //  return try RenderPlan(timeline: timeline, style: edits.style, output: edits.output.spec(for: source, style: edits.style))
        fatalError("not implemented")
    }

    /// Preview canvas follows the chosen output's aspect, so what you see is what you export.
    public func previewPlan() throws(ProjectError) -> RenderPlan { fatalError("not implemented") }
}

/// Persists `EditState` as `<take>.osrec/studio.json`.
///
/// Why inside the take: it moves, copies and archives with the recording, and Spotlight and AirDrop
/// treat the package as one thing. Why that is safe: `studio.json` is a new file the recorder never
/// reads or writes, no recording file is touched, and recovery runs only on unfinalised takes, which
/// the editor refuses to open. The file name lives here and nowhere else, as `RecordingLayout` does
/// for the recording's own files.
public actor ProjectStore {
    public init(directory: URL, recordingID: UUID) { fatalError("not implemented") }

    /// nil when there is no file. Throws on unreadable, newer-than-supported, or another recording's file.
    public func load() throws(ProjectError) -> EditState? { fatalError("not implemented") }

    /// Coalescing, last-write-wins: calls within `delay` collapse into one write of the latest value.
    /// The write is temp file plus atomic rename, so a reader (osrec export while the app runs) sees
    /// the old or the new file, never a torn one, and a crash mid-write keeps the old file.
    public func scheduleSave(_ edits: EditState, delay: Duration = .milliseconds(400)) { fatalError("not implemented") }

    /// Writes any pending value now. Called on leaving the editor, on app deactivation, and at export start.
    public func flush() async throws(ProjectError) { fatalError("not implemented") }
}

/// On disk:
///     { "format": "open-studio.edits", "version": 1, "recordingID": "<manifest id>", "edits": { ... } }
/// Additive fields keep version 1 (Codable ignores unknown keys). Zoom segments keep their ids, so a
/// regenerated and an edited track can be diffed.
public enum ProjectError: Error, Sendable {
    case source(SourceLoadError)
    case render(RenderError)
    case editsUnreadable(String)
    case editsFromNewerVersion(found: Int, supported: Int)
    case editsBelongToAnotherRecording
    case invalidZoomTrack(ZoomTrackError)
}
