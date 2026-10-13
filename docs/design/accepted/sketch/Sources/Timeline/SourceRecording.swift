import Foundation
internal import RecordingFormat

/// The validated facts of one finalized recording. Immutable; built only by `load(from:)`.
///
/// Every array is sorted by time and every reference resolves, so code that takes a
/// `SourceRecording` never re-checks the file.
public struct SourceRecording: Sendable {
    public let id: UUID
    public let directory: URL
    public let duration: RecordingTime
    /// Screen video size in pixels. Every `Point` in this model is in this space.
    public let frameSize: Size
    public let hasMicrophone: Bool
    public let termination: SourceTermination

    /// Every pointer position: the t = 0 state, moves, drags, downs, and ups. Sorted by time.
    public let pointer: [PointerSample]
    /// Button transitions. Both downs and ups feed auto-zoom (each up extends the click's window by the
    /// press duration, matching the observed behaviour).
    public let buttons: [ButtonEvent]
    /// Times of key presses. Key codes are not exposed; nothing in Timeline needs them.
    public let keyDowns: [RecordingTime]
    /// Which cursor image is showing from each time on. The first entry is at t = 0 when the state
    /// line named a cursor.
    public let cursorChanges: [CursorChange]
    public let cursorImages: [CursorImageID: CursorImageInfo]

    /// Diagnostics found while loading (torn event tail after recovery, events past the end,
    /// out-of-order lines that were re-sorted). Loading succeeded despite them.
    public let loadWarnings: [String]

    /// Reads `recording.json` and `events.ndjson` (never the media), then validates into the domain.
    ///
    /// This is the only I/O in Timeline, kept at the edge; everything after it is pure.
    public static func load(from directory: URL) throws(SourceLoadError) -> SourceRecording {
        // TODO:
        // let metadata = try RecordingReader.readMetadata(at: directory)   // map FormatError
        // guard metadata.manifest.status == .finalized else { throw .notFinalized }
        // return try SourceRecording(metadata)
        fatalError("not implemented")
    }

    /// Pure: wire values in, domain out. Internal so tests can feed synthetic metadata.
    init(_ metadata: RecordingMetadata) throws(SourceLoadError) {
        // TODO:
        // - Stable-sort events by t. The recorder merges per batch, so cross-batch inversions of a few
        //   ms are possible; sorting once here means no consumer ever has to.
        // - Drop .unknown events. Drop events with t < 0 (there should be none) and keep events past
        //   `duration` but clamp nothing: queries clamp t instead.
        // - Expand .state into a pointer sample, a down event per held button at t = 0, and a cursor
        //   change at t = 0.
        // - Resolve cursor references: a reference to an undeclared id becomes a nil image change and a
        //   warning, rather than a load failure (the cursor falls back to the renderer's default arrow).
        // - Require finite coordinates; non-finite is a hard error (the file is corrupt, not torn).
        fatalError("not implemented")
    }
}

public struct PointerSample: Sendable, Hashable {
    public let time: RecordingTime
    public let position: Point
}

public struct ButtonEvent: Sendable, Hashable {
    public enum Button: Sendable, Hashable { case left, right, other }
    public enum Edge: Sendable, Hashable { case down, up }

    public let time: RecordingTime
    public let button: Button
    public let edge: Edge
    public let position: Point
}

public struct CursorImageID: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct CursorChange: Sendable, Hashable {
    public let time: RecordingTime
    /// nil when the recorder referenced an image it never declared.
    public let image: CursorImageID?
}

public struct CursorImageInfo: Sendable, Hashable {
    /// Relative to `SourceRecording.directory`. The renderer loads it; Timeline never does.
    public let relativePath: String
    /// Screen pixels.
    public let hotspot: Point
    /// Screen pixels: the size to draw at 1x camera zoom.
    public let size: Size
}

public enum SourceTermination: Sendable, Hashable {
    case userStopped
    case durationReached
    case streamFailed(String)
    case recovered(String?)
}

public enum SourceLoadError: Error, Sendable, Equatable {
    case notARecording(URL)
    /// Status is still `recording`: run `osrec recover` (or `RecordingSession.recover`) first.
    case notFinalized
    case unsupportedVersion(found: Int, supported: Int)
    case corrupt(String)
}
