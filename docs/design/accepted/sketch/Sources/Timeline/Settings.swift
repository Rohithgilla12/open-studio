/// A damped harmonic oscillator: m x'' + c x' + k (x - target) = 0.
public struct Spring: Sendable, Hashable, Codable {
    public var stiffness: Double
    public var damping: Double
    public var mass: Double

    public init(stiffness: Double, damping: Double, mass: Double) {
        self.stiffness = stiffness; self.damping = damping; self.mass = mass
    }

    public static let camera = Spring(stiffness: 125, damping: 12, mass: 1.5)
    public static let cursorSmooth = Spring(stiffness: 470, damping: 70, mass: 3)
    public static let cursorMedium = Spring(stiffness: 340, damping: 60, mass: 3)
    public static let cursorRapid = Spring(stiffness: 530, damping: 40, mass: 1)

    /// Time until the envelope of |x - target| falls below `precision` of the step, from rest.
    /// Used to decide when a short interval needs a stiffer spring.
    public func settleTime(precision: Double = 0.002) -> Double { fatalError("not implemented") }
}

public struct AutoZoomSettings: Sendable, Hashable, Codable {
    public var windowBefore: RecordingTime = .milliseconds(300)
    public var windowAfter: RecordingTime = .milliseconds(2500)
    /// Windows whose gap is at most this merge into one segment.
    public var mergeGap: RecordingTime = .milliseconds(2500)
    /// Clicks in the final second start no zoom.
    public var ignoreClicksInFinal: RecordingTime = .milliseconds(1000)
    /// Segments end at least this long before the recording ends, so the zoom-out finishes on screen.
    public var endMargin: RecordingTime = .milliseconds(800)
    public var scale: Double = 2

    public init() {}
}

public struct CameraSettings: Sendable, Hashable, Codable {
    public var spring: Spring = .camera
    /// Start zooming in this long before a segment begins. 0 disables the lead-in.
    public var leadIn: RecordingTime = .zero
    /// Pointer samples closer than this to the previous kept sample are dropped before grouping.
    public var thinningDistance: Double = 10
    /// Manhattan distance; see `CursorSettings.shakeThreshold`.
    public var shakeThreshold: Double = 500
    /// When a target holds for less than the spring's settle time, stiffen the spring so it arrives:
    /// k *= (T / available)^2, c *= T / available.
    public var rescaleShortIntervals: Bool = true

    public init() {}
}

public struct CursorSettings: Sendable, Hashable, Codable {
    public var spring: Spring = .cursorMedium
    /// The cursor switches to this spring shortly before each mouse-down, so it lands on the click.
    public var clickSpring: Spring = .cursorRapid
    public var clickSpringLead: RecordingTime = .milliseconds(175)
    /// A sample that jumps more than this (Manhattan, pixels) from its predecessor and whose successor
    /// comes back within the same distance is a glitch and is dropped.
    public var shakeThreshold: Double = 500
    public var pressedScale: Double = 0.9
    public var pressTransition: RecordingTime = .milliseconds(80)
    /// Typing: at least `typingKeyCount` key presses within `typingWindow` hides the cursor.
    public var typingKeyCount: Int = 3
    public var typingWindow: RecordingTime = .milliseconds(1800)
    public var fadeDuration: RecordingTime = .milliseconds(150)
    /// nil disables idle hiding.
    public var idleHideAfter: RecordingTime? = nil

    public init() {}
}

/// Every tunable Timeline uses. Codable so the editor can persist it with its other edit state.
public struct TimelineSettings: Sendable, Hashable, Codable {
    public var autoZoom = AutoZoomSettings()
    public var camera = CameraSettings()
    public var cursor = CursorSettings()

    public init() {}
    public static let `default` = TimelineSettings()
}
