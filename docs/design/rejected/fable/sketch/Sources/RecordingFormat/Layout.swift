import Foundation

/// Bumped only when an existing reader could misinterpret a file. Adding an optional
/// field is not a bump; renaming or re-basing a timestamp is.
public enum RecordingFormatVersion {
    public static let current = 1
    public static let supported: ClosedRange<Int> = 1...1
}

/// File names inside a recording directory. Both the writer (Recording) and the reader
/// (Timeline) go through this so the contract has one spelling.
///
/// Lifecycle of the files, in write order:
///
///   manifest.json   written once before any capture starts; immutable
///   events.ndjson   append-only for the whole take; not guaranteed time-ordered
///   cursors/*.png   written the first time a cursor image is seen
///   display.mov     fragmented QuickTime; playable up to the last complete fragment
///   timebase.json   written once, when the first video frame is handed to the writer
///   finish.json     written last, on a clean stop; its absence means "recover"
public enum RecordingDirectoryLayout {
    public static let directoryExtension = "osrec"
    public static let manifest = "manifest.json"
    public static let timebase = "timebase.json"
    public static let finish = "finish.json"
    public static let events = "events.ndjson"
    public static let video = "display.mov"
    public static let cursorsDirectory = "cursors"

    public static func cursorImage(id: CursorImageID) -> String {
        "\(cursorsDirectory)/\(id.rawValue).png"
    }
}

/// Content hash of the cursor bitmap (first 16 hex chars of SHA-256 of the PNG bytes), so
/// the same system cursor seen twice gets one file and one id across takes.
public struct CursorImageID: RawRepresentable, Hashable, Codable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}
