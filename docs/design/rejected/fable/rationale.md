# Rationale: native recorder and timeline core (candidate: fable)

Sketch: [`sketch/`](sketch/). Example directory: [`recording-directory-example.md`](recording-directory-example.md).

## Problem

Capture one display with the cursor hidden, plus input events and cursor bitmaps, into a directory that a pure Swift timeline can turn into per-frame camera and cursor answers for an `AVVideoCompositing` renderer that asks out of order on any thread. The shape is non-obvious in three places. Video PTS and input events come from different APIs and must share one clock. A crash at second 40 must leave the first 40 seconds usable, which tempts a helper process but is really a file-format question. And the spring maths that makes the camera feel right is normally stateful, while the renderer needs `camera(at:)` to be a pure function of `t`. Constants to honour come from the teardown (click windows t−300..t+2500 ms merged at gaps ≤ 2500 ms, 2× zoom, k=125 c=12 m=1.5, cursor presets, 500 px shake filter, typing fade at 3 keyDowns in 1800 ms).

## Usage (caller's view)

Recording, from the app or `osrec`:

```swift
import Recording

let report = Permissions.check()
guard report.allowsRecording else {
    for p in report.missing { print("Missing \(p): \(p.settingsURL)") }
    exit(2)
}

var config = RecordingConfig(outputDirectory: URL(filePath: "~/Movies/20261013-143012.osrec"))
config.microphone = .systemDefault
let session = try await RecordingSession.start(config)      // returns once frames are being written
try await Task.sleep(for: .seconds(5))
let result = try await session.stop()                        // idempotent; Ctrl-C path calls it too
print(result.duration, result.videoFrames)
```

Editing and rendering, later units:

```swift
import Timeline

let take = try Take.load(from: directoryURL)                 // validates version, clock, cursor ids
var project = Project.automatic(take: take)                  // AutoZoom applied
project.cursor.preset = .rapid
let sampler = Sampler(project: project)                      // rebuilt per edit, cheap

// Inside AVVideoCompositing.startRequest(_:), on any thread, any order:
let t = Duration.seconds(request.compositionTime.seconds)
let frame = sampler.frame(at: t)
let crop = frame.camera.viewport(in: take.display.size)      // source rect to show
let cursor = take.cursors[frame.cursor.image!]               // PNG url, hotspot, size
```

Test:

```swift
let sampler = Sampler(project: .automatic(take: try Take.load(from: fixture)))
let forward = times.map(sampler.frame(at:))
let scrubbed = Dictionary(uniqueKeysWithValues: times.shuffled().map { ($0, sampler.frame(at: $0)) })
#expect(forward == times.map { scrubbed[$0]! })
```

## Shape

Build it up in four steps.

Step 1, one clock. Nothing coordinates on time; everyone stamps from the host clock and the reader re-bases.

```
HostClock.start()  ── startHostNanos ──▶ manifest.json
      │
      ├─ CGEvent.timestamp ──▶ events.ndjson   t = ts − start
      ├─ NSCursor poll     ──▶ events.ndjson   t = now − start
      └─ SCStream PTS      ──▶ display.mov     movie 0 = first frame
                            └▶ timebase.json  firstVideoFrameOffsetNanos
```

Step 2, the directory is the contract and the crash plan. Each file has one writer and the JSON files are write-once, so recovery is only "drop the torn tail".

```
manifest.json  (first, immutable)        display.mov  (fragmented, 1 s)
events.ndjson  (append-only, unsorted)   timebase.json (once, at first frame)
cursors/*.png  (content-addressed)       finish.json  (last; absent ⇒ recovered)
```

Step 3, modules. The wire types live in one place so neither public API shows them.

```
RecordingFormat ◀── Recording (SCStream, AVAssetWriter, CGEventTap, NSCursor)  ◀── osrec, App
      ▲
      └──────────── Timeline (Take, Project, AutoZoom, Spring, Sampler)        ◀── Renderer, Editor, osrec inspect
```

Step 4, per-frame answers are pure functions over precomputed sorted arrays.

```
Project ──Sampler.init──▶ CameraTargetTrack [keyframes]   cursorPath [MouseSample]  clicks  keyPresses  cursorChanges
                                 │                                │
frame(at: t) ─▶ Spring.value(t) { targets.center(at: s) }   Spring.value(t) { path.position(at: s) }
                 60 steps from t−1 s, x₀ = target(t−1 s)     binary search per step
```

Data structures. `Take` is the loaded recording: immutable, times re-based to the first video frame, positions re-based to the display's top-left, every track a sorted array (`moves`, `clicks`, `keyPresses`, `cursorChanges`), cursor bitmaps as a dictionary of descriptors with URLs. The invariants (sorted, non-negative, every cursor id known) are established once in `Take.init` and trusted everywhere after, per boundary-discipline. `Project` is the document: a `Take` plus a `ZoomTrack` (sorted, non-overlapping by construction; overlaps are rejected, not repaired) and settings. `Sampler` is derived from a `Project` and holds only immutable precomputed tracks. Every dominant access pattern is "last element at or before t" on a sorted array, so no index or cache is ever needed.

Flow. `RecordingSession.start` preflights permissions, writes the manifest, starts the three producers, and only returns once the first complete frame has been appended and `timebase.json` exists; "started" means frames are flowing. Producer callbacks funnel into `apply(_:)`, which asks the pure `RecordingStateMachine.next` what to do; stop is idempotent because the machine answers `.noop` for repeated stops. `Take.load` reads four files and calls the pure initialiser. `AutoZoom.segments` runs once at project creation. `Sampler.init` builds click groups per segment into a piecewise-constant `CameraTargetTrack`. `camera(at:)` and `cursor(at:)` replay a spring from `t − 1 s` with a fixed step; the target functions are binary searches. Cost is around 120 steps and 120 binary searches per frame, microseconds, well inside a 4K60 budget.

Load-bearing decisions.

- In-process capture, no helper. Crash survival is delivered by fragmented QuickTime plus an append-only log, not by process isolation. A helper would add a second contract to version, bundle signing before the app exists, and TCC responsible-process plumbing, to protect a UI this unit does not ship. `RecordingSession` is already the boundary a helper would wrap if a later unit wants one. Per subtract-before-you-add.
- One clock, no coordination. `startHostNanos` is sampled once before any producer starts; producers stamp independently; the reader merges. Per separate-before-serializing-shared-state.
- Microphone through the same `SCStream` (macOS 15 `captureMicrophone`), into the same movie as a second track. One clock, one file, one fragment cadence. Per subtract-before-you-add.
- One event stream, with cursor bitmaps described inline (`cursorImageDefined` before first use). One ordering, one truncation case to recover.
- Wire types isolated in `RecordingFormat`; `Timeline` re-exports only three ids. A format change is not a Timeline API change.
- `Spring.value(at:)` is stateless; the integrator's start state is `target(t − warmup)`. Determinism across threads and seek order follows from purity, not from locking. Encoded in the signature, per encode-lessons-in-structure.
- `ZoomTrack` and `Take` carry their invariants in their initialisers; `RecordingStateMachine` is a pure function tested without a display.
- Keystrokes record timing only; key codes are opt-in. Privacy by structure.

Interface depth. Public surface: `Permissions`, `RecordingConfig`, `RecordingSession` (start/stop/notices), `Take.load`, `Project.automatic`, `AutoZoom.segments`, `Sampler` (two functions). Hidden behind it: SCStream configuration, AVAssetWriter fragment handling, event-tap threading, cursor hashing, NDJSON recovery, click grouping, shake filtering, spring fitting and lead-in. Exposed to callers on purpose: the `Project` value, because the editor edits it, and `Take.cursors`, because the renderer decodes PNGs. Nothing else leaks.

What it deliberately does not do: no window or region capture, no webcam, no pause/resume, no multi-display, no flat MP4 (export produces one), no AX focus stream. Each is additive to the format (new event cases, new descriptors) without a version bump.

## Synthesis decision

*Placeholder: filled in by arena.*

## Tradeoffs accepted

- We accept that a capture-side crash takes the whole process down in exchange for one binary, one contract, and no helper signing work; the data survives either way.
- We accept a fragmented `.mov` that is not directly shareable in exchange for crash-safe video without an HLS segment list and a flatten step.
- We accept polling `NSCursor` at 30 Hz in exchange for not needing a private cursor-change notification; the fast path is one identity compare.
- We accept 60 spring steps per query (instead of a cached integrator) in exchange for order-independent results; the cost is microseconds.
- We accept that `start` blocks until the first frame (up to 3 s) in exchange for "recording" meaning "frames are being written".
- We accept rejecting overlapping zoom segments rather than auto-repairing in exchange for the editor finding its own bugs.
- We accept keeping events in global coordinates on disk and converting at load in exchange for a dumb, fast writer.

## Alternatives considered

- Helper process (`osrecd`) driven over stdin/stdout, the Screen Studio shape. Hides capture crashes from the UI but exposes a control protocol, signal semantics, and bundle embedding to every caller, and the crash-survival requirement is met by the format regardless. Lost on surface size for one developer.
- Per-kind event files (`mousemoves.json`, `mouseclicks.json`, …) and a flat MP4, the teardown's layout. Simpler to eyeball, but four orderings to merge, four tail-truncation cases, and a flat MP4 loses the whole take on a crash. Lost on the crash constraint.
- Separate `AVCaptureSession` for the microphone into `mic.m4a`. More device control, but a second clock domain to align and an unfragmentable container. Lost on the one-clock constraint; revisit if SCStream's device selection proves too narrow.
- Cached spring state keyed by last `t` (fast path for sequential playback). Order-dependent by construction; violates deterministic seeking. Rejected outright.
- HLS fMP4 segments plus playlist (polyrecorder's output). Equivalent crash safety, more files, needs a flatten step before AVFoundation can treat it as one asset. Lost on file count.

## Implementation reconciliation

*Placeholder: filled in during implementation.*

## Open questions and risks

- Do SCStream sample-buffer PTS and `CGEvent.timestamp` sit on exactly the same clock on Apple Silicon under macOS 15, or is there a fixed offset to measure? `osrec inspect` prints `pts − startHostNanos` against `firstVideoFrameOffsetNanos` so the first 5 s take answers this.
- Is a fragmented `.mov` left by SIGKILL always openable by `AVAsset`, or does the partial last fragment sometimes need trimming? If trimming is needed, does it belong in `Take.load` (Timeline would then need AVFoundation) or in the renderer?
- The teardown's click-group step reads as grouping mouse moves, not only clicks. This design groups moves plus click positions inside a segment. Is that the behaviour you want, or should groups be built from clicks alone?
- Should `Take.load` refuse a take recorded on a different format version with a migration hook, or is "unsupported version" sufficient for now?
- Is Input Monitoring alone acceptable for the listen-only tap, or do you want the Accessibility fallback for users who granted that first?
- `start` waits for the first frame. Is 3 s the right timeout for a cold SCStream on an external display?

## Next implementation step

Implement `RecordingFormat` (types, Codable, NDJSON with tolerant decode) and `Take.init` with the fixture-free parsing tests, since every other unit consumes that contract.
