import Foundation

/// A damped harmonic oscillator: m x'' + c x' + k (x - target) = 0.
public struct Spring: Sendable, Hashable, Codable {
    public var stiffness: Double
    public var damping: Double
    public var mass: Double

    public init(stiffness: Double, damping: Double, mass: Double) {
        self.stiffness = stiffness
        self.damping = damping
        self.mass = mass
    }

    /// The observed product's "Focused" screen animation. Damping ratio about 0.84, so the
    /// zoom-out barely overshoots and settles in about 0.7 s, inside the 800 ms end margin.
    public static let screenFocused = Spring(stiffness: 250, damping: 40, mass: 2.25)
    /// The observed product's "Smooth" screen animation. Overdamped, so it never overshoots.
    public static let screenSmooth = Spring(stiffness: 170, damping: 50, mass: 3)
    public static let cursorSmooth = Spring(stiffness: 470, damping: 70, mass: 3)
    public static let cursorMedium = Spring(stiffness: 340, damping: 60, mass: 3)
    public static let cursorRapid = Spring(stiffness: 530, damping: 40, mass: 1)

    var naturalFrequency: Double { (stiffness / mass).squareRoot() }
    var dampingRatio: Double { damping / (2 * (stiffness * mass).squareRoot()) }

    /// Time until the envelope of |x - target| falls below `precision` of the step, from rest.
    /// Used to decide when a short interval needs a stiffer spring.
    public func settleTime(precision: Double = 0.002) -> Double {
        let w0 = naturalFrequency
        let zeta = dampingRatio
        let slowestDecay = zeta < 1 ? zeta * w0 : w0 * (zeta - (zeta * zeta - 1).squareRoot())
        return -log(precision) / slowestDecay
    }

    /// The same spring compressed to settle in `available` seconds instead of its own settle time.
    /// k scales by r² and c by r, so the damping ratio is unchanged and only the clock speeds up.
    func rescaled(toSettleWithin available: Double) -> Spring {
        let ratio = settleTime() / available
        guard ratio > 1 else { return self }
        return Spring(stiffness: stiffness * ratio * ratio, damping: damping * ratio, mass: mass)
    }
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

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try c.decodeIfPresent(RecordingTime.self, forKey: .windowBefore).map { windowBefore = $0 }
        try c.decodeIfPresent(RecordingTime.self, forKey: .windowAfter).map { windowAfter = $0 }
        try c.decodeIfPresent(RecordingTime.self, forKey: .mergeGap).map { mergeGap = $0 }
        try c.decodeIfPresent(RecordingTime.self, forKey: .ignoreClicksInFinal).map { ignoreClicksInFinal = $0 }
        try c.decodeIfPresent(RecordingTime.self, forKey: .endMargin).map { endMargin = $0 }
        try c.decodeIfPresent(Double.self, forKey: .scale).map { scale = $0 }
    }
}

public struct CameraSettings: Sendable, Hashable, Codable {
    public var spring: Spring = .screenFocused
    /// Start zooming in this long before a segment begins. nil disables the lead-in.
    public var leadIn: RecordingTime? = nil
    /// The lead-in the observed product uses when the option is on.
    public static let observedLeadIn = RecordingTime.milliseconds(350)
    /// Pointer samples closer than this to the previous kept sample are dropped before grouping.
    public var thinningDistance: Double = 10
    /// Manhattan distance; see `CursorSettings.shakeThreshold`.
    public var shakeThreshold: Double = 500
    /// When a target holds for less than the spring's settle time, stiffen the spring so it arrives:
    /// k *= (T / available)^2, c *= T / available.
    public var rescaleShortIntervals: Bool = true

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try c.decodeIfPresent(Spring.self, forKey: .spring).map { spring = $0 }
        // An optional setting keeps its explicit null: a saved "no lead-in" must not become the default.
        if c.contains(.leadIn) { leadIn = try c.decodeIfPresent(RecordingTime.self, forKey: .leadIn) }
        try c.decodeIfPresent(Double.self, forKey: .thinningDistance).map { thinningDistance = $0 }
        try c.decodeIfPresent(Double.self, forKey: .shakeThreshold).map { shakeThreshold = $0 }
        try c.decodeIfPresent(Bool.self, forKey: .rescaleShortIntervals).map { rescaleShortIntervals = $0 }
    }
}

/// How the drawn cursor follows the recorded pointer.
public enum CursorSmoothing: String, Sendable, Hashable, Codable, CaseIterable {
    case smooth, medium, rapid
    /// Sample-and-hold on the raw samples, no spring.
    case none

    public var spring: Spring? {
        switch self {
        case .smooth: .cursorSmooth
        case .medium: .cursorMedium
        case .rapid: .cursorRapid
        case .none: nil
        }
    }
}

public struct CursorSettings: Sendable, Hashable, Codable {
    public var smoothing: CursorSmoothing = .medium
    /// The cursor switches to this spring shortly before each mouse-down, so it lands on the click.
    public var clickSpring: Spring = .cursorRapid
    public var clickSpringLead: RecordingTime = .milliseconds(175)
    /// Pointer samples closer than this to the previous kept sample are dropped, except a sample the
    /// pointer rests on or clicks at, so the cursor still stops exactly where the user did.
    public var thinningDistance: Double = 10
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
    public static let observedIdleHide = RecordingTime.milliseconds(2000)
    /// A scale on the redrawn cursor, on top of the camera's zoom and the press shrink.
    public var size: Double = 1
    public static let sizeRange: ClosedRange<Double> = 0.5...3
    /// Never draw the cursor. Click rings still show when `showsClicks` is on.
    public var isHidden = false
    /// A ring that grows and fades where each button went down.
    public var showsClicks = false
    public static let clickDuration = RecordingTime.milliseconds(450)

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try c.decodeIfPresent(CursorSmoothing.self, forKey: .smoothing).map { smoothing = $0 }
        try c.decodeIfPresent(Spring.self, forKey: .clickSpring).map { clickSpring = $0 }
        try c.decodeIfPresent(RecordingTime.self, forKey: .clickSpringLead).map { clickSpringLead = $0 }
        try c.decodeIfPresent(Double.self, forKey: .thinningDistance).map { thinningDistance = $0 }
        try c.decodeIfPresent(Double.self, forKey: .shakeThreshold).map { shakeThreshold = $0 }
        try c.decodeIfPresent(Double.self, forKey: .pressedScale).map { pressedScale = $0 }
        try c.decodeIfPresent(RecordingTime.self, forKey: .pressTransition).map { pressTransition = $0 }
        try c.decodeIfPresent(Int.self, forKey: .typingKeyCount).map { typingKeyCount = $0 }
        try c.decodeIfPresent(RecordingTime.self, forKey: .typingWindow).map { typingWindow = $0 }
        try c.decodeIfPresent(RecordingTime.self, forKey: .fadeDuration).map { fadeDuration = $0 }
        if c.contains(.idleHideAfter) { idleHideAfter = try c.decodeIfPresent(RecordingTime.self, forKey: .idleHideAfter) }
        try c.decodeIfPresent(Double.self, forKey: .size).map { size = $0 }
        try c.decodeIfPresent(Bool.self, forKey: .isHidden).map { isHidden = $0 }
        try c.decodeIfPresent(Bool.self, forKey: .showsClicks).map { showsClicks = $0 }
    }
}

/// Every tunable Timeline uses. Codable so the editor can persist it with its other edit state.
public struct TimelineSettings: Sendable, Hashable, Codable {
    public var autoZoom = AutoZoomSettings()
    public var camera = CameraSettings()
    public var cursor = CursorSettings()

    public init() {}
    public static let `default` = TimelineSettings()

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try c.decodeIfPresent(AutoZoomSettings.self, forKey: .autoZoom).map { autoZoom = $0 }
        try c.decodeIfPresent(CameraSettings.self, forKey: .camera).map { camera = $0 }
        try c.decodeIfPresent(CursorSettings.self, forKey: .cursor).map { cursor = $0 }
    }
}
