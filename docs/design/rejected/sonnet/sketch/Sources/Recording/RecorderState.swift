import Foundation
import RecordingFormat

/// What observers see. Terminal states carry their payload.
public enum RecordingState: Sendable, Equatable {
    case starting
    case recording(elapsed: RecordingTime)
    case stopping
    case finished(RecordingSummary)
    case failed(RecordingError, salvage: RecordingSummary?)
}

public struct RecordingSummary: Sendable, Equatable, Codable {
    public var directory: URL
    public var duration: RecordingTime
    public var degradations: [Degradation]
    public var stats: RecordingManifest.Stats
}

/// Internal phase of the session. The reducer is a pure function so every transition,
/// including the crash-adjacent ones, is unit-testable without a display or TCC.
enum Phase: Equatable {
    case idle
    case starting(Progress)
    case recording(Running)
    case stopping(Reason, Running?)
    case finished(RecordingSummary)
    case failed(RecordingError, RecordingSummary?)

    struct Progress: Equatable {
        var streamStarted = false
        var tapStarted = false
        var firstFrame: HostTime?
    }

    struct Running: Equatable {
        var origin: HostTime
        var degradations: [Degradation]
    }

    enum Reason: Equatable { case requested, durationReached, captureError(RecordingError) }
}

enum Input: Equatable {
    case begin
    case streamStarted
    case tapStarted
    case tapUnavailable
    case firstFrame(HostTime)
    case stopRequested
    case durationReached
    case streamFailed(RecordingError)
    case writerFailed(RecordingError)
    case degraded(Degradation)
    case finalised(RecordingSummary)
}

enum Effect: Equatable {
    case acquireLockAndWriteInitialManifest
    case startStream
    case startEventTap
    case startCursorWatcher
    case writeOriginToManifest(HostTime)
    case stopCaptureAndFlush
    case finaliseWriters
    case writeFinalManifest
    case releaseLock
}

/// Rules the reducer enforces:
/// - stop is idempotent: stopRequested while .stopping or .finished is a no-op with no effects.
/// - a lost tap or mic degrades; a lost stream or video writer ends the take with salvage.
/// - origin is set exactly once, by the first frame; later .firstFrame inputs are ignored.
/// - .finalised is only accepted from .stopping.
func transition(_ phase: Phase, _ input: Input) -> (Phase, [Effect]) {
    // TODO: exhaustive switch over (phase, input); default branch returns (phase, []) so a
    // late callback from a torn-down component can never move the machine.
    fatalError("not implemented")
}
