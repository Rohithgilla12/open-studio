# Design brief: the recording experience (track A1)

## Goal

The user tried to record a real video for their team with open-studio. The app quit on Stop (fixed in 9938739), and they switched to another app. Even with that fixed, recording here is missing what other recorders give them before and during a take. This unit adds:

1. **Countdown.** 3, 2, 1 before the take starts. Esc or the Stop control cancels it, and nothing is written.
2. **Camera preview.** A floating, draggable, circular bubble that shows the chosen camera on Home before recording and stays up during it. It is never in the screen video, because the camera is recorded to `camera.mov` and composited at export.
3. **Pause and resume.** The user decided that a pause becomes a cut. The clock keeps running. Nothing is written while paused: no frames, no audio, no input events. The pause ranges are stored in `recording.json`, and when the take opens they become cuts that the editor draws differently and does not let the user restore. The cuts unit (`docs/design/cuts/rationale.md`) already removes time everywhere.
4. **Restart.** Discards the take in progress and starts again with the same settings, through the countdown. The discarded take goes to the Trash, not `removeItem`.
5. **Recording controls.** A small floating control bar while recording, excluded from capture: elapsed time (excluding pauses), pause/resume, restart, stop. The menu bar extra stays as it is.
6. **Global hotkeys.** Start or stop with a shortcut while another app is frontmost, and pause or resume with another. No new permission prompt.

The Cap-style on-screen target picker is track A2, after this unit. Do not design it here, but do not block it: it will start a recording through the same entry point Home uses.

## Grounding: what exists today

Read these files to confirm details.

**Session** (`Sources/Recording/RecordingSession.swift`). `RecordingSession.start(configuration)` checks permissions, resolves the target, creates the take directory, takes the lock, starts `InputCapture` and `CaptureSink`, waits for the first complete screen frame, and uses that frame's host time as the origin (`clock.origin = first-screen-frame`). It writes `recording.json` and returns a live actor. `stop()` is idempotent. A `SessionPhase` state machine drives it. Crash safety comes from the directory format: fragmented movies and an append-only event log, finalised by `recover(at:)`.

**Writers** (`Sources/Recording/CaptureSink.swift`, `MovieWriter.swift`, `AudioTrack.swift`, `Camera.swift`, `EventLogWriter.swift`). One writer per file. The screen writer repeats the last frame once per second when the screen is still. The system-audio writer fills gaps in delivery with silence, capped at a named maximum. The microphone and camera run through `AVCaptureSession`, which `Camera.swift` and the microphone path own today. Every timestamp is in microseconds from the origin.

**Format** (`Sources/RecordingFormat/Manifest.swift`). `recording.json` is the commit point, replaced atomically. Format version 4 with system audio, 3 with a camera, 2 with an area, 1 otherwise: the lowest version that describes the file. Readers refuse newer versions.

**Cuts** (`Sources/Timeline/Cuts.swift`, `TimeMap.swift`, `Sources/Render/Project.swift`). `Edits.cuts` holds user cuts in recording time. `Cuts` keeps sorted, disjoint ranges with kept spans of at least 200 ms. `TimeMap` is derived from them, and `project.json` stores them at version 2.

**App** (`Sources/Studio/StudioModel.swift`, `HomeView.swift`, `RecordingViews.swift`, `StudioScene.swift`, `StudioAppDelegate.swift`). `StudioModel.phase` is `home`, `recording(LiveRecording)`, `editing`, or `exporting`. On Record the app hides itself (`setAppHidden(true)`) so its window stays out of the capture, and a `MenuBarExtra` shows while recording. `recordingEnded` unhides and opens the take in the editor. `StudioServices` injects the recorder, area picker, and window list so `StudioModel` is testable without capture.

## Questions your design must answer

1. **Countdown and the origin.** Should capture start before the countdown, so the first frame is ready when it ends, or after it? Where does time zero land, and what happens to frames, audio, and events delivered before it? How does a cancelled countdown leave no directory?
2. **One camera, two users.** The bubble and the recorder both want the camera. Do they share one `AVCaptureSession`, and who owns it before, during, and after a take? What happens when the user changes camera on Home, unplugs it mid-take, or records without a camera but with the bubble on?
3. **Keeping our windows out of the video.** The bubble, the control bar, and the countdown are our windows. With display, area, and window targets, how is each excluded from the capture, and how is that tested?
4. **Pause in the recorder.** What each writer does on pause and on resume: the screen's once-a-second repeat, the system-audio silence fill, the microphone, the camera, the event log (no keystrokes logged while paused), cursor images. What the files look like across a pause, and that `recover(at:)` still finalises a take killed while paused.
5. **Pause in the format and the editor.** The manifest shape for pauses and its version. How pauses reach `Edits` as cuts the user cannot restore: a separate list, a flag on `Cut`, or derived at `Project.open` and merged with user cuts. What happens when a user cut overlaps a pause, and to a pause shorter than the cuts' 200 ms minimum kept span.
6. **Restart and the state machine.** The `StudioModel` phases and `SessionPhase` transitions for countdown, recording, paused, restarting, and stopping, so that no button can act in the wrong phase. A model, not booleans.
7. **Hotkeys.** Which API (for example Carbon `RegisterEventHotKey`, which needs no permission), the default shortcuts, and what each does in each phase.

## Constraints

- The single clock stays: microseconds from the origin, one origin per take.
- Crash safety stays: a take killed at any point, including while paused or counting down, is either absent or recoverable.
- The recorder never writes `project.json`.
- macOS 15, Swift 6.2, strict concurrency. `swift test` passes today (402 tests).
- Comments only for a non-obvious why, never banner comments.

## Deliverable

A candidate design package under `docs/design/recording-ux/candidate/` in your own worktree: `rationale.md` per the architect rationale template, and `sketch/` with Swift type and signature sketches (`fatalError("not implemented")` bodies). Spikes go under `docs/design/recording-ux/candidate/spike/` if your design depends on an AVFoundation or ScreenCaptureKit behaviour you have not seen measured. Examples are whether `SCContentFilter` excludes a borderless panel of our own app from a display capture, or whether one `AVCaptureSession` can feed a preview layer and a recording output at once. Do not launch the Studio app.
