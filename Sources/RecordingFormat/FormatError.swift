public import Foundation

public enum FormatError: Error, Sendable, Equatable {
    case notARecordingDirectory(URL)
    /// The directory has no manifest: the recorder died before the first screen frame, or is
    /// still waiting for it.
    case noManifest(URL)
    case manifestUnreadable(detail: String)
    case wrongFormat(found: String)
    case unsupportedVersion(found: Int, supported: Int)
    case eventsUnreadable(detail: String)
    /// A terminated line that does not decode. 1-based.
    case eventLineInvalid(lineNumber: Int, detail: String)
    case tornTailInFinalizedRecording(byteCount: Int)
    case lockUnreadable(detail: String)
}
