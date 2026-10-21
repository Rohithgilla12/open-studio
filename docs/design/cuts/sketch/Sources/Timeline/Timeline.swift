/// Answers per-frame questions about one edited take. Built once from (source, zooms, settings,
/// cuts); every query is a pure function of immutable tables, safe from any thread in any order.
///
/// The time rule, stated once:
/// - what output frame `o` shows is the recording at `map.recording(at: o)`: screen pixels, the
///   cursor image, presses, and the typing and idle fades are step or ramp functions of that
///   recording instant, so they cut with the content;
/// - every spring (camera scale, camera centre, cursor position) chases the target it would chase
///   at `map.recording(at: o)`, but is solved over output time, so at a join its position and
///   velocity are continuous. The camera never jumps at a cut, and a zoom wholly inside a cut has
///   no effect on any kept frame.
///
/// That is one transformation of the existing builders: they produce their `TargetChange` lists in
/// recording time as today, then `Retiming` moves each change to `map.output(collapsing:)`. The
/// map is monotone, so the lists stay sorted, and changes that collapse onto one join reduce to
/// the last of them, which `SpringTrack` already does for equal times. A speed range later changes
/// only the map, and camera moves keep their pace instead of running at 2x.
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
        let retiming = Retiming(map: map)
        camera = CameraTrack(source: source, zooms: zooms, settings: settings.camera, retiming: retiming)
        cursor = CursorTrack(source: source, settings: settings.cursor, retiming: retiming)
    }

    /// The camera and cursor for one output frame. `t` is clamped to `[0, map.duration]`.
    public func frame(at t: OutputTime) -> FrameState {
        let t = t.clamped(to: .zero...map.duration)
        let recording = map.recording(at: t)
        return FrameState(
            camera: camera.state(at: t.seconds),
            cursor: cursor.state(springAt: t.seconds, recordingAt: recording.seconds))
    }
}

/// Moves spring target changes from recording seconds to output seconds.
struct Retiming: Sendable {
    let map: TimeMap

    /// `changes` sorted by recording time in, sorted by output time out.
    ///
    /// - Changes that collapse onto one join reduce to the last of them, and that one is dropped
    ///   when its target and spring equal the change already in effect. So a zoom wholly inside a
    ///   cut leaves no knot at all, and `rescaleShortIntervals` sees the same neighbours as if the
    ///   zoom had been deleted.
    /// - Changes that land on output 0 (inside or at the head trim) fold into the initial value,
    ///   so the output starts at rest on the target in effect where the take now begins instead of
    ///   springing in from wherever the recording started.
    /// - With no cuts nothing collapses, so the output is the input and today's tracks are
    ///   reproduced exactly.
    func apply<Value: SpringValue>(initial: Value, _ changes: [TargetChange<Value>]) -> (initial: Value, changes: [TargetChange<Value>]) {
        // TODO: one pass. time = map.output(collapsing: .seconds(change.time)).seconds; group runs
        // of equal output time that came from inside a cut; keep each run's last change unless it
        // repeats the change in effect; fold time-0 survivors into `initial`.
        fatalError("not implemented")
    }
}

// Signature changes inside the module. Bodies are today's, plus one `retiming.apply` call each
// right before `SpringTrack(initial:changes:...)`.

extension CameraTrack {
    init(source: SourceRecording, zooms: ZoomTrack, settings: CameraSettings, retiming: Retiming) {
        // TODO: today's body builds scaleChanges and centerChanges in recording seconds (zoomIn =
        // start - leadIn, group starts, zoom-out at range.end). Then:
        //   let scale = retiming.apply(initial: 1, scaleChanges)
        //   let center = retiming.apply(initial: frameCenter, centerChanges)
        // and SpringTrack over those. state(at:) is unchanged and now receives output seconds.
        fatalError("not implemented")
    }
}

extension CursorTrack {
    init(source: SourceRecording, settings: CursorSettings, retiming: Retiming) {
        // TODO: positionSpring builds its changes (samples plus click-spring leads) in recording
        // seconds, sorts, assigns springs, then retiming.apply right before SpringTrack. The
        // `.held` samples, images, presses, and hidden intervals stay in recording seconds.
        fatalError("not implemented")
    }

    /// The spring position at output seconds; everything else at recording seconds.
    func state(springAt output: Double, recordingAt recording: Double) -> CursorState {
        fatalError("not implemented")
    }
}
