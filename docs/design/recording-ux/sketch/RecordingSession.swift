// Sources/Recording/RecordingSession.swift, SessionPhase.swift, SessionTypes.swift (changed).
//
// One actor owns one recording attempt from the first frame of the countdown to the end, across
// any number of restarts. The countdown, the origin, pauses, restart, and the trash are recorder
// concerns, so they live here and every caller (Studio, osrec, tests) gets them by construction.

public import Foundation

public actor RecordingSession {
    /// State changes, progress, warnings, discarded takes, and exactly one `.ended`, after which
    /// the stream finishes.
    public nonisolated let updates: AsyncStream<RecordingUpdate>

    /// Checks permissions, resolves the target, leases the camera, starts the stream, waits for its
    /// first complete frame, and configures every writer for the first take without touching the
    /// disk. Returns with the countdown running: `.state(.countingDown(until:))` is the first update.
    ///
    /// Throws, leaving nothing on disk, when capture cannot start. With `configuration.countdown`
    /// of zero the take rolls on the first frame, which is today's behaviour.
    public static func start(_ configuration: RecordingConfiguration) async throws(RecordingError) -> RecordingSession {
        fatalError("not implemented")
    }

    /// Opens a pause at `at`, the time of the click or key press that asked for it, so the press
    /// itself falls inside the removed range. Ignored unless recording.
    public func pause(at: SuspendingClock.Instant = .now) {
        handle(.pauseRequested(at: HostTime(at)))
    }

    /// Closes the open pause at `at`. Ignored unless paused.
    public func resume(at: SuspendingClock.Instant = .now) {
        handle(.resumeRequested(at: HostTime(at)))
    }

    /// Finishes the take in progress, moves its directory to the Trash, and counts down again with
    /// the same configuration. The stream and the camera keep running, so the new countdown starts
    /// at once. Ignored unless recording or paused.
    public func restart(at: SuspendingClock.Instant = .now) {
        handle(.restartRequested(at: HostTime(at)))
    }

    /// During the countdown, cancels: nothing was ever written, and the outcome is
    /// `.nothingRecorded(.cancelled)`. Otherwise stops at `at` and finalizes. Idempotent: every
    /// call returns the same outcome.
    public func stop(at: SuspendingClock.Instant = .now) async -> RecordingOutcome {
        fatalError("not implemented")
    }

    // Recovery is unchanged in shape. It now also closes an open pause; see Manifest.swift.
    // public static func recover(at directory: URL) async throws(RecoveryError) -> FinishedRecording

    private var phase: SessionPhase
    private let rig: CaptureRig
    private var take: LiveTake?

    private init(rig: CaptureRig, countdown: Duration) {
        fatalError("not implemented")
    }

    func handle(_ input: SessionInput) {
        // let transition = SessionPhase.next(phase, input, countdown: countdown, now: .now())
        // phase = transition.phase
        // for effect in transition.effects { run(effect) }   // run is the only impure step
        fatalError("not implemented")
    }
}

/// The parts that live as long as the session: the stream, the event tap, the camera lease, and
/// the sink that routes their buffers. A restart keeps the rig and replaces only the take.
struct CaptureRig: Sendable {
    let sink: CaptureSink
    let input: InputCapture
    let camera: CameraLease?
    let plan: TakePlan
}

/// What one take writes: the directory it will create, the configured writers, the event log
/// (created at roll), and the manifest. Owned by the session; replaced on restart.
struct LiveTake {
    let layout: RecordingLayout
    var manifest: WireManifest
    let eventLog: EventLogWriter
    let lock: DirectoryLock
}

extension RecordingConfiguration {
    // public var countdown: Duration       // default .zero: osrec and every existing caller keep
    //                                      // today's "origin = first frame"; Studio passes 3 s.
}

/// Everything a take needs that does not change between takes of one session.
struct TakePlan: Sendable {
    var outputDirectory: URL
    var frameRate: Int
    var codec: VideoCodec
    var countdown: Duration
    var maxDuration: Duration?
}

public enum RecordingUpdate: Sendable, Equatable {
    case state(LiveState)
    case progress(RecordingProgress)
    case warning(RecordingWarning)
    /// A restarted take, finalized and moved here (the Trash), or left in the library when the
    /// volume has no Trash.
    case discarded(URL)
    case ended(RecordingOutcome)
}

public enum LiveState: Sendable, Equatable {
    /// Capture runs and nothing is on disk. The take's time zero is `until`.
    case countingDown(until: SuspendingClock.Instant)
    case recording(LiveTakeInfo)
    case paused(LiveTakeInfo)
    case stopping
}

public struct LiveTakeInfo: Sendable, Equatable {
    public let directory: URL
    public let clock: TakeClock
}

/// The take's clock as a caller sees it. The elapsed time the control bar shows is derived from
/// it at display time, not pushed, so it keeps running while the screen is still and no frame
/// (and so no progress update) arrives.
public struct TakeClock: Sendable, Equatable {
    public let origin: SuspendingClock.Instant
    /// Closed pauses, sorted, disjoint, as offsets from the origin.
    public let pauses: [Range<Duration>]
    /// Offset of the pause in progress.
    public let openPause: Duration?

    public var isPaused: Bool { openPause != nil }

    /// Media time minus paused time, as of `now`. Frozen while paused.
    public func recorded(at now: SuspendingClock.Instant) -> Duration {
        fatalError("not implemented")
    }
}

public enum RecordingOutcome: Sendable, Equatable {
    case recorded(FinishedRecording)
    case nothingRecorded(NoTake)

    public enum NoTake: Sendable, Equatable {
        case cancelled
        /// The stream failed during the countdown, before anything was written.
        case streamFailed(String)
    }
}

/// The recorder's state machine. Pure, like today's: inputs in, phase and effects out. Every
/// command a button or hot key sends lands here, and a command that does not fit the phase is a
/// no-op transition, so the UI cannot make the recorder act in the wrong phase even if it shows
/// the wrong button for a frame.
enum SessionPhase: Sendable, Equatable {
    case countingDown(notBefore: HostTime)
    case recording(HostClock)
    case paused(HostClock)
    case stopping(StopReason)
    case finished(RecordingOutcome)

    static func next(_ phase: SessionPhase, _ input: SessionInput, countdown: Duration, now: HostTime) -> SessionTransition {
        switch (phase, input) {
        // case (.countingDown, .rolled(let origin)):            -> .recording(HostClock(origin)), [.beginTake(origin), .emitState]
        // case (.countingDown, .stopRequested):                  -> .stopping(.cancelled), [.cancelTake]
        // case (.countingDown, .streamFailed(let m)):            -> .stopping(.streamFailed(m)), [.cancelTake]
        // case (.recording(let c), .pauseRequested(let at)):     -> .paused(c.pausing(at)), [.applyClock, .writeManifest, .emitState]
        // case (.paused(let c), .resumeRequested(let at)):       -> .recording(c.resuming(at)), [.applyClock(resumedAt: at), .writeManifest, .emitState]
        // case (.recording, .restartRequested(let at)), (.paused, .restartRequested(let at)):
        //     -> .countingDown(notBefore: now + countdown), [.discardTake(at), .armNextTake(notBefore:), .emitState]
        // case (.recording(let c), .stopRequested(let at)), (.paused(let c), .stopRequested(let at)):
        //     -> .stopping(.userStopped), [.finalize(.userStopped, closing: c, at: at)]
        // case (.recording, .durationReached), (.paused, .durationReached): -> .stopping(.durationReached), [.finalize]
        // case (.recording, .streamFailed), (.paused, .streamFailed):       -> .stopping(.streamFailed), [.finalize]
        // case (_, .discarded(let url)):                         -> same phase, [.emit(.discarded(url))]
        // case (.stopping, .finalized(let outcome)):             -> .finished(outcome), [.emit(.ended(outcome))]
        // case (.recording, .progress), (.paused, .progress), warnings in any live phase: emit
        // default: no-op
        fatalError("not implemented")
    }
}

/// The take's clock on the host clock: what the sink gates by and what the manifest stores.
/// Made only by `rolled`, changed only by the two methods below, so a pause can never be open
/// twice or closed before it opened.
struct HostClock: Sendable, Equatable {
    let origin: HostTime
    private(set) var closed: [Range<HostTime>]
    private(set) var open: HostTime?

    /// Whether a buffer stamped `t` belongs to the take: at or after the origin and in no pause.
    func admits(_ t: HostTime) -> Bool { fatalError("not implemented") }

    /// `at` is clamped to be no earlier than the origin and the end of the last pause.
    func pausing(at: HostTime) -> HostClock { fatalError("not implemented") }

    /// `at` is clamped to be no earlier than the open pause's start.
    func resuming(at: HostTime) -> HostClock { fatalError("not implemented") }

    func closing(at end: HostTime) -> HostClock { fatalError("not implemented") }

    var wire: [WirePause] { fatalError("not implemented") }
}

enum StopReason: Sendable, Equatable {
    case userStopped
    case durationReached
    case streamFailed(String)
    case cancelled
}

enum SessionInput: Sendable, Equatable {
    /// From the sink: the directory exists and the origin frame is in `screen.mov`.
    case rolled(origin: HostTime)
    case pauseRequested(at: HostTime)
    case resumeRequested(at: HostTime)
    case restartRequested(at: HostTime)
    case stopRequested(at: HostTime)
    case durationReached
    case streamFailed(String)
    case progress(RecordingProgress)
    case warning(RecordingWarning)
    case discarded(URL)
    case finalized(RecordingOutcome)
}

struct SessionTransition: Sendable, Equatable {
    var phase: SessionPhase
    var effects: [SessionEffect]
}

enum SessionEffect: Sendable, Equatable {
    case emit(RecordingUpdate)
    /// Create the event log and write the first manifest for the take that just rolled.
    case beginTake(origin: HostTime)
    /// Push the clock to the sink and the event log. With `resumedAt`, the sink appends the newest
    /// frame it held during the pause at that time, and the event log writes a state event there.
    case applyClock(HostClock, resumedAt: HostTime?)
    case writeManifest
    /// Finish the take's writers and event log at `at`, finalize its manifest, release its lock,
    /// and move the directory to the Trash. Runs while the next countdown counts.
    case discardTake(at: HostTime)
    /// Configure fresh writers (in memory only) and tell the sink not to roll before `notBefore`.
    case armNextTake(notBefore: HostTime)
    /// Drop the configured writers, stop the stream, release the camera lease. Nothing on disk.
    case cancelTake
    case finalize(StopReason, clock: HostClock, at: HostTime)
}

extension HostTime {
    /// `SuspendingClock` is `CLOCK_UPTIME_RAW` on Darwin, the recorder's host clock (measured in
    /// spike/hotkey: equal to the microsecond, while `ContinuousClock` differs by time asleep).
    init(_ instant: SuspendingClock.Instant) { fatalError("not implemented") }
}
