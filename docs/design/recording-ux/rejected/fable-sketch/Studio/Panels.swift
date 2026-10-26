// Sketch. Module Studio. The three windows and the hotkeys.
//
//   ┌──────────────────────────── target display ────────────────────────────┐
//   │                                                                        │
//   │                              ┌───────┐                                 │
//   │                              │   3   │  CountdownPanel, centred,       │
//   │                              └───────┘  "Esc to cancel"                │
//   │   ╭────╮                                                               │
//   │   │ ◉  │ CameraBubblePanel                 ┌───────────────────────┐   │
//   │   ╰────╯ draggable, circular               │ ● 01:24  ⏸  ↺  ■     │   │
//   │                                            └───────────────────────┘   │
//   │                                               ControlBarPanel          │
//   └────────────────────────────────────────────────────────────────────────┘
//
// All three are `FloatingPanel`s: NSPanel, borderless, non-activating, floating level, on every
// space and over full-screen apps, `hidesOnDeactivate = false`, movable by background. They are
// kept out of the capture by the content filter (not by hiding), so where they sit is free.
// The main window is ordered out while a take runs, not `NSApp.hide`, because hiding the app would
// hide these panels too.

import AppKit
import AVFoundation
import Recording
import SwiftUI

@MainActor
class FloatingPanel: NSPanel {
    /// `.borderless, .nonactivatingPanel`; `level = .floating`; `collectionBehavior =
    /// [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`; `hidesOnDeactivate = false`;
    /// `isMovableByWindowBackground = true`; transparent background with the SwiftUI content's own
    /// shape.
    init<Content: View>(content: Content, frame: NSRect) { fatalError("not implemented") }
}

/// The digit over the target display. Key while shown so Esc reaches it (the app activates for
/// the three seconds, which is fine: the panels are excluded from capture and the main window is
/// out). Esc, the Stop control, and the start/stop hotkey all send `.cancel`.
@MainActor
final class CountdownPanel {
    init(take: LiveRecording, display: DisplayInfo) { fatalError("not implemented") }
    func close() { fatalError("not implemented") }
}

/// A circle showing `feed.previewLayer`, aspect-filled and mirrored, 180 pt by default, draggable.
/// Shown whenever Studio holds a feed: on Home (the picked camera), through the countdown, and
/// during the take. Closed with the feed when the person picks None or opens the editor. Shows
/// "Camera disconnected" over a dimmed last picture on `.lost`. Its origin is saved in
/// `RecordingPreferences.bubbleOrigin` (global points) and clamped onto a connected display when
/// restored.
@MainActor
final class CameraBubblePanel {
    init(feed: CameraFeed, preferences: Binding<RecordingPreferences>) { fatalError("not implemented") }
    func replace(feed: CameraFeed) { fatalError("not implemented") }
    func close() { fatalError("not implemented") }
}

/// Elapsed (from `TakeClock`, ticking once a second through `TimelineView(.periodic)`), then the
/// controls `TakeFlow.controls(for:)` lists: pause or resume, restart, stop. During the countdown
/// it shows only Stop (cancel). Its origin is saved like the bubble's; default bottom centre of
/// the target display, above the Dock.
struct ControlBar: View {
    let take: LiveRecording
    var body: some View { fatalError("not implemented") }
}

@MainActor
final class ControlBarPanel {
    init(take: LiveRecording, display: DisplayInfo, preferences: Binding<RecordingPreferences>) { fatalError("not implemented") }
    func close() { fatalError("not implemented") }
}

/// A global shortcut, as Carbon wants it. Pure: `carbonModifiers` and `keyCode` are tested
/// against known values (⌃⌥⌘R = keyCode 15, modifiers controlKey | optionKey | cmdKey).
struct Hotkey: Hashable, Sendable {
    enum Action: Hashable, Sendable {
        case startStop
        case pauseResume
    }
    let action: Action
    let keyCode: UInt32
    let modifiers: NSEvent.ModifierFlags

    /// ⌃⌥⌘R and ⌃⌥⌘P. Three modifiers so no app's own shortcut is shadowed (a registered hot
    /// key takes the chord from every app, including the one in front). Not user-configurable in
    /// this unit; the values live in one place for when they are.
    static let defaults: [Hotkey] = []

    var carbonModifiers: UInt32 { fatalError("not implemented") }
}

/// `RegisterEventHotKey` on the application event target. Needs no permission: registration
/// returns noErr from an accessory process with Input Monitoring and Accessibility both absent and
/// unchanged afterwards (measured, `spike/hotkey.swift`). The handler running while another app
/// is frontmost is documented Carbon behaviour, not measured here (the spike waits for a real
/// press; posting the chord needs Accessibility). Registered once at launch for the app's life,
/// through `StudioServices.registerHotkeys` so tests inject presses without Carbon.
@MainActor
final class HotkeyCenter {
    init(_ hotkeys: [Hotkey], onPress: @escaping @MainActor (Hotkey.Action) -> Void) { fatalError("not implemented") }
    deinit { /* UnregisterEventHotKey each */ }
}

extension StudioServices {
    // var prepare: @Sendable (RecordingConfiguration, CameraFeed?) async throws(RecordingError) -> any PreparedHandle
    // var openCamera: @Sendable (CameraSelection) async throws(RecordingError) -> CameraFeed
    // var registerHotkeys: @MainActor ([Hotkey], @escaping @MainActor (Hotkey.Action) -> Void) -> AnyObject
    // var setMainWindowHidden: @MainActor @Sendable (Bool) -> Void     replaces setAppHidden
    // var trash: @Sendable (URL) throws -> URL                           (used by Recording's discard; here for the fake)
    // startRecording is deleted (migrate callers, delete the old path).
}

// StudioModel changes, in prose:
// - `cameraFeed: CameraFeed?` follows `preferences.camera` while `phase` is `.home` or `.recording`;
//   nil in the editor and while exporting. The bubble panel follows the feed.
// - `record()` sends `.record` to the flow; every button and hotkey sends a `TakeInput`;
//   `LiveRecording.stage` is the reducer's state, and `LiveRecording` runs the effects.
// - `recordingEnded` becomes the `.ended` branch of the reducer's effects: `.discarded` opens
//   nothing and prepares again; a stop opens the take as today.
// - `readiness` is `.busy` whenever `phase` is `.recording`, as today, so Home's pickers are
//   inert during a countdown too.
// - Track A2's target picker starts a take by sending `.record` with its configuration. One entry.
