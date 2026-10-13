import RecordingFormat

/// Resolution-independent screen coordinates: 0...1, top-left origin. The renderer scales
/// to whatever output size it draws, so zoom and cursor maths never see pixels.
public struct NormalizedPoint: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let center = NormalizedPoint(x: 0.5, y: 0.5)
}

public struct NormalizedRect: Hashable, Sendable {
    public var origin: NormalizedPoint
    public var width: Double
    public var height: Double
}

/// Where the virtual camera is. `visibleRect` is the region of the source frame to draw
/// full-size. Invariant: scale >= 1 and visibleRect lies inside 0...1 on both axes.
public struct CameraState: Hashable, Sendable {
    public let scale: Double
    public let center: NormalizedPoint
    public var visibleRect: NormalizedRect { fatalError("not implemented") }
}

/// What to draw for the cursor at one instant.
public struct CursorState: Hashable, Sendable {
    /// Hotspot position in the source frame.
    public var position: NormalizedPoint
    /// Look up in `Timeline.cursorImages` for the bitmap and hotspot offset.
    public var image: CursorImageID
    public var isPressed: Bool
    /// 0...1. Fades while typing. The renderer multiplies it into the sprite alpha.
    public var opacity: Double
    /// False when the pointer is on another display, or idle-hide is on and elapsed.
    public var isVisible: Bool
}

public struct ZoomSegment: Hashable, Sendable, Codable, Identifiable {
    /// Derived from `range.start` and `origin`, never random, so regenerating an auto segment
    /// yields the same id and an edit keyed on it survives.
    public var id: ID
    public var range: TimeRange
    public var scale: Double
    public var focus: Focus
    public var origin: Origin

    public struct ID: Hashable, Sendable, Codable { public var rawValue: String }
    public enum Origin: String, Sendable, Codable { case automatic, manual }
    public enum Focus: Hashable, Sendable, Codable {
        /// Camera follows the time-weighted centroid of pointer groups (the auto behaviour).
        case followPointer
        case fixed(NormalizedPoint)
    }
}
