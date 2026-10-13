import Foundation
import RecordingFormat

/// A loaded recording. Immutable value: everything a renderer or editor needs to know
/// about the source, with time re-based so that `.zero` is the first video frame and
/// positions re-based so that `Point.zero` is the recorded display's top-left, in points.
///
/// Invariants (enforced by the parsing initialiser, trusted afterwards):
/// - every track array is sorted by time, ascending, stable
/// - no event has a negative time (events before the first frame are dropped)
/// - every `CursorChange.cursorID` has an entry in `cursors`
public struct Take: Sendable, Equatable {
    public enum Integrity: Sendable, Equatable {
        case complete
        /// `finish.json` was missing. `duration` is an estimate from the last event; the
        /// renderer must trust the movie's own duration over it.
        case recovered(truncatedEventTail: Bool)
    }

    public let id: UUID
    public let directory: URL
    public let display: Display
    public let video: Video
    public let duration: Duration
    public let integrity: Integrity
    public let input: InputTrack
    public let cursors: [CursorImageID: CursorImage]

    public struct Display: Sendable, Equatable {
        public var size: Size
        public var pixelSize: Size
        public var scaleFactor: Double
    }

    public struct Video: Sendable, Equatable {
        public var url: URL
        public var frameRate: Int
        public var hasMicrophoneTrack: Bool
    }

    /// Pure parse from already-read bytes. Tests build takes from literals through this.
    public init(
        directory: URL,
        manifest: Manifest,
        timebase: Timebase,
        finish: Finish?,
        events: NDJSON.DecodeReport
    ) throws(TakeLoadError) {
        // TODO:
        // guard RecordingFormatVersion.supported.contains(manifest.formatVersion)
        // rebase: t_rec = record.t - timebase.firstVideoFrameOffsetNanos, drop < 0
        // positions: Point(x - display.originX, y - display.originY)
        // pair mouseDown/Up by button in time order -> Click(time, release, position)
        // collect cursorImageDefined -> cursors; cursorChanged -> changes (reject unknown id)
        // sort each track (stable)
        // duration: finish?.durationNanos ?? last event time; integrity accordingly
        fatalError("not implemented")
    }
}

public struct InputTrack: Sendable, Equatable {
    public let moves: [MouseSample]
    public let clicks: [Click]
    public let scrolls: [ScrollSample]
    public let keyPresses: [KeyPress]
    public let cursorChanges: [CursorChange]

    /// Index of the last element with `time <= t`, or nil. Every per-frame query is one
    /// of these, so the tracks stay plain sorted arrays and need no side index.
    public static func lastIndex<T: Timed>(in track: [T], atOrBefore t: Duration) -> Int? {
        fatalError("not implemented")
    }
}

public protocol Timed: Sendable {
    var time: Duration { get }
}

public struct MouseSample: Timed, Sendable, Equatable {
    public var time: Duration
    public var position: Point
}

public struct Click: Timed, Sendable, Equatable {
    public var time: Duration
    /// nil when the recording ended with the button still down.
    public var release: Duration?
    public var position: Point
    public var button: MouseButton
}

public struct ScrollSample: Timed, Sendable, Equatable {
    public var time: Duration
    public var position: Point
    public var delta: Point
}

public struct KeyPress: Timed, Sendable, Equatable {
    public var time: Duration
    public var modifiers: Modifiers
    public var keyCode: UInt16?
}

public struct CursorChange: Timed, Sendable, Equatable {
    public var time: Duration
    public var cursorID: CursorImageID
}

public struct CursorImage: Sendable, Equatable {
    public var id: CursorImageID
    /// Resolved against `Take.directory`. Timeline never decodes it.
    public var url: URL
    public var hotspot: Point
    public var size: Size
    public var scaleFactor: Double
}

public enum TakeLoadError: Error, Sendable, Equatable {
    case notADirectory(URL)
    case missingFile(String)
    /// `timebase.json` absent: the recorder died before its first frame. Nothing to show.
    case neverStarted
    case unsupportedVersion(Int)
    case malformed(file: String, reason: String)
}
