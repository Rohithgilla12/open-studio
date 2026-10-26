# Recording experience: countdown, camera bubble, pause as cut, restart, control bar, hot keys

Accepted design for track A1. The brief is `docs/design/brief-recording-ux.md`. `sketch/` and `spike/` are this candidate's. `rejected/` holds the other candidate, and `spike-fable/` its spikes. The grafts under Synthesis decision change Q2, Q3, Q4, and Q5. Where the Synthesis decision and the body or sketch disagree, the Synthesis decision wins.

## Problem

A take today has one shape: `RecordingSession.start` waits for the first complete screen frame, makes it time zero, writes until `stop`, and finalizes. The app hides itself so its window stays out of the video. Track A1 adds six things around that take, and they do not fit the shape as separate features.

- The countdown puts time before the take. Capture has to be warm when it ends, yet a cancelled countdown must leave no directory.
- A pause puts time inside the take that the clock counts but nothing records. Every writer has its own idea of a gap. `AVAssetWriter` packs audio back to back, the screen repeats a frame every second, and the event log writes whatever the tap saw.
- Restart ends one take and starts another without the person reaching for the settings again.
- The bubble, the control bar, and the countdown are our own windows on screen during capture. Hiding the app no longer keeps them out.
- The bubble and the recorder both want the camera, and the device's format is global to it.
- Hot keys arrive while another app is frontmost, in every phase.

Constraints carried in from earlier units. One clock: microseconds from one origin per take (`accepted/rationale.md`). Crash safety from the directory format: fragmented movies, an append-only event log, and `recover(at:)`. The recorder never writes `project.json`. Cuts are stored in recording time, with kept spans of at least 200 ms, and `TimeMap` is derived from them (`cuts/rationale.md`). The camera has its own `AVCaptureSession` and is moved onto the host clock (`camera/rationale.md`).

One correction to the brief. It says the microphone runs through `AVCaptureSession`. It does not. `CaptureSink.startCapture` sets `captureMicrophone` on the `SCStream` (read in `CaptureSink.swift`, lines 72 to 75, and `accepted/rationale.md` "Microphone on the same SCStream"). Only the camera uses `AVCaptureSession`. The design follows the code.

## Usage (caller's view)

The Studio starts every take through one call, whatever surface asked.

```swift
// StudioModel.record(), reached from the Record button, File > New Recording, the start hot key,
// and later the A2 target picker.
var configuration = baseConfiguration
configuration.countdown = preferences.countdown            // 3 s by default
let session = try await RecordingSession.start(configuration)
// Returns with capture warm and the countdown running. Nothing is on disk yet.
for await update in session.updates {
    switch update {
    case .state(let state):    live.state = .live(state)   // countingDown, recording, paused, stopping
    case .warning(let w):      live.warnings.append(w)
    case .discarded:           break                       // a restarted take, now in the Trash
    case .progress:            break
    case .ended(let outcome):  await recordingEnded(outcome)
    }
}
```

Buttons and hot keys go through one table and carry the time of the press.

```swift
// The pause hot key, from GlobalHotkeys, with GetEventTime converted to SuspendingClock.
await model.perform(.pauseOrResume, at: pressedAt)
// inside: switch command.action(in: state) { case .pause: await session.pause(at: pressedAt) ... }
```

The control bar shows elapsed time from the clock the session published, not from progress updates, so it keeps counting while the screen is still.

```swift
TimelineView(.periodic(from: .now, by: 0.25)) { _ in
    if case .live(.recording(let take)) = live.state {
        Text(Elapsed.text(take.clock.recorded(at: .now)))
    }
}
```

`osrec` keeps today's behaviour with no change but the outcome type, because `countdown` defaults to zero.

```swift
let session = try await RecordingSession.start(configuration)       // rolls on the first frame
switch await session.stop() {
case .recorded(let finished): print(finished.directory.path)
case .nothingRecorded(let why): print("nothing recorded: \(why)")
}
```

The editor gets pauses from the recording and never stores them.

```swift
let extent = project.source.extent                // duration + normalized pauses, from recording.json
let (cuts, id) = project.edits.cuts.cutting(range, within: extent)!
let timeline = Timeline(source: project.source, zooms: zooms, cuts: cuts)
// timeline.map skips user cuts and pauses alike
```

## Shape

### The idea in four steps

Step 1. Today. Capture starts, the first frame is time zero, and every buffer after it is written.

```
start ──▶ stream ──▶ first frame = origin ──▶ write everything ──▶ stop ──▶ finalize
```

Step 2. Warm capture before the take. The stream and the camera run, the writers are configured in memory, and nothing is on disk. The take rolls at a time fixed in advance, the end of the countdown. The newest held frame is restamped to that time, so `screen.mov` has a picture at zero even when the screen is still.

```
start ──▶ stream ──▶ first frame (held) ─┐
                                         │  countdown: buffers dropped, writers configured, no directory
                         notBefore ──────┴──▶ roll: mkdir, start writers, held frame @ origin
                                              ──▶ write ──▶ stop
```

Step 3. One clock decides what is written. `HostClock` holds the origin and the pauses. A buffer is written when the clock admits its timestamp. Before the origin and inside a pause are the same case to every writer: time the clock does not admit.

```
host time ──────────────────────────────────────────────────────────────────────▶
           countdown        │ take ............. pause ........ take ......│ stop
admits:    no               │ yes                no             yes        │
screen:    hold newest      │ write              hold newest    restamp held @ resume, write
audio:     drop             │ write              drop; silence  write
                                                 written by the beat
events:    drop             │ write              drop           .state @ resume, write
manifest:  (none)           │ written at roll    pause opened   pause closed
```

Step 4. Restart loops back to step 2 inside the same session. The rig (stream, tap, camera lease) keeps running. Only the take is replaced.

```
              ┌──────────────── restart: finish + trash old take, arm new writers ─────────────┐
              ▼                                                                                │
start ─▶ countingDown ─rolled─▶ recording ⇄ paused ──────────────────────────────────────────┘
              │                     │           │
              └─stop: cancel        └──stop─────┴──▶ stopping ─▶ finished(outcome)
```

### Data structures

- **`HostClock`** (internal, Recording). `origin`, closed pauses, and at most one open pause, in host time. Made only by the `.rolled` input and changed only by `pausing(at:)`, `resuming(at:)`, and `closing(at:)`, so a pause cannot be open twice or close before it opened. `admits(_:)` is the one predicate every writer uses. The session's state machine is its only writer. The sink and the event log receive each new value through the `applyClock` effect and never change it, so they hold snapshots, not a second owner. Its public projection, `TakeClock`, carries offsets from a `SuspendingClock.Instant` origin so callers derive elapsed time themselves.
- **`SessionPhase`** (internal). `countingDown(notBefore:)`, `recording(HostClock)`, `paused(HostClock)`, `stopping(StopReason)`, `finished(RecordingOutcome)`. A pure `next(phase, input)` returns the new phase and effects, as today. A command that does not fit the phase is a no-op transition. Per model-the-domain, the phase carries the clock, so "paused with no clock" cannot exist.
- **`CaptureSink.Stage`**. `armed(TakeWriters, notBefore:)`, `writing(TakeWriters, HostClock)`, `idle`. It replaces today's `origin`, `stopping`, and optional writers, so writing before the origin or after finishing has no representation.
- **`TakeWriters`**. One take's movies, configured together off the sink's queue, started together at the origin.
- **`CameraLease`** (public). A claim on a shared camera feed. The registry keeps one `AVCaptureSession` per device and runs it while any lease is alive.
- **`CaptureFilterPlan`**. A pure decision per target: `displayExcludingOwnApp`, `application(pid)`, or `window(id)`.
- **`WirePause`** in the manifest, format version 5. **`TakeExtent`** and **`Removals`** in Timeline.
- **`RecordingCommand.action(in:)`**. A table from (command, state) to action, read by buttons and hot keys alike.

### Q1. Countdown and the origin

Capture starts before the countdown. `start` returns once the stream has delivered its first complete frame, so the countdown starts only when the take could roll, and a failure (permissions, a missing window, no frames) shows before any number appears. The writers are configured during the countdown in memory. Configuring is the slow part: 120 to 165 ms for four writers cold, 27 to 40 ms warm (measured, spike/writer-startup). Creating the directory and starting all four takes 10 to 17 ms cold and about 2 ms warm (measured). So the roll costs a few milliseconds on the sink's queue, not a frame-dropping stall.

Time zero is `max(notBefore, first admitted frame)`. With a countdown, frames are already flowing, so the origin is the countdown's end exactly, and the newest held frame is restamped to it. Without one (`countdown: .zero`, osrec), `notBefore` is the moment `start` was called, the first frame arrives after it, and the origin is that frame's PTS, which is today's rule. The roll fires from a timer on the sink's queue at `notBefore` and also from `receiveScreen` if a later frame arrives first. `rollIfDue` is idempotent, so whichever runs second does nothing (per make-operations-idempotent).

Before the origin, nothing is written. Screen frames replace the one held frame. Audio and camera buffers are dropped. Events stay in the tap's buffer and are dropped by the existing `mediaTime(since:)` check when the take's event log first drains.

A cancelled countdown leaves no directory because none exists until the roll. An `AVAssetWriter` that was configured but never started creates no file and no parent directory (measured: the spike asserts the directory is absent after configuring four writers). A crash during the countdown therefore leaves nothing. Between `mkdir` and the first manifest there is a window of a few milliseconds in which a crash leaves a directory with no manifest, which recovery already reports as `nothingRecorded`. Today that window lasts until the first frame, up to the 5 s start timeout (inferred from `RecordingSession.start`).

### Q2. One camera, two users

They share one `AVCaptureSession`, owned by neither. `CameraFeeds`, a main-actor registry, keeps one feed per device: one input, one `AVCaptureVideoDataOutput`, and the format and frame duration chosen once by `CameraFormat.plan`. A `CameraLease` keeps the feed running. The bubble holds a lease while it is visible. The session holds one from `start` to the end. Preview layers attach to the feed's session. The recorder attaches as the data output's single consumer, delivered on the sink's queue as today. Because only the feed sets `activeFormat`, the bubble shows exactly the picture the recorder writes, and two sessions never fight over a device-global setting (per separate-before-serializing-shared-state: one writer of the device configuration, two readers).

| When | Who holds a lease | Camera |
|------|-------------------|--------|
| Home, camera chosen, bubble shown | bubble | on |
| Home, camera chosen, bubble hidden | nobody | off |
| Countdown, recording, paused | session, and bubble if shown | on |
| Restart | both, unchanged | stays on, no relight |
| Editing, exporting | nobody | off |

Changing the camera on Home releases the old lease and acquires a new one. The picker is a Home control, so the camera cannot change mid-take. Unplugging mid-take sends `.lost` to every lease. The recorder ends the camera track with today's `cameraLost` warning and the screen continues. The bubble shows a "camera disconnected" face. Recording without a camera but with the bubble on cannot be represented: the bubble is a preview of the camera track, so `camera: .none` means no bubble. The bubble can be hidden while the camera records.

Whether one session drives a preview layer and a data output at once without changing the data output's frame rate is not measured. spike/camera-preview tests it, and it exited without measuring because Camera is not authorized for the shell that ran it.

### Q3. Keeping our windows out of the video

By the capture filter, not by hiding the app. For display and area targets, the filter becomes `SCContentFilter(display:excludingApplications: [own], exceptingWindows: [])`, where `own` is this process's `SCRunningApplication` from the same shareable content the target came from. Excluding the application, rather than a list of windows, is meant to cover panels opened after the stream started (the bubble shown mid-take, the countdown on a restart) and the menu bar extra (inferred from the API's contract, not measured). For window targets the filter already includes only the target app, so our panels are never in it. Hiding the main window on Record stays, for the person's sake. The panels set `canHide = false` so they survive it. The countdown's exclusion matters only for the held frame restamped at the origin, since nothing else before the origin is written.

`sharingType = .none` is not relied on. The Studio shows the control bar, in its "Starting" state, before it calls `start`, so the app is listed in the shareable content. `osrec` has no windows and nothing to exclude.

Testing has two layers. A unit test pins `CaptureFilterPlan.plan(for:)` for every target kind. spike/capture-exclusion is the integration check: it starts a control stream that excludes nothing and two that exclude this app, one built before the app has a window and one after. Then it shows a magenta panel and a `sharingType = .none` cyan panel for about a second and counts their pixels in each stream's latest frame. The control must show the magenta panel, or the check cannot detect a leak. It exited without measuring because Screen Recording is not granted to the shell that ran it. Run it with `swiftc -O docs/design/recording-ux/candidate/spike/capture-exclusion/main.swift -o /tmp/ce && /tmp/ce` from a terminal that has Screen Recording.

### Q4. Pause in the recorder

| Source | On pause | While paused | On resume | Files across a pause |
|--------|----------|--------------|-----------|----------------------|
| Screen | Gate closes at the press time | New frames replace the held frame and are never written. The beat repeats `lastFrame`, a frame from before the pause | Held frame restamped to the resume time, then frames as usual | One movie, held picture through the pause |
| Microphone, system audio | Buffers at or after the press are dropped | The beat writes silence through `now - 500 ms` | The next buffer's continuity fill covers the last second or two | One movie, digital silence through the pause |
| Camera | Buffers dropped | Nothing | Buffers appended as they arrive | One movie, a gap the player holds across |
| Event log | Events at or after the press are dropped at drain | Same | One `.state` event at the resume time (position, held buttons, cursor image) | Events skip the pause |
| Cursor images | Changes dropped | Same | Current image declared in the `.state` event | |
| Manifest | Pause written with no end | | End written | `pauses` |

Two choices in this table rest on measurements.

- **Silence is written during the pause, not at resume.** An AAC input in real-time mode took 12 one-second silence buffers back to back and then refused. A 60 s, 600 s, and 1800 s gap filled at once each produced a 14.005 s file where 62, 602, and 1802 s were expected (measured, spike/audio-gap-fill, three gap lengths, consistent). `AudioTrackWriter.fill` returns early on a refusal, so a pause filled at resume would drop all but 12 s and the audio after it would play early. The beat writes about one second per second instead. Each beat is one chunk, and the resume has at most about two seconds left to fill.
- **The held frame, not the pre-pause frame, appears at resume.** ScreenCaptureKit delivers a frame only when the display changes (`CaptureSink.startHeartbeat`'s comment, from the accepted design). If the person rearranged windows during the pause and the screen is still when they resume, no new frame comes. Restamping the held frame shows the screen as it is. The same restamp gives the roll its frame at zero, so roll and resume share one code path.

"Nothing is written while paused" holds for content. No frame captured during the pause, no microphone or system sample, no event, and no cursor change reaches a file. What is written is the screen's last pre-pause frame repeated once a second and digital silence. Both are needed for crash safety, and the editor removes the range. The gate closes at the time of the press (`GetEventTime` for a hot key, the event timestamp for a click), so the press itself is inside the removed range. Buffers the sink appended between the press and the moment the gate closed, a few milliseconds of content, land inside the cut and are never shown (inferred).

`recover(at:)` still finalizes a take killed while paused. The screen movie keeps a sample in every one-second fragment through the pause because of the beat, so the probed duration reaches the moment of death, not the pause's start (inferred from the fragmented-movie experiment in `Experiments/README.md`). Audio movies also keep fragments through the pause because the beat writes silence. The camera movie ends at the pause's start, which the format already allows for a lost camera. Recovery then closes the open pause at the probed duration and clamps any pause end past it. The take opens with its paused tail removed.

### Q5. Pause in the format and the editor

The manifest gains `pauses: [{start, end?}]` in media microseconds, written at each pause and resume through the existing atomic replace. A take with any pause is format version 5. A take without one keeps the version it has today, per the "lowest version that describes the file" rule. An older reader refuses version 5. Otherwise it would play the paused ranges, a frozen frame and silence where the person asked for nothing. An open pause is legal only while `status` is `recording`. The reader rejects a finalized manifest with one.

Pauses reach the editor derived, not stored. They are rejected as a separate list in `Edits` and as a flag on `Cut`. Either one would store in `project.json` a fact `recording.json` already owns (split ownership), and a flag would make `Cuts.cutting`'s merge decide whether a merged range is restorable. Instead:

1. `SourceRecording.load` validates the pauses at the boundary and normalizes them into `TakeExtent { duration, pauses }`. Two pauses less than 200 ms apart merge. A sliver before the first or after the last is absorbed, unless that would leave nothing kept.
2. Every `Cuts` operation takes `within extent: TakeExtent` where it took `within duration:`. Pauses act as immovable neighbours in the clamps, so the existing rules hold across cuts and pauses together in the one place that derives "kept". These rules are kept spans of at least 200 ms and at least one kept span.
3. `Cuts.removals(within:)` merges user cuts and pauses into `Removals`. `TimeMap` and `Retiming` read `Removals`, so a zoom change inside a pause collapses onto the join exactly as one inside a cut does.
4. The strip draws `extent.pauses` hatched, with no handles and no Restore item. Nothing can restore a pause because no edit holds one.

A user cut that overlaps a pause is stored as the person made it and merged only in `Removals`. Restoring it leaves the pause removed. A pause shorter than 200 ms is kept as a removal. The minimum is on what is kept, not on what is removed. `project.json` stays at version 2.

### Q6. Restart and the state machine

The session's phases are the recorder's model. The app's `LiveRecording.state` is `.starting` until the session exists, then the last `LiveState` the session sent. It is a projection, not a second machine.

```
recorder (SessionPhase)                 app (LiveRecording.state)     control bar shows
                                        starting                      "Starting", Stop
countingDown(notBefore) ──rolled──▶     countingDown(until)           "3", Stop
recording(clock)       ◀─resume─        recording(take)               time, Pause, Restart, Stop
   │ pause ─▶ paused(clock)             paused(take)                  time (frozen), Resume, Restart, Stop
   │ restart ─▶ countingDown            countingDown(until)           "3", Stop
   └ stop / limit / failure ─▶ stopping stopping                      "Saving"
stopping ──finalized──▶ finished        (phase leaves .recording)
```

Restart is a transition of the same session, not a new session. `recording` or `paused` plus `restartRequested(at:)` goes to `countingDown(notBefore: now + countdown)` with two effects. `discardTake(at:)` finishes the old take's writers and event log at the press time, finalizes its manifest, releases its lock, and moves the directory to the Trash with `FileManager.trashItem`, never `removeItem`. It runs in the background while the next countdown counts. `armNextTake` configures fresh writers. The stream, the tap, and the camera lease keep running, so the countdown starts at once and the camera light does not blink. If the volume has no Trash, the old take stays in the library as an ordinary finalized take, with a warning. The recorder never deletes a take. `MovieWriter.cancel`, which removes its file, stays reserved for a track that never received a sample.

`RecordingCommand.action(in:)` is the one table buttons and hot keys read (StudioRecording.swift). The control bar shows a button only when its command maps to an action. The session ignores any command that does not fit its phase, so a button rendered one frame stale costs a no-op, never a wrong action.

### Q7. Hot keys

Carbon `RegisterEventHotKey`. It needs no permission: registration returned `noErr` in a process with no Accessibility, Input Monitoring, or Post Event access (measured, spike/hotkey). The key press is consumed and does not reach the frontmost app. `NSEvent.addGlobalMonitorForEvents` and a listen-only `CGEventTap` cannot consume the press. An active tap needs Accessibility, a new prompt.

Defaults are Control-Option-Command R for start or stop, and Control-Option-Command P for pause or resume. While a countdown runs, Esc is registered too, and it is unregistered when the countdown ends. Esc is the only global combo taken for a few seconds only. Three modifiers, because a registered combo is taken from every app, and two-modifier letters collide with app menus. Shift-Command-R is Safari's Reader, for example.

| State | Start/stop | Pause/resume | Esc |
|-------|-----------|--------------|-----|
| Home, editing (ready) | record() | nothing | not registered |
| Starting, countdown | cancel | nothing | cancel |
| Recording | stop | pause | not registered |
| Paused | stop | resume | not registered |
| Stopping, exporting, not ready | nothing | nothing | not registered |

`GetEventTime` reads the same clock as `ProcessInfo.systemUptime`, `CLOCK_UPTIME_RAW`, and `SuspendingClock`, equal to the microsecond. `ContinuousClock` differs by the time asleep (measured, spike/hotkey). So the public API takes `SuspendingClock.Instant`, a standard type, and the session converts it to `HostTime` exactly. A second registration of the same combo in-process returns `eventHotKeyExistsErr`, -9878 (measured). A clash with the system or another app is not reported. Registering Shift-Command-3, the system screenshot shortcut, returned `noErr` (measured). Whether a registered hot key actually fires was not measured, because posting a synthetic key press needs Post Event access the shell did not have.

### Interface depth

`RecordingSession`'s public surface grows from `start`, `stop`, `updates`, and `recover` by three methods: `pause`, `resume`, and `restart`. Behind it sit the warm-capture countdown, the restamped origin and resume frames, writer configuration off the hot path, the per-source gate, beat-driven silence, event filtering and the resume state event, the manifest's pause ledger, the background discard to the Trash, and the camera lease. A caller never sequences two calls to get one behaviour. Restart is one call, not stop plus start plus a countdown. Cancel is `stop` during the countdown, not a separate method. `CameraLease` is acquire, make a surface, events, and release, and hides the registry and the device configuration. On the Timeline side, the only signature change is `within: TakeExtent`. `Removals` is read by `TimeMap` and `Retiming` only.

What stays exposed on purpose is `TakeClock`. The UI needs elapsed time on its own schedule, and deriving it from published facts beats a stream of ticks that stops when the screen does.

## Measured

Apple M2 Max, macOS 27.0.1, run from Rex on 2026-10-26, load average 5 to 7.

| Spike | Result |
|-------|--------|
| audio-gap-fill | AAC, 48 kHz stereo, real-time input. One second of tone, then an N-second gap filled with one-second silence buffers back to back. N = 5: all 5 taken, 7.005 s file. N = 60, 600, 1800: 12 taken, then `isReadyForMoreMediaData` false, ready again 4 ms later. File 14.005 s each time, where 62, 602, and 1802 s were expected. |
| writer-startup | Four writers (3456 x 2234 HEVC screen, 1080p HEVC camera, mono and stereo AAC), 10 runs, 3 repeats. Configure (init, `canApply`, add input): first run 122 to 164 ms, median 27 to 40 ms. `mkdir` + `startWriting` + `startSession`: first 10 to 17 ms, median 1.9 to 2.3 ms. Configuring created no directory. |
| hotkey | `RegisterEventHotKey` with no permissions: `noErr` for Control-Option-Command R and P, Esc, and Shift-Command-3. Second registration of R: -9878. `GetEventTime` 42340.498194, `systemUptime` 42340.498196, `CLOCK_UPTIME_RAW` 42340.498196, `SuspendingClock` 42340.498229. `CLOCK_MONOTONIC_RAW` and `ContinuousClock` 261018.80. Firing not measured. |
| capture-exclusion | Not measured. Exited 2: Screen Recording not granted to the shell. |
| camera-preview | Not measured. Exited 2: Camera not authorized for the shell. |

The gap-fill number is a queue limit, not a throughput. All 12 appends took about 1 ms together, and the input became ready again in 4 ms, so a resume could loop with waits. That loop would block the sink's queue, which also carries screen frames. Writing silence as the pause runs needs no loop.

## Synthesis decision

Two runners designed against the brief in separate worktrees, Opus (this package) and Fable (`rejected/fable-rationale.md`). There were two runners, not three, to save usage. A Sonnet cross-judge scored both blind against a six-criterion rubric. It recommended this candidate as the base, and so did the lead's own reading.

**Where they agreed, and so the agreement was not reopened.**
- Capture warms up during the countdown, and time zero is set at its end.
- The newest held frame is restamped onto zero, so `screen.mov` has a picture there even on a still screen.
- No directory exists until the take rolls, so a cancelled countdown leaves nothing on disk.
- One `AVCaptureSession` feeds both the bubble and the recorder.
- The capture filter excludes our own application.
- One pause gate, keyed on each buffer's timestamp, covers every source and the event log.
- During a pause, the heartbeat keeps writing a held frame and silence, about one second per second.
- At resume, a state event re-declares the pointer and the cursor.
- Pauses are stored in the manifest at format version 5, and recovery closes an open pause.
- Hot keys use Carbon `RegisterEventHotKey`, with ⌃⌥⌘R for start or stop and ⌃⌥⌘P for pause or resume.

**Why this base.**
- **Restart.** Restart happens inside the session and finalises the old take before trashing it, so the Trash holds a real, recoverable take. Fable's discard cancels the writers, and `MovieWriter.cancel` removes the movie files (verified in `MovieWriter.swift`), which would leave a hollow directory in the Trash.
- **Silence fill.** Only this candidate measured that a bulk fill is refused after about 12 one-second buffers.
- **Resume frame.** At resume this candidate restamps the held frame, so the current screen shows. Fable re-appends the pre-pause frame instead.
- **Focus.** A global Esc during the countdown means the countdown never steals focus from the app being recorded.

**Grafted.**
1. **Pauses reach Timeline through `Cuts.merging(pauses:)`, not `TakeExtent`** (from Fable). `Timeline.init` derives its map and retiming from `cuts.merging(pauses: source.pauses)`. That function folds each pause through the existing total edit `Cuts.cutting`. As a result:
   - no `Cuts` signature changes;
   - a user cut that overlaps a pause, or lies within 200 ms of one, merges with it in the derived removals only;
   - the stored user cuts are unchanged, so restoring a user cut leaves the pause removed;
   - a pause of any length is valid;
   - a pause that would leave nothing kept is skipped;
   - with no pauses the result is the input, so the pinned no-cuts hash holds.

   `Removals` and `TakeExtent` are dropped. The strip draws `source.pauses` with their own hatch, and they cannot be selected.
2. **The camera is one plain `CameraFeed` that Studio owns and passes explicitly to the session** (from Fable). The per-device lease registry is dropped. This candidate's on/off rule stays: the camera runs while the bubble is shown, or while a take with a camera is live. Hiding the bubble on Home turns the camera off.
3. **The main window is ordered out on Record instead of `NSApp.hide`** (from Fable). Every panel (bubble, control bar, countdown) sets `hidesOnDeactivate = false` and `canHide = false`. The countdown does not activate the app. Esc during the countdown is the global hot key from Q7, and the app calls `NSApp.deactivate()` after showing the panels, so the recorded app keeps focus.
4. **A stop while paused ends the take at the pause's start** (from Fable). The duration then matches the clock the user watched, and no trailing pause is written.
5. **An exhaustive command table test** (from Fable). A test sends every `RecordingCommand` in every session state and asserts exactly which pairs act.

**Risks kept open and handled by construction.**
- **Exclusion.** Neither spike could measure whether `excludingApplications` covers a panel opened after the stream starts, or whether the app is listed before it has a window. This Rex shell holds neither Screen Recording nor Camera permission. The implementation must not depend on either answer. The control bar is shown before `start`. Whenever a panel opens mid-capture, the sink rebuilds the filter with `SCStream.updateContentFilter` and the current shareable content, which costs one call.
- **Clicks on our panels.** Clicks on our own panels must not become auto-zoom targets. The event log drops clicks whose target pid is ours, and falls back to the panels' frames when the tap gives no pid.
- **Back-to-back restarts.** A second restart waits for the first take's finalisation.

**Found outside this unit.** The system-audio writer's existing gap fill has the same limit of about 12 s. A delivery gap longer than that makes everything after it play early. It is filed as its own issue, and the heartbeat-driven silence here is the same fix.

**Corrected.** The brief said the microphone runs through `AVCaptureSession`. It runs on the `SCStream` (`CaptureSink.swift`), and this design follows the code.

## Tradeoffs accepted

- We accept a held screen frame repeated once a second and digital silence in the files during a pause, in exchange for one movie per source with no seams and a take that recovers to the moment of death when killed while paused.
- We accept the camera and microphone staying live during a pause, with their indicators on, in exchange for an instant resume with no ScreenCaptureKit or `AVCaptureSession` restart. Nothing they deliver is written.
- We accept that a few milliseconds of content between the press and the gate closing are written, in exchange for gating by timestamp. The cut covers them.
- We accept a restarted take being finalized before it goes to the Trash, finishing in the background while the next countdown runs. That costs some disk churn, and in exchange the trashed take is a valid recording the person can drag back.
- We accept that pauses count toward `maxDuration`, because the single clock keeps running. A limit on recorded time would need a second clock.
- We accept `Cuts` operations taking a `TakeExtent` instead of a duration, a mechanical change at about six editor call sites and the tests, in exchange for the cuts' invariants holding across pauses in the one place that derives "kept".
- We accept that the editor cannot restore a pause, by construction. Recording it again is the only undo.
- We accept that hot key clashes with other apps are invisible, because Carbon reports only in-process clashes.

## Alternatives considered

- **The app owns the countdown and calls today's `start` at "go".** It hides nothing new in the recorder, but the take starts late. The first ScreenCaptureKit buffer arrived 229 ms after its PTS in the step-0 experiment, and configuring writers takes 120 to 165 ms cold (measured). The person starts talking at "go" and the first few hundred milliseconds are lost (inferred sum). It also leaves restart to the app as stop, start, and a second countdown, with the camera relit.
- **Two public types, `ArmedCapture.arm()` then `armed.roll() -> RecordingSession`.** The countdown stays in the app with no lost time. It is shallower. Callers coordinate two objects and a hand-off, restart becomes "finish, get an armed capture back, roll again", and `osrec` has to learn arming. One session with a `countdown` parameter hides all of it.
- **Pause by stopping the stream or the writers, a file segment per stretch.** Nothing at all is written while paused, but it breaks one movie per source and the single origin, and every reader would learn segments. A fresh stream's first buffer arrived 229 ms after its PTS in the step-0 experiment (measured there), and a resume would show that wait.
- **Fill a pause's silence at resume.** Simplest, and it is what `AudioContinuity` already does for gaps. Measured to lose all but 12 s of any longer pause.
- **The bubble on its own `AVCaptureSession`.** Simple ownership. But `activeFormat` and the frame duration belong to the device, so the bubble's session and the recorder's would reconfigure each other. The camera also relights when a take starts.
- **The bubble drawn from the recorder's data output** (`AVSampleBufferDisplayLayer`). One output, but the bubble could exist only while the recorder runs, so no preview on Home.
- **Pauses as cuts with a flag, or a pause list in `Edits`.** Both store in `project.json` a fact `recording.json` owns, and the flag puts restorability into `Cuts`' merge rules.
- **Excluding windows by `sharingType = .none`.** Rejected unmeasured, in favour of the documented filter API. The exclusion spike measures both.
- **Global monitor or event tap for hot keys.** It cannot consume the press, or it needs Accessibility.

## Implementation reconciliation

Empty until implementation starts.

## Open questions and risks

1. **Does `excludingApplications` leave out a panel opened after the stream started, and is the app listed before it has a window?** The design depends on yes and yes. Unmeasured here. If the first is no, the sink calls `SCStream.updateContentFilter` when the chrome opens a panel. If the second is no, the Studio's ordering (control bar first) already covers it. Will someone with Screen Recording run spike/capture-exclusion before the sink is written?
2. **Does one `AVCaptureSession` feed a preview layer and the recorder's data output at the locked 30 fps?** Unmeasured. If the preview lowers the rate, does the bubble draw from the data output instead, which needs the feed running before any take?
3. **Does a listen-only session tap see `eventTargetUnixProcessID` filled for clicks on our panels?** Without it, a click on the control bar becomes an auto-zoom target. The fallback is filtering by our panels' frames, which leaks UI into the recorder.
4. **Should pause turn the microphone indicator off?** That needs the stream reconfigured on pause. It is a product call, not an engineering one.
5. **Should the bubble's position on screen set the export's camera corner?** The camera design chose corners. A dragged bubble suggests a point. Editing-polish track, not this one?
6. **Today's system-audio gap fill has the same 12 s limit.** A delivery gap longer than about 12 s would pull everything after it early. Should a separate issue fix `fill` before this unit, since the beat-driven fill is the same fix?
7. **Restart finalization time is unmeasured.** It runs in the background, but a restart pressed twice within a second means two takes finishing at once. Should a second restart wait for the first discard?
8. **Should hot keys be rebindable in v1?** The design registers fixed defaults and shows them in the control bar's tooltips.

## Next implementation step

Write `HostClock` and the new `SessionPhase.next` as pure code with table tests for every (phase, input) pair, then move `CaptureSink` onto `Stage` and `admits(_:)` behind the existing `start` and `stop`, with countdown zero, so the 402 existing tests pass before any UI exists.
