// Sketch. Module Studio. The take as the app sees it: one pure reducer, one stage value, and every
// button and hotkey mapped to an input. No booleans.
//
//   home ──record──▶ preparing ──prepared──▶ counting ──countdownDone──▶ starting ──began──▶ live(recording)
//                       │ countdownDone                                                        │ pause/resume
//                       ▼ (digits reached 1 and hold)                                           ▼
//                    preparing(ready)                                                     live(paused)
//                                                                                              │ stop     ──▶ stopping ──ended──▶ home (opens the editor)
//   esc / start-stop hotkey while preparing|counting ──▶ cancelling ──▶ home              │ restart  ──▶ discarding ──ended──▶ preparing (same configuration)

import Foundation
import Recording

/// One value, owned by `LiveRecording`, read by the control bar, the countdown panel, the menu bar
/// extra, and the hotkeys. `StudioModel.Phase.recording(LiveRecording)` is unchanged; the stage
/// replaces `LiveRecording.Stage` and its booleans.
enum TakeStage: Equatable {
    /// Capture is warming. `countdown` runs from the moment Record was pressed, so the warm-up
    /// hides under the digits; if it finishes first, the last digit holds until `prepared`.
    case preparing(Countdown)
    case counting(any PreparedHandle, Countdown)
    /// `begin()` in flight.
    case starting(any PreparedHandle)
    case live(any RecordingHandle, TakeClock)
    case stopping(any RecordingHandle)
    /// Restart: the take is being trashed; the next stage is `preparing` with the same configuration.
    case discarding(any RecordingHandle)
    case cancelling(any PreparedHandle)

    static func == (lhs: TakeStage, rhs: TakeStage) -> Bool { fatalError("not implemented") }
}

struct Countdown: Equatable {
    static let length: Duration = .seconds(3)
    let endsAt: SuspendingClock.Instant
    /// Set when the timer fired while capture was still warming.
    var finished: Bool
    /// 3, 2, 1, or 0 once finished. The panel draws this.
    func digit(at now: SuspendingClock.Instant) -> Int { fatalError("not implemented") }
}

enum TakeInput: Equatable {
    // from the user
    case record, cancel, togglePause, pause, resume, restart, stop
    // from the clock
    case countdownFinished
    // from Recording
    case prepared(any PreparedHandle)
    case began(any RecordingHandle)
    case clock(TakeClock)
    case ended(FinishedRecording)
    case failed(RecordingError)

    static func == (lhs: TakeInput, rhs: TakeInput) -> Bool { fatalError("not implemented") }
}

enum TakeEffect: Equatable {
    case prepare(RecordingConfiguration)
    case startCountdown(Countdown)
    case begin(any PreparedHandle)
    case cancel(any PreparedHandle)
    case pause(any RecordingHandle)
    case resume(any RecordingHandle)
    case stop(any RecordingHandle)
    case discard(any RecordingHandle)
    case showMainWindow
    case hideMainWindow
    case openEditor(URL)
    case alert(StudioAlert)

    static func == (lhs: TakeEffect, rhs: TakeEffect) -> Bool { fatalError("not implemented") }
}

/// The table. An input not listed for a stage returns the stage unchanged with no effects, so a
/// button or hotkey in the wrong phase does nothing, and a test can press every input in every
/// stage and assert exactly which pairs act (`TakeFlowSpec.onlyTheseInputsActInEachStage`).
enum TakeFlow {
    static func next(_ stage: TakeStage?, _ input: TakeInput, now: SuspendingClock.Instant) -> (stage: TakeStage?, effects: [TakeEffect]) {
        // nil (home/editing) + record        -> preparing(countdown), [.prepare(config), .startCountdown, .hideMainWindow]
        // preparing(c)       + prepared(p)   -> c.finished ? starting(p), [.begin(p)] : counting(p, c), []
        // preparing(c)       + countdownFinished -> preparing(c.finished = true), []
        // counting(p, c)     + countdownFinished -> starting(p), [.begin(p)]
        // preparing|counting + cancel        -> cancelling or nil, [.cancel(p)?, .showMainWindow]   (a cancel while preparing waits for prepared, then cancels it)
        // starting(p)        + began(s)      -> live(s, clock at now), []
        // starting(p)        + failed(e)     -> nil, [.showMainWindow, .alert]
        // live(s, k)         + pause         -> live, [.pause(s)]            (if !k.isPaused)
        // live(s, k)         + resume        -> live, [.resume(s)]           (if k.isPaused)
        // live(s, k)         + togglePause   -> the one of the two that applies
        // live(s, k)         + clock(k')     -> live(s, k'), []
        // live(s, _)         + stop          -> stopping(s), [.stop(s)]
        // live(s, _)         + restart       -> discarding(s), [.discard(s)]
        // stopping(s)        + ended(f)      -> nil, [.showMainWindow, .openEditor(f.directory)] (plus the alerts today's recordingEnded shows)
        // discarding(s)      + ended(_)      -> preparing(countdown at now), [.prepare(config), .startCountdown]
        // any live stage     + ended(f) where f.termination is streamFailed -> nil, [.showMainWindow, .alert, .openEditor]
        fatalError("not implemented")
    }

    /// What a global hotkey means in each stage. Start/stop: nil -> record, preparing|counting ->
    /// cancel, live -> stop, else nothing. Pause/resume: live -> togglePause, else nothing.
    static func input(for hotkey: Hotkey, in stage: TakeStage?) -> TakeInput? { fatalError("not implemented") }

    /// Which controls the bar shows and enables, derived from the stage so the bar cannot show a
    /// button the reducer would ignore.
    static func controls(for stage: TakeStage) -> [Control] { fatalError("not implemented") }

    enum Control: Equatable {
        case pause, resume, restart, stop, cancelCountdown
    }
}

/// `RecordingHandle` exists today. `PreparedHandle` is its twin for the prepared state, so
/// `StudioServices.prepare` can return a fake in tests.
protocol PreparedHandle: Sendable {
    func begin() async throws(RecordingError) -> any RecordingHandle
    func cancel() async
}

extension PreparedRecording: PreparedHandle {}

// RecordingHandle gains pause(), resume(), discard().
