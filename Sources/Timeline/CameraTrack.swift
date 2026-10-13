/// Precomputed camera answers: a scale spring and a center spring, plus the frame for clamping.
struct CameraTrack: Sendable {
    let frameSize: Size
    let scale: SpringTrack<Double>
    let center: SpringTrack<Vector2>

    init(source: SourceRecording, zooms: ZoomTrack, settings: CameraSettings) {
        frameSize = source.frameSize
        let frameCenter = Vector2(x: source.frameSize.width / 2, y: source.frameSize.height / 2)
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

            let reach = Self.reachableCenters(frame: source.frameSize, scale: segment.scale)
            switch segment.focus {
            case .fixed(let x, let y):
                let target = reach.clamp(Vector2(x: x * source.frameSize.width, y: y * source.frameSize.height))
                centerChanges.append(TargetChange(time: zoomIn.seconds, target: target, spring: settings.spring))
            case .followPointer:
                let groups = PointerGroups.build(
                    samples: Self.samples(of: source, from: segment.range.start, until: followUntil),
                    segmentEnd: followUntil,
                    visibleViewport: Size(width: source.frameSize.width / segment.scale, height: source.frameSize.height / segment.scale),
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

        scale = SpringTrack(initial: 1, changes: scaleChanges, rescaleShortIntervals: settings.rescaleShortIntervals)
        center = SpringTrack(initial: frameCenter, changes: centerChanges, rescaleShortIntervals: settings.rescaleShortIntervals)
    }

    /// Samples inside `[start, end)`, led by the sample in effect at `start` re-stamped to `start`.
    static func samples(of source: SourceRecording, from start: RecordingTime, until end: RecordingTime) -> [PointerSample] {
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
        return result
    }

    /// Centers for which a viewport of `frame / scale` stays inside the frame.
    struct ReachableCenters {
        var x: ClosedRange<Double>
        var y: ClosedRange<Double>

        func clamp(_ c: Vector2) -> Vector2 {
            Vector2(x: min(max(c.x, x.lowerBound), x.upperBound), y: min(max(c.y, y.lowerBound), y.upperBound))
        }
    }

    static func reachableCenters(frame: Size, scale: Double) -> ReachableCenters {
        let halfWidth = frame.width / max(scale, 1) / 2
        let halfHeight = frame.height / max(scale, 1) / 2
        return ReachableCenters(x: halfWidth...(frame.width - halfWidth), y: halfHeight...(frame.height - halfHeight))
    }

    func state(at seconds: Double) -> CameraState {
        let (s, scaleVelocity) = scale.evaluate(at: seconds)
        let (c, centerVelocity) = center.evaluate(at: seconds)
        let shown = max(1, s)
        let size = Size(width: frameSize.width / shown, height: frameSize.height / shown)
        let clamped = Self.reachableCenters(frame: frameSize, scale: shown).clamp(c)
        return CameraState(
            viewport: Rect(origin: Point(x: clamped.x - size.width / 2, y: clamped.y - size.height / 2), size: size),
            scale: shown,
            center: clamped.point,
            centerVelocity: centerVelocity.velocity,
            scaleVelocity: scaleVelocity)
    }
}

public struct CameraState: Sendable, Hashable {
    /// Source pixels shown in the output frame. Always inside the frame: center is clamped so the
    /// viewport never leaves the source, and scale is clamped to >= 1 (the camera spring is
    /// underdamped and would otherwise overshoot below 1 when zooming out).
    public let viewport: Rect
    public let scale: Double
    public let center: Point
    /// Unclamped spring velocities, for motion blur.
    public let centerVelocity: Velocity
    public let scaleVelocity: Double
}
