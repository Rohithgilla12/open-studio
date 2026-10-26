// Sources/Studio/StudioModel.swift, RecordingViews.swift (changed).
//
// The app does not keep its own copy of the recorder's state. `LiveRecording.state` is the last
// `LiveState` the session sent, plus `.starting` before the session exists. Buttons and hot keys
// read one table from it, and the session ignores a command that does not fit its own phase, so
// a stale button costs a no-op, never a wrong action.

import AppKit
import Recording

extension StudioModel {
    // public enum Phase { case home, recording(LiveRecording), editing(Editor), exporting(ExportJob) }  // unchanged

    /// The one entry point for every way of starting: the Record button, File > New Recording,
    /// the start hot key, and later the A2 target picker. Unchanged in shape: area targets still
    /// pick the area first. `configuration.countdown` comes from preferences (3 s by default).
    // public func record() async

    /// Routes a command from any surface through `RecordingCommand.action(in:)`.
    public func perform(_ command: RecordingCommand, at time: SuspendingClock.Instant = .now) async {
        // switch command.action(in: liveState) {
        // case .start:   await record()
        // case .cancel, .stop: let outcome = await handle.stop(at: time); await recordingEnded(outcome, from: live)
        // case .pause:   await handle.pause(at: time)
        // case .resume:  await handle.resume(at: time)
        // case .restart: await handle.restart(at: time)
        // case nil:      break
        // }
        fatalError("not implemented")
    }
}

/// What a person can ask for while recording, from a button or a hot key.
public enum RecordingCommand: Sendable, CaseIterable {
    /// The start/stop hot key and the Stop button.
    case startOrStop
    /// The pause hot key and the pause/resume button.
    case pauseOrResume
    case restart
    /// Esc during the countdown.
    case cancel

    /// The whole policy, as a table. The control bar shows a button only when its command maps to
    /// an action here, and the hot key handler sends every press through it.
    ///
    ///   state            startOrStop   pauseOrResume   restart   cancel
    ///   idle (home/edit) start         -               -         -
    ///   starting         cancel        -               -         cancel
    ///   countingDown     cancel        -               -         cancel
    ///   recording        stop          pause           restart   -
    ///   paused           stop          resume          restart   -
    ///   stopping         -             -               -         -
    ///   busy (export)    -             -               -         -
    public func action(in state: RecordingCommandState) -> RecordingAction? { fatalError("not implemented") }
}

public enum RecordingAction: Sendable, Equatable {
    case start, cancel, stop, pause, resume, restart
}

/// `StudioModel.phase` and `LiveRecording.state` folded into what the table needs.
public enum RecordingCommandState: Sendable, Equatable {
    case idle(canStart: Bool)
    case starting
    case countingDown
    case recording
    case paused
    case stopping
    case busy
}

@MainActor
@Observable
public final class LiveRecording {
    public enum State: Equatable {
        /// `RecordingSession.start` is resolving the target and waiting for the first frame.
        case starting
        case live(LiveState)
    }

    public internal(set) var state: State = .starting
    public internal(set) var warnings: [RecordingWarning] = []
    var handle: (any RecordingHandle)?
}

protocol RecordingHandle: Sendable {
    var updates: AsyncStream<RecordingUpdate> { get }
    func pause(at: SuspendingClock.Instant) async
    func resume(at: SuspendingClock.Instant) async
    func restart(at: SuspendingClock.Instant) async
    func stop(at: SuspendingClock.Instant) async -> RecordingOutcome
}

extension RecordingPreferences {
    // var countdown: Duration                // 3 s; 0 turns it off
    // var showsCameraBubble: Bool            // meaningful only with a camera; no camera, no bubble
    // var bubbleCenter: [DisplayID: CGPoint] // where the person dragged it, per display
}
