/// The session lifecycle after `start` returns. Starting is not a phase: a session exists only
/// once frames are being written, so "stop while starting" cannot happen.
///
///     recording --stopRequested / durationReached / streamFailed--> stopping(reason)
///     stopping  --finalized(result)-------------------------------> finished(result)
///
/// The first termination reason wins. A later one is ignored, so `stop()` after a stream failure,
/// or a stream failure during finalization, is a no-op rather than a race.
enum SessionPhase: Sendable, Equatable {
    case recording(RecordingProgress)
    case stopping(Termination)
    case finished(FinishedRecording)

    static func next(_ phase: SessionPhase, _ input: SessionInput) -> SessionTransition {
        switch (phase, input) {
        case (.recording, .progress(let progress)):
            return SessionTransition(phase: .recording(progress), effects: [.emit(.progress(progress))])
        case (.recording, .warning(let warning)):
            return SessionTransition(phase: phase, effects: [.emit(.warning(warning))])
        case (.recording, .stopRequested):
            return stopping(.userStopped)
        case (.recording, .durationReached):
            return stopping(.durationReached)
        case (.recording, .streamFailed(let message)):
            return stopping(.streamFailed(message))
        case (.stopping, .finalized(let result)):
            return SessionTransition(phase: .finished(result), effects: [.emit(.ended(result))])
        case (.recording, .finalized):
            assertionFailure("finalized arrived while still recording")
            return SessionTransition(phase: phase, effects: [])
        case (.stopping, _), (.finished, _):
            return SessionTransition(phase: phase, effects: [])
        }
    }

    private static func stopping(_ reason: Termination) -> SessionTransition {
        SessionTransition(phase: .stopping(reason), effects: [.finalize(reason)])
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
