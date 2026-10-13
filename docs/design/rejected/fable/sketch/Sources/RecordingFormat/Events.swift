import Foundation

/// One line of `events.ndjson`.
///
/// Wire shape: `{"t":<Int64 nanos after clock.startHostNanos>,"type":"<case>", ...fields}`.
/// Lines are appended by three independent producers (event tap, cursor watcher, and the
/// session itself), so the file is not sorted; the reader sorts. The last line may be
/// truncated after a crash; the reader drops it.
public struct EventRecord: Sendable, Equatable {
    public var t: Int64
    public var body: EventBody

    public init(t: Int64, body: EventBody) {
        self.t = t
        self.body = body
    }
}

public enum EventBody: Sendable, Equatable {
    /// Positions are CoreGraphics global points (see `DisplayDescriptor.originX/Y`).
    case mouseMoved(x: Double, y: Double)
    case mouseDown(x: Double, y: Double, button: MouseButton, modifiers: Modifiers)
    case mouseUp(x: Double, y: Double, button: MouseButton, modifiers: Modifiers)
    case scrolled(x: Double, y: Double, deltaX: Double, deltaY: Double)
    case keyDown(modifiers: Modifiers, keyCode: UInt16?)
    case keyUp(modifiers: Modifiers, keyCode: UInt16?)
    /// Emitted once per distinct cursor bitmap, before the first `cursorChanged` that
    /// references it. Carries everything a renderer needs except the pixels.
    case cursorImageDefined(CursorImageDescriptor)
    case cursorChanged(cursorID: CursorImageID)
    /// Session-level marks: `recordingStarted`, `stopRequested`. Useful when verifying
    /// alignment by eye in `osrec inspect`.
    case mark(String)
}

public enum MouseButton: String, Codable, Sendable {
    case left, right, other
}

public struct Modifiers: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = Modifiers(rawValue: 1 << 0)
    public static let control = Modifiers(rawValue: 1 << 1)
    public static let option = Modifiers(rawValue: 1 << 2)
    public static let command = Modifiers(rawValue: 1 << 3)
}

public struct CursorImageDescriptor: Codable, Sendable, Equatable {
    public var id: CursorImageID
    /// Relative to the recording directory, e.g. `cursors/3f9c…png`.
    public var fileName: String
    /// Points, origin top-left of the bitmap.
    public var hotspotX: Double
    public var hotspotY: Double
    public var pointWidth: Double
    public var pointHeight: Double
    public var scaleFactor: Double
    /// `NSCursor`'s name if one is known (`arrow`, `iBeam`, …) for debugging only.
    public var systemName: String?
}

extension EventRecord: Codable {
    private enum CodingKeys: String, CodingKey {
        case t, type, x, y, deltaX, deltaY, button, modifiers, keyCode, cursorID, cursor, mark
    }

    public init(from decoder: any Decoder) throws {
        // TODO: switch on `type`, decode only the keys that case carries; unknown type -> throw
        // so the reader counts it as an invalid line instead of guessing.
        fatalError("not implemented")
    }

    public func encode(to encoder: any Encoder) throws {
        fatalError("not implemented")
    }
}

/// Newline-delimited JSON. Encode one record to one line; decode a whole file tolerantly.
public enum NDJSON {
    public struct DecodeReport: Sendable, Equatable {
        public var records: [EventRecord]
        /// True when the final line had no trailing newline or did not parse: the process
        /// died mid-write. Expected on a recovered take, a bug on a completed one.
        public var truncatedTail: Bool
        public var invalidLines: Int
    }

    /// Returns exactly one line including the trailing `\n`, with no embedded newlines.
    public static func encodeLine(_ record: EventRecord) throws -> Data {
        fatalError("not implemented")
    }

    public static func decode(_ data: Data) -> DecodeReport {
        // TODO: split on \n; decode each; count failures; flag tail if last byte != \n
        fatalError("not implemented")
    }
}
