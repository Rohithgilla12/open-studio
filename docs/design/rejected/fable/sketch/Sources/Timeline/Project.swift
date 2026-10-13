import Foundation

/// The editable document: a take plus everything the user can change. A plain value, so
/// undo is "keep the previous value" and the renderer gets a snapshot per edit.
public struct Project: Sendable, Equatable {
    public var take: Take
    public var zooms: ZoomTrack
    public var camera: CameraSettings
    public var cursor: CursorSettings

    /// A new project with automatic zooms applied.
    public static func automatic(take: Take) -> Project {
        fatalError("not implemented")
    }
}

public struct ZoomSegment: Sendable, Equatable, Identifiable {
    public enum Target: Sendable, Equatable {
        /// Camera follows the time-weighted centroid of click groups (see `ClickGroups`).
        case followClicks
        /// Fixed point in normalised display coordinates (0...1).
        case fixed(Point)
    }

    public var id: UUID
    public var range: Range<Duration>
    public var scale: Double
    public var target: Target
}

/// Sorted, non-overlapping zoom segments. The only way to get one with overlaps is to
/// bypass this type, so the sampler trusts it.
public struct ZoomTrack: Sendable, Equatable {
    public private(set) var segments: [ZoomSegment]

    public static let empty = ZoomTrack(segments: [])

    /// Rejects overlaps and unsorted input rather than silently fixing them, so a caller
    /// that computed something wrong finds out.
    public init(validating segments: [ZoomSegment]) throws(ZoomTrackError) {
        fatalError("not implemented")
    }

    private init(segments: [ZoomSegment]) {
        self.segments = segments
    }

    public func segment(containing t: Duration) -> ZoomSegment? {
        fatalError("not implemented")
    }

    public func inserting(_ segment: ZoomSegment) throws(ZoomTrackError) -> ZoomTrack {
        fatalError("not implemented")
    }

    public func removing(id: ZoomSegment.ID) -> ZoomTrack {
        fatalError("not implemented")
    }
}

public enum ZoomTrackError: Error, Sendable, Equatable {
    case overlap(ZoomSegment.ID, ZoomSegment.ID)
    case emptyRange(ZoomSegment.ID)
}

public struct CameraSettings: Sendable, Equatable {
    public var spring: SpringParams = .camera
    /// Start moving towards the next click group this long before it begins.
    public var leadIn: Duration = .milliseconds(350)
    /// A click group closes when its bounding box would exceed this fraction of the
    /// visible viewport at the segment's zoom.
    public var groupBoundsFraction: Double = 0.5
    /// Mouse samples closer than this to the previous kept sample are dropped before
    /// grouping.
    public var thinningDistance: Double = 10
    public init() {}
}

public struct CursorSettings: Sendable, Equatable {
    public var preset: CursorPreset = .smooth
    /// A sample that jumps farther than this (Manhattan) and immediately returns is a
    /// glitch, not a move.
    public var shakeThreshold: Double = 500
    public var typingFade = TypingFade()
    public var idleHideAfter: Duration? = nil
    public var pressedScale: Double = 0.9
    /// The rapid preset takes over this long before each click so the drawn cursor
    /// arrives where the click lands.
    public var preClickRapidWindow: Duration = .milliseconds(175)
    public init() {}

    public struct TypingFade: Sendable, Equatable {
        public var keyPressCount = 3
        public var window: Duration = .milliseconds(1800)
        public var fadeDuration: Duration = .milliseconds(200)
        public init() {}
    }
}

public enum CursorPreset: Sendable, Equatable, CaseIterable {
    case smooth, medium, rapid

    public var spring: SpringParams {
        switch self {
        case .smooth: .cursorSmooth
        case .medium: .cursorMedium
        case .rapid: .cursorRapid
        }
    }
}
