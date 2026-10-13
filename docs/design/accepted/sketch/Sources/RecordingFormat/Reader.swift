import Foundation

/// The metadata of a recording directory, decoded but not yet interpreted. Readers (Timeline,
/// recovery, `osrec inspect`) turn this into their own domain types.
public struct RecordingMetadata: Sendable {
    public var directory: URL
    public var manifest: WireManifest
    public var events: DecodedEventLog
}

public enum RecordingReader {
    /// Reads `recording.json` and `events.ndjson`. Does not open media files or cursor PNGs.
    ///
    /// Checks only what the format itself guarantees: the manifest decodes, `format` matches,
    /// `formatVersion <= FormatVersion.current`, and the event log decodes (torn tail allowed only
    /// while `status == .recording`). Semantic checks belong to the consumer.
    public static func readMetadata(at directory: URL) throws(FormatError) -> RecordingMetadata {
        fatalError("not implemented")
    }
}

public enum FormatError: Error, Sendable, Equatable {
    case notARecordingDirectory(URL)
    /// The directory exists but has no manifest: the recorder died before the first screen frame.
    case noManifest(URL)
    case manifestUnreadable(detail: String)
    case wrongFormat(found: String)
    case unsupportedVersion(found: Int, supported: Int)
    case eventLineInvalid(lineNumber: Int, detail: String)
    case tornTailInFinalizedRecording
}
