import Foundation

/// Display-local point, top-left origin. The same space CGEvent.location uses once the
/// display's global origin is subtracted, so no axis flip is ever needed.
public struct DisplayPoint: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public enum MouseButton: String, Sendable, Codable { case left, right, other }

public struct Modifiers: OptionSet, Sendable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = Modifiers(rawValue: 1 << 0)
    public static let control = Modifiers(rawValue: 1 << 1)
    public static let option = Modifiers(rawValue: 1 << 2)
    public static let command = Modifiers(rawValue: 1 << 3)
}

/// Keystrokes carry timing and modifiers only. There is deliberately no key code or
/// character field: the recorder cannot leak a password because the type cannot hold one.
public struct KeyTick: Hashable, Sendable {
    public var time: RecordingTime
    public var isRepeat: Bool
    public var modifiers: Modifiers
}

public struct PointerSample: Hashable, Sendable {
    public var time: RecordingTime
    public var position: DisplayPoint
}

public struct ButtonEvent: Hashable, Sendable {
    public enum Phase: Sendable { case down, up }
    public var time: RecordingTime
    public var phase: Phase
    public var button: MouseButton
    public var position: DisplayPoint
    public var clickCount: Int
}

public struct ScrollEvent: Hashable, Sendable {
    public var time: RecordingTime
    public var position: DisplayPoint
    public var deltaX: Double
    public var deltaY: Double
}

public struct CursorImageID: Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(stringLiteral value: String) { rawValue = value }
    public init(_ value: String) { rawValue = value }
    /// Used when a change references an image the catalog lost; the renderer draws an arrow.
    public static let fallbackArrow: CursorImageID = "system-arrow"
}

public struct CursorImage: Hashable, Sendable, Codable {
    public var id: CursorImageID
    /// Relative to the recording directory.
    public var file: String
    /// Offset of the click point from the image's top-left, in points.
    public var hotspot: DisplayPoint
    public var pointSize: Double2
    public var scale: Double

    public struct Double2: Hashable, Sendable, Codable {
        public var width: Double
        public var height: Double
    }
}

public struct CursorChange: Hashable, Sendable {
    public var time: RecordingTime
    public var image: CursorImageID
}
