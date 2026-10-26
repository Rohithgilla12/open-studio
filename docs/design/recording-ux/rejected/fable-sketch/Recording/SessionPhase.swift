// Sketch. Module Recording. The session's lifecycle, extended. Pure, as today.
//
//   recording ──pauseRequested──▶ paused ──resumeRequested──▶ recording
//       │                           │
//       ├── stopRequested / durationReached / streamFailed ──▶ stopping(reason) ──finalized──▶ finished
//       └── discardRequested ───────┴──────────────────────────▶ discarding ─────finalized──▶ finished
//
// Every input that does not appear on an arrow is ignored in that phase (returns the phase with no
// effects), which is what makes pause, resume, stop, and discard idempotent at the session level.

enum SessionPhase: Sendable, Equatable {
    case recording(RecordingProgress)
    /// `since` is the pause's host time, which the manifest and the clock both carry.
    case paused(RecordingProgress, since: HostTime)
    case stopping(StopReason)
    case discarding
    case finished(FinishedRecording)

    static func next(_ phase: SessionPhase, _ input: SessionInput) -> SessionTransition {
        // recording + pauseRequested(at)     -> paused,     [.pauseCapture(at), .emit(.clock)]
        // paused    + resumeRequested(at)    -> recording,  [.resumeCapture(at), .emit(.clock)]
        // paused    + stopRequested          -> stopping(.userStopped), [.finalize]  (a stop while paused ends the take at the pause's start: see CaptureSink)
        // paused    + durationReached        -> stopping(.durationReached), [.finalize]
        // recording|paused + discardRequested -> discarding, [.discard]
        // recording|paused + streamFailed    -> stopping(.streamFailed), [.finalize]
        // paused    + progress               -> paused (progress while paused is the heartbeat; not emitted)
        // paused    + warning                -> paused, [.emit(.warning)]
        // discarding + finalized(result)     -> finished, [.emit(.ended(result))]
        // everything else as today
        fatalError("not implemented")
    }
}

enum SessionInput: Sendable, Equatable {
    case progress(RecordingProgress)
    case warning(RecordingWarning)
    case pauseRequested(at: HostTime)
    case resumeRequested(at: HostTime)
    case stopRequested
    case discardRequested
    case durationReached
    case streamFailed(String)
    case finalized(FinishedRecording)
}

enum SessionEffect: Sendable, Equatable {
    case emit(RecordingUpdate)
    case pauseCapture(at: HostTime)
    case resumeCapture(at: HostTime)
    case finalize(StopReason)
    case discard
}

/// What a stop while paused means. The take ends at the pause's start, not at the stop: the user
/// paused to end the content, then decided to stop. Recording, the manifest, and the editor then
/// agree that nothing after the pause exists, and the trailing pause does not appear as a trim.
/// The clock the user saw (elapsed excluding pauses) is exactly the take's duration.
enum StopWhilePaused {
    static let endsAtPauseStart = true
}
