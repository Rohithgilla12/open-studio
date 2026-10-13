public import Foundation

/// What a recording directory is, from a reader's point of view.
public enum RecordingHealth: Sendable, Equatable {
    /// The manifest is finalized. Safe to read as a whole.
    case finalized
    /// A live recorder holds the lock. Leave the directory alone.
    case live
    /// The manifest still says recording and no one holds the lock: the recorder died. Recovery
    /// can finalize it.
    case crashed
    /// No manifest and no live recorder: the recorder died before the first frame. Nothing to keep.
    case unrecoverable
}

/// A recording's manifest and events, decoded but not interpreted. Timeline, recovery, and
/// `osrec inspect` turn this into their own domain types.
public struct RecordingMetadata: Sendable {
    public let layout: RecordingLayout
    public let manifest: WireManifest
    public let events: DecodedEventLog
    /// Whether a live recorder held the lock when the directory was read.
    public let recorderAlive: Bool

    public var health: RecordingHealth { RecordingHealth(status: manifest.status, recorderAlive: recorderAlive) }
}

extension RecordingHealth {
    init(status: ManifestStatus, recorderAlive: Bool) {
        switch status {
        case .finalized: self = .finalized
        case .recording: self = recorderAlive ? .live : .crashed
        }
    }
}

public enum RecordingReader {
    /// Reads only the lock and the manifest, so a launch-time scan of a library stays cheap.
    public static func health(at directory: URL) throws(FormatError) -> RecordingHealth {
        let layout = try recordingLayout(at: directory)
        let alive = try DirectoryLock.isHeld(in: layout)
        guard let manifest = try manifest(in: layout) else { return alive ? .live : .unrecoverable }
        return RecordingHealth(status: manifest.status, recorderAlive: alive)
    }

    /// Reads `recording.json` and `events.ndjson`, never the media or cursor PNGs, in any state
    /// that has a manifest.
    ///
    /// Checks only what the format guarantees: the version gate, a decodable manifest and log, and
    /// no torn tail once finalized. A recording that is still being written may lack its event log.
    /// Semantic checks belong to the consumer.
    public static func read(at directory: URL) throws(FormatError) -> RecordingMetadata {
        let layout = try recordingLayout(at: directory)
        let alive = try DirectoryLock.isHeld(in: layout)
        guard let manifest = try manifest(in: layout) else { throw .noManifest(directory) }

        let finalized = if case .finalized = manifest.status { true } else { false }
        let data: Data
        do {
            data = try Data(contentsOf: layout.events)
        } catch CocoaError.fileReadNoSuchFile where !finalized {
            data = Data()
        } catch {
            throw .eventsUnreadable(detail: String(describing: error))
        }
        let events = try EventLog.decode(data)
        if finalized, events.tornTailByteCount > 0 {
            throw .tornTailInFinalizedRecording(byteCount: events.tornTailByteCount)
        }
        return RecordingMetadata(layout: layout, manifest: manifest, events: events, recorderAlive: alive)
    }

    private static func recordingLayout(at directory: URL) throws(FormatError) -> RecordingLayout {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw .notARecordingDirectory(directory) }
        return RecordingLayout(directory: directory)
    }

    /// The lock is probed before this runs. A recorder commits its final manifest before it drops
    /// the lock, so a lock seen free means the manifest read next is the last one it wrote.
    private static func manifest(in layout: RecordingLayout) throws(FormatError) -> WireManifest? {
        let data: Data
        do {
            data = try Data(contentsOf: layout.manifest)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            throw .manifestUnreadable(detail: String(describing: error))
        }
        return try WireManifest.decode(data)
    }
}
