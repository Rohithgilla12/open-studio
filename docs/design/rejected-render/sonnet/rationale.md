# Candidate design (sonnet): renderer, export, and the first SwiftUI app

Sketch: `docs/design/candidate/sketch/` (Swift, bodies `fatalError("not implemented")`, parses with `swiftc -parse`). Spike: `docs/design/candidate/spike/ThroughputSpike.swift`. The brief was read from the main checkout (`docs/design/brief-renderer-app.md`), because it is untracked and absent from this worktree.

## Problem

Turn the verified Timeline into a picture, an MP4, and an app. The shape is non-obvious for these reasons:

- `AVVideoCompositing` classes are created by AVFoundation and called on its threads, ahead of playback and out of order. Edit state has to reach them without shared mutable state.
- `screen.mov` is variable frame rate, and the output must be constant frame rate with the microphone in sync.
- Preview and export must give the same pixels, and edits must reach a playing preview without a rebuilt player.
- `Timeline` hides `RecordingFormat` behind `internal import`, so today nobody outside it can learn where `screen.mov` is.
- Edit state must persist without touching the recorder's crash-safety directory contract, and the app must make recording, editing, and exporting mutually exclusive by construction.

## Usage (caller's view)

CLI, first deliverable:

```
osrec export 20261013-115409.osrec --out zoomed.mp4 --preset 1080p60
osrec export take.osrec --out big.mp4 --preset 4k60 --codec hevc
osrec still take.osrec --at 1.25 --out frame.png      # same renderer, one frame, for inspection
```

Library, as `osrec` and the app both use it:

```swift
import Project

let project = try await Project.open(takeURL)          // take + studio.json (or auto-zoom defaults)
let plan = try project.plan()                           // immutable: Timeline + Style + OutputSpec
let result = try await project.media.export(plan: plan, to: mp4URL) { print($0.fraction, $0.speed) }
```

The app's editor, per user action and per frame of drag:

```swift
editor.apply(.moveZoom(id, to: t))     // clamps, persists (debounced), rebuilds the plan, swaps it onto the live item
editor.apply(.setStyle(style))
// the player and its item are created once, in EditorModel.init
```

The compositor, per request (AVFoundation's thread):

```swift
let plan = (request.videoCompositionInstruction as! PlanInstruction).plan
let layout = plan.layout(at: plan.recordingTime(for: request.compositionTime), canvas: canvasFromRenderContext)
renderer.draw(layout, sprites: plan.sprites, source: sourceFrame, into: target) { _ in request.finish(withComposedVideoFrame: target) }
```

## Shape

### Step 1: four modules, one direction

```
App ──┐
      ├──▶ Project ──▶ Render ──▶ Timeline ──(internal)──▶ RecordingFormat
osrec ┘        └──────────────────▶ Timeline
Recording (unchanged; App and osrec call it directly)
```

- `Render` imports only Timeline's public API. It never sees a file name: Timeline gains `SourceRecording.media` (`screenVideo`, `microphone`, `cursorImage(id)`), built from `RecordingLayout` internally. That keeps `RecordingLayout` the only place file names appear, with no new loader. Cost: a small addition to Timeline.
- `Project` is new and deep. It joins a take, its edits, its plan, and its media. The app and `osrec export` both start at `Project.open`, so "which zooms and style does this take have" has one answer. The brief's layout had no such module, and without it the CLI and the app would each assemble edits and plans, which is two ways to do one task.
- Call chain for the heaviest path: `EditorModel.apply` → `Project.plan` → `RenderPlan` → `FrameLayout`. Three files after the model.

### Step 2: the frame is a pure function in two halves

```
Timeline.frame(at: t) ─▶ FrameState ┐
Style, canvas size ─────────────────┼─▶ FrameLayout   (pure CPU geometry, unit-tested, no GPU)
sprites (decoded PNGs) ─────────────┘        │
                                             ▼
source pixel buffer ───────────────▶ FrameRenderer.draw  (one Metal pass, draws the layout, decides nothing)
                                             │
                                             ▼
                                     BGRA pixel buffer, tagged BT.709
```

- `FrameLayout.make` holds every decision: aspect-fit of the screen into the padded canvas, viewport-to-canvas mapping `map(p) = content.origin + (p - viewport.origin) * s` with `s = content.w / viewport.w`, and the cursor quad. The cursor scales about its hotspot by `s * sizeMultiplier * (1 - (1 - pressedScale) * pressAmount)`, so a press shrinks toward the click point. These are exactly the "pure geometry tests" the brief wants, and they need no GPU (per boundary-discipline: thin shell, business logic pure).
- The shader draws, per pixel: background, an analytic shadow (the Gaussian-blurred edge of the rounded-rect signed distance, via an erf approximation), the screen sample with SDF edge coverage, the cursor quad clipped to the rounded rect, and a 1/255 dither that is a function of pixel coordinates (so it is deterministic and removes gradient banding in 8 bit).
- Every `Style` length is a fraction of canvas width, so a 1920 px preview and a 3840 px export are the same picture at different sizes.
- State between frames: none. The renderer caches the compiled pipeline, texture uploads of cursor PNGs, and a `CVMetalTextureCache`. Each is a function of immutable inputs (shader source, content-addressed PNG bytes), so determinism holds (per make-operations-idempotent, boundary-discipline).

### Step 3: how the plan reaches AVFoundation

```
TakeMedia (built once per take): AVMutableComposition { screen video track, microphone track }, both at 0
RenderPlan (per edit): Timeline, Style, OutputSpec, sprites          -- immutable value
PlanInstruction: AVVideoCompositionInstruction carrying the plan     -- one, spanning the whole duration
AVVideoComposition: frameDuration = 1/fps, renderSize = canvas, instructions = [that one], customVideoCompositorClass = StudioCompositor
```

- The plan rides inside the instruction. A request is therefore self-describing, with no global, no lookup, no lock (per separate-before-serializing-shared-state: there is no shared state to serialise).
- Edits reach a playing preview without rebuilding the player. `TakeMedia.apply(plan, to: item)` assigns a fresh `videoComposition` to the same `AVPlayerItem`. The `AVPlayer`, the item, the composition, and the decoder session stay. Frames already in flight finish with the old plan, and new requests get the new one, so no frame mixes two edit states.
- The alternative, one mutable box that the compositor reads, was rejected. A frame prefetched before an edit and finished after it would disagree with the one next to it, and invalidation would still need the composition swap.
- Preview canvas is the chosen output's aspect at 1920 long side, so what you see is the export framing. A window resize only scales the layer.

### Step 4: VFR to CFR, and export

`AVVideoComposition.frameDuration = 1/fps` makes AVFoundation request one frame per output tick. For each request, `sourceFrame(byTrackID:)` returns the source frame in effect at that composition time, so a still screen repeats its last frame and a busy one drops extras. The variable-rate source is resampled by the composition itself, and `StudioCompositor` has no timestamp logic. This is the one load-bearing claim I did not measure (see open questions), and it is the first test to write.

```
AVAssetReader(composition)
  ├─ AVAssetReaderVideoCompositionOutput(videoComposition: vc)  ── BGRA frames, CFR ──▶ AVAssetWriterInput(video)
  └─ AVAssetReaderAudioMixOutput(mic track, LPCM 48 kHz)        ── PCM ──────────────▶ AVAssetWriterInput(AAC)
writer: .mp4, writes <name>.partial then renames on success
```

- Export uses the same compositor as preview. There is one drawing path, so "preview equals export" is true by construction, not by a test that compares two implementations. The test that remains compares an extracted export frame with `osrec still` at the same time (the same renderer), with a PSNR bound because H.264 and HEVC are lossy.
- Reader/writer instead of `AVAssetExportSession`, for three reasons. Bitrate, keyframe interval, and colour tags are explicit. Progress and cancellation fall out of the pump loop. The recorder already uses the classic writer path on macOS 15, so there is one convention.
- Audio and video both start at media time 0 in the take, so both are inserted at zero. The microphone range is clipped to the screen duration.
- Presets are data (`OutputSpec`): 1080p30, 1080p60, `native` (the canvas where an unzoomed screen is 1:1: `frame / (1 - 2 * padding)`, so text is pixel exact at scale 1), and 4K60.

### Step 5: colour, GPU path, cursor

- **Colour.** Source is tagged BT.709 primaries, transfer, and matrix, video range, 8-bit 4:2:0 (measured with ffprobe on `20261013-115409.osrec/screen.mov`). The renderer does no colour management. It decodes BT.709 video range to RGB, blends in that encoded space, writes BGRA tagged BT.709 on all three attachments, and the writer is told BT.709 too. `AVPlayerLayer` and the MP4 then carry the same tags, so the display pipeline treats both identically and the source colours are preserved. Generated backgrounds are defined in the same encoded space. The cost is that shadows blend in encoded space, so they look slightly heavier than a linear-light blend. That is accepted for determinism and zero conversion cost.
- **GPU path: one hand-written Metal render pass, with the MSL source embedded as a Swift string and compiled at first use.** The deciding reasons are not speed (see the numbers below). They are: no filter graph whose fusion and intermediate colour spaces I do not control, an analytic shadow and dither that Core Image does not give, and a layout struct that is the whole contract between CPU geometry and GPU. Embedding the source means `swift build` and `swift test` need no Metal toolchain (a separate download on recent Xcode), and the SwiftPM resource bundle is not involved.
- **Cursor crispness.** The recorded PNG is 56 x 80 px at 1:1 with screen pixels (measured). At a 1080p canvas, content width is 1690 px, so `s` is 0.49 at camera scale 1 and 0.98 at 2x: crisp at the zoom where the cursor matters. At a 4K or native canvas, `s` is 0.98 at 1x and 1.96 at 2x, a 2x upscale of a 56 px bitmap, which is soft. I accept the softness and resample with Catmull-Rom on premultiplied alpha, rather than inventing vector replacements for arbitrary system cursors. See open questions.

### Step 6: persistence and the app

- **Edits live in `<take>.osrec/studio.json`**, owned by `ProjectStore`, written by temp file and atomic rename, coalesced at 400 ms, flushed on leaving the editor and before export. It is a new file the recorder never reads or writes. No recording file changes. Recovery runs only on unfinalised takes, which the editor refuses to open. So the crash contract is untouched, and the take plus its edits move, copy, and archive as one package. Beside the take was rejected because it orphans on rename and copy.
- `EditState` (zooms, timeline settings, style, output choice) is the single source of truth. `Timeline` and `RenderPlan` are derived from it, never the reverse. A take with no file gets `EditState.initial`, which is deterministic (AutoZoom's ids derive from ranges), so nothing is written until the first real edit.
- Zoom edits are pure functions (`ZoomEditing`) that clamp to neighbours and to `[0, duration]`, so the editor cannot produce the overlap `ZoomTrack(validating:)` rejects.
- **App state is one enum** (`AppPhase`): `home`, `recording(RecordingFlow)`, `editing(EditorModel)`, `exporting(ExportFlow)`. Each case owns only its data. `exporting` holds the parked editor and a frozen plan. Edits cannot race the export because the phase that has editing controls is not current, and `beginExport` flushes the store first.
- Recording goes through `RecordingSession` as `osrec` does. `RecordingFlow` encodes starting, live, and finishing, and `stop()` is already memoised by the session.
- **Permissions.** `PermissionsBanner` lists what `Permissions.check()` reports missing, with buttons that open the Screen Recording and Input Monitoring panes, and shows `Permissions.responsibleProcess`. Ad hoc signing gives each build a new code identity, so macOS drops the grants. A developer signs with a stable Apple Development identity and a fixed bundle id, so the designated requirement survives rebuilds. When a grant goes stale anyway, `tccutil reset ScreenCapture <bundle id>` and `tccutil reset ListenEvent <bundle id>` clear it.
- **Packaging.** Keep the accepted checked-in `App/OpenStudio.xcodeproj`. The objection to hand-edited `.pbxproj` churn is answered by Xcode's file-system-synchronised root group for `App/OpenStudio/`: new Swift files do not touch the project file. No `xcodegen`.

**Interface depth.** Render's public surface is `RenderPlan`, `Style`, `OutputSpec`, `TakeMedia` (`makePlayerItem`, `apply`, `export`, `still`), and the progress and result values. Behind it sit the compositor, the instruction, the Metal pipeline, the geometry, sprite decoding, the CFR resampling, the reader and writer pumps, colour tagging, and partial-file handling. Project's surface is `open`, `with`, `plan`, `ProjectStore.{load, scheduleSave, flush}`, and `ZoomEditing`. A caller coordinates no stages: there is no "set up compositor, then set up instruction, then set up reader". The app and the CLI do not see AVFoundation types except `AVPlayerItem` and `AVPlayer` in the editor.

### Measured (spike, not through AVFoundation)

Apple M2 Max, macOS 27.0.1, take `20261013-115409.osrec` (3456 x 2234 HEVC). Sixty decoded frames cycled 300 times, camera sweeping scale 1 to 2, one cursor sprite, BGRA output, GPU work waited per frame. Source: `spike/ThroughputSpike.swift`.

| Item | 3840 x 2160 | 1920 x 1080 |
|---|---|---|
| HEVC decode to 420v, reader only | 4.1 ms/frame | same |
| Core Image chain (crop, scale, rounded mask, blurred shadow, gradient, cursor) | 2.44 ms | 1.12 ms |
| One Metal pass | 0.67 ms | 0.47 ms |

- The Metal shader compiled from source took 298 ms cold and 0.1 ms on a second process run.
- The 4K Metal output was inspected visually: gradient, rounded corners, shadow, zoomed screen, and the cursor are all drawn correctly. The Core Image output was not inspected, so its number only says the chain ran.
- At 4K60 the budget is 16.7 ms per frame. Decode plus Metal is about 4.8 ms, so those two have about 3x headroom. Encode, the compositor handoff, and the real pipeline were not measured, so "4K60 export at or faster than real time" is unproven. Core Image would also fit the budget, which is why the choice rests on the reasons above and not on speed.

## Synthesis decision

*Filled in by arena.*

## Tradeoffs accepted

- We accept a hand-written shader to maintain (about 70 lines now) in exchange for one deterministic pass and no filter-graph surprises. Core Image would be less code and is fast enough.
- We accept a runtime shader compile (298 ms cold) in exchange for no Metal toolchain requirement and no resource bundle.
- We accept blending shadows in encoded space in exchange for zero colour conversion and an exact match with the source's tags.
- We accept reassigning `videoComposition` on edit, and the possible hiccup that causes in a playing preview, in exchange for immutable per-request state. The editor pauses playback during a drag to avoid it.
- We accept a 1920 px preview canvas in exchange for one fixed render size and a cheap resize. A large Retina window shows a scaled picture.
- We accept soft cursors on 4K and native canvases at 2x zoom in exchange for rendering from the recorded bitmaps only.
- We accept a new `Project` module in exchange for one way from a take to a plan, shared by the CLI and the app. It may look like a pass-through layer, but it owns edits, persistence, and plan construction.
- We accept `studio.json` inside the `.osrec` package in exchange for portability. Something that hashes or syncs the directory sees a new file after the first edit.
- We accept an `osrec still` command beyond the brief's `export`, in exchange for a verification surface that goes through the real renderer.

## Alternatives considered

- **`AVPlayerItemVideoOutput` plus a Metal view for preview, with a separate export loop.** It avoids AVFoundation's compositor threading and gives full control over frame pacing. It would need an A/V sync clock, scrubbing logic, and two drivers around one drawing function. It hides less behind the interface: the editor would own clocks and display links. Rejected, since the custom compositor already gives sync, scrubbing, and one pipeline. We give up direct control of prefetch.
- **Core Image for the draw.** It has the shortest code and measured 2.44 ms at 4K. It exposes filter-graph and working-space decisions to the implementer, has no analytic shadow, and its blur costs more as the radius grows. Rejected on control and on one-struct CPU/GPU contract, not on speed.
- **A mutable `EditBox` read by the compositor.** It keeps a single composition, but a frame prefetched before an edit and finished after it can disagree with its neighbours, and invalidation still needs a composition swap. Rejected for shared mutable state.
- **A separate hand-written export loop (reader of source frames, own CFR sampler, own render).** It would give exact control of VFR resampling and drop AVFoundation from export. It creates a second path to pixels, which breaks preview equals export by construction. It is the fallback if the `frameDuration` resampling test fails.
- **Edits beside the take (`take.osrec.studio`).** Safer against directory hashing. Rejected for orphaning on rename and copy.
- **`AVAssetExportSession`.** Less code. No control of bitrate, colour tags, or keyframe cadence, and a coarser progress model. Rejected.

## Implementation reconciliation

Nothing implemented yet.

## Open questions and risks

- Does a 1/60 s `frameDuration` on the composition resample the variable-rate `screen.mov` the way this design assumes, including a long still stretch at the 1 s heartbeat cadence? If not, is a source-frame-and-hold sampler inside the exporter acceptable, at the cost of a second path?
- Does reassigning `item.videoComposition` while playing cause a visible stall, and how bad is it at 1920 px? If it does, should dragging always pause?
- Is 4K60 HEVC export at or above real time with the real pipeline, encode included? The spike covers decode and draw only.
- Should the recorder capture cursor images at a higher scale where the system offers one, so that 2x zoom on a 4K canvas stays crisp? That is a Recording and format change, not a renderer one.
- Is `StudioCompositor.cancelAllPendingVideoCompositionRequests` safe if committed GPU work finishes and calls `finish` afterwards? If not, a generation flag is needed.
- Should output colour be tagged BT.709 as the source is, or Display P3 or sRGB for a wider-gamut deliverable? That would add a conversion pass.
- Does `studio.json` inside the package interact badly with any sync or backup tool the user runs on the library?

## Next implementation step

Write `FrameLayout` with its pure tests (viewport mapping, aspect fit, cursor scale about the hotspot), and in parallel a throwaway test that runs a one-frame-per-tick `AVAssetReaderVideoCompositionOutput` with a trivial compositor over a real VFR take at `frameDuration = 1/60`, asserting the output count and constant timestamps. That test decides whether Step 4 stands.
