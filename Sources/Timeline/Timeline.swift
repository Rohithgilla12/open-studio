/// Answers per-frame questions about one edited take. Built once from (source, zooms, settings,
/// cuts); every query afterwards is a pure function of immutable precomputed tables. So
/// `frame(at:)` returns identical values in any query order, on any thread, and a renderer can
/// share one `Timeline` value across AVFoundation's compositor threads without locks. When the
/// user edits zooms, settings, or cuts, build a new `Timeline` and swap it in.
///
/// The time rule, stated once:
/// - what output frame `o` shows is the recording at `map.recording(at: o)`: screen pixels, the
///   cursor image, and presses are step functions of that recording instant, so they cut with the
///   content;
/// - every spring (camera scale, camera centre, cursor position) chases the target it would chase
///   at `map.recording(at: o)`, but is solved over output time, so at a join its position and
///   velocity are continuous. The camera never jumps at a cut, and a zoom wholly inside a cut has
///   no effect on any kept frame. The cursor is the one exception: it snaps to rest at each join;
/// - the typing and idle fades measure durations the viewer sees, so they run over output time;
/// - click rings are press state: a ring's age is measured at the recording instant, and a click
///   inside a cut has none.
///
/// Cost: construction is O(n) in pointer samples. Each query is a few binary searches plus a
/// closed-form spring evaluation per track, independent of t and of the recording length.
public struct Timeline: Sendable {
    public let source: SourceRecording
    public let zooms: ZoomTrack
    public let settings: TimelineSettings
    public let cuts: Cuts
    /// The only TimeMap in the process for this edit state. Render reads it from here.
    public let map: TimeMap

    private let camera: CameraTrack
    private let cursor: CursorTrack

    public init(source: SourceRecording, zooms: ZoomTrack, settings: TimelineSettings = .default, cuts: Cuts = .none) {
        self.source = source
        self.zooms = zooms
        self.settings = settings
        self.cuts = cuts
        map = TimeMap(cuts: cuts, duration: source.duration)
        let retiming = Retiming(map: map, cuts: cuts)
        camera = CameraTrack(source: source, zooms: zooms, settings: settings.camera, retiming: retiming)
        cursor = CursorTrack(source: source, settings: settings.cursor, retiming: retiming)
    }

    /// The camera and cursor for one output frame. `t` is clamped to `[0, map.duration]`.
    public func frame(at t: OutputTime) -> FrameState {
        let t = t.clamped(to: .zero...map.duration)
        let recording = map.recording(at: t)
        return FrameState(
            camera: camera.state(at: t.seconds),
            cursor: cursor.state(springAt: t.seconds, recordingAt: recording.seconds),
            clicks: cursor.clicks(at: recording))
    }

    /// Knot counts per spring track, for diagnostics and the performance test.
    var knotCounts: (cameraScale: Int, cameraCenter: Int, cursorPosition: Int) {
        let cursorKnots: Int
        switch cursor.position {
        case .spring(let track): cursorKnots = track.knots.count
        case .held(let samples): cursorKnots = samples.count
        }
        return (camera.scale.knots.count, camera.center.knots.count, cursorKnots)
    }
}

public struct FrameState: Sendable, Hashable {
    public let camera: CameraState
    public let cursor: CursorState
    /// The click rings showing, oldest first. Empty unless `CursorSettings.showsClicks`.
    public let clicks: [ClickPulse]

    /// For renderer tests that pin geometry to exact numbers without running a spring.
    public init(camera: CameraState, cursor: CursorState, clicks: [ClickPulse] = []) {
        self.camera = camera
        self.cursor = cursor
        self.clicks = clicks
    }
}

/// Moves spring target changes from recording seconds to output seconds.
struct Retiming: Sendable {
    let map: TimeMap
    let cuts: Cuts

    static func identity(for source: SourceRecording) -> Retiming {
        Retiming(map: .identity(duration: source.duration), cuts: .none)
    }

    /// `changes` sorted by recording time in, sorted by output time out.
    ///
    /// - A change inside a cut lands on the cut's join, marked `collapsed`. A run of them reduces
    ///   to its last, and that one is dropped when it repeats the change already in effect, so a
    ///   zoom wholly inside a cut leaves no knot at all and `rescaleShortIntervals` sees the same
    ///   neighbours as if the zoom had been deleted. It is also dropped when the next kept change
    ///   puts the target back before its spring would have settled, unless `snapsAtJoins`.
    /// - A change inside the head trim folds into the initial value, so the output starts at rest
    ///   on the target in effect where the take now begins instead of springing in from wherever
    ///   the recording started.
    /// - With `snapsAtJoins`, a rest knot is added at every join on the target in effect at the
    ///   recording instant shown there. The cursor uses it; the camera carries its spring.
    /// - With no cuts nothing collapses, so the output is the input and today's tracks are
    ///   reproduced exactly.
    func apply<Value: SpringValue>(
        initial: Value, _ changes: [TargetChange<Value>], snapsAtJoins: Bool = false
    ) -> (initial: Value, changes: [TargetChange<Value>]) {
        var initial = initial
        var kept: [TargetChange<Value>] = []
        kept.reserveCapacity(changes.count)
        var collapsed: TargetChange<Value>?

        func flush() {
            guard let change = collapsed else { return }
            collapsed = nil
            if change.time == 0 {
                initial = change.target
            } else if let last = kept.last {
                if last.target != change.target || last.spring != change.spring { kept.append(change) }
            } else if change.target != initial {
                kept.append(change)
            }
        }

        for change in changes {
            let r = RecordingTime.seconds(change.time)
            var moved = change
            moved.time = map.output(collapsing: r).seconds
            if cuts.cut(containing: r) != nil {
                if let pending = collapsed, pending.time != moved.time { flush() }
                moved.collapsed = true
                collapsed = moved
            } else {
                flush()
                kept.append(moved)
            }
        }
        flush()

        // A zoom-out moved onto the join with the next zoom-in landing before it could settle would
        // bounce the camera at a cut the user made to bring the two zooms together, so the
        // collapsed change goes when the kept one after it restores the target it replaced. The
        // restorer goes with it when it would then only restate the change in effect, because a
        // restatement still ends the interval `rescaleShortIntervals` measures. Not with
        // `snapsAtJoins`: the snap restores the collapsed target from the raw changes, so dropping
        // the restorer would leave nothing to move the cursor off it.
        var index = 0
        while !snapsAtJoins, index + 1 < kept.count {
            let change = kept[index]
            let previous = index == 0 ? nil : kept[index - 1]
            let restorer = kept[index + 1]
            guard change.collapsed, restorer.target == previous?.target ?? initial,
                restorer.time - change.time < change.spring.settleTime()
            else {
                index += 1
                continue
            }
            kept.remove(at: index)
            if let previous, restorer.spring == previous.spring {
                kept.remove(at: index)
            }
        }

        if snapsAtJoins, !map.joins.isEmpty {
            for join in map.joins {
                let shown = map.recording(at: join).seconds
                var rest = TargetChange(time: join.seconds, target: initial, spring: kept.first?.spring ?? .screenFocused, snap: true)
                if !changes.isEmpty {
                    let inEffect = changes[changes.lastIndex(keyedBy: \.time, atOrBefore: shown)]
                    if inEffect.time <= shown {
                        rest.target = inEffect.target
                        rest.spring = inEffect.spring
                    }
                }
                kept.append(rest)
            }
            kept.sort { ($0.time, $0.snap ? 1 : 0) < ($1.time, $1.snap ? 1 : 0) }
        }
        return (initial, kept)
    }
}
