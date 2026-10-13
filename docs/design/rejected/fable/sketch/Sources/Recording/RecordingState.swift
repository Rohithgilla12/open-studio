import Foundation

/// The session's lifecycle. Pure and testable: `RecordingStateMachine.next` is the only
/// place a transition is decided, and the actor just applies what it returns.
///
///   preparing ──firstFrame──▶ recording ──stopRequested──▶ stopping ──writerFinished──▶ finished
///       │                         │                            │
///       └────────── failure ──────┴──────── failure ───────────┘──▶ failed
///
/// `stopRequested` in `stopping`, `finished`, or `failed` is a no-op (idempotent stop).
/// `firstFrame` after `recording` is a no-op (SCStream may deliver frames while stopping).
public enum RecordingState: Sendable, Equatable {
    case preparing
    case recording(firstFrameOffset: Duration)
    case stopping
    case finished(RecordingResult)
    case failed(RecordingError)
}

enum RecordingStateMachine {
    enum Action: Sendable, Equatable {
        case firstFrame(offset: Duration)
        case stopRequested
        case writerFinished(RecordingResult)
        case failure(RecordingError)
    }

    enum Outcome: Equatable {
        /// Apply the new state and run its side effect (write timebase, write finish, ...).
        case transition(RecordingState)
        /// Already in the state this action leads to. Caller does nothing.
        case noop
        /// A genuine misuse, e.g. `writerFinished` while `preparing`.
        case invalid
    }

    static func next(_ state: RecordingState, _ action: Action) -> Outcome {
        // TODO:
        // (preparing, firstFrame)         -> recording
        // (preparing, stopRequested)      -> stopping   (user cancelled before frames; finish.json records failed/noFrames)
        // (recording, stopRequested)      -> stopping
        // (stopping, writerFinished)      -> finished
        // (recording|stopping, firstFrame)-> noop
        // (stopping|finished|failed, stopRequested) -> noop
        // (_, failure) unless finished    -> failed
        // everything else                 -> invalid
        fatalError("not implemented")
    }
}
