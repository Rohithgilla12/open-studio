import Foundation

/// The session lifecycle after `start` returns. Starting is not a phase: a session object only exists
/// once recording has begun, so "stop while starting" cannot happen.
///
///     recording --stopRequested / durationReached / streamFailed--> stopping(reason)
///     stopping  --finalized(result)-------------------------------> finished(result)
///
/// The first termination reason wins; later ones are ignored. That makes `stop()` after a stream
/// failure, or a stream failure during finalization, a no-op instead of a race.
enum SessionPhase: Sendable, Equatable {
    case recording(RecordingProgress)
    case stopping(Termination)
    case finished(FinishedRecording)

    /// Pure, so every lifecycle rule is unit-testable without ScreenCaptureKit.
    static func next(_ phase: SessionPhase, _ input: SessionInput) -> SessionTransition {
        // TODO:
        // switch (phase, input):
        //   (.recording, .progress(p))           -> .recording(p), [.emit(.progress(p))]
        //   (.recording, .warning(w))            -> same phase, [.emit(.warning(w))]
        //   (.recording, .stopRequested)         -> .stopping(.userStopped), [.finalize(.userStopped)]
        //   (.recording, .durationReached)       -> .stopping(.durationReached), [.finalize(.durationReached)]
        //   (.recording, .streamFailed(m))       -> .stopping(.streamFailed(m)), [.finalize(.streamFailed(m))]
        //   (.stopping, .finalized(r))           -> .finished(r), [.emit(.ended(r))]
        //   (.stopping or .finished, anything else) -> unchanged, []
        //   (.recording, .finalized)             -> impossible; assertionFailure, unchanged
        fatalError("not implemented")
    }
}

enum SessionInput: Sendable, Equatable {
    case progress(RecordingProgress)
    case warning(RecordingWarning)
    case stopRequested
    case durationReached
    case streamFailed(String)
    case finalized(FinishedRecording)
}

struct SessionTransition: Sendable, Equatable {
    var phase: SessionPhase
    var effects: [SessionEffect]
}

enum SessionEffect: Sendable, Equatable {
    case emit(RecordingUpdate)
    case finalize(Termination)
}
