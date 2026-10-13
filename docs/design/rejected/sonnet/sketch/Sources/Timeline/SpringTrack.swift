import RecordingFormat

/// A one-dimensional spring driven by a piecewise-constant target, evaluated in closed
/// form from precomputed checkpoints.
///
/// Why this shape. The renderer calls us out of order from many threads, so no state may
/// carry between calls. Replaying a window before every query (the teardown's approach)
/// costs about 60 integrator steps per query and truncates history. Instead the whole
/// trajectory is integrated once, sequentially, when the track is built. Each target change
/// starts a Piece that stores the exact (position, velocity) at its start. A query is a
/// binary search plus one closed-form evaluation, and a pure function of t.
struct SpringTrack: Sendable {
    struct Piece: Sendable {
        var start: RecordingTime
        var x0: Double
        var v0: Double
        var target: Double
        var spring: SpringParameters
    }

    private(set) var pieces: [Piece]

    struct Input: Sendable { var start: RecordingTime; var target: Double; var spring: SpringParameters }

    /// `inputs` sorted by start; the first sets the initial position (at rest on its target).
    static func build(_ inputs: [Input]) -> SpringTrack {
        // TODO:
        //  pieces[0] = (inputs[0].start, x0: target, v0: 0, ...)
        //  for each following input: (x, v) = evaluate(previousPiece, at: input.start)
        //      pieces.append(Piece(start: input.start, x0: x, v0: v, target:, spring:))
        //  Optional settle rescale (open question): when the next change arrives sooner than the
        //  settle time T, use k *= (T/avail)^2, c *= T/avail for this piece.
        //  Floating-point error accumulates the same way every build, so results are reproducible.
        fatalError("not implemented")
    }

    func value(at t: RecordingTime) -> Double {
        // TODO: i = last piece with start <= t (binary search; before first -> pieces[0] at rest)
        //       return Self.evaluate(pieces[i], at: t).x
        fatalError("not implemented")
    }

    static func evaluate(_ p: Piece, at t: RecordingTime) -> (x: Double, v: Double) {
        // TODO closed form, with y = x - target, tau = (t - p.start).seconds:
        //   w0 = sqrt(k/m);  zeta = c / (2 sqrt(k m))
        //   zeta < 1 (all shipped presets):
        //     a = zeta*w0; wd = w0*sqrt(1 - zeta^2); B = (v0 + a*y0)/wd
        //     y = e^(-a tau) (y0 cos(wd tau) + B sin(wd tau))
        //     v = e^(-a tau) (v0 cos(wd tau) - ((w0^2 y0 + a v0)/wd) sin(wd tau))
        //   zeta == 1 (within 1e-9): y = e^(-w0 tau) (y0 + (v0 + w0 y0) tau)
        //   zeta > 1: r1,r2 = -w0 (zeta -/+ sqrt(zeta^2-1)); y = C1 e^(r1 tau) + C2 e^(r2 tau)
        //   x = target + y
        fatalError("not implemented")
    }
}

struct CameraTrack: Sendable {
    let scale: SpringTrack
    let centerX: SpringTrack
    let centerY: SpringTrack

    static func build(_ zooms: [ZoomSegment], _ source: TimelineSource, _ s: TimelineSettings.Camera) -> CameraTrack {
        // TODO:
        //  scale target: 1 outside segments, segment.scale inside (switch at start - zoomLeadIn / end)
        //  centre target: .center outside; inside, FocusGrouping.groups(...) steps or .fixed(point)
        //  At end of a segment the centre target returns to .center, so the camera unwinds.
        //  Nearby segments that overlap after lead-in clamp to the later start.
        fatalError("not implemented")
    }

    func state(at t: RecordingTime) -> CameraState {
        // TODO: s = max(1, scale.value); cx, cy from tracks, then clamp each to [0.5/s, 1 - 0.5/s].
        // The clamp runs on the output so the camera never shows outside the frame mid-transition.
        fatalError("not implemented")
    }
}

struct CursorTrack: Sendable {
    let x: SpringTrack
    let y: SpringTrack
    let pressIntervals: [TimeRange]
    let fadeIntervals: [TimeRange]
    let changes: [CursorChange]

    static func build(_ source: TimelineSource, _ s: TimelineSettings.Cursor) -> CursorTrack {
        // TODO:
        //  target pieces: one per pointer sample, zero-order hold of the raw position
        //  spring: s.preset.spring, except in the rapidLeadBeforeClick window before each button down,
        //  where CursorPreset.rapid.spring applies. Both are per-piece constants, so closed form still holds.
        //  fadeIntervals = TypingActivity.intervals(...)
        fatalError("not implemented")
    }

    func state(at t: RecordingTime) -> CursorState {
        // TODO:
        //  position = (x.value, y.value)
        //  image = last change with time <= t (binary search), else .fallbackArrow
        //  isPressed = pressIntervals contains t (binary search)
        //  opacity = 1 - smoothstep over typingFade at the edges of fadeIntervals
        //  isVisible = raw sample at t is on the recorded display, and idle-hide has not elapsed
        fatalError("not implemented")
    }
}
