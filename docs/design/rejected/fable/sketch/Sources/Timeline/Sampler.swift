import Foundation

/// The renderer's view of a project: two pure functions of time. Build one per project
/// edit (cheap: milliseconds for a minute-long take), then query it from any thread in
/// any order. Holds only immutable precomputed tracks; no state survives a call.
public struct Sampler: Sendable {
    private let display: Size
    private let cameraParams: SpringParams
    private let cameraTargets: CameraTargetTrack
    private let cursorSettings: CursorSettings
    private let cursorPath: [MouseSample]
    private let clicks: [Click]
    private let keyPresses: [KeyPress]
    private let cursorChanges: [CursorChange]

    public init(project: Project) {
        // TODO:
        // display = project.take.display.size
        // cameraTargets = CameraTargetTrack.build(project)   // click groups per segment + lead-in
        // cursorPath = ClickGroups.shakeFiltered(project.take.input.moves, threshold: cursor.shakeThreshold)
        // copy remaining tracks
        fatalError("not implemented")
    }

    public func camera(at t: Duration) -> Camera {
        // TODO:
        // center = Spring.value(at: t, params: cameraParams) { cameraTargets.center(at: $0) }
        // zoom   = Spring.value(at: t, params: cameraParams) { cameraTargets.zoom(at: $0) }
        // return Camera(center:, zoom:).clamped(to: display)
        fatalError("not implemented")
    }

    public func cursor(at t: Duration) -> CursorFrame {
        // TODO:
        // params = cursorSettings.preset.spring, or .cursorRapid if a click lies in (t, t + preClickRapidWindow]
        //          (chosen from t alone, so still a pure function of t)
        // position = Spring.value(at: t, params: params) { rawPosition(at: $0) }   // last sample <= s
        // pressed  = last click with time <= t has release == nil || release > t
        // image    = last cursorChange <= t
        // opacity  = typingOpacity(at: t) * idleOpacity(at: t)
        //   typing: count keyPresses in (t - window, t]; >= keyPressCount -> fade towards 0 over fadeDuration
        // return CursorFrame(position:, image:, isPressed:, opacity:, scale: pressed ? pressedScale : 1)
        fatalError("not implemented")
    }

    /// Both in one call for renderers that want a single lookup per frame.
    public func frame(at t: Duration) -> Frame {
        Frame(time: t, camera: camera(at: t), cursor: cursor(at: t))
    }
}

public struct Camera: Sendable, Equatable {
    /// Display points.
    public var center: Point
    /// 1 = whole display visible; 2 = half of each axis.
    public var zoom: Double

    /// The source rect to show, clamped inside the display.
    public func viewport(in display: Size) -> Rect {
        fatalError("not implemented")
    }
}

public struct CursorFrame: Sendable, Equatable {
    /// Display points; renderer subtracts the image hotspot.
    public var position: Point
    /// nil before the first cursor sample; renderer draws nothing.
    public var image: CursorImageID?
    public var isPressed: Bool
    public var opacity: Double
    public var scale: Double
}

public struct Frame: Sendable, Equatable {
    public var time: Duration
    public var camera: Camera
    public var cursor: CursorFrame
}

/// Piecewise-constant camera target over the whole take: one keyframe per click group
/// (and per segment boundary), so `center(at:)` and `zoom(at:)` are binary searches.
/// Outside every zoom segment the target is the display centre at zoom 1.
struct CameraTargetTrack: Sendable, Equatable {
    struct Keyframe: Sendable, Equatable {
        var start: Duration
        var center: Point
        var zoom: Double
    }

    /// Sorted by `start`; first keyframe starts at `.zero`.
    var keyframes: [Keyframe]

    static func build(_ project: Project) -> CameraTargetTrack {
        // TODO:
        // keyframes = [Keyframe(start: .zero, center: display.center, zoom: 1)]
        // for segment in project.zooms.segments:
        //   groups = ClickGroups.build(samples: moves + click positions within segment, ...)
        //   for g in groups: append Keyframe(start: g.range.lowerBound - leadIn, center: g.centroid, zoom: segment.scale)
        //   append Keyframe(start: segment.range.upperBound, center: display.center, zoom: 1)
        // (lead-in may pull a keyframe before the previous segment's end; clamp to that end)
        fatalError("not implemented")
    }

    func center(at t: Duration) -> Point { fatalError("not implemented") }
    func zoom(at t: Duration) -> Double { fatalError("not implemented") }
}
