// Sources/Studio/RecordingChrome.swift, GlobalHotkeys.swift (new).
//
// Every floating window the app shows around a take has one owner. It observes the model and
// shows, moves, and hides panels; it never decides what the recorder does.

import AppKit
import Recording

@MainActor
final class RecordingChrome {
    /// Built once at launch, beside the model.
    init(model: StudioModel, hotkeys: GlobalHotkeys) { fatalError("not implemented") }

    /// Derived from the model on every change, so no panel outlives the state that shows it:
    ///
    ///   panel        home/editing          starting      countingDown   recording/paused   stopping
    ///   bubble       camera on and shown   same          same           same               hidden
    ///   control bar  -                     "Starting"    "3" + Stop     time, ⏸, ↺, ■       "Saving"
    ///   countdown    -                     -             digits         -                  -
    ///   Esc hot key  -                     registered    registered     -                  -
    ///
    /// The bubble holds a `CameraLease` while it is visible; the session holds its own. Changing the
    /// camera on Home releases one lease and acquires another. In editing the bubble is hidden and
    /// its lease released, so the camera light goes off.
    private func render() { fatalError("not implemented") }
}

/// A borderless, non-activating `NSPanel`: clicking it never takes focus from the app being
/// recorded. `canHide = false`, so it stays when the app hides its main window on Record, and
/// `collectionBehavior` joins all Spaces and full-screen apps. Excluded from capture by the
/// filter (CaptureFilter.swift), not by `sharingType`.
@MainActor
final class FloatingPanel: NSPanel {
    enum Role { case bubble, controlBar, countdown }
    init(role: Role, on display: CGDirectDisplayID) { fatalError("not implemented") }
}

/// Carbon `RegisterEventHotKey`: global, needs no permission (measured: registration returned
/// noErr in a process with no Accessibility, Input Monitoring, or Post Event access), and the key
/// press does not reach the frontmost app. Times come from `GetEventTime`, which reads the same
/// clock as `SuspendingClock` and the recorder (measured, to the microsecond), so a pause starts at
/// the key press, not when the handler ran.
@MainActor
final class GlobalHotkeys {
    struct Combo: Hashable, Sendable {
        var keyCode: UInt32
        var modifiers: UInt32
        /// Control-Option-Command R and P. Three modifiers, because a registered combo is taken
        /// from every app while it is registered, and two-modifier letters collide with app menus
        /// (Shift-Command-R is Safari's Reader).
        static let startOrStop = Combo(keyCode: 15, modifiers: 0x1900)
        static let pauseOrResume = Combo(keyCode: 35, modifiers: 0x1900)
        static let escape = Combo(keyCode: 53, modifiers: 0)
    }

    enum Registration: Equatable {
        case active
        /// `eventHotKeyExistsErr` (-9878, measured for a second registration in-process). A clash
        /// with another app's or the system's shortcut is not reported: registering
        /// Shift-Command-3, the system screenshot, returned noErr (measured).
        case taken
    }

    /// `handler` gets the command and the key press's time.
    init(handler: @escaping @MainActor (RecordingCommand, SuspendingClock.Instant) -> Void) { fatalError("not implemented") }

    /// Registered at launch and kept for the app's life.
    func register(_ combo: Combo, for command: RecordingCommand) -> Registration { fatalError("not implemented") }

    /// Esc is taken from every app only while a countdown runs, a few seconds at most.
    func setEscapeCancels(_ enabled: Bool) { fatalError("not implemented") }
}
