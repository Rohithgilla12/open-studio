# Candidate design (fable): the recording experience

Brief: `docs/design/brief-recording-ux.md`. Sketch: `sketch/` (Swift, bodies `fatalError("not implemented")`). Spikes: `spike/`, results under "Spike results" with each claim labelled measured or inferred.

## Problem

Add a countdown, a camera bubble, pause-as-cut, restart, a floating control bar, and global hotkeys to a recorder whose shape is already fixed in four ways. One clock: every file is in microseconds from one origin per take, and the camera and audio writers already drop everything before that origin. Crash safety by format: fragmented movies, an append-only event log, a manifest that is the commit point, and an idempotent `recover(at:)`. One owner of every writer: the `CaptureSink` actor on the ScreenCaptureKit queue. Cuts already remove time everywhere through one derived `TimeMap`, with a 200 ms minimum kept span and user cuts stored in `project.json`, which the recorder never writes. The design has to add six features without a second clock, a second writer owner, a second place that stores a removed range, or a state that a boolean could get wrong.

## Usage (caller's view)

Studio, from Record to the editor. Every button and hotkey sends one `TakeInput`; the reducer decides what it means now.

```swift
model.cameraFeed = try await CameraFeed.open(preferences.camera)       // on Home: the bubble appears, the light goes on
model.send(.record)                                                    // countdown starts, capture warms underneath
//   3 … 2 … 1 …   Esc, the bar's Stop, or ⌃⌥⌘R sends .cancel: nothing was written
//   0             begin(): time zero is this instant
model.send(.togglePause)                                               // ⌃⌥⌘P, or the bar; the clock stands still
model.send(.restart)                                                   // take to the Trash, countdown again, same settings
model.send(.stop)                                                      // ⌃⌥⌘R, the bar, or the menu bar extra; opens the editor
```

Recording, from osrec or Studio's services:

```swift
let feed = try await CameraFeed.open(.systemDefault)
let prepared = try await PreparedRecording.prepare(configuration, camera: feed)   // warm, nothing on disk
let session = try await prepared.begin()                                           // directory, lock, writers, origin = now
for await update in session.updates {
    if case .clock(let clock) = update { bar.elapsed = clock.elapsed() }           // excludes pauses
}
await session.pause(); await session.resume()
let finished = await session.stop()          // or await session.discard() -> Termination.discarded(trashedTo:)
```

Timeline and the editor read one more fact and change no signature:

```swift
source.pauses                       // [TimeRange], from the manifest
project.timeline.map                // derived from edits.cuts.merging(pauses: source.pauses)
editor.pauses                       // the strip draws them hatched differently; not selectable
```

`osrec record --countdown 3 --camera default` prints the digits then the directory. `osrec inspect --timeline` lists pauses beside cuts.

## Shape

The design in one sentence: the take becomes two types (prepared, then recording), a pause is a host-time range in one ledger that every writer consults, that range is a manifest fact which Timeline folds into the existing cuts, and the app drives it all through one pure reducer whose table is the answer to "which button works when".

### 1. Countdown and the origin (brief question 1)

```
Record pressed ──▶ PreparedRecording.prepare()         SCStream up, tap up, camera attached, first frame seen
     digits 3 2 1 run over the warm-up (230 ms to a frame, a few hundred ms for a camera, from earlier designs)
countdown ends ──▶ prepared.begin()                     origin = HostTime.now()
                     directory, lock, writers.startSession(at: origin)
                     append lastWarmFrame re-stamped at origin      ◀── media time 0 always has a picture
                     recording.json (status: recording)
```

- **Capture starts before the countdown and writes nothing until it ends.** `PreparedRecording` holds a warm stream and no directory (sketch `Recording/PreparedRecording.swift`). The countdown hides the warm-up, so time zero is the instant the digits reach zero, not a few hundred milliseconds later. A cancelled countdown calls `cancel()`; there is nothing to delete. A process killed during the countdown leaves nothing either, per make-operations-idempotent's "what if it crashes at every point".
- **Time zero is a chosen instant, and the last warm frame is re-stamped onto it.** ScreenCaptureKit delivers a frame only when the display changes, so waiting for "the first frame after the countdown" on a still screen would wait up to the 5 s timeout. The heartbeat already re-stamps the last frame when the screen is still; `arm` does it once at the origin. The manifest's clock origin string stays `first-screen-frame`, because the first frame in `screen.mov` is at 0.
- **Everything before the origin is dropped by rules that exist.** Audio and camera buffers before the session start, inputs whose `mediaTime(since:)` is nil. No new filtering code; the warm sink keeps only `lastFrame`.
- **`RecordingSession.start` is deleted and osrec migrates** to prepare then begin, per migrate-callers-then-delete-legacy-apis, so there is one way to start a take and track A2 uses it too.

### 2. One camera, two users (brief question 2)

`CameraFeed` (sketch `Recording/CameraFeed.swift`) is the one owner of an `AVCaptureSession` for the chosen device. It gives the bubble a preview layer and gives the recorder a video data output on the sink's queue, attached at `prepare` and detached at cancel, stop, or discard. Studio opens the feed when a camera is picked on Home and closes it on None or on entering the editor, so the bubble, the feed, and the camera light are one thing. The recorder never opens a camera itself; `CameraCapture` is deleted. Change on Home: the feed is replaced, the bubble swaps layers. Unplugged mid-take: today's `cameraLost` path ends `camera.mov`; the bubble labels itself. "Bubble on without a camera" is not a state (see Open questions).

### 3. Our windows out of the video (brief question 3)

Display and area targets exclude this process's `SCRunningApplication` (`excludingApplications: [self]`), which covers every window the process has and makes later, so the countdown, the bubble, and the bar need no registration with the filter (inferred from the API's documentation; `spike/exclusion.swift` measures it, see below). Window targets include only the target app, so ours are out by construction. The main window is ordered out, not hidden with `NSApp.hide`, because hiding the app hides the panels too; the exclusion, not the hiding, is what keeps the video clean. Testing: the filter is built from a pure `FilterPlan` value (display, excluded pids, included app or window) that a unit test checks per target kind; the spike is the one measurement of ScreenCaptureKit honouring it.

### 4. Pause in the recorder (brief question 4)

```
pause(at P)  ──▶ PauseLedger.pause(P); manifest.pauses += {start: P}      (open, written now)
   screen frames, audio, camera, inputs, cursor changes with stamp in [P, R):  dropped at one gate, ledger.contains(t)
   heartbeat each second:  screen repeats its last pre-pause frame;  audio writers fill one second of silence
resume(at R) ──▶ ledger.resume(R); manifest closes the pause; event log writes move(R, pointer) and cursor(R, image)
```

- **One gate for every source** (`PauseLedger`, sketch `Recording/CaptureSinkPause.swift`): the sink asks it before appending any buffer; the event log asks it for every drained input and cursor change. The gate is the stamp, not the drain time, so ordering races between the UI's instant and the queues cannot leak or lose an event. No keystroke from a pause reaches disk.
- **Nothing captured during the pause is written, and the heartbeat keeps the files in lockstep.** The screen repeats its pre-pause frame once a second as it already does on a still screen. The audio writers fill a second of silence per second, because `AVAssetWriter` cannot express a gap (measured in the system-audio design: audio after a gap plays early). Filling at the trickle rather than at resume avoids a burst of up to 1 800 appends on the capture queue at the moment the user wants frames again. This departs from the brief's literal "no frames, no audio": a repeated old frame and silence carry nothing from the pause.
- **Resume re-declares the pointer and the cursor**, because the user moved during the pause and the first kept frame after it would otherwise show the pointer in the wrong place.
- **A stop while paused ends the take at the pause's start.** The user paused to end the content, then decided to stop. Every writer's `endSession` is at P, the pause is omitted from the manifest, and the duration equals the clock they watched.
- **A take killed while paused recovers.** The open pause is in the manifest from the moment it began; `recover` closes it at the recovered duration (the heartbeat kept the screen file current to within a second) or drops it when its start is at or past the duration.

### 5. Pause in the format and the editor (brief question 5)

- **Manifest:** `"pauses": [{start, end}]` in recording microseconds, `end` absent only while recording, version 5 when present (sketch `RecordingFormat/Pauses.swift`). The version bump has the camera's two reasons: an older build would export the paused content, and an older recovery would drop the key for good.
- **Derived, not stored twice.** `SourceRecording.pauses` is a fact of the take. `Edits.cuts` stays the user's list in `project.json` at version 2. `Timeline` builds its map and retiming from `cuts.merging(pauses:)`, which folds each pause through the existing total edit `Cuts.cutting` (sketch `Timeline/Pauses.swift`). That one function already answers every edge the brief asks about: a user cut overlapping or within 200 ms of a pause merges with it, keeping the user's id so their selection survives; a pause within 200 ms of the start or end becomes a trim; a pause of any length is valid because the 200 ms rule is about kept spans; a pause covering the whole take would keep nothing, so it is skipped and the take shows everything. With no pauses the union is the input, so the pinned no-cuts hash holds.
- **The editor** draws pauses with their own hatch and caption, cannot select them (`Selection` gains no case), and keeps every cut interaction as it is. Restoring a user cut that overlapped a pause leaves the pause.

### 6. Restart and the state machine (brief question 6)

Two machines, both pure and already the pattern here. `SessionPhase` gains `paused` and `discarding` (sketch `Recording/SessionPhase.swift`); unlisted inputs are ignored, so pause, resume, stop, and discard are idempotent. `TakeFlow` (sketch `Studio/TakeFlow.swift`) is the app's: `preparing → counting → starting → live → stopping | discarding`, with `cancelling` from the first two. `TakeStage` replaces `LiveRecording.Stage` and its booleans, per model-the-domain. The bar's buttons are `TakeFlow.controls(for:)`, derived from the stage, so no button that the reducer would ignore is drawn, and a test presses every input in every stage and asserts exactly which pairs act. Restart is `discard` (writers cancelled, lock released, directory to the Trash via `FileManager.trashItem`) and then the same `prepare` and countdown with the same configuration; the countdown hides the second warm-up.

### 7. Hotkeys (brief question 7)

Carbon `RegisterEventHotKey` on the application target, registered once at launch (sketch `Studio/Panels.swift`). Defaults ⌃⌥⌘R (start/stop) and ⌃⌥⌘P (pause/resume), three modifiers so no app's own shortcut is shadowed. What each does per stage is one function, `TakeFlow.input(for:in:)`: start/stop is record on Home or in the editor, cancel during the countdown, stop while live; pause/resume toggles only while live. Registration needs no permission (measured). Studio's in-app ⌘⇧R stays.

### Interface depth

Public additions: `PreparedRecording` (prepare, begin, cancel), `pause`, `resume`, `discard`, `TakeClock`, `RecordingUpdate.clock`, `Termination.discarded`, `CameraFeed` (open, previewLayer, health, close), `SourceRecording.pauses`, `Editor.pauses`. Behind them: the warm-sink arming, the origin re-stamp, the pause gate and its heartbeat behaviour, the manifest version rule, recovery of open pauses, the cut union, the capture exclusion, and the camera session shared between a layer and an output. `Cuts.merging` and the reducer are the only new pure surfaces, both tested without capture.

## Synthesis decision

Left for the arena.

## Tradeoffs accepted

- We accept a second lifecycle type, `PreparedRecording`, in exchange for a countdown that ends exactly at time zero and a cancel that deletes nothing.
- We accept one re-stamped frame at the origin in exchange for never waiting on a still display at begin.
- We accept heartbeat frames and silence during a pause, written at one append per second per writer, in exchange for files that recover from a crash mid-pause and a resume with no burst. Nothing captured in the pause is on disk.
- We accept that a stop while paused ends the take at the pause, in exchange for the duration matching the clock the user watched.
- We accept a manifest version bump for paused takes in exchange for older builds never exporting paused content.
- We accept a restart that re-warms the stream (hidden under the countdown) in exchange for a sink that never re-arms, so its per-take state is one optional `Take`.
- We accept three-modifier chords nobody configures yet in exchange for no shadowed app shortcuts.
- We accept that the app activates for the countdown so Esc reaches the digit panel.

## Alternatives considered

- **Capture starts after the countdown.** Smallest change: today's `start` behind a 3 s delay. The take then begins a few hundred milliseconds after zero, more with a camera, and a still screen waits for a frame. Hides nothing more than the chosen shape and costs the user the moment they were counting to.
- **A sink that re-arms across takes**, so restart keeps the stream and writes the next take without a second warm-up. It saves about 300 ms the countdown already hides, at the cost of a sink whose lifecycle has a loop in it.
- **`AVAssetWriter` sessions per kept span** (`endSession` at pause, `startSession` at resume), which removes the pause from every movie at write time. It makes media time diverge from the event log's clock, puts the pause where the editor cannot show it, and changes what a crash mid-pause leaves. Rejected for breaking the one-clock rule.
- **Stop the input tap during a pause** instead of filtering by stamp. Structural, but re-creating a tap can fail (permission revoked), and the stamp filter is one pure rule for every source including the cursor watcher and the camera.
- **Pauses as a flag on `Cut` in `project.json`.** Stores a manifest fact in an edit file; a hand-edited project could restore a pause, and a regenerated project would lose them. Rejected for split ownership.
- **Pauses as a separate `Edits.pauses` list.** Same ownership problem plus a second list the strip and the map must read.
- **A second `AVCaptureSession` for the bubble.** Simpler ownership (each consumer owns its own), but two decodes of one device, two format choices that can disagree, and a bubble that may fail when the recorder opens the device. One session with two consumers is AVFoundation's model.
- **Excluding specific `SCWindow`s** instead of the application. Needs the panel windows to exist before the filter is built and a filter update when one is added; the application exclusion covers windows made later.
- **`NSEvent.addGlobalMonitorForEvents`** for hotkeys. Needs Input Monitoring, which the brief rules out, and cannot consume the key.

## Implementation reconciliation

Nothing yet.

## Spike results

Run on 2026-10-26, Apple Silicon, macOS 27.0.1, Xcode 27.1, from a shell whose responsible process is Rex Server, which holds neither Screen Recording nor Camera. Two spikes therefore preflight and exit without prompting; they are ready to run from a terminal that has the grants (`swiftc -O -swift-version 5 docs/design/recording-ux/candidate/spike/<name>.swift`).

- **Hotkeys (measured, `spike/hotkey.swift`).** `RegisterEventHotKey` returned noErr for both chords from an accessory process with Input Monitoring and Accessibility absent, and both stayed absent afterwards. The handler firing is not measured: it needs a real press, and the first attempt to post the chord through `CGEvent` put up the Accessibility prompt instead (measured: posting keyboard events is gated; a SecurityAgent dialog was frontmost before the register-only run and is a leftover of that attempt).
- **Clocks (measured, same spike).** `SuspendingClock.now` equals `CLOCK_UPTIME_RAW` to 0.1 µs in two runs (42267.816383916 s against 42267816384041 ns; 42372.885596999 s against 42372885597083 ns), and `ContinuousClock` is `CLOCK_MONOTONIC_RAW`. So `TakeClock` can carry `SuspendingClock.Instant` and convert from `HostTime` exactly.
- **Capture exclusion (inferred, `spike/exclusion.swift` not run here).** The design relies on `SCContentFilter(display:excludingApplications:exceptingWindows:)` excluding every window of the listed apps, present and future, as its documentation says. The spike shows a red floating non-activating panel for about three seconds and reports the red fraction under three filters, plus a panel created after the filter was built.
- **Camera sharing (inferred, `spike/camera-share.swift` not run here).** One session feeding a preview layer and a data output, and an output added through `beginConfiguration`/`commitConfiguration` while running, are the documented session model. The spike counts data-output frames across four phases, with a 320 x 240 preview window up for about four seconds.

## Open questions and risks

1. Should a person be able to see themselves in the bubble without recording the camera? The design ties the bubble to the chosen camera. A "preview only" option would be one more flag on the feed, not a new type.
2. Is a stop while paused really "end at the pause"? The alternative keeps the trailing pause as a tail trim the user can see on the strip. The chosen rule matches the clock they watched; the alternative keeps more information.
3. Do heartbeat frames during a long pause matter for file size? One P-frame of a still picture per second at 4K is small, but a 30 minute pause is 1 800 of them. Not measured.
4. Should the hotkeys be configurable in this unit, or is a single "open-studio chord" enough until someone asks?
5. The capture exclusion and the shared camera session are inferred until the two spikes run from a granted terminal. If the exclusion by application does not cover a late window, the fallback is excluding `SCWindow`s and rebuilding the filter when a panel appears, which `SCStream.updateContentFilter` supports.

## Next implementation step

`PauseLedger`, `Cuts.merging(pauses:)`, and `TakeFlow.next` with their specs, all pure, so `swift test` proves the gate, the union, and the button table before any capture code moves.
