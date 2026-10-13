import Foundation
internal import RecordingFormat

/// A recording in progress. The only way to get one is `start`, so there is no idle or
/// half-configured session to misuse: holding a `RecordingSession` means frames are being written.
///
/// Runs in the caller's process. Crash safety comes from the directory format, not from process
/// isolation: if this process dies, everything written up to the last movie fragment (1 s) and the
/// last event flush (100 ms) stays on disk, and `recover(at:)` finalizes it.
public actor RecordingSession {
    public nonisolated let directory: URL
    /// Progress, warnings, and exactly one `.ended`, after which the stream finishes.
    public nonisolated let updates: AsyncStream<RecordingUpdate>

    private var phase: SessionPhase
    /// Memoized so concurrent and repeated `stop()` calls await the same finalization.
    private var finalization: Task<FinishedRecording, Never>?
    private let capture: CaptureSink
    private let input: InputCapture
    private let eventLog: EventLogWriter
    private let lock: DirectoryLock

    /// Checks permissions, creates the directory, starts capture, and returns once the first complete
    /// screen frame has been written and `recording.json` exists.
    ///
    /// Either returns a live session or throws and leaves nothing behind: on any failure the
    /// half-created directory is removed.
    public static func start(_ configuration: RecordingConfiguration) async throws(RecordingError) -> RecordingSession {
        // TODO:
        // 1. let missing = Permissions.check().missing(for: configuration)
        //    guard missing.isEmpty else { throw .missingPermissions(missing) }
        // 2. Resolve SCDisplay (and the microphone uniqueID) from SCShareableContent.current;
        //    throw .displayNotFound / .microphoneNotFound.
        // 3. Create <parent>/<YYYYMMDD-HHMMSS>.osrec (suffix -2, -3 on collision) and take the
        //    flock on .lock. From here on, any thrown error runs cleanup: stop sources, remove dir.
        // 4. Start InputCapture before the stream so the t = 0 state snapshot has a real pointer
        //    position and cursor. It stamps events with host time and buffers them.
        // 5. Build SCStreamConfiguration: showsCursor = false, width/height = display pixels,
        //    minimumFrameInterval = 1 / min(maxFrameRate, refresh), queueDepth = 6,
        //    captureMicrophone + microphoneCaptureDeviceID when a microphone is selected (macOS 15),
        //    so microphone buffers arrive on the same stream and host clock as video.
        // 6. startCapture, then await CaptureSink.firstFrame (timeout 5 s -> .noFramesDelivered).
        //    origin = that frame's PTS in host nanoseconds.
        // 7. Both writers startSession(atSourceTime: origin); write the manifest (status .recording);
        //    eventLog.begin(origin:) writes the state snapshot at t = 0, then drains buffered events
        //    with host time >= origin and drops earlier ones.
        // 8. If maxDuration is set, schedule stop(.durationReached) against media time, not wall time.
        fatalError("not implemented")
    }

    /// Stops capture and finalizes the directory. Idempotent: every call, including calls made after
    /// the session already ended on its own, returns the same `FinishedRecording`.
    ///
    /// Never throws. A finalization problem (disk full, writer error) still leaves a readable
    /// directory; it is reported through `termination` and the manifest stays `.recording` so
    /// `recover(at:)` can finish the job.
    public func stop() async -> FinishedRecording {
        fatalError("not implemented")
    }

    /// Finalizes a directory whose recorder died. Safe to call on any recording directory, any
    /// number of times:
    /// - already finalized: returns it unchanged
    /// - recorder still alive (flock held): throws `.stillRecording`
    /// - no manifest (died before the first frame): throws `.nothingRecorded`
    ///
    /// The SwiftUI app calls this on launch for every `.osrec` in its library; `osrec recover` calls it
    /// for one directory.
    public static func recover(at directory: URL) async throws(RecoveryError) -> FinishedRecording {
        // TODO:
        // 1. Try flock(LOCK_EX | LOCK_NB) on .lock. EWOULDBLOCK -> throw .stillRecording.
        //    flock is released by the kernel when the holder dies, so this is a liveness check that
        //    a stale PID file cannot fake.
        // 2. RecordingReader.readMetadata. .noManifest -> .nothingRecorded.
        //    status == .finalized -> return FinishedRecording(manifest) (idempotent no-op).
        // 3. If the event log has a torn tail, truncate events.ndjson to validByteCount.
        //    Truncation to the same length is idempotent, so a crash here is harmless.
        // 4. Open screen.mov with AVURLAsset and load the video track's duration. A fragmented movie
        //    reads up to its last complete fragment. Unreadable -> keep going with duration 0 and a
        //    message, because the events alone are still worth keeping.
        // 5. Same for microphone.mov if the manifest lists one; a bad microphone file only
        //    adds to the message.
        // 6. Commit point, written last: manifest.status = .finalized,
        //    durationMicros = screen duration, termination = .recovered(message).
        //    A crash before this line leaves status .recording, and rerunning repeats steps 3-5 safely.
        fatalError("not implemented")
    }

    private init(
        directory: URL, capture: CaptureSink, input: InputCapture,
        eventLog: EventLogWriter, lock: DirectoryLock
    ) {
        fatalError("not implemented")
    }

    /// Single entry point for everything that can end or change the session: user stop, duration
    /// reached, stream failure, and writer progress. Runs the pure transition and performs its effects.
    private func handle(_ input: SessionInput) {
        // TODO:
        // let transition = SessionPhase.next(phase, input)
        // phase = transition.phase
        // for effect in transition.effects:
        //   .emit(update)        -> continuation.yield(update); finish the stream after .ended
        //   .finalize(reason)    -> finalization = Task { await finalize(reason) }
        fatalError("not implemented")
    }

    /// Ordered so each step's crash leaves a recoverable directory:
    /// stop SCStream and the tap -> flush the event log and close it -> writers endSession at the
    /// last media time and finishWriting -> manifest .finalized (the commit) -> release the flock.
    private func finalize(_ reason: Termination) async -> FinishedRecording {
        fatalError("not implemented")
    }
}

public struct FinishedRecording: Sendable, Equatable {
    public let directory: URL
    public let duration: Duration
    public let hasMicrophone: Bool
    public let termination: Termination
}

public enum Termination: Sendable, Equatable {
    case userStopped
    case durationReached
    /// ScreenCaptureKit stopped the stream (display unplugged, permission revoked mid-take...).
    /// Everything up to the failure is kept.
    case streamFailed(String)
    /// The recorder died and `recover(at:)` finalized the directory. The message lists anything lost.
    case recovered(String?)
    /// `stop()` could not finalize cleanly; the directory is readable but needs `recover(at:)`.
    case finalizationFailed(String)
}

public enum RecordingUpdate: Sendable, Equatable {
    case progress(RecordingProgress)
    case warning(RecordingWarning)
    case ended(FinishedRecording)
}

public struct RecordingProgress: Sendable, Equatable {
    public let mediaTime: Duration
    public let framesWritten: Int
    public let eventsWritten: Int
}

public enum RecordingWarning: Sendable, Equatable {
    /// The microphone track ends early; screen and events continue.
    case microphoneLost(String)
    /// The system disabled the event tap (callback timeout or user input lockout) and it was
    /// re-enabled. Input in the gap is missing.
    case inputTapReenabled(at: Duration)
    case framesDropped(count: Int)
}

public enum RecordingError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingPermissions([Permission])
    case displayNotFound(DisplaySelection)
    case microphoneNotFound(MicrophoneSelection)
    case outputDirectoryUnwritable(URL, String)
    case captureFailedToStart(String)
    /// The stream started but no complete frame arrived within 5 seconds.
    case noFramesDelivered

    /// For `.missingPermissions`, names each pane in System Settings and says the grant belongs to
    /// the app or terminal that launched this process.
    public var description: String { fatalError("not implemented") }
}

public enum RecoveryError: Error, Sendable, Equatable {
    case stillRecording
    case nothingRecorded
    case notARecording(URL)
    case unsupportedVersion(found: Int)
    case unreadable(String)
}
