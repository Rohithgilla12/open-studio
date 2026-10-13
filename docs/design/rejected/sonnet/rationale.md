# Candidate design (sonnet): native recorder and timeline core

## Problem

Build the first native unit of open-studio. A `Recording` library captures one display (cursor hidden), input events and cursor images, and optionally the microphone. It writes a recording directory. A `Timeline` library loads that directory's metadata and answers per-frame camera and cursor queries for an `AVVideoCompositing` compositor. That compositor calls from many threads, ahead of playback and out of order, so answers must be pure functions of `t`.

Constraints the design honours:

- The directory is the contract. It needs a version and one clock.
- A crash at second 40 of a 60 s take must leave usable data.
- The brief's numbers hold: 300/2500 ms click windows, 2500 ms merge gap, 2x zoom, camera spring 125/12/1.5, cursor presets, 500 px shake filter, typing fade at 3 keys in 1800 ms.
- Timeline's core has no AppKit, AVFoundation or I/O.
- `swift build` and `swift test` work on the libraries without an Xcode project.

## Usage (caller's view)

Recording from the CLI, and later the app (same library, in process):

```swift
let session = try await Recorder().start(RecordingConfig(outputDirectory: out))   // throws .permissionsMissing([...])
Task { for await s in session.states { log(s) } }
let summary = try await session.stop()                 // idempotent
print(summary.directory.path)
```

The editor and renderer, which never see Recording:

```swift
let recording = try RecordingReader.read(url)          // validated; throws .needsRecovery for a crashed take
let timeline = Timeline(recording)                     // auto-zoom runs here, springs integrate here

// inside AVVideoCompositing.startRequest, any thread, any order
let t = RecordingTime(value: request.compositionTime.value, timescale: request.compositionTime.timescale)
let camera = timeline.camera(at: t)                    // scale, center, visibleRect
let cursor = timeline.cursor(at: t)                    // position, image id, isPressed, opacity, isVisible
let sprite = timeline.cursorImages[cursor.image]       // bitmap path + hotspot
```

Verifying on a real Mac:

```
osrec check --mic
osrec record --out ./out --duration 5 --mic     # prints ./out/20261013-102231-4f9c.osrec
osrec inspect ./out/*.osrec
osrec zooms ./out/*.osrec
osrec sample ./out/*.osrec --at 1.2 --count 60 > fwd.txt
osrec sample ./out/*.osrec --at 1.2 --count 60 --reverse | tac | diff - fwd.txt   # order independence
osrec verify-clock ./out/*.osrec
kill -9 mid-take; osrec inspect <dir> (exit 2); osrec recover <dir>; osrec inspect <dir> (exit 0)
```

## Shape

Sketch lives in `sketch/`. Example directory with file contents lives in `example/`.

### Module map

Built up in three steps.

Step 1, the obvious split. Recording writes, Timeline reads. Problem: Timeline has to parse the directory, so it either imports Recording (dragging in AppKit and ScreenCaptureKit) or duplicates the schema.

```
Recording ──writes──► [directory] ◄──reads── Timeline
      \_____ both need the schema _____/
```

Step 2, give the contract its own module. It holds the schema, the file layout, the reader and the line encoders, and imports only Foundation.

```
Recording ───► RecordingFormat ◄─── Timeline
```

Step 3, add the shell.

```
osrec ───► Recording ───► RecordingFormat ◄─── Timeline ◄─── osrec
                                   ▲
                       future editor / renderer
```

The brief proposed two libraries. A third, `RecordingFormat`, is a deliberate challenge to the layout: it keeps Timeline pure by construction and puts the on-disk contract in one place. Dependency direction is enforced by `Package.swift`, not by convention. The `RecordingFormat` target is small: types, one reader, one line encoder.

### The clock

One clock: host time in nanoseconds (the `mach_absolute_time` basis, which is what `CMClockGetHostTimeClock` and SCStream sample timestamps use). Two newtypes stop mixing:

- `HostTime`: absolute. Appears only in the capture shell and in event files.
- `RecordingTime`: nanoseconds since the origin, where origin is the PTS of the first video frame. Appears everywhere after `RecordingReader`.

Video is written so that file time 0 equals the origin (`startSession(atSourceTime: firstFramePTS)`). The microphone starts its session at the same origin, and arrives through `SCStreamConfiguration.captureMicrophone` (macOS 15), so it shares the video's clock and no second capture session needs aligning. Event and cursor files store raw `HostTime` (`"h"`). The origin is written to the manifest once, when the first frame lands. The reader does `host - origin` in one place. Events can start before the first frame, so recording origin cannot be known at tap start. Storing absolute values means nothing has to be rewritten, and that is what makes the files append-only.

Integer nanoseconds also give Timeline exact arithmetic: no float drift in comparisons, and `CMTime` converts exactly (`RecordingTime(value:timescale:)`).

### The recording directory

See `example/20261013-102231-4f9c.osrec/`.

```
20261013-102231-4f9c.osrec/
  manifest.json            atomic rewrite only (tmp + fsync + rename); status recording | finalized
  .recording.lock          flock held by the recorder; kernel releases it on death
  video/display.mp4        fragmented MP4 (movieFragmentInterval 1 s), PTS 0 = origin
  audio/mic.mp4            fragmented AAC, same origin (optional)
  input.ndjson             append-only: move | button | scroll | key, host-time stamped
  cursor.ndjson            append-only: cursor image changes
  cursors/catalog.ndjson   append-only: id, file, hotspot, size, scale
  cursors/<id>.png
```

Decisions inside it:

- **Separate files per writer, merged at the read boundary.** The event tap thread, the cursor watcher and the capture queue each own exactly one file. No shared writer, so no lock and no ordering problem. `RecordingReader` merges and sorts. Per **separate-before-serializing-shared-state**.
- **NDJSON, append-only.** One `write(2)` per flush, newline-terminated. A crash tears at most the last line, and the reader drops it with a `Diagnostic`. The alternative, a single JSON array rewritten on close, loses everything on a crash.
- **Keystrokes record time and modifiers, never key codes.** `KeyTick` has no field that can hold a character. Auto-zoom and typing fade need only timing. A recording directory is therefore safe to share without containing typed passwords. Per **encode-lessons-in-structure**.
- **Cursor ordering.** The PNG is written, then its catalog line, then the change line, so a change never references a missing image. The reader maps any dangling id to `.fallbackArrow` anyway.
- **Coordinates:** display-local points, top-left origin (`CGEvent.location` minus the display's global origin, no flips). Timeline normalises to 0...1, so nothing downstream sees pixels or Retina scale.
- **Versioning:** `formatVersion` is a major number. The reader accepts equal majors, ignores unknown keys and unknown line kinds, and rejects a newer major. `clock.kind` is a string so a future clock is refused rather than misread.
- **Health, not a flag.** `status == recording` plus an acquirable lock means "crashed"; a held lock means "in progress". There is no stale-flag problem because the kernel owns liveness.

### Video durability

`AVAssetWriter` with `movieFragmentInterval` produces a fragmented MP4: the file is valid up to the last completed fragment even if the process dies. One file stays directly playable by the compositor, in the editor, with no concatenation step.

Alternatives: HLS-style segments (Screen Studio) need a flatten step before the editor can build a single `AVAsset`, and add a playlist to recover. A single non-fragmented MP4 loses everything. Verification is mandatory in the first implementation step (see risks).

### Process boundary: in-process library

Capture runs in the host process. The CLI is the host today and the SwiftUI app is the host later. The three options:

```
A. in-process (chosen)         B. helper in the app bundle           C. separate daemon
app ─ Recording ─ SCK/tap      app ─XPC─► helper ─ SCK/tap           app ─XPC─► launchd agent
```

| | In-process | Bundled helper | Daemon |
|---|---|---|---|
| TCC | One bundle id, one prompt per permission | Helper is its own responsible process or inherits unpredictably; Screen Recording prompts risk doubling | Own identity, own prompts, install flow |
| Crash isolation | None from process; recovered by storage design | Real | Real |
| Moving parts | None | XPC protocol, helper signing, lifecycle | Plus launchd, upgrade, uninstall |
| Testing | Direct | Needs a connected app to run | Same |
| CLI harness | Trivial | Must ship helper too | Same |

The choice rests on one observation. The crash we are guarding against, a take that dies at second 40, is handled by storage (fragmented video, append-only logs, lock-based health, `recover`), not by a second process. If the editor window crashes while the user is recording, they lose at most 1 s of tail, not the take. The seam to move to B later is preserved: `RecordingConfig`, `RecordingState`, `RecordingSummary` and `RecordingError` are `Codable` and `Sendable`, and the session API is async plus an `AsyncStream`. XPC would be a transport shim, not a redesign.

### Recorder state machine

`RecordingSession` is an actor that owns a `Phase`. Components (screen capture, input tap, cursor watcher, file writers) send `Input`s; a pure `transition(phase, input) -> (phase, [Effect])` decides; the actor runs the effects. This keeps every ordering rule testable without a display or TCC.

```
idle ─begin─► starting ─firstFrame(origin)─► recording ─stopRequested─► stopping ─finalised─► finished
                 │                               │  ▲                     ▲
                 └─streamFailed──────────────────┼──┼─────────────────────┘ (writerFailed / streamFailed)
                                                 └─ degraded(tap | mic | cursor): stays recording, manifest warning
failure after origin  ──►  failed(error, salvage: summary)
```

Rules: stop is idempotent; origin is set once; late callbacks from torn-down components are no-ops; losing the tap or mic degrades and is recorded in the manifest, while losing the stream or the video writer ends the take with a salvage summary.

Permissions are a separate `PermissionProviding` seam: Screen Recording (`CGPreflightScreenCaptureAccess`), Input Monitoring (`CGPreflightListenEventAccess`; a listen-only tap needs this, not Accessibility), microphone when requested. `start` throws `.permissionsMissing([...])` before touching anything. `osrec check` names the terminal app, because TCC attaches to the responsible process, not to `osrec`.

### Recovery

`RecordingRecovery.recover(dir)` is idempotent. It probes health, truncates each log after its last newline, asks `AVAsset` for the readable video end, sets `duration = videoEnd`, drops catalog entries whose PNG is missing, then rewrites the manifest atomically with `finalisation.kind = .recovered`. Run on a finalised directory it does nothing; run twice on a crashed one it produces the same manifest, because every input is frozen once the writer is dead. Unrecoverable only when there is no origin (no first frame ever arrived). `RecordingReader` never recovers implicitly: it throws `.needsRecovery(health)`, so loading stays free of AVFoundation and a read has no side effects.

### Timeline

Data structures first. Dominant access pattern: the renderer asks `camera(at: t)` and `cursor(at: t)` for arbitrary `t`, possibly 60 times per second at 4K, from any thread, in any order.

Step 1, the teardown's approach: reset the spring at `t - 1000 ms` and replay about 60 integrator steps per query. Deterministic, but each query costs a loop and the one-second window truncates real history, so a spring still moving at `t - 1000` is wrongly snapped to rest.

Step 2, make the trajectory a value. Targets are piecewise constant (a zoom starts, a focus group changes, a pointer sample arrives). Between target changes a damped spring has a closed-form solution. So integrate the whole trajectory once, at `Timeline.init`, and store a `Piece` at each target change: start time, exact position and velocity at that instant, target, spring parameters.

```
time ─────────────────────────────────────────────────────►
target   ┌──T0──┐┌────T1────┐┌──T2──┐┌────────T3────────
pieces   [x0,v0] [x1,v1]     [x2,v2] [x3,v3]    ← computed once, in order, from the previous piece
query t:  binary search piece → closed-form evaluate(piece, t)   O(log n), no state, no allocation
```

Step 3, compose: `CameraTrack` is three `SpringTrack`s (scale, centre x, centre y); `CursorTrack` is two (x, y) plus sorted interval arrays for pressed, typing-fade and cursor-image changes, all binary-searched. `Timeline` is an immutable struct of arrays, so `Sendable` comes for free and thread-safety needs no lock.

Why this is determinism and not just caching: the checkpoints are built sequentially in one thread, in fixed order, so floating-point results are the same every build. No query changes any state. Edits (`replacingZoomSegments`) return a new `Timeline`; tracks rebuild in `O(events)`.

Two honest differences from the teardown: (1) we use the closed-form solution of the same ODE instead of semi-implicit Euler at 1/60 s, so results match within integrator error, and tests compare against a fine-grained reference integrator; (2) pointer targets are zero-order-held between samples. Both are listed in tradeoffs.

Auto-zoom is a pure function over click times (`AutoZoom.segments`): windows `[max(t-300ms, 1ms), min(t+2500ms, duration-800ms)]` for clicks before `duration-1000ms`, sorted by start, merged in one left-to-right pass while the gap is at most 2500 ms. One pass over start-sorted windows equals the teardown's "merge repeatedly" because a later window cannot reach back past an earlier start. Segment ids derive from start time and origin, never random, so an edit keyed on an id survives regeneration. `TimelineEdits` (manual zooms, removed auto zooms) layer on top and are persisted by the editor in `project.json`, never in the recording.

Camera focus inside a zoom: pointer samples are thinned to 10 px, out-and-back jumps over 500 px (Manhattan) are dropped as shake, then grouped greedily in time order until a group's box exceeds half the visible viewport (`0.5 / scale` per axis, normalised). The group's time-weighted centroid becomes the target from the group's start. Outside zooms the target is the frame centre at scale 1. Centres are clamped so the visible rect stays inside the frame, both on the target and on the output.

Cursor: spring over the raw pointer, preset Smooth by default, switching to Rapid for the 175 ms before a button down (per-piece parameters, so closed form still holds). Opacity fades around typing bursts (at least 3 keyDowns within 1800 ms). `isVisible` is false when the pointer is on another display.

### Interface depth

- **Recording:** the public surface is `Recorder.start`, `RecordingSession.stop` and `.states`, `RecordingConfig`, `RecordingRecovery.recover`, `PermissionProviding`. Hidden behind it: SCStream configuration, writer sessions, fragmenting, the tap thread, cursor hashing, clock conversion, flush cadence, lock handling, the whole state machine. Callers never see a `CMSampleBuffer`, a `CGEvent` or a file name.
- **RecordingFormat:** the surface is the read side (`RecordingReader.read` returning a validated `LoadedRecording`) and the manifest types. The wire line structs are not public; `LogLine.encode` takes domain types. Per **boundary-discipline**.
- **Timeline:** two queries, two value types, an init. Hidden: click windows, merging, shake filter, grouping, spring integration, typing detection, track layout. The renderer never touches a spring.

### Invariants in types

- `HostTime` vs `RecordingTime`: mixing is a compile error.
- `KeyTick` has no key code field.
- `LoadedRecording` can only come from `RecordingReader.read`, which establishes sortedness, bounds, paired buttons and resolvable cursor ids. Timeline trusts them.
- `RecordingDirectoryWriter` is `~Copyable` with a `consuming finalise`: writing after finalise does not compile.
- `RecordingConfig`, state and errors are `Codable` and `Sendable` by construction.
- Spring parameters are validated in `SpringParameters.init`.

## Synthesis decision

*Filled in by arena.*

## Tradeoffs accepted

- We accept a third library (`RecordingFormat`) beyond the brief's two, in exchange for Timeline being pure by construction and one owner for the contract.
- We accept in-process capture with no process-level crash isolation, in exchange for one TCC identity, no XPC, and a trivially testable CLI. Storage design carries crash safety.
- We accept a fragmented single-file MP4 whose recoverability must be proven on hardware, in exchange for one directly playable `AVAsset` and no flatten step. Fallback is segment output.
- We accept the closed-form spring instead of the teardown's replayed semi-implicit Euler. Output is not bit-identical to Screen Studio's, but it is exact for the ODE, history-complete, O(log n) and order-independent. Clean-room is not violated: behaviour, not code.
- We accept zero-order hold between pointer samples, which assumes samples are dense enough (tens of Hz) that held steps are invisible under the spring. Sparse pointer streams will look steppy.
- We accept absolute host-time stamps on disk and a subtract-at-read, so files are not human-readable as seconds-from-start. The example directory shows the values.
- We accept that `Timeline.init` does work (grouping, integration) proportional to event count. It runs once per project load or edit, not per frame.
- We accept no key codes, so a future shortcut-overlay feature needs a format bump and an opt-in.
- We accept no pause/resume in v1. It would be a Phase extension (`paused`), and fragmented output makes a gapless pause a timestamp-offset question, not a format question.
- A `README.txt` and `.recording.lock` sit in each directory; readers ignore unknown files.

## Alternatives considered

- **Capture in a helper process over XPC.** Real crash isolation, but a second signing identity, TCC attribution that is hard to reason about, an IPC protocol and a longer verification path. Interface depth: it exposes lifecycle and transport to callers. Loses for this unit; the Codable API keeps it reachable.
- **Spring replay from `t - 1000 ms`, as in the teardown.** Simple, stateless, matches the original. Loses on per-query cost (about 60 steps times 5 springs) and on truncated history; it would be the fallback if the closed-form checkpoint design hit a problem.
- **HLS/segmented fMP4 plus playlist.** Standard recoverability story, but it exposes segment handling to the editor and needs flattening for a single `AVAsset`. Hides less than the single fragmented file.
- **Per-type files, e.g. `mousemoves.json`, `clicks.json`, `keystrokes.json`.** Matches the teardown, but N files each need tail repair and N readers need merging. One input log keeps one writer and one repair path.
- **Zero-copy shared event store with a lock between tap, cursor and video origin.** Rejected under separate-before-serializing: per-actor files and a merge at read need no lock.
- **SwiftPM-only versus Xcode project.** Chosen: SwiftPM for libraries, tests and `osrec` (works with `swift build`/`swift test`), with the later SwiftUI app as an Xcode project at `App/` that depends on the local package. The app needs a bundle id, entitlements and an asset catalog; the libraries do not. `osrec` embeds an Info.plist via `-sectcreate` so the microphone prompt works from a bare CLI. Screen Recording and Input Monitoring attach to the terminal (responsible process).

## Implementation reconciliation

*Placeholder. Filled during implementation.*

## Open questions and risks

- Does `AVAssetWriter` with `movieFragmentInterval` produce a file `AVAsset` can read after `kill -9`, including a truncated final fragment, on macOS 27? This design depends on it. Should the first implementation step be this experiment alone?
- Are `CGEvent.timestamp` values nanoseconds or mach ticks on Apple Silicon? `HostClock.nanoseconds(fromEventTimestamp:)` assumes conversion is needed. `osrec verify-clock` (click on a flashing frame) is the proof; should it block the first milestone?
- Does `SCStreamConfiguration.captureMicrophone` share the video's clock to within one audio buffer in practice? If it drifts, should the microphone fall back to `AVCaptureSession` with explicit offset correction?
- SCK delivers frames only on change, so the video is VFR. Is the renderer fine with VFR input, or should the writer duplicate frames to a constant rate?
- The teardown does not say how the "settle rescale" (`k *= (T/avail)^2`) applies. It is a `SpringTrack` open point. Do we want it for v1 or defer it?
- Should auto-zoom count both mouse down and up (as the teardown infers) or only down? Both widens each window by the press duration; this sketch follows the teardown.
- Multi-display: pointer on another display makes the cursor invisible. Is that the desired behaviour, or should we clamp to the edge?
- `recordings/` fixtures: commit metadata-only (no video) for Timeline tests with `ReadOptions.metadataOnly`, plus one real 5 s recording for the CLI check. Is a roughly 1 MB binary in the repo acceptable?
- Is the monthly macOS 15+ Screen Recording re-approval prompt a UX issue for the app, and should `PermissionReport` expose it?

## Next implementation step

Run the throwaway experiment: an `AVAssetWriter` fragmented-MP4 recording killed with `kill -9`, read back with `AVAsset`, and an event tap stamping a flashing frame to settle the clock units, before writing any other Recording code.
