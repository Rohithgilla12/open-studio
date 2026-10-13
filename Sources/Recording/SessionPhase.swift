enum SessionPhase: Sendable, Equatable {
    case recording(RecordingProgress)
    case stopping(StopReason)
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

    private static func stopping(_ reason: StopReason) -> SessionTransition {
        SessionTransition(phase: .stopping(reason), effects: [.finalize(reason)])
    }
}

enum StopReason: Sendable, Equatable {
    case userStopped
    case durationReached
    case streamFailed(String)

    var termination: Termination {
        switch self {
        case .userStopped: .userStopped
        case .durationReached: .durationReached
        case .streamFailed(let message): .streamFailed(message)
        }
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
    case finalize(StopReason)
}
