import AVFoundation
import Foundation
import Timeline

/// One take opened for editing or export: the immutable source plus the current edit document.
///
/// The edit document lives at `<take>.osrec/edit.json`. It is inside the take so it travels with it
/// in Finder, and it is not one of the recorder's files: the recorder holds `.lock` until it has
/// finalized and never writes again, `load` refuses a live or crashed take, and recovery touches only
/// `recording.json` and `events.ndjson`. So the recorder and the editor never write the same file.
public struct Project: Sendable {
    public let source: SourceRecording
    public private(set) var edit: EditDocument
    /// Loaded once at open: every declared cursor PNG as a Core Image image, plus the default arrow.
    let cursors: CursorAtlas
    /// screen.mov and microphone.mov as one asset, both at time 0. Built once; AVPlayer and the
    /// exporter both read it, which is what keeps their audio sync identical.
    let asset: SourceAsset

    /// Loads the take through `SourceRecording.load`, then `edit.json` if present, else
    /// `EditDocument.initial`. A corrupt edit file is reported, not silently replaced.
    public static func open(_ takeURL: URL) async throws(ProjectError) -> Project {
        fatalError("not implemented")
    }

    /// Replaces the edit document. Pure on the value; call `save()` to persist.
    public mutating func replaceEdit(_ edit: EditDocument) { self.edit = edit }

    /// Writes `edit.json` with temp file and rename, so a crash leaves the old document or the new
    /// one. Idempotent: writing the same document twice gives identical bytes.
    public func save() throws(EditStoreError) { fatalError("not implemented") }

    static let editFileName = "edit.json"
    var editFileURL: URL { fatalError("not implemented") }
}

public enum ProjectError: Error, Sendable {
    case source(SourceLoadError)
    case edit(EditStoreError)
    /// screen.mov could not be opened. The take is readable as metadata but not renderable.
    case mediaUnreadable(URL, String)
}

/// `AVComposition` with the screen video track and, when present, the microphone audio track.
/// Composition track IDs are stable for the asset's lifetime and are what the instruction names.
struct SourceAsset: @unchecked Sendable {
    let composition: AVComposition
    let screenTrackID: CMPersistentTrackID
    let microphoneTrackID: CMPersistentTrackID?
    let duration: CMTime

    static func build(from media: SourceRecording.Media, duration: RecordingTime) async throws -> SourceAsset {
        // TODO: AVMutableComposition; insert screen video [0, duration] at .zero; same for microphone
        // if present. The VFR sample timing is preserved by insertTimeRange, which is what gives the
        // compositor sample-and-hold: a source frame lasts until the next one's PTS.
        fatalError("not implemented")
    }
}
