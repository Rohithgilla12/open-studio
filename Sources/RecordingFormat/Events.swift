import Foundation

/// One line of `events.ndjson`, and the single list of event kinds. The recorder encodes these and
/// Timeline decodes these, so a new kind is one case here plus a compile error at each switch.
///
/// Times are `MediaTime`. Coordinates and sizes are screen video pixels.
public enum WireEvent: Sendable, Hashable {
    /// Declares a cursor image. It has no time because it is a declaration, not an occurrence. Its
    /// PNG is on disk before this line is written, and this line comes before any reference to it.
    case cursorImage(CursorImageDeclaration)

    /// The pointer, held buttons, and cursor image at `t`. Written at t = 0 so the stream is
    /// self-contained from the first frame.
    case state(t: MediaTime, position: WirePoint, buttons: Set<WireButton>, cursor: CursorImageID?)

    /// Pointer movement, including drags. Whether a button is held follows from `down` and `up`.
    case move(t: MediaTime, position: WirePoint)
    case down(t: MediaTime, button: WireButton, position: WirePoint, clickCount: Int)
    case up(t: MediaTime, button: WireButton, position: WirePoint)

    /// Scroll deltas as the event reported them. Recorded for later features, unused by auto-zoom.
    case scroll(t: MediaTime, position: WirePoint, dx: Double, dy: Double)

    case key(t: MediaTime, stroke: KeyStroke)
    case cursor(t: MediaTime, id: CursorImageID)
}

public struct CursorImageDeclaration: Sendable, Hashable {
    public let id: CursorImageID
    public let hotspot: WirePoint
    public let size: WireSize

    public init(id: CursorImageID, hotspot: WirePoint, size: WireSize) {
        self.id = id
        self.hotspot = hotspot
        self.size = size
    }
}

public enum WireButton: String, Sendable, Hashable, CaseIterable, Codable {
    case left, right, other
}

public enum WireModifier: String, Sendable, Hashable, CaseIterable, Codable {
    case shift, control, option, command, function, capsLock
}

/// A key press, without the typed text.
///
/// The key code survives only for shortcuts, while Command or Control is held. Ordinary typing,
/// passwords included, is stored as a time and modifiers alone. The typing-fade rule needs only
/// the times.
public struct KeyStroke: Sendable, Hashable {
    public let modifiers: Set<WireModifier>
    public let keyCode: UInt16?

    /// The privacy rule lives here, so no caller can write a plain key code by mistake.
    public init(modifiers: Set<WireModifier>, pressedKeyCode: UInt16) {
        self.modifiers = modifiers
        keyCode = Self.isShortcut(modifiers) ? pressedKeyCode : nil
    }

    /// Fails for a key code recorded without Command or Control, which the format forbids.
    init?(modifiers: Set<WireModifier>, recordedKeyCode: UInt16?) {
        if recordedKeyCode != nil, !Self.isShortcut(modifiers) { return nil }
        self.modifiers = modifiers
        keyCode = recordedKeyCode
    }

    private static func isShortcut(_ modifiers: Set<WireModifier>) -> Bool {
        modifiers.contains(.command) || modifiers.contains(.control)
    }
}

/// The `type` discriminator of each line. `WireEvent.kind` switches exhaustively over the events
/// and decoding switches exhaustively over the kinds, so the two cannot drift apart.
enum WireEventKind: String, CaseIterable {
    case cursorImage, state, move, down, up, scroll, key, cursor
}

extension WireEvent {
    var kind: WireEventKind {
        switch self {
        case .cursorImage: .cursorImage
        case .state: .state
        case .move: .move
        case .down: .down
        case .up: .up
        case .scroll: .scroll
        case .key: .key
        case .cursor: .cursor
        }
    }
}

/// Flat objects with a `type` discriminator, such as
/// `{"button":"left","clickCount":1,"t":512000,"type":"down","x":1210.5,"y":644}`. Points and
/// sizes are flattened so lines stay greppable.
enum WireEventKey: String, CodingKey {
    case type, t, x, y, buttons, cursor, button, clickCount, dx, dy, modifiers, keyCode, id
    case hotspotX, hotspotY, width, height
}

extension WireEvent: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: WireEventKey.self)
        let type = try container.decode(String.self, forKey: .type)
        guard let kind = WireEventKind(rawValue: type) else {
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "unknown event type \(type)")
        }
        try self.init(kind: kind, container: container)
    }

    init(kind: WireEventKind, container c: KeyedDecodingContainer<WireEventKey>) throws {
        func t() throws -> MediaTime { try c.decode(MediaTime.self, forKey: .t) }
        func position() throws -> WirePoint {
            WirePoint(x: try c.decode(Double.self, forKey: .x), y: try c.decode(Double.self, forKey: .y))
        }
        switch kind {
        case .cursorImage:
            self = .cursorImage(CursorImageDeclaration(
                id: try c.decode(CursorImageID.self, forKey: .id),
                hotspot: WirePoint(
                    x: try c.decode(Double.self, forKey: .hotspotX), y: try c.decode(Double.self, forKey: .hotspotY)),
                size: WireSize(
                    width: try c.decode(Double.self, forKey: .width), height: try c.decode(Double.self, forKey: .height))))
        case .state:
            self = .state(
                t: try t(), position: try position(),
                buttons: Set(try c.decode([WireButton].self, forKey: .buttons)),
                cursor: try c.decodeIfPresent(CursorImageID.self, forKey: .cursor))
        case .move:
            self = .move(t: try t(), position: try position())
        case .down:
            self = .down(
                t: try t(), button: try c.decode(WireButton.self, forKey: .button), position: try position(),
                clickCount: try c.decode(Int.self, forKey: .clickCount))
        case .up:
            self = .up(t: try t(), button: try c.decode(WireButton.self, forKey: .button), position: try position())
        case .scroll:
            self = .scroll(
                t: try t(), position: try position(),
                dx: try c.decode(Double.self, forKey: .dx), dy: try c.decode(Double.self, forKey: .dy))
        case .key:
            let modifiers = Set(try c.decode([WireModifier].self, forKey: .modifiers))
            guard let stroke = KeyStroke(
                modifiers: modifiers, recordedKeyCode: try c.decodeIfPresent(UInt16.self, forKey: .keyCode))
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .keyCode, in: c, debugDescription: "keyCode recorded without Command or Control")
            }
            self = .key(t: try t(), stroke: stroke)
        case .cursor:
            self = .cursor(t: try t(), id: try c.decode(CursorImageID.self, forKey: .id))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: WireEventKey.self)
        try c.encode(kind.rawValue, forKey: .type)
        func position(_ p: WirePoint) throws {
            try c.encode(p.x, forKey: .x)
            try c.encode(p.y, forKey: .y)
        }
        switch self {
        case .cursorImage(let declaration):
            try c.encode(declaration.id, forKey: .id)
            try c.encode(declaration.hotspot.x, forKey: .hotspotX)
            try c.encode(declaration.hotspot.y, forKey: .hotspotY)
            try c.encode(declaration.size.width, forKey: .width)
            try c.encode(declaration.size.height, forKey: .height)
        case .state(let t, let p, let buttons, let cursor):
            try c.encode(t, forKey: .t)
            try position(p)
            try c.encode(WireButton.allCases.filter(buttons.contains), forKey: .buttons)
            try c.encodeIfPresent(cursor, forKey: .cursor)
        case .move(let t, let p):
            try c.encode(t, forKey: .t)
            try position(p)
        case .down(let t, let button, let p, let clickCount):
            try c.encode(t, forKey: .t)
            try c.encode(button, forKey: .button)
            try position(p)
            try c.encode(clickCount, forKey: .clickCount)
        case .up(let t, let button, let p):
            try c.encode(t, forKey: .t)
            try c.encode(button, forKey: .button)
            try position(p)
        case .scroll(let t, let p, let dx, let dy):
            try c.encode(t, forKey: .t)
            try position(p)
            try c.encode(dx, forKey: .dx)
            try c.encode(dy, forKey: .dy)
        case .key(let t, let stroke):
            try c.encode(t, forKey: .t)
            try c.encode(WireModifier.allCases.filter(stroke.modifiers.contains), forKey: .modifiers)
            try c.encodeIfPresent(stroke.keyCode, forKey: .keyCode)
        case .cursor(let t, let id):
            try c.encode(t, forKey: .t)
            try c.encode(id, forKey: .id)
        }
    }
}
