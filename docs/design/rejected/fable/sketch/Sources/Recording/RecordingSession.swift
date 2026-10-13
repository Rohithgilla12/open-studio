import Foundation
import RecordingFormat

/// One take. Owns the display stream, the event tap, the cursor watcher, and the
/// directory they write into. Runs in the caller's process: the directory format, not a
/// helper process, is what makes a crash survivable (see `RecordingDirectoryLayout`).
///
/// Usage:
///
///     let session = try await RecordingSession.start(config)   // returns once frames flow
///     for await notice in session.notices { ... }               // optional
///     let result = try await session.stop()                     // safe to call twice
public actor RecordingSession {
    public enum Notice: Sendable, Equatable {
        case stateChanged(RecordingState)
        case droppedFrames(Int)
        case warning(String)
    }

    public nonisolated let config: RecordingConfig
    public nonisolated let notices: AsyncStream<Notice>
    public private(set) var state: RecordingState = .preparing

    private let directory: RecordingDirectory
    private let clock: HostClock
    private let display: DisplayCapture
    private let input: InputTap
    private let cursor: CursorWatcher
    private let noticeContinuation: AsyncStream<Notice>.Continuation

    /// Preflights permissions, resolves the display, creates the directory and writes
    /// `manifest.json`, starts all producers, then waits for the first video frame so
    /// "started" means "frames are being written". Throws `RecordingError` on any failure
    /// and removes the directory if no frame was ever written.
    public static func start(_ config: RecordingConfig) async throws -> RecordingSession {
        // TODO:
        // guard Permissions.check().allowsRecording else throw .permissionsMissing
        // let clock = HostClock.start()                 // samples startHostNanos once
        // let shareable = try await resolveDisplay(config.display)
        // let directory = try RecordingDirectory.create(at:, manifest:)
        // await directory.events.append(.mark("recordingStarted"), at: clock.now())
        // input.start(); cursor.start(); try await display.start()
        // await withTimeout(config.firstFrameTimeout) { await display.firstFrame }
        //   -> apply(.firstFrame(offset)) which writes timebase.json
        fatalError("not implemented")
    }

    /// Stops producers, finishes the movie (`AVAssetWriter.finishWriting`), writes
    /// `finish.json`, returns the result. Idempotent: a second call during `stopping`
    /// awaits the same completion; after `finished` it returns the stored result.
    public func stop() async throws -> RecordingResult {
        fatalError("not implemented")
    }

    /// Applies a state-machine action and performs its side effect. Every producer
    /// callback funnels through here, so state changes are serialised by the actor.
    private func apply(_ action: RecordingStateMachine.Action) {
        // TODO: switch RecordingStateMachine.next(state, action)
        //   .transition(let s): state = s; side effects:
        //        .recording(offset)  -> directory.writeTimebase(...)
        //        .finished(result)   -> directory.writeFinish(.completed)
        //        .failed(error)      -> directory.writeFinish(.failed) if timebase exists
        //      noticeContinuation.yield(.stateChanged(s))
        //   .noop: return
        //   .invalid: assertionFailure in debug; yield .warning in release
        fatalError("not implemented")
    }

    private init(
        config: RecordingConfig,
        directory: RecordingDirectory,
        clock: HostClock,
        display: DisplayCapture,
        input: InputTap,
        cursor: CursorWatcher
    ) {
        fatalError("not implemented")
    }
}

/// Lists displays for `osrec displays` and the app's picker. Separate from the session
/// because it is needed before a config exists.
public struct DisplayInfo: Sendable, Equatable, Identifiable {
    public var id: UInt32
    public var name: String
    public var pointWidth: Double
    public var pointHeight: Double
    public var scaleFactor: Double
    public var isMain: Bool

    public static func available() async throws -> [DisplayInfo] {
        fatalError("not implemented")
    }
}
