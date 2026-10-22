struct CameraTrack: Sendable {
    let visibleRect: Rect
    let scale: SpringTrack<Double>
    let center: SpringTrack<Vector2>

    init(source: SourceRecording, zooms: ZoomTrack, settings: CameraSettings, retiming: Retiming) {
        visibleRect = source.visibleRect
        let changes = Self.targetChanges(source: source, zooms: zooms, settings: settings)
        let retimedScale = retiming.apply(initial: 1, changes.scale)
        let retimedCenter = retiming.apply(initial: changes.frameCenter, changes.center)
        scale = SpringTrack(initial: retimedScale.initial, changes: retimedScale.changes, rescaleShortIntervals: settings.rescaleShortIntervals)
        center = SpringTrack(initial: retimedCenter.initial, changes: retimedCenter.changes, rescaleShortIntervals: settings.rescaleShortIntervals)
    }

    /// The spring targets the zooms ask for, in recording seconds, before any cut moves them.
    static func targetChanges(
        source: SourceRecording, zooms: ZoomTrack, settings: CameraSettings
    ) -> (scale: [TargetChange<Double>], center: [TargetChange<Vector2>], frameCenter: Vector2) {
        let bounds = source.visibleRect
        let frameCenter = Vector2(bounds.center)
        let segments = zooms.segments
        let zoomInTimes = segments.map { segment in
            max(segment.range.start - (settings.leadIn ?? .zero), .zero)
        }

        var scaleChanges: [TargetChange<Double>] = []
        var centerChanges: [TargetChange<Vector2>] = []
        for (index, segment) in segments.enumerated() {
            let zoomIn = zoomInTimes[index]
            let nextZoomIn = index + 1 < segments.count ? zoomInTimes[index + 1] : nil
            // Back-to-back segments skip the dip to 1 between them.
            let zoomsOut = nextZoomIn.map { $0 > segment.range.end } ?? true
            let followUntil = min(segment.range.end, nextZoomIn ?? segment.range.end)

            scaleChanges.append(TargetChange(time: zoomIn.seconds, target: segment.scale, spring: settings.spring))
            if zoomsOut {
                scaleChanges.append(TargetChange(time: segment.range.end.seconds, target: 1, spring: settings.spring))
            }

            let reach = Self.reachableCenters(bounds: bounds, scale: segment.scale)
            switch segment.focus {
            case .fixed(let x, let y):
                let target = reach.clamp(Vector2(x: bounds.minX + x * bounds.size.width, y: bounds.minY + y * bounds.size.height))
                centerChanges.append(TargetChange(time: zoomIn.seconds, target: target, spring: settings.spring))
            case .followPointer:
                let groups = PointerGroups.build(
                    samples: Self.visibleSamples(of: source, from: segment.range.start, until: followUntil),
                    segmentEnd: followUntil,
                    visibleViewport: Size(width: bounds.size.width / segment.scale, height: bounds.size.height / segment.scale),
                    thinning: settings.thinningDistance, shakeThreshold: settings.shakeThreshold)
                for (position, group) in groups.enumerated() {
                    let at = position == 0 ? zoomIn : group.start
                    centerChanges.append(
                        TargetChange(time: at.seconds, target: reach.clamp(Vector2(group.target)), spring: settings.spring))
                }
                if groups.isEmpty {
                    centerChanges.append(TargetChange(time: zoomIn.seconds, target: frameCenter, spring: settings.spring))
                }
            }
            if zoomsOut {
                centerChanges.append(TargetChange(time: segment.range.end.seconds, target: frameCenter, spring: settings.spring))
            }
        }

        return (scaleChanges, centerChanges, frameCenter)
    }

    static func visibleSamples(of source: SourceRecording, from start: RecordingTime, until end: RecordingTime) -> [PointerSample] {
        let pointer = source.pointer
        guard !pointer.isEmpty else { return [] }
        let inEffect = pointer.lastIndex(keyedBy: { Double($0.time.microseconds) }, atOrBefore: Double(start.microseconds))
        var result: [PointerSample] = []
        if pointer[inEffect].time <= start {
            result.append(PointerSample(time: start, position: pointer[inEffect].position))
        }
        var index = pointer[inEffect].time <= start ? inEffect + 1 : inEffect
        while index < pointer.count, pointer[index].time < end {
            if pointer[index].time > start { result.append(pointer[index]) }
            index += 1
        }
        return result.filter { source.visibleRect.contains($0.position) }
    }

    struct ReachableCenters {
        var x: ClosedRange<Double>
        var y: ClosedRange<Double>

        func clamp(_ c: Vector2) -> Vector2 {
            Vector2(x: min(max(c.x, x.lowerBound), x.upperBound), y: min(max(c.y, y.lowerBound), y.upperBound))
        }
    }

    static func reachableCenters(bounds: Rect, scale: Double) -> ReachableCenters {
        let halfWidth = bounds.size.width / max(scale, 1) / 2
        let halfHeight = bounds.size.height / max(scale, 1) / 2
        return ReachableCenters(
            x: (bounds.minX + halfWidth)...(bounds.maxX - halfWidth), y: (bounds.minY + halfHeight)...(bounds.maxY - halfHeight))
    }

    /// `seconds` is output time.
    func state(at seconds: Double) -> CameraState {
        let (s, scaleVelocity) = scale.evaluate(at: seconds)
        let (c, centerVelocity) = center.evaluate(at: seconds)
        let shown = max(1, s)
        let size = Size(width: visibleRect.size.width / shown, height: visibleRect.size.height / shown)
        let clamped = Self.reachableCenters(bounds: visibleRect, scale: shown).clamp(c)
        return CameraState(
            viewport: Rect(origin: Point(x: clamped.x - size.width / 2, y: clamped.y - size.height / 2), size: size),
            scale: shown,
            center: clamped.point,
            centerVelocity: centerVelocity.velocity,
            scaleVelocity: scaleVelocity)
    }
}

public struct CameraState: Sendable, Hashable {
    /// Source pixels shown in the output frame. Always inside the source's visible rect: center is
    /// clamped so the viewport never leaves it, and scale is clamped to >= 1 (the camera spring is
    /// underdamped and would otherwise overshoot below 1 when zooming out).
    public let viewport: Rect
    public let scale: Double
    public let center: Point
    /// Unclamped spring velocities, for motion blur.
    public let centerVelocity: Velocity
    public let scaleVelocity: Double

    public init(viewport: Rect, scale: Double, center: Point, centerVelocity: Velocity, scaleVelocity: Double) {
        self.viewport = viewport
        self.scale = scale
        self.center = center
        self.centerVelocity = centerVelocity
        self.scaleVelocity = scaleVelocity
    }
}
