import Foundation

/// The one place that names files inside a recording directory. Writers and readers both go
/// through it, so a renamed file is a one-line change.
///
/// A recording directory is a package with the `.osrec` extension:
///
///     20261013-142233.osrec/
///       recording.json      manifest; written at the first screen frame and again at finalization
///       events.ndjson       append-only input and cursor events, one JSON object per line
///       screen.mov          fragmented QuickTime movie, cursor not drawn
///       microphone.mov      fragmented QuickTime movie, present only when the manifest says so
///       cursors/<id>.png    content-addressed cursor images
///       .lock               held with flock(2) by the live recorder; never read for content
///
/// Ownership: the recorder is the only writer until the manifest status is `finalized`
/// (or recovery finalizes it). After that the recording files are immutable. Editors keep their
/// own state in files the recorder never names, so no file has two writers.
public enum RecordingLayout {
    public static let packageExtension = "osrec"
    public static let manifest = "recording.json"
    public static let events = "events.ndjson"
    public static let screen = "screen.mov"
    public static let microphone = "microphone.mov"
    public static let cursorsDirectory = "cursors"
    public static let lock = ".lock"

    public static func cursorImage(_ id: String) -> String { "\(cursorsDirectory)/\(id).png" }

    /// `YYYYMMDD-HHMMSS.osrec`, local time, so a directory listing sorts by recording start.
    public static func directoryName(for start: Date, in timeZone: TimeZone = .current) -> String {
        fatalError("not implemented")
    }
}

/// Format version gate shared by the writer and every reader.
///
/// Additive changes (a new event type, a new optional manifest key) keep the version: readers
/// ignore event types and keys they do not know. Anything that changes the meaning of an existing
/// field bumps the version, and readers refuse versions newer than `current`.
public enum FormatVersion {
    public static let current = 1
    public static let identifier = "open-studio.recording"
}
