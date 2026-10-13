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

**Note for the recorder: macOS 27 deprecations.** `AVAssetWriterInput.expectsMediaDataInRealTime` and `AVAssetWriterInputPixelBufferAdaptor` are deprecated in the macOS 27 SDK. The deployment target is macOS 15, so the recorder needs the older API or an availability branch.

## Open questions and risks

- **CGEvent timestamp units.** Are they mach ticks or nanoseconds on Apple Silicon? The sketch assumes ticks and converts with `mach_timebase_info`. The 5 s recording should check the event timestamp against `mach_absolute_time()` taken in the callback, and fall back to stamping in the callback if they disagree.
- **Crash recovery of the fragmented `.mov`.** Does it really read to the last fragment after `kill -9` on macOS 15 and 27? `--abort-after` exists to prove this before anything builds on it.
- **Shake and thinning thresholds.** Are the 500 px and 10 px values in screen pixels, as assumed here, or in points? On a 2× display that doubles their effective size.
- **Default cursor preset.** Should it be Medium (assumed here) or Smooth?
- **Clock for edits.** When trims and speed changes arrive, should springs run in source time, as now, or in output time, so the camera stays continuous across a cut? If output time, `Timeline.init` gains a time map, and the knot design accommodates it.
- **Distribution.** Will the app be sandboxed for the App Store, or Developer ID only? Listen-only taps and ScreenCaptureKit work in both, but the choice changes entitlements and the library location used by recovery.
- **Sequoia-style re-consent prompts.** Recurring "allow screen recording" prompts may push towards `SCContentSharingPicker` for display selection. Should the app adopt it now or later?
- **`NSCursor.currentSystem`.** It is documented loosely. Does it keep returning other apps' cursors from a CLI with no key window? The 5 s recording verifies this.

## Next implementation step

Implement `RecordingFormat` with its round-trip tests, then `SpringTrack` and `AutoZoom` against the spec tests in `Tests/TimelineTests/TimelineSpec.swift`. All three are pure, so they are verifiable with `swift test` before any capture code exists.
