import Foundation

/// One line of `events.ndjson`. The single list of event kinds: the recorder encodes these and
/// Timeline decodes these, so adding a kind is one edit here plus a compile error at each switch.
///
/// Times are microseconds of screen media time (see `WireManifest`). Coordinates are screen
/// video pixels.
public enum WireEvent: Sendable, Equatable {
    /// Defines a cursor image before any line references it. No timestamp: it is a declaration.
    /// The PNG at `RecordingLayout.cursorImage(id)` is fully written (temp file + rename) before
    /// this line is appended, so a crash can never leave a reference to a missing image.
    case cursorImage(id: String, hotspot: WirePoint, size: WireSize)

    /// Written once, at t = 0, so the stream is self-contained from the first frame: pointer
    /// position, held buttons, and cursor image are known without looking back before 0.
    case state(t: Int64, position: WirePoint, buttons: [WireButton], cursor: String?)

    case move(t: Int64, position: WirePoint)
    case down(t: Int64, button: WireButton, position: WirePoint, clickCount: Int)
    case up(t: Int64, button: WireButton, position: WirePoint)
    case scroll(t: Int64, position: WirePoint, dx: Double, dy: Double)

    /// A key press. `keyCode` is recorded only while Command or Control is held, so ordinary
    /// typing (including passwords) never reaches disk; the typing-fade rule needs only the times.
    case key(t: Int64, modifiers: [WireModifier], keyCode: UInt16?)

    case cursor(t: Int64, id: String)

    /// A line whose `type` this reader does not know. Kept so additive format changes do not
    /// break old readers; Timeline drops these.
    case unknown(type: String)
}

public struct WirePoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
}

public struct WireSize: Codable, Sendable, Equatable {
    public var width: Double
    public var height: Double
}

public enum WireButton: String, Codable, Sendable {
    case left, right, other
}

public enum WireModifier: String, Codable, Sendable {
    case shift, control, option, command, function, capsLock
}

extension WireEvent: Codable {
    // Flat objects with a "type" discriminator, e.g. {"t":512000,"type":"down","button":"left",
    // "x":1210.5,"y":644.0,"clickCount":1}. Points and sizes are flattened (x/y, hotspotX/hotspotY,
    // width/height) so lines stay greppable. docs/design/candidate/recording-directory-example.md
    // shows every kind.
    public init(from decoder: any Decoder) throws {
        fatalError("not implemented")
    }

    public func encode(to encoder: any Encoder) throws {
        fatalError("not implemented")
    }
}

/// NDJSON framing for `events.ndjson`.
public enum EventLog {
    /// One line, terminated by "\n". The recorder appends batches of these with a single write(2).
    public static func encodeLine(_ event: WireEvent) throws -> Data {
        fatalError("not implemented")
    }

    /// Decodes a whole file.
    ///
    /// A process crash can only tear the final line (earlier lines were complete write(2) calls).
    /// So: a malformed final line without a trailing newline is reported as `tornTail` and skipped;
    /// a malformed line anywhere else is a hard error. Returns the byte length of the valid prefix
    /// so recovery can truncate to it.
    public static func decode(_ data: Data) throws(FormatError) -> DecodedEventLog {
        fatalError("not implemented")
    }
}

public struct DecodedEventLog: Sendable {
    public var events: [WireEvent]
    public var validByteCount: Int
    public var tornTail: Bool
}
