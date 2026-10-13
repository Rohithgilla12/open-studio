/// Precomputed camera answers: a scale spring and a center spring, plus the frame for clamping.
struct CameraTrack: Sendable {
    let frameSize: Size
    let scale: SpringTrack<Double>
    let center: SpringTrack<Vector2>

    init(source: SourceRecording, zooms: [ZoomSegment], settings: CameraSettings) {
        // TODO:
        // Scale targets (initial 1):
        //   for each segment: change(at: start - leadIn, to: segment.scale); change(at: end, to: 1)
        //   If the next segment's lead-in starts at or before this segment's end, skip the zoom-out and
        //   emit only the next segment's scale (no dip to 1 between back-to-back segments).
        //
        // Center targets (initial frame center):
        //   for each segment:
        //     .fixed(x, y)   -> change(at: start - leadIn, to: (x * W, y * H))
        //     .followPointer -> groups = PointerGroups.build(samples in range, viewport: frameSize / scale)
        //                       first group at start - leadIn, each later group at its own start time
        //   change(at: end, to: frame center) unless the next segment starts there.
        //   Every center target is clamped for that segment's scale, so the spring aims at a reachable
        //   point instead of being clipped hard at the edge.
        //
        // scale = SpringTrack(initial: 1, changes: scaleChanges, rescaleShortIntervals: settings.rescaleShortIntervals)
        // center = SpringTrack(initial: frameCenter, changes: centerChanges, rescaleShortIntervals: ...)
        fatalError("not implemented")
    }

    func state(at t: Double) -> CameraState {
        // TODO:
        // (s, sv) = scale.evaluate(at: t); (c, cv) = center.evaluate(at: t)
        // shown = max(1, s)
        // size = frameSize / shown
        // clampedCenter = clamp(c, size.width / 2 ... W - size.width / 2, size.height / 2 ... H - size.height / 2)
        // viewport = Rect(origin: clampedCenter - size / 2, size: size)
        fatalError("not implemented")
    }
}

/// The camera's "where to look" policy inside a follow-pointer zoom segment.
enum PointerGroups {
    struct Group: Sendable, Equatable {
        var start: Double
        var target: Vector2
    }

    /// `samples` are the pointer samples inside the segment, plus the sample in effect at the segment's
    /// start re-stamped to that start (so a segment with no movement still has a target).
    static func build(
        samples: [PointerSample], segmentEnd: Double, visibleViewport: Size,
        thinning: Double, shakeThreshold: Double
    ) -> [Group] {
        // TODO:
        // 1. Thin: keep a sample only if it is at least `thinning` px (Euclidean) from the last kept one.
        // 2. Shake filter: ShakeFilter.apply(threshold: shakeThreshold).
        // 3. Greedy grouping in time order. limit = visibleViewport / 2 (half the visible viewport at
        //    this segment's zoom). Keep a running bounding box; if adding the next sample would make
        //    bbox.width > limit.width or bbox.height > limit.height, close the group and start a new
        //    one at that sample.
        // 4. Each group's target is its time-weighted centroid: weight_i = t_(i+1) - t_i, where the last
        //    sample's successor time is the next group's start (or segmentEnd). If all weights are 0,
        //    fall back to the plain mean.
        // A group's start time is its first sample's time; the spring supplies the lag, so no extra
        // anticipation is applied here.
        fatalError("not implemented")
    }
}

enum ShakeFilter {
    /// Drops sample i when it jumps more than `threshold` (Manhattan) from i-1 and sample i+1 is back
    /// within `threshold` of i-1: a one-sample excursion, typically a cursor warp glitch. A real
    /// fast move does not come back, so it survives.
    static func apply(_ samples: [PointerSample], threshold: Double) -> [PointerSample] {
        fatalError("not implemented")
    }
}

/// Precomputed cursor answers.
struct CursorTrack: Sendable {
    let frameSize: Size
    let position: SpringTrack<Vector2>
    /// Sorted by time.
    let images: [CursorChange]
    /// Sorted, disjoint `[down, up)` intervals of any button held.
    let presses: [Interval]
    /// Sorted, disjoint intervals during which the cursor is hidden (typing or idle).
    let hidden: [Interval]
    let settings: CursorSettings

    struct Interval: Sendable, Equatable {
        var start: Double
        var end: Double
    }

    init(source: SourceRecording, settings: CursorSettings) {
        // TODO:
        // Position:
        //   samples = ShakeFilter.apply(source.pointer, threshold: settings.shakeThreshold)
        //   changes = samples.map { TargetChange(time, position, spring: settings.spring) }
        //   for each button down at td:
        //     insert a change at td - clickSpringLead with the target in effect at that time and
        //     spring = clickSpring; every change in [td - lead, td) uses clickSpring; the down sample
        //     itself (at td) switches back to settings.spring.
        //   position = SpringTrack(initial: first sample, changes, rescaleShortIntervals: false)
        //   Rescaling is camera-only: pointer samples arrive every few ms, so every interval is "short".
        //
        // Presses: pair downs and ups per button; union across buttons; an unmatched down runs to the end.
        //
        // Hidden intervals:
        //   Typing: scan keyDowns with a sliding window. When keyDowns[i + n - 1] - keyDowns[i] <= window
        //   (n = typingKeyCount), the cursor hides from keyDowns[i + n - 1] until the earlier of the next
        //   pointer sample or button event after it, and the last key of that run + typingWindow.
        //   Idle (if enabled): from lastPointerActivity + idleHideAfter until the next pointer activity.
        //   Union and sort.
        fatalError("not implemented")
    }

    func state(at t: Double) -> CursorState {
        // TODO:
        // (p, v) = position.evaluate(at: t)
        // image = last images entry with time <= t
        // press: inside [down, up) -> pressed, amount = min(1, (t - down) / pressTransition)
        //        after an up -> amount = max(0, 1 - (t - up) / pressTransition)
        // opacity: 1 outside hidden intervals; ramps linearly over fadeDuration into and out of each
        //          interval (fade out ending at interval.start + fadeDuration, fade in starting at end)
        // isVisible = opacity > 0 && 0 <= p.x < W && 0 <= p.y < H
        fatalError("not implemented")
    }
}
