import Foundation

/// The one place file names live. Recorder, reader, recovery and the CLI all go through it,
/// so a renamed file is a one-line change and a typo cannot make two modules disagree.
public struct RecordingLayout: Sendable, Hashable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public static let directoryExtension = "osrec"

    public var manifest: URL { root.appending(path: "manifest.json") }
    /// Held with flock(LOCK_EX) by the recording process. The kernel drops the lock when
    /// the process dies, so "lock is acquirable and manifest says recording" means crashed.
    public var lock: URL { root.appending(path: ".recording.lock") }
    public var video: URL { root.appending(path: "video/display.mp4") }
    public var microphone: URL { root.appending(path: "audio/mic.mp4") }
    public var input: URL { root.appending(path: "input.ndjson") }
    public var cursorChanges: URL { root.appending(path: "cursor.ndjson") }
    public var cursorCatalog: URL { root.appending(path: "cursors/catalog.ndjson") }
    public var cursorImages: URL { root.appending(path: "cursors", directoryHint: .isDirectory) }
    public func cursorImage(_ id: CursorImageID) -> URL { cursorImages.appending(path: "\(id.rawValue).png") }
}

/// Append-only JSON-lines encoding. One line per record, newline-terminated, written with a
/// single write(2). A crash can tear only the final line, and the reader drops it.
public enum LogLine {
    public struct InputRecord: Sendable {
        public enum Kind: Sendable {
            case move(DisplayPoint)
            case button(ButtonEvent.Phase, MouseButton, DisplayPoint, clickCount: Int)
            case scroll(DisplayPoint, dx: Double, dy: Double)
            case key(isRepeat: Bool, Modifiers)
        }
        public var host: HostTime
        public var kind: Kind
        public init(host: HostTime, kind: Kind) { self.host = host; self.kind = kind }
    }

    public static func encode(_ record: InputRecord) -> Data { fatalError("not implemented") }
    public static func encode(host: HostTime, cursor: CursorImageID) -> Data { fatalError("not implemented") }
    public static func encode(_ image: CursorImage) -> Data { fatalError("not implemented") }
}
