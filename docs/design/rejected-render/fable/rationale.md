# Candidate design (fable): renderer, export, and the first app

Sketch: `sketch/` (Swift, bodies `fatalError("not implemented")`). Spike: `spike/main.swift`, numbers under Shape, step 5.

## Problem

Turn a finalized `.osrec` take into pixels, an MP4, and an app. The shape is non-obvious for four reasons. The source movie is variable frame rate (57 to 121 frames for 5 s) and the output must be constant rate. Preview and export must produce the same pixels for the same time and edit state, and an edit must reach a playing preview without rebuilding the player. The compositor is instantiated by AVFoundation and called on its threads, ahead of time and out of order. And the app must keep recording, editing, and exporting as distinct states while persisting edits without touching the recorder's files.

Constraints inherited from the accepted design: `Timeline` is pure and `Sendable`, `frame(at:)` costs 0.33 µs, zoom segments are an input the editor owns, `RecordingFormat` is invisible to Timeline's callers, and `RecordingSession.start` is the only way to record. Timeline exposes no media URL today.

## Usage (caller's view)

The CLI, first visible result:

```
osrec export 20261013-115409.osrec --out zoomed.mp4             # 1080p60 H.264, auto-zoom, default style
osrec export take.osrec --out native.mp4 --size native --codec hevc
osrec frame take.osrec --at 1250 --out frame.png                 # the export's pixels at 1.25 s
```

The app, or anything that edits:

```swift
import Render

var project = try await Project.open(takeURL)       // SourceRecording + edit.json (or the auto-zoom default)
let preview = try Preview(project: project)          // AVPlayer behind it; bind preview.player to VideoPlayer
preview.seek(to: .seconds(1.25)); preview.play()

let next = try project.edit.applying(.deleteZoom(id), source: project.source)   // pure
project.replaceEdit(next)
preview.apply(edit: next)                            // next rendered frame uses it; player untouched
try project.save()                                   // atomic edit.json

let job = Exporter.export(project, to: outURL)
for await p in job.progress { bar.value = p }
let result = try await job.result.value              // result.realTimeFactor >= 1 is the perf target
```

What the caller never sees: `CIImage`, `AVVideoComposition`, the compositor, the frame loop, track IDs, colour tags, or file names inside the take.

## Shape

### Step 1: one composition, two consumers

```
Project ── SourceAsset (AVComposition: screen.mov video + microphone.mov audio, both at t=0)
   │
   └─ RenderPlan (Timeline + Style + output size + cursor atlas)  ── PlanBox ── RenderInstruction
                                                                                      │
                               AVVideoComposition { renderSize, frameDuration = 1/fps, [instruction] }
                                   ├── AVPlayerItem            → Preview (AVPlayer)
                                   └── AVAssetReaderVideoCompositionOutput → Exporter (AVAssetWriter)
```

The brief's path is kept, and both consumers use the very same `AVVideoComposition` and compositor class. That is a stronger guarantee than "one drawing function": the frame cadence, the source-frame selection, and the drawing are shared, so a preview frame and an export frame at the same time are the same request.

`frameDuration` is the VFR-to-CFR conversion. AVFoundation asks for a frame at every tick and hands the compositor the source sample in effect at that time. Render has no frame-stepping loop. The recorder's heartbeat (one frame per second on a still screen) bounds the sample-and-hold gap.

### Step 2: inside a request

```
startRequest(request)
   plan  = instruction.plan.current                      read once (the only mutable cell)
   t     = RecordingTime(request.compositionTime)         TimeBridge: the one CMTime boundary
   frame = plan.timeline.frame(at: t)                     pure, 0.33 µs
   src   = request.sourceFrame(byTrackID:)                420v from the HEVC decoder, may be nil in a gap
   out   = renderContext.newPixelBuffer()                 BGRA, IOSurface, tagged BT.709
   FrameRenderer.shared.draw(src, frame, plan, into: out) Core Image, pure
   request.finish(withComposedVideoFrame: out)
```

The compositor owns nothing per take. `FrameRenderer` is process-wide (one Metal device, one thread-safe `CIContext`), and everything per take rides on the instruction. Order and concurrency cannot change a pixel because every input is immutable or read once.

### Step 3: the drawing, in two spaces

```
source px (y down)  ──viewport crop──▶  CanvasLayout.contentRect (output px, y down)  ──flip──▶  Core Image (y up)
cursor rect = CursorPlacement(cursor, image, pressedScale)  ──same ViewportTransform──▶  one resample, Lanczos
backdrop = background + blurred rounded-rect shadow      cached per (Style, output size)
```

`Geometry.swift` is pure and tested with exact numbers. `Style` lengths are fractions of the shorter output side, so 1080p and native are one picture at two sizes and the preview matches the export without a second set of numbers. The cursor rect is computed in source space (press shrink about the hotspot) and mapped by the same transform as the content, so it grows with the zoom and is resampled once. The shadow blur, the one expensive op, lives in the backdrop, which is a cache of a pure function of (style, output size), at most two entries.

### Step 4: the edit loop and the box

```
ZoomStripView gesture → EditAction → EditDocument.applying (pure, validates ZoomTrack)
       → Editor.apply: undo(previous value), project.replaceEdit, preview.apply (PlanBox.replace), debounced save
```

`PlanBox` is the single mutable cell between the editor and a playing preview. AVFoundation holds the instruction for the life of the item; an edit swaps the plan; the next request reads it. The player is never rebuilt for an edit (per separate-before-serializing-shared-state: one writer, readers snapshot). The exporter builds its own box and never replaces it, so export is frozen by construction and both consumers use one mechanism. Changing the output preset changes `renderSize`, which is a new composition; that rare action builds a new `Preview`.

### Step 5: measured (spike)

On the M2 Max, macOS 27.0.1, with the real 10 s 3456x2234 HEVC take (199 source frames), `spike/main.swift` ran the whole graph at native size, 600 output frames at 60 fps:

- Draw only (reader to Core Image to pooled BGRA): 322 and 351 fps, 5.4x and 5.9x real time; `CIContext.render` 2.2 to 2.5 ms per frame.
- Draw plus HEVC encode (AVAssetWriter): 109 fps both runs, 1.82x real time; `render` 1.9 to 2.1 ms per frame.
- Output verified with ffprobe: 600 frames, 60/1, bt709. The frame at 1.5 s (`frame90.png`) shows the padded, rounded, shadowed content and the cursor at the mapped position.

What limits the number: in export mode the loop is single-threaded and waits on `isReadyForMoreMediaData`, so the 109 fps is the hardware HEVC encoder at 4K, not the drawing. Core Image is therefore the GPU path; a Metal pipeline could at best remove 2 ms from a 9 ms frame budget that the encoder sets. Not measured: 1080p (cheaper on both counts) and an H.264 encode.

### Load-bearing decisions

- **Timeline grows `SourceRecording.media` and `cursorImageURL(_:)`.** It already names the directory and each cursor's relative path, so the movie URLs belong beside them. Render depends on Timeline only and `RecordingFormat` stays unreachable from the renderer (per boundary-discipline, against the importable-internals flag).
- **`edit.json` lives inside the take.** It travels with the take in Finder. It is not a recorder file: the recorder never writes after dropping `.lock`, `load` refuses live and crashed takes, and recovery touches only `recording.json` and `events.ndjson`. Written atomically (temp and rename), versioned, newer versions refused rather than rewritten with fields dropped (per make-operations-idempotent).
- **`EditDocument` holds a `ZoomTrack`, not `[ZoomSegment]`.** A document in memory is always one `Timeline.init` accepts (per type-system-discipline). The reducer is the one place edits are validated; the strip clamps drags so a throw is a bug surfacing.
- **Exporter is reader plus writer, not `AVAssetExportSession`.** Same compositor via `AVAssetReaderVideoCompositionOutput`, but with explicit codec, bitrate, and colour properties, AAC passthrough for the microphone, exact progress, cancellation, and a `.partial` rename on success.
- **Colour: sRGB working and output space, BGRA output tagged BT.709 in both consumers.** The source is BT.709 from ScreenCaptureKit (same primaries as sRGB), so screen content passes through, and AVPlayer's display path and the encoder's YUV conversion read the same tags.
- **Cursor crispness: accepted softness at native size and 2x, mitigated with Lanczos.** The system supplies cursor bitmaps at 1x and 2x only, the recorder stored the 2x. At 1080p the cursor at 2x zoom is a 1.125x resample, effectively crisp. The clean route to crisp at native is a recorder change that tags standard cursors (arrow, I-beam, hand) so the renderer can substitute its own vector drawings; the atlas already has the fallback hook (`defaultArrow`).
- **App phases are an enum with payloads.** `RecordingSession` exists only in `.recording`, `Preview` only in `.editing`, and the editable `EditDocument` only in `Editor.Mode.editing`. While exporting, the frozen document is the only one reachable, so "edit during export" is a type error, not a disabled button (per model-the-domain).

**Interface depth.** Render's public surface: `Project.open/save/replaceEdit`, `EditDocument.applying` and `EditAction`, `Style`, `OutputFormat`, `Preview` (init, apply, seek, play, pause, playhead), `Exporter.export/frame`, `ExportJob`. Behind it: the composition build, the instruction and compositor, the box, Core Image graph and caches, the colour tagging, the y flip, the reader and writer pump, passthrough audio, and partial-file handling. No framework object other than `AVPlayer` (needed for `VideoPlayer`) crosses the boundary.

**What it deliberately does not do:** trims, speed, motion blur (velocities are already in `FrameState`), webcam, masks, a preview render size smaller than the export (not needed at the measured speed), and sandboxing.

## Synthesis decision

*Filled in by arena.*

## Tradeoffs accepted

- We accept one mutable cell (`PlanBox`) in an otherwise immutable render path, in exchange for edits reaching a playing preview with no player rebuild. Purity holds per request because the box is read once.
- We accept rendering the preview at the export size in exchange for identical pixels and no second code path. The spike shows 4K60 draws in 2 ms.
- We accept a cached backdrop, which looks like state across frames, in exchange for keeping the blur out of the per-frame graph. It is keyed by its inputs and holds two entries.
- We accept soft cursors at native output with 2x zoom in exchange for drawing exactly the recorded bitmap now, with a vector substitution route left open.
- We accept AAC passthrough that assumes the recorder's microphone track is AAC in exchange for byte-exact audio and no re-encode. If a recorder ever writes PCM, the writer input needs settings.
- We accept a fifth target (`Render`) that also owns the edit document, in exchange for one module the CLI and the app both import. The document is the renderer's input contract.

## Alternatives considered

- **`AVPlayerItemVideoOutput` plus a Metal view for preview, with a separate export loop calling the same draw function.** Gains: no AVFoundation compositor lifecycle. Loses: the free VFR-to-CFR, AVPlayer's seek coalescing, and the guarantee that preview and export share frame selection. Callers see the same API either way, so it hides nothing more. Rejected.
- **Raw Metal renderer.** Full control and no Core Image overhead, at the cost of shaders for YUV conversion, blur, rounded masks, and Lanczos, and a texture-cache plumbing layer. The spike shows the encoder, not Core Image, bounds export. Rejected until a measurement says otherwise.
- **`AVAssetExportSession`.** Smaller code, but presets decide codec and bitrate, progress is coarse, and audio handling is implicit. Rejected for the reader/writer pair, which exposes the same `ExportJob` surface.
- **Reassign `playerItem.videoComposition` per edit instead of the box.** Keeps the instruction immutable, but rebuilds an AVFoundation composition on every drag tick and depends on AVFoundation's handling of a mid-playback swap. The box is the smaller moving part. Rejected.
- **`edit.json` beside the take (`<name>.osedit`).** Cleaner ownership on paper, but a rename or move in Finder separates the two. Rejected for the user's sake.
- **Render imports `RecordingFormat` for the movie URLs.** Avoids touching Timeline, but makes a third consumer of wire types and the file layout. Rejected; the URL belongs with the other facts about a take.

## Implementation reconciliation

*Empty until implementation.*

## Open questions and risks

- Scrubbing exact seeks on 4K HEVC decode from the previous keyframe. What keyframe interval does the recorder's writer use? If it is long, should drags seek with tolerance and only the release seek exactly?
- Should the output be tagged BT.709 (chosen, widest player compatibility) or sRGB? Players render the two slightly differently in shadows.
- Is 109 fps (1.82x) at native HEVC acceptable as the export ceiling, or should native default to H.264 if its encoder is faster? Not measured.
- `edit.json` inside the take: does anyone object to a non-recorder file in the `.osrec` directory, given `RecordingLayout`'s comment that the recorder is the only writer until finalization?
- Does the recording phase hide the main window and show the floating panel, or stay visible and get recorded? The sketch hides it.
- Sandbox and distribution remain open from the previous unit; the library path `~/Movies/open-studio` assumes no sandbox.

## Next implementation step

Add `SourceRecording.media` to Timeline with a load test, then write `Geometry.swift` with its exact-number tests and `FrameRenderer.draw` lifted from the spike, and wire `osrec export` so the first MP4 of a real take exists before any compositor or app code.
