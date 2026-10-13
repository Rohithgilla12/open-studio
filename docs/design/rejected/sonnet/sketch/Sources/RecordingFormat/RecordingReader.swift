import Foundation

/// A validated recording. Every invariant below holds for any value of this type, so
/// Timeline can trust it without re-checking.
///
/// Invariants:
/// - manifest.status == .finalized and finalisation is non-nil
/// - duration > 0
/// - every array is sorted by time (stable) and every time is in 0...duration
/// - every ButtonEvent .up has a preceding .down of the same button; strays are dropped
/// - every CursorChange.image resolves in cursorImages (else replaced by .fallbackArrow)
public struct LoadedRecording: Sendable {
    public let manifest: RecordingManifest
    public let layout: RecordingLayout
    public let duration: RecordingTime
    public let displaySize: RecordingManifest.Size
    public let pointer: [PointerSample]
    public let buttons: [ButtonEvent]
    public let scrolls: [ScrollEvent]
    public let keys: [KeyTick]
    public let cursorChanges: [CursorChange]
    public let cursorImages: [CursorImageID: CursorImage]
    public let diagnostics: [Diagnostic]
}

public struct Diagnostic: Sendable, Equatable {
    public enum Severity: Sendable { case info, warning }
    public var severity: Severity
    public var message: String
}

public enum RecordingReadError: Error, Sendable, Equatable {
    case notARecording(URL)
    case unsupportedVersion(found: Int, supported: Int)
    case unsupportedClock(String)
    /// Manifest says .recording. Carries what to do about it.
    case needsRecovery(RecordingHealth)
    case missingFile(String)
    case malformed(file: String, reason: String)
}

public enum RecordingHealth: Sendable, Equatable {
    case finalized
    /// Another process holds the lock right now.
    case beingRecorded(pid: Int32?)
    /// Manifest says recording, nobody holds the lock.
    case crashed
    /// Crashed and there is nothing to salvage, e.g. no first frame.
    case unrecoverable(reason: String)
}

public struct ReadOptions: Sendable {
    /// Tests read metadata-only fixtures; production insists the media files exist.
    public var requireMedia: Bool = true
    public static let `default` = ReadOptions()
    public static let metadataOnly = ReadOptions(requireMedia: false)
}

public enum RecordingReader {
    /// Single boundary where bytes become domain types.
    public static func read(_ root: URL, options: ReadOptions = .default) throws(RecordingReadError) -> LoadedRecording {
        // TODO:
        //  1. decode manifest; check formatVersion == currentFormatVersion, clock.kind
        //  2. health = RecordingHealth.probe(layout); anything but .finalized throws needsRecovery
        //  3. for each ndjson file: split on "\n", decode each line independently;
        //     a line that fails to decode becomes a Diagnostic and is skipped; unknown "k" skipped
        //  4. convert host -> RecordingTime with RecordingTime(host:origin:)
        //  5. drop times outside 0...duration; stable sort; pair button down/up
        //  6. resolve cursor ids against the catalog
        fatalError("not implemented")
    }
}

extension RecordingHealth {
    /// flock(LOCK_EX | LOCK_NB) on .recording.lock, released immediately after the probe.
    public static func probe(_ layout: RecordingLayout) -> RecordingHealth { fatalError("not implemented") }
}
