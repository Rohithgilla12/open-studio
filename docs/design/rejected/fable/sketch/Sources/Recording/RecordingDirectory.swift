import Foundation
import RecordingFormat

/// Writer side of the on-disk contract. Each file has exactly one writer and each JSON
/// file is written once, so there is no partially-updated state to recover beyond the
/// tail of `events.ndjson` and the last movie fragment.
struct RecordingDirectory: Sendable {
    let url: URL
    let events: EventLog

    /// Creates the directory and `cursors/`, writes `manifest.json` atomically.
    static func create(at url: URL, manifest: Manifest) throws -> RecordingDirectory {
        fatalError("not implemented")
    }

    var videoURL: URL { fatalError("not implemented") }

    func writeTimebase(_ timebase: Timebase) throws {
        fatalError("not implemented")
    }

    func writeFinish(_ finish: Finish) throws {
        fatalError("not implemented")
    }

    /// Writes the PNG only if the file does not already exist (same hash, same bytes).
    func storeCursorImage(id: CursorImageID, png: Data) throws -> String {
        fatalError("not implemented")
    }
}

/// The single append point for `events.ndjson`. Producers already carry their own
/// host-clock stamp, so append order is irrelevant and the actor only serialises bytes.
/// Each append is one `write(2)` of one line; once it returns, a process crash cannot
/// lose it (only power loss can, and we do not fsync for that).
actor EventLog {
    private let handle: FileHandle
    private(set) var count = 0

    init(fileURL: URL) throws {
        fatalError("not implemented")
    }

    func append(_ body: EventBody, at t: Int64) {
        // TODO: handle.write(try NDJSON.encodeLine(EventRecord(t: t, body: body)))
        // Encoding cannot fail for our own enum; if it ever does, drop and count as warning.
        fatalError("not implemented")
    }

    func close() {
        fatalError("not implemented")
    }
}
