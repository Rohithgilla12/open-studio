# Candidate design (opus): Recording, Timeline, and the `.osrec` contract

Sketch: `docs/design/candidate/sketch/` (Swift, bodies `fatalError("not implemented")`). On-disk example: `docs/design/candidate/recording-directory-example.md`.

## Problem

Build the first native unit of open-studio. It has a recorder that writes a directory, and a pure Timeline that reads the directory and answers per-frame camera and cursor questions for a renderer that comes later. The shape is non-obvious because of five constraints:

- The later renderer is an `AVVideoCompositing` compositor. It queries `camera(at:)` and `cursor(at:)` on several threads, ahead of playback, and out of order. So every answer must be a pure function of t, at 4K60 cost.
- A crash at second 40 must not lose the take.
- The two modules must agree on a clock and a coordinate space without sharing internals.
- TCC charges Screen Recording and Input Monitoring to the responsible process. That process is the app bundle for the app, and the terminal for `osrec`.
- `swift build` and `swift test` must work without an app bundle.

The teardown fixes the behaviour to match: 300/2500 ms windows with a 2500 ms merge gap, 2× zoom, half-viewport click groups, the spring constants, a 500 px shake filter, and typing fade. It also describes the observed technique of replaying springs from t − 1000 ms.

## Usage (caller's view)

Recording, from the SwiftUI app later or from `osrec` now:

```swift
import Recording

let config = RecordingConfiguration(outputDirectory: libraryURL, microphone: .systemDefault)
let missing = Permissions.check().missing(for: config)
guard missing.isEmpty else { return show(RecordingError.missingPermissions(missing)) }

let session = try await RecordingSession.start(config)   // returns once frame 1 is on disk
Task { for await update in session.updates { hud.apply(update) } }
// ... user clicks Stop
let finished = await session.stop()                      // idempotent, never throws
open(finished.directory)
```

Crash recovery on app launch, or `osrec recover DIR`:

```swift
for dir in library.osrecDirectories {
    _ = try? await RecordingSession.recover(at: dir)     // no-op if finalised; refuses if still live
}
```

The renderer (later unit), inside `startRequest(_:)`, on any thread:

```swift
import Timeline

let source = try SourceRecording.load(from: dir)          // the only I/O in Timeline
let timeline = Timeline(source: source, zooms: AutoZoom.segments(for: source))

// compositor, per frame:
let t = RecordingTime(request.compositionTime)            // CMTime bridge lives in the renderer
let cam = timeline.camera(at: t)                          // viewport rect, scale, velocities
let cur = timeline.cursor(at: t)                          // position, image id, pressAmount, opacity
```

Verification, from the terminal:

```
osrec permissions
osrec record --duration 5 --mic default            # prints the .osrec path
osrec inspect 20261013-142233.osrec --check-determinism
osrec record --duration 10 --abort-after 5 && osrec recover <dir> && osrec inspect <dir>
```

## Shape

### Step 1: one process, three modules

```
            ┌──────────────────────────── app process (or osrec) ───────────────────────────┐
            │                                                                               │
 SwiftUI ──▶│  Recording ──writes──▶  20261013-142233.osrec/  ──reads──▶  Timeline         │
 osrec   ──▶│     │                          ▲      ▲                       │              │
            │     └────── internal import ───┴ RecordingFormat ┴── internal import         │
            └───────────────────────────────────────────────────────────────────────────────┘
```

- **Capture runs in the caller's process.** The format provides crash safety, and the process topology does not need to (see step 2). The single process gives these benefits:
  - TCC attaches to the app bundle, or to the terminal for `osrec`.
  - There is no XPC protocol to version.
  - The CLI and the app call the same API.
- **`RecordingFormat` is the contract module.** It holds the wire `Codable` types, the file names, the version gate, NDJSON framing, and the atomic manifest write. It is not a product. Recording and Timeline import it with `internal import` (SE-0409), so the compiler rejects any wire type on either public API. This is the only list of event kinds, and a new kind is a compile error at each `switch` (per encode-lessons-in-structure, and against the hand-synced list red flag).

### Step 2: inside the recorder, three sources and one clock

```
SCStream (showsCursor=false, + microphone on macOS 15) ──▶ CaptureSink actor (executor = SCK queue)
                                                              ├─▶ MovieWriter screen.mov     (fragments every 1 s)
                                                              └─▶ MovieWriter microphone.mov (same session start)
CGEventTap thread (listen-only) ──▶ tapBuffer   ┐
CursorWatcher @MainActor 60 Hz  ──▶ cursorBuffer┴─▶ EventLogWriter (100 ms drain, merge by host time)
                                                       ├─▶ cursors/<sha>.png  (temp + rename, before reference)
                                                       └─▶ events.ndjson      (one write(2) per batch)
first complete frame PTS = origin ──▶ both writers startSession(origin) ──▶ recording.json (status: recording)
stop ──▶ drain + close events ──▶ finishWriting ──▶ recording.json (status: finalized)  ◀── commit point
```

Load-bearing decisions:

- **One clock and one space, fixed at write time.** Every source is converted to mach host time, then to integer microseconds since the first complete screen frame. Coordinates are converted to screen-video pixels before anything reaches disk. Readers never see host time or points. The single conversion lives in pure `HostTime` and `DisplayMapping`, which are unit-tested (per boundary-discipline).
- **Microphone on the same `SCStream`** (`captureMicrophone`, macOS 15+). Audio arrives on the same host clock and queue as video. There is no separate `AVCaptureSession` to align. Separate writers keep a microphone fault from killing the screen file.
- **The hot path never hops.** `CaptureSink` is an actor whose executor is the `DispatchSerialQueue` that ScreenCaptureKit delivers on. Frame callbacks enter with `assumeIsolated`.
- **Separate producers, one consumer.** The tap thread and the cursor watcher each own a `Mutex` buffer. `EventLogWriter` alone writes the log and merges at drain time (per separate-before-serializing-shared-state).
- **Crash safety, file by file.**
  - The movies are fragmented. AVFoundation documents that they stay playable up to the last fragment.
  - The event log is append-only. A process crash can tear only the last line, and the reader tolerates exactly that.
  - Cursor PNGs are content-addressed, and each one lands before the line that references it.
  - The manifest is replaced atomically and written last as the commit point.
  - The `.lock` uses `flock`, which the kernel releases on death. That makes a liveness test that cannot go stale.
- **Recovery is idempotent.** It truncates to the valid prefix, probes the media duration, and then commits. Rerunning it after a crash mid-recovery repeats safe steps (per make-operations-idempotent).
- **The session's type is its state.** `RecordingSession` exists only after `start` succeeds, so there is no idle or "start twice" state. `start` either returns a live session or removes the directory. `stop()` is memoised as one `Task` and is never thrown from: a finalisation problem is a `Termination` value, and the directory stays recoverable. The lifecycle rules live in the pure `SessionPhase.next`, and the first termination reason wins.
- **Privacy by omission.** A `key` event records the time and modifiers. It records `keyCode` only while Command or Control is held. Typing fade needs only the times.

### Step 3: Timeline, built once and queried purely

```
load(from:) ── RecordingReader (bytes → wire) ── SourceRecording.init (wire → validated domain, sorted, refs resolved)
                                                        │
AutoZoom.segments(source) ──▶ [ZoomSegment] (edit state, owned by the editor later)
                                                        │
Timeline.init(source, zooms, settings)   O(n), once ────┤
   ├─ CameraTrack: SpringTrack<Double> scale, SpringTrack<Vector2> center   (targets from segments + PointerGroups)
   └─ CursorTrack: SpringTrack<Vector2> position, image changes, press intervals, hidden intervals
                                                        │
camera(at:) / cursor(at:)  ── binary search + closed form, O(log n), no mutation
```

- **The springs are solved exactly, not replayed.** Every target in this system is piecewise constant:
  - the zoom target changes at segment edges
  - the camera center changes at group boundaries
  - the cursor target is sample-and-hold between pointer samples

  Between changes, the spring is a linear ODE with a closed-form solution. `SpringTrack` folds that solution forward once at build time to store the exact state at each change ("knots"). A query is a binary search plus one `exp` and one `sin`/`cos` pair. Determinism follows from immutability rather than from a replay convention. Cost does not depend on t or on recording length. There is no reset discontinuity for springs that take longer than 1 s to settle. The default camera spring takes about 1.55 s to settle, so the observed 1000 ms replay window would cut it off. The solution is linear in (y0, v0) with scalar coefficients, so one solver serves both 1-D zoom and 2-D positions.
- **Zoom segments are an input to `Timeline`, not an output.** Generation is a separate pure function. The editor will own and edit the segments, and `Timeline` never regenerates them. Generated ids derive from the range, so generating twice gives equal arrays.
- **Auto-zoom merging is a single sorted sweep.** The TODO includes the proof that the sweep reaches the same fixed point as "merge repeatedly", and a property test checks it against the naive oracle.
- **Invariants live in types.**
  - `TimeRange` is non-empty by construction (failable init), so a click whose window clamps to nothing simply disappears.
  - `SourceRecording` is sorted and resolved.
  - `CameraState.viewport` is always inside the frame, with scale clamped to ≥ 1 because the camera spring is underdamped (ζ ≈ 0.44) and would overshoot below 1.
- **Settings are one `Codable` value** (`TimelineSettings`) with the teardown's constants as defaults. A preset is a `static let` on `Spring`.

**Interface depth.** Recording's public surface has five parts:

- `Permissions.check` and `Permissions.request`
- `RecordingConfiguration`
- `RecordingSession.start`, `stop`, `recover`, and `updates`
- `CaptureSources`
- the value types

Behind it sit ScreenCaptureKit, two writers, an event tap thread, cursor polling, clock and space conversion, crash-safe file protocols, and recovery. Timeline's surface is `SourceRecording.load`, `AutoZoom.segments`, `Timeline.init`, `camera(at:)`, `cursor(at:)`, and value types. Behind it sit validation, grouping, shake filtering, typing and idle detection, spring solving, and clamping. Neither surface exposes a stage, a wire type, or a framework object.

**Packaging.** The library modules and `osrec` live in SwiftPM at the repository root. The app arrives later as a thin, checked-in Xcode project in `App/` that depends on the package by local path, and it owns the bundle id, usage strings, entitlements, and signing. No project generator is involved: one app target keeps `.pbxproj` churn small, and a generator would be another tool to install and keep in step with Xcode 27. The repository adds `Sources/RecordingFormat/`, `Tests/RecordingTests/` (pure lifecycle and conversions), and `Tests/RecordingFormatTests/` to the brief's layout.

**What it deliberately does not do:**

- pause and resume
- system audio, window capture, or multiple displays
- segmented HLS output
- scroll- or focus-driven zoom (scroll is recorded but unused)
- fsync per batch
- composition-time mapping (trims and speed)

## Synthesis decision

Three runners (Opus, Fable, Sonnet) each sketched the brief independently in their own worktrees. A Fable cross-judge scored them against a six-point rubric: A (Opus) 26, C (Sonnet) 22, B (Fable) 18. I read all three end to end, and my pick was the same as the judge's, so this candidate (A) is the base.

**Where all three agreed.** All three converged on the same shape:

- capture in the caller's process, with no helper
- a separate `RecordingFormat` contract module
- a fragmented movie, plus an append-only NDJSON event log
- microphone capture through the same `SCStream` on macOS 15
- a pure lifecycle transition function
- keystrokes stored without typed text
- SwiftPM for the libraries, with a thin Xcode project for the app later

When independent runners agree like this, it is a strong signal, so these points are settled.

**Why A won.**

- One clock and one coordinate space are fixed at write time, so readers never see host time.
- The wire boundary is enforced by the compiler (`internal import`).
- The session's type is its state.
- Springs are solved exactly, and zoom segments are an input that the editor owns.
- It has the strongest verification hooks: `--abort-after`, `--check-determinism`, and a property test against a naive merge oracle.

**Why the springs are solved exactly, not replayed.** B replays the spring from t − 1 s on every query. The default camera spring takes about 1.55 s to settle, so B's reset produces a visible step one second after each target change. A and C both avoid this with exact checkpoints ("knots").

**Grafts applied.** Each one overrides the sketch wherever they conflict:

1. **Overlapping zooms are rejected, not repaired** (from B). `Timeline.init` takes a validated `ZoomTrack`, built with `ZoomTrack(validating:) throws`, which rejects overlaps. The silent repair in `Timeline.init` is removed. An editor bug should surface, not be patched over.
2. **One lookup per frame** (from B). `Timeline.frame(at:) -> FrameState` returns `{camera, cursor}` from a single knot search per track. `camera(at:)` and `cursor(at:)` are removed, so there is one way to ask.
3. **CGEvent timestamp units are settled by experiment, not assumption** (judge, B). The judge says `CGEventTimestamp` is documented as nanoseconds since boot. The sketch assumed mach ticks, which would skew events about 41× on Apple Silicon, where the timebase is 125/3. Step 0 below measures it with a real listen-only tap and fixes `HostTime`'s initialiser to match. No conversion goes in until the measurement exists.
4. **`RecordingHealth`** (from C). The reader reports `.finalized`, `.live` (flock held), `.crashed` (status recording, lock free), or `.unrecoverable` (no first frame), and throws `.needsRecovery(health)` for a crashed take. That gives the app's launch-time recovery a clear decision.
5. **Degradation is recorded in the manifest** (from C). Losing the microphone or the event tap keeps the take running. It is also written as a manifest warning, not only emitted as an update, so it survives a later crash.
6. **Experiment first** (from C). Step 0 is a throwaway experiment that settles two things before any Recording code is written. First, whether a fragmented `.mov` killed with `kill -9` reads back with `AVURLAsset`. Second, CGEvent timestamp units against `mach_absolute_time` and `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`. The results get written into this document.

**Rejected.**

- B's public `Spring`, `InputTrack`, and `@_exported` wire types leak internals.
- C's three event logs contradict its own one-repair-path argument.
- C's `Timeline(LoadedRecording)` puts a wire type on the public API.
- C writes `.mp4`. `movieFragmentInterval` is documented for QuickTime movies, so A and B's `.mov` is the safe choice.
- C's embedded Info.plist relies on `unsafeFlags`, and an unbundled CLI gets its TCC usage strings from the terminal anyway.

**Memory note.** The judge corrected A's knot estimate. Thirty minutes at 120 Hz is about 216 k knots, roughly 17 MB, which is still bounded. Thinning pointer samples to 10 px before building knots (already in the design) cuts this substantially.

## Tradeoffs accepted

- We accept that an editor crash during recording ends the take, in exchange for having no IPC layer. The data up to the last 1 s fragment and the last 100 ms of events survives, and `recover` finalises it.
- We accept analytic springs that differ slightly from the observed semi-implicit Euler at a 1/60 s step, in exchange for exact, O(log n), seek-independent answers with no reset artefacts. "Matches observed behaviour" means the same constants and feel, not the same numerical error.
- We accept knot tables that grow with pointer samples (about 60 k knots for 10 minutes of continuous movement, about 5 MB at ~80 bytes per knot), in exchange for O(log n) queries and millisecond rebuilds when the user edits zooms.
- We accept losing up to 1 s of video and 100 ms of events on a crash, and more on power loss because there is no fsync, in exchange for writers that never stall on disk flushes.
- We accept polling `NSCursor.currentSystem` at 60 Hz, in exchange for having no private API. A byte hash keeps the steady-state cost near zero.
- We accept that `stop()` never throws, so callers must read `termination`. A thrown error would imply the recording is gone, and it never is.
- We accept a third target (`RecordingFormat`) in exchange for a compiler-enforced wire boundary and a single list of event kinds. It looks like a layer, but it is the contract the brief asks for.
- We accept dropping key codes for ordinary typing, which rules out a future keystroke-overlay feature for non-shortcut keys, in exchange for never writing typed text to disk.

## Alternatives considered

- **Helper process (an XPC service in the app bundle, or a spawned sidecar as in Screen Studio).** It would let a recording survive an editor crash. It costs a versioned message protocol, lifecycle management, and a second debugging target. Callers would see the same `start`/`stop` surface, so it hides no more complexity than this design. It mostly duplicates the crash safety that the format already gives. Rejected for this unit. The public API is async and `Sendable`-only, so an XPC-backed implementation can slot in later without touching callers.
- **Replay from t − 1000 ms per query (the observed technique).** It is deterministic and simple to write. It costs 60 to 1000 integration steps per axis per query, it truncates slow springs, and it puts a correctness convention (the reset window) where an invariant should be. It lost on interface depth: callers get the same API either way, but the knot table hides the dependence on query order structurally.
- **Dense pre-sampled tracks at 240 Hz.** Queries are O(1), but memory and rebuild time scale with duration, and there is interpolation error. It approximates what the knot table computes exactly.
- **A single non-fragmented MP4, or segmented fMP4 with an HLS playlist.** A single MP4 loses the whole take on a crash. Segments bound the loss more tightly but need a concatenation step before `AVPlayer` can open the result. A fragmented `.mov` is readable as is after a crash.
- **Separate event files per kind** (the teardown's `mousemoves-0.json`, `mouseclicks-0.json`, and so on). That design has several writers, no global order, and JSON arrays that a crash leaves unterminated. One append-only NDJSON file has a single writer and tolerates a torn tail.

## Implementation reconciliation

Step 0 ran on 2026-10-13 on an Apple M2 Max with macOS 27.0.1. The programs and full tables are in `Experiments/README.md`.

**Confirmed: fragmented `.mov` survives `kill -9`.** An `AVAssetWriter` wrote 1920 × 1080 frames at 30 fps to a QuickTime movie with `movieFragmentInterval` = 1 s. A child process was killed with `SIGKILL` and the file was opened in a separate process.

- Killed at 5.5 s: all three HEVC runs were playable, with one video track, a duration of 5.033 s, and 150 decoded frames. H.264 was playable at 5.000 s with 150 frames.
- Killed at 3.3 s: all three HEVC runs read as 3.033 s with 90 frames. H.264 read as 3.000 s.
- Control, with no fragment interval: all six runs failed to open (`AVFoundationErrorDomain -11829 "Cannot Open"`).

The readable duration always lands on the last whole-second fragment boundary, so a crash loses at most one fragment interval of video. The design stands as written.

**Accepted deviation: `HostTime` is built from `CGEvent.timestamp` as nanoseconds, not mach ticks.** A listen-only session tap compared each `mouseMoved` timestamp with `CLOCK_UPTIME_RAW` and `mach_absolute_time()` read in the callback (timebase 125/3). Read as nanoseconds, the timestamp trails `CLOCK_UPTIME_RAW` by a median of 0.22 to 0.29 ms across three runs (900 posted events, plus 27 real mouse events), with a p95 of at most 1.6 ms. Read as mach ticks, it lands about 17.9 million seconds in the future. So `CGEvent.timestamp` is nanoseconds on `CLOCK_UPTIME_RAW`. The recorder must take it as `HostTime(nanoseconds:)` directly. The sketch's `HostTime(machTicks: event.timestamp)` is wrong, and would skew events by a factor of 41.7. `init(machTicks:)` stays only for `mach_absolute_time()` and `SCStreamFrameInfo.displayTime`. Stamping in the callback is not needed, because the timestamp is on the right clock and is earlier than any callback stamp.

**Confirmed: SCStream PTS is on the same clock.** Screen sample buffers carry a PTS with timescale 10⁹ that equals `SCStreamFrameInfo.displayTime` (mach ticks) converted to nanoseconds, exactly, on 12 of 12 buffers. It agrees with `CMClockGetHostTimeClock()` read on arrival to within 4 ms. Video PTS, CGEvent timestamps, and `CLOCK_UPTIME_RAW` are one clock in nanoseconds, which is the single clock the format assumes. The PTS is a display time and can be up to about 4 ms ahead of arrival.

**RecordingFormat deviations from the sketch.** Each is the smallest change the implementation needed, and each is covered by a test in `Tests/RecordingFormatTests/`.

- **No `.unknown` event case.** A line whose `type` the reader does not know is counted in `DecodedEventLog.unknownTypeCounts` and skipped. `WireEvent` holds only events a writer may write, so encoding is total and no caller can write an unknown event.
- **`KeyStroke` owns the privacy rule.** The recorder passes the raw key code to `KeyStroke(modifiers:pressedKeyCode:)`, which keeps it only while Command or Control is held. Decoding rejects a key code without one of those modifiers, so the rule holds in both directions.
- **Status carries its payload.** `ManifestStatus` is `.recording` or `.finalized(duration:termination:)`, and `WireTermination` carries a message only where one exists. The JSON keeps the flat `status`, `durationMicros`, and `termination` keys. `format`, `formatVersion`, and the clock's `unit` and `origin` are constants written on encode and checked on decode, not stored fields.
- **Manifest warnings (graft 5).** `warnings` holds `microphoneLost(at:message:)` and `inputTapReenabled(at:)`. A warning kind added later is dropped on decode instead of failing the manifest. A reader that rewrites the manifest, such as an older recovery, drops warning kinds and top-level keys it does not know. That is accepted for version 1.
- **`createdAt` is millisecond precision.** Foundation's fractional ISO 8601 style truncates, so `33.412` held as `33.41199…` printed as `.411` and decoded to a different date. The manifest rounds `createdAt` to whole milliseconds on init and formats from integer milliseconds.
- **Health and reading are two calls (graft 4).** `RecordingReader.health(at:)` reads only the lock and the manifest and returns all four `RecordingHealth` cases, so a launch-time library scan stays cheap. `RecordingReader.read(at:)` returns the manifest and event log for any directory that has a manifest, with `health` derived from the status and the lock. It does not throw `.needsRecovery`. Recovery and `osrec inspect` must read crashed takes through the same reader, so Timeline's `load` maps a health other than `.finalized` to its own error.
- **Lock and probe live in RecordingFormat.** `DirectoryLock` is the recorder's exclusive, non-blocking flock. The probe takes a shared lock, so two probes never report each other as a live recorder. A probe briefly blocks an exclusive acquire, so recovery should retry a failed acquire before reporting `.stillRecording`. A directory with a held lock and no manifest is `.live`, because the recorder may still be waiting for its first frame. The reader always probes the lock before it reads the manifest, in one function. The recorder commits its final manifest before it drops the lock, so a lock seen free means the manifest read next is the last one written.
- **Cursor storage is a format call.** `RecordingLayout.storeCursorImage(png:hotspot:size:)` content-addresses the PNG, writes it once with temp file and rename, and returns the `CursorImageDeclaration` to append. `CursorImageID` accepts only 16 lowercase hex digits, because the id becomes a file name.
- **A missing event log.** While the status is `recording`, a missing `events.ndjson` reads as an empty log, which covers a crash between the manifest and the first event write. A finalized recording without one is an error.
- **Keys are sorted.** Event lines and the manifest are encoded with sorted keys so equal values give equal bytes. Readers accept any key order, including the example's.

**Note for the recorder: macOS 27 deprecations.** `AVAssetWriterInput.expectsMediaDataInRealTime` and `AVAssetWriterInputPixelBufferAdaptor` are deprecated in the macOS 27 SDK. The deployment target is macOS 15, so the recorder needs the older API or an availability branch.

### D2: Timeline

**Timeline deviations from the sketch.** Implemented on 2026-10-13 against the frozen `RecordingFormat`. Each is covered by a test in `Tests/TimelineTests/`.

- **Grafts 1 and 2 as written.** `Timeline.init(source:zooms: ZoomTrack, settings:)` takes a `ZoomTrack` built by `ZoomTrack(validating:) throws(ZoomTrackError)`, which sorts and rejects overlaps and scales below 1. `Timeline.frame(at:) -> FrameState` is the only query; there is no `camera(at:)` or `cursor(at:)`. `AutoZoom.track(for:)` wraps the generated segments without a `try`, because generation cannot overlap.
- **Load errors name the next action.** `SourceLoadError` has `.stillRecording` (a recorder holds the lock) and `.needsRecovery` (crashed) instead of one `.notFinalized`, so the app can tell "wait" from "run recover". `RecordingReader.read` never throws for health, so `load` maps `RecordingHealth` itself.
- **Shake filter before thinning.** The sketch thinned first. Thinning can drop the sample that proves a warp returned, which lets the warp through. The order is swapped for both the camera groups and the cursor.
- **Cursor thinning keeps rest, click, and final samples.** The cursor spring's targets are thinned to 10 px like the camera's, which cuts a 30-minute, 120 Hz recording from 216 k to about 57 k knots, but a sample the pointer rested on for over 100 ms, clicked at, or ended on is always kept, so the cursor settles exactly where the user stopped.
- **`CursorSmoothing` is an enum.** `smooth`, `medium` (default), `rapid`, and `none`. `none` holds the raw shake-filtered samples with zero velocity instead of running a spring. The click spring stays Rapid in every mode that has a spring.
- **Lead-in and idle hide are optionals.** `CameraSettings.leadIn: RecordingTime?` and `CursorSettings.idleHideAfter: RecordingTime?` default to nil (off). The observed values are `CameraSettings.observedLeadIn` (350 ms) and `CursorSettings.observedIdleHide` (2000 ms).
- **Typing hide extends while keys keep landing.** A key that arrives while the cursor is already hidden extends the hide, even when the three-key sliding window no longer holds, so a slow but continuous typist does not flicker. Hidden intervals closer than the fade duration are merged for the same reason.
- **Generated ids are the range bytes.** The segment id is the 16 bytes of (start, end) in little-endian microseconds read as a UUID, not a hash, so equal ranges in different recordings share an id.
- **Measured.** On an Apple M2 Max (12 cores, load average 3 to 6 during the runs), a synthetic 30-minute recording with 216 516 pointer samples at 120 Hz, 258 clicks (257 segments), and a typing burst a minute builds its `Timeline` in 10.2 to 10.8 ms in release (six runs) and answers a random `frame(at:)` in 0.31 to 0.36 µs on average over 1000 queries. Knots: 515 scale, 942 center, 57 164 cursor, about 5 MiB. The cursor table bounds both numbers: build is one closed-form step per knot, and a query is three binary searches, the largest over 57 k knots, plus two `exp` and two `sin`/`cos` pairs. Thinning bounds the knot count by path length over 10 px plus rest points and clicks, not by sample rate.

### D3: Recording and osrec

Measured on 2026-10-13 on the same M2 Max, macOS 27.0.1, from Ghostty with all three permissions granted. The recordings are scratch artifacts, not committed.

**Accepted deviation: the classic `AVAssetWriterInput` path, no availability branch.** The macOS 27 SDK deprecates `expectsMediaDataInRealTime`, `isReadyForMoreMediaData`, and `append(_:)` for Swift only (`#if __swift__` in the header), in favour of an input receiver that exists only on macOS 27. With a macOS 15 deployment target the deprecation does not fire and the classic path is the only one available on every supported OS, so the writer has one path. ScreenCaptureKit hands over timed `CMSampleBuffer`s, which are appended directly, so no pixel buffer adaptor is involved. Revisit when the deployment target reaches 27.

**Added: a heartbeat frame once per fragment interval.** ScreenCaptureKit sends a frame only when the display changes, and the cursor is hidden from the capture, so a still screen produces no frames at all. A crashed take of a still screen then read back as 1.000 s although its events ran to 4.9 s, because only the first fragment held a sample. The sink now re-appends the last complete frame with a fresh PTS whenever a second passes without one. The same scenario recovers at 4.925 s. A clean stop never needed this: `endSession(at:)` extends the last frame to the stop time.

**Accepted deviation: `InputBuffer` instead of bare `Mutex` fields.** `Mutex` is non-copyable and its `withLock` sends the value, so two owners cannot share one and it cannot hold the non-Sendable CF types the tap needs. The producers and the writer share a small `InputBuffer<Element>` class (append and take-all), and the tap context holds its `CFMachPort` and `CFRunLoop` as plain fields on an `@unchecked Sendable` class, each written once on the tap thread before `start()`'s continuation resumes.

**Accepted deviation: `flagsChanged` is not tapped.** The format has no event for it, and modifiers ride on each `key` event.

**Accepted deviation: recovery keeps the screen duration as the take's duration.** With the heartbeat in place the screen duration tracks the crash time to within one fragment interval, so the example's "events after `durationMicros` stay in the file" still holds and nothing is derived from the event log.

**Measured.** All through `osrec` with a scratch tool posting synthetic moves at 50 Hz (and a left click per second on an uncovered desktop spot) while logging `CLOCK_UPTIME_RAW` before each post:

- 5 s take, 3456 × 2234 HEVC: manifest `finalized`, `durationReached`, screen.mov 5.000 s and playable, 121 frames (57 on a still screen), 158 event lines (150 moves, 3 down, 3 up, 1 state, 1 cursorImage), 1 cursor PNG (56 × 80 px, hotspot 10, 10). `NSCursor.currentSystem` works from an unbundled CLI.
- Clock: 150 posted moves, 150 matched by pixel position. Recorded time (origin + t) minus posted time: min 0.022 ms, p50 0.067 ms, p95 1.400 ms, max 12.9 ms. The maximum is the mover's first post (HID warm-up) and the next largest, 6.2 ms, follows the first desktop click. The offset is positive because the HID system stamps the event after `post` returns.
- Crash: `--duration 10 --abort-after 5` died by SIGABRT with the manifest at `recording`; `inspect` reported `crashed`, 102 frames, 4.925 s readable. `recover` finalized at 4.925 s with `recovered`; a second `recover` left `recording.json` and `events.ndjson` byte-identical (SHA-256 compared). The same test on the build before the heartbeat recovered 1.000 s.
- Microphone: 3 s take with `--mic default` (MacBook Pro Microphone, 48 kHz, 1 channel): microphone.mov 2.999 s, playable, AAC through the same `SCStream`.

**Found while verifying.** Posting synthetic events from a separate process reaches a session tap, but only while the tap is up: an earlier run that started the poster from a separate shell command missed the take entirely, which looked like a dead tap until a probe showed same-process posts arriving on both a secondary thread and the main thread. The scratch tool now spawns `osrec` itself.

### D4: integration

Measured on 2026-10-13 on the same M2 Max, macOS 27.0.1, from Ghostty. This is the first time Timeline loaded a real recording. The recordings are scratch artifacts, not committed.

**Added: Timeline verification in `osrec inspect`.** It is a thin shell over the public Timeline API.

- `--timeline` loads the take through `SourceRecording.load`, then prints its buttons and the `AutoZoom.track(for:)` segments.
- `--check-determinism` evaluates `frame(at:)` at every frame of the manifest's frame rate in four orders: forward, reversed, shuffled with a fixed seed, and from a `TaskGroup`. It compares the bit patterns of every `Double`, and exits 1 on any difference.
- `--frames <start-ms>:<end-ms>:<step-ms>` prints the camera scale, centre, and viewport, and the cursor position, opacity, and pressed state per sample.

Both flags imply `--timeline`, so the verification command under Usage works as written.

**Method.** A scratch tool spawns `osrec record` and takes its directory line as t = 0. It posts moves at 50 Hz on a circle of radius 8 pt, and left clicks with click state 1. Before each post it hit-tests the point with `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` and looks the window up with `CGWindowListCopyWindowInfo`. Only Finder at the desktop-icon level passes. A layer filter over the window list is not enough, because Notification Centre keeps a click-through window over the whole display at layer 21. Every point fails a layer test, but a click still reaches the desktop. A script computes the expected segments from the `down` and `up` lines of `events.ndjson` with the designed rule, without Timeline. The rule is [t − 300, t + 2500] ms, start ≥ 1 ms, end ≤ duration − 800 ms, no clicks in the final 1000 ms, and a merge when the gap is ≤ 2500 ms.

| | Take 1 (8 s) | Take 2 (10 s) |
|---|---|---|
| Event lines | 338: 330 move, 3 down, 3 up, 1 state, 1 cursorImage | 413: 405 move, 3 down, 3 up, 1 state, 1 cursorImage |
| Click 1 down/up (ms), position (px) | 1028.448 / 1088.708, (60, 240) | 1019.731 / 1085.696, (100, 240) |
| Click 2 down/up (ms), position (px) | 2026.650 / 2090.044, (60, 300) | 2016.373 / 2078.906, (100, 300) |
| Click 3 down/up (ms), position (px) | 6025.959 / 6091.011, (100, 1960) | 8019.474 / 8084.472, (3380, 1960) |
| Expected segments (ms) | [728.448, 7200.000] | [719.731, 4578.906], [7719.474, 9200.000] |
| Actual segments (ms) | [728.448, 7200.000], scale 2 | [719.731, 4578.906], [7719.474, 9200.000], scale 2 |
| Cursor error at the 6 button events (px) | 0.86, 0.14, 1.02, 0.10, 1.00, 0.14 | 0.94, 0.14, 1.32, 0.10, 0.99, 0.10 |
| Determinism | 481 frames at 60 fps, bit-identical in all four orders, 478 distinct | 601 frames, bit-identical, 599 distinct |
| Clock check, recorded minus posted | 330 of 330 matched, p50 0.043 ms, p95 0.085 ms | 405 of 405 matched, p50 0.049 ms, p95 0.096 ms |

Every segment matches its expected window to the microsecond. `isPressed` is true at every down and false at every up.

**Take 1 merges, as the rule says.** It follows the plan as briefed: two clicks 1 s apart, a 4 s pause, then a far click. The gap is measured from window to window, not from click to click. Click 2's up window ends at 4590.044 ms and click 3's down window starts at 5725.959 ms. That gap is 1135.9 ms, which is within 2500 ms. A new segment needs the next down more than 5.3 s (300 + 2500 + 2500 ms) after the previous up. Take 2 waits 5.94 s and gets two segments, with a gap of 3140.6 ms.

**Scale.** Inside a segment the zoom-in overshoots to 2.21 at the first up, then settles to 2.0000 (take 2: 2.0005 at 2649 ms, 2.0000 at 4569 ms). Outside, it is 1.0000 before the first segment (520 ms) and 320 ms after a zoom-out starts (4900 ms in take 2).

**Centre.** At 2× on a 3456 × 2234 px frame, the reachable centres are x 864 to 2592 and y 558.5 to 1675.5. All the desktop spots were near the screen edges, so each target clamps to the nearest reachable corner. In take 2, the clicks at (100, 240 to 300) move the centre to (864.0, 558.5) by 1720 ms. The centre returns to the frame centre (1728, 1117) between segments. The click at (3380, 1960) moves it to (2590.1, 1674.3) by 9190 ms. In take 1, the pointer jumps to the far spot at about 5.0 s, inside the merged segment, and the centre pans from (864.0, 558.5) to (864.0, 1675.5) by 5400 ms.

**Fixed: the clock check missed fractional moves.** The HID system stores an event's location as Float32 points. The clock check compared the posted `Double` position with the recorded pixel exactly, so only whole-point posts matched: 46 of 330 and 43 of 405. It now rounds the posted point through `Float` first, and matches every move. `osrec` has no test target and `Package.swift` was out of scope, so the two re-run takes are the regression evidence.

**Observed, not changed: the clamped camera spring rebounds.** The camera spring has ζ = 12 / (2√(125 × 1.5)) ≈ 0.44, so it overshoots by about 22% of each step. The clamp hides the overshoot past a limit, but it does not hide the rebound. After take 2's first zoom-out starts at 4578.9 ms, scale holds at 1.0000 from about 4900 to 5200 ms. It then rises to a peak of 1.0467 at 5350 ms and is back at 1.0000 by 5600 ms. A second, smaller rebound (1.0022 at 6100 ms) settles by 6500 ms. The centre rebounds the same way from a frame edge, by 52 px from 1675.5 to 1623.4 at 5800 ms in take 1. The 800 ms end margin also leaves take 2's last frame at scale 1.0446, so the zoom-out has not settled when the take ends. This is the designed spring and clamp, so Timeline is unchanged. See Open questions.

**Changed after review: the default camera spring is now "Focused".** The 125/12/1.5 constant in the brief is not one of the observed product's screen-animation presets, which are Focused (250/40/2.25) and Smooth (170/50/3). `Spring.camera` is replaced by `Spring.screenFocused` and `Spring.screenSmooth`, and `CameraSettings` defaults to Focused (ζ ≈ 0.84, settles in about 0.7 s). Measured on take 2 with `osrec inspect --frames 0:10000:5`, peak scale is 2.0072 (was 2.21), the minimum is 1.0000 with no rebound after the zoom-out (was 1.0467), and the last frame is at 1.0000 (was 1.0446). `--check-determinism` still reports 601 bit-identical frames.

**Found while verifying.** Clicking the wallpaper probably triggers "Click wallpaper to reveal desktop". This is inferred, not confirmed. Before take 1 the desktop hit-test found 96 free spots. Before take 2 it found 3652, as if the windows had moved aside. After take 2 the original layout was back. The per-click hit-test still held, because the tool re-checks each point just before it posts the click.

## Open questions and risks

- **Resolved: CGEvent timestamp units.** Nanoseconds on `CLOCK_UPTIME_RAW`, measured by D1 and confirmed by D3's clock check. See Implementation reconciliation.
- **Resolved on macOS 27: crash recovery of the fragmented `.mov`.** It reads to the last whole fragment after `kill -9` (D1) and after `abort()` with the heartbeat frame (D3). It is not yet measured on macOS 15.
- **Shake and thinning thresholds.** Are the 500 px and 10 px values in screen pixels, as assumed here, or in points? On a 2× display that doubles their effective size.
- **Default cursor preset.** Should it be Medium (assumed here) or Smooth?
- **Camera rebound after a clamp.** On a real take, the underdamped camera spring shows a rebound that the clamp cannot hide. Scale rises back to about 1.047 after each zoom-out, and the centre rebounds about 52 px from a frame edge (D4). Does the observed product show the same rebound? If not, options include a critically damped spring for the zoom-out only, or a longer end margin than 800 ms.
- **Clock for edits.** When trims and speed changes arrive, should springs run in source time, as now, or in output time, so the camera stays continuous across a cut? If output time, `Timeline.init` gains a time map, and the knot design accommodates it.
- **Distribution.** Will the app be sandboxed for the App Store, or Developer ID only? Listen-only taps and ScreenCaptureKit work in both, but the choice changes entitlements and the library location used by recovery.
- **Sequoia-style re-consent prompts.** Recurring "allow screen recording" prompts may push towards `SCContentSharingPicker` for display selection. Should the app adopt it now or later?
- **Resolved: `NSCursor.currentSystem`.** It works from an unbundled CLI (D3's 5 s take captured a cursor image).

## Next implementation step

Implement `RecordingFormat` with its round-trip tests, then `SpringTrack` and `AutoZoom` against the spec tests in `Tests/TimelineTests/TimelineSpec.swift`. All three are pure, so they are verifiable with `swift test` before any capture code exists.
