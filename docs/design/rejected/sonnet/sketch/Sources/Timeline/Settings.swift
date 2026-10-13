import RecordingFormat

public struct SpringParameters: Hashable, Sendable, Codable {
    public var stiffness: Double
    public var damping: Double
    public var mass: Double
    public init(stiffness: Double, damping: Double, mass: Double) {
        precondition(stiffness > 0 && damping >= 0 && mass > 0)
        self.stiffness = stiffness; self.damping = damping; self.mass = mass
    }

    public static let camera = SpringParameters(stiffness: 125, damping: 12, mass: 1.5)
    public static let cameraFocused = SpringParameters(stiffness: 250, damping: 40, mass: 2.25)
    public static let cameraSmooth = SpringParameters(stiffness: 170, damping: 50, mass: 3)
}

public enum CursorPreset: String, Sendable, Codable, CaseIterable {
    case smooth, medium, rapid
    public var spring: SpringParameters {
        switch self {
        case .smooth: .init(stiffness: 470, damping: 70, mass: 3)
        case .medium: .init(stiffness: 340, damping: 60, mass: 3)
        case .rapid: .init(stiffness: 530, damping: 40, mass: 1)
        }
    }
}

/// Every tunable behaviour in one Codable value, so a project file can pin it and a test can
/// vary it. Defaults reproduce the behaviour in the teardown.
public struct TimelineSettings: Hashable, Sendable, Codable {
    public var autoZoom = AutoZoom()
    public var camera = Camera()
    public var cursor = Cursor()

    public static let `default` = TimelineSettings()

    public struct AutoZoom: Hashable, Sendable, Codable {
        public var scale = 2.0
        public var lead = RecordingTime.milliseconds(300)
        public var tail = RecordingTime.milliseconds(2500)
        public var mergeGap = RecordingTime.milliseconds(2500)
        public var ignoreClicksInLast = RecordingTime.milliseconds(1000)
        public var endInset = RecordingTime.milliseconds(800)
        public var minimumStart = RecordingTime.milliseconds(1)
    }

    public struct Camera: Hashable, Sendable, Codable {
        public var spring = SpringParameters.camera
        /// Optional early start of the zoom-in. Zero by default.
        public var zoomLeadIn = RecordingTime.zero
        /// Pointer thinning and shake rejection, in display pixels.
        public var thinningDistance = 10.0
        public var shakeThreshold = 500.0
        /// A group closes when its bounding box exceeds this fraction of the visible viewport.
        public var groupExtentFraction = 0.5
    }

    public struct Cursor: Hashable, Sendable, Codable {
        public var preset = CursorPreset.smooth
        public var rapidLeadBeforeClick = RecordingTime.milliseconds(175)
        public var typingMinimumKeys = 3
        public var typingWindow = RecordingTime.milliseconds(1800)
        public var typingFade = RecordingTime.milliseconds(200)
        public var idleHideAfter: RecordingTime? = nil
    }
}
