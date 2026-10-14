# Accepted design: renderer, export, and the first app

Sketch: `docs/design/accepted-render/sketch/`. It is a SwiftPM package that depends on the root package by path, and it builds with tests (`swift build --build-tests` from the sketch directory). So every signature here type-checks against the real `Timeline` and `Recording` products. Bodies are `fatalError("not implemented")` with TODO pseudocode. Proposed Timeline changes are in `sketch/Proposed/Timeline/` because they use Timeline internals. `sketch/Sources/Render/TimelineShims.swift` stands in for them. Spike: `docs/design/accepted-render/spike/main.swift`, with numbers under [Spike results](#spike-results-measured).

## Problem

Turn a finalised `.osrec` take into a styled picture three ways: a preview that plays and scrubs, an MP4 export, and a single still. All three must give the same pixels for the same time and edit state. The shape is not obvious for five reasons.

- AVFoundation instantiates the compositor itself and calls it on its own threads, ahead of time and out of order. Data reaches it only through the instruction object.
- An edit must reach a playing preview without rebuilding the player, yet a frame must stay a pure function of (source frame, frame state, style, output size).
- `screen.mov` has a variable frame rate, and the output must be constant 30 or 60 fps with the microphone in sync.
- Timeline hides file names behind `internal import RecordingFormat`, so today no public API yields `screen.mov`'s URL.
- Edits must persist and survive restarts without touching the recorder's files, and `osrec export` must render what the app shows.

Constraints from Phase A that this design honours. Timeline is immutable, `Sendable`, and answers `frame(at:)` in about 0.33 µs. Zoom segments are editor-owned input. `ZoomTrack(validating:)` is the only way to build a track. Packaging stays SwiftPM at the root with a thin checked-in Xcode project in `App/`. The deployment target is macOS 15.

## Usage (caller's view)

The command line, which ships first:

```
osrec export 20261013-115409.osrec --out demo.mp4                  # project.json if present, else auto zooms; 1080p60 HEVC
osrec export 20261013-115409.osrec --out demo-native.mp4 --size native
osrec export 20261013-115409.osrec --still 1200 --still 4200        # PNGs through the same compositor
osrec export 20261013-115409.osrec --out raw.mp4 --auto-zooms       # ignore saved edits
```

Library callers (the `Studio` app module and `osrec`):

```swift
import Render
import Timeline

var project = try Project.open(takeURL)            // metadata + project.json, or generated defaults; never writes
project.edits.zooms = project.edits.zooms.removing(segmentID)   // total edit; timeline rebuilds on didSet
project.edits.style.padding = 0.06
try project.save()                                 // atomic <take>.osrec/project.json

let report = try await Export.run(project, to: outURL) { p in bar.update(p.fraction) }
print(report.realTimeFactor)                       // >= 1 is the brief's bar for 4K60

let png = try await Still.png(project, at: .milliseconds(4200))
```

The editor, inside the app's `Editor` class:

```swift
let preview = try await PreviewPlayer(project: project)   // AVPlayer with the styled composition
playerLayer.player = preview.player

// a zoom block drag, per mouse event, then once at the end
editor.moveZoom(id, toStart: strip.time(atX: x))   // drag step: edits + preview.show(project), no undo yet
editor.endDrag("Move Zoom")                        // one undo step, autosave in 1 s
```

## Shape

### Step 1: module map

```
                       App/  (Xcode: @main, Info.plist, entitlements, signing)
                         │ one line: StudioScene()
                         ▼
  osrec ──────────▶   Studio   (SwiftUI views + StudioModel state machine; SwiftPM library)
    │                 │     │
    ▼                 ▼     ▼
  Render ◀────────────┘   Recording
    │                         │
    ▼                         ▼
  Timeline ── internal import ─ RecordingFormat ─ internal import ──┘
```

- **`Render` is new and owns everything between a take and pixels.** That covers the project document, style, geometry, the Core Image recipe, the compositor, the composition builder, preview, export, and stills.
- **`Studio` is new and holds the whole app as a package library.** The Xcode target is one `@main` line plus bundle files. So `swift build` type-checks every view, and `swift test` reaches the editor logic. The brief's `App/OpenStudio/` holds only what must live in a bundle.
- **Timeline gains the media URLs** (`screenMovie`, `microphoneMovie`). The file names stay in `RecordingLayout`, and Timeline stays the one public reader of a take. `CursorImageInfo.relativePath` is the precedent: Timeline already hands the renderer cursor file locations. `hasMicrophone` becomes derived from `microphoneMovie != nil`, so there is one source of truth.

### Step 2: a project is a take plus one edits value

```
<take>.osrec/
  recording.json  events.ndjson  screen.mov  microphone.mov  cursors/   ◀── recorder's, never written
  project.json                                                          ◀── editor's, atomic replace

Project.open(take)
  ├─ SourceRecording.load(take)                        (Timeline: metadata, never media)
  ├─ project.json ? decode (validated) : Edits(AutoZoom.track, .default, .default, .hd1080)
  └─ timeline = Timeline(source, edits.zooms, edits.settings)   derived; rebuilt on every edits change

Edits { zooms: ZoomTrack, settings: TimelineSettings, style: Style, format: OutputFormat }
```

- **Edits live inside the take** at `project.json`. Moving, copying, or deleting a take in Finder carries its edits, and the library has one item per take. The recorder's crash-safety contract holds. Recovery and the reader address files by name and never enumerate the directory (checked in `Recovery.swift` and `RecordingSession.swift`, whose only `removeItem` calls run during a failed `start`). The editor never opens a take that is not finalised, because `SourceRecording.load` throws `.stillRecording` or `.needsRecovery` first.
- **`Edits` is one value**, per model-the-domain. Undo keeps the previous value, autosave encodes the current value, and export snapshots by copy. `timeline` is derived in `didSet`, never stored beside the edits by hand.
- **The chosen output format is part of the edits**, because the preview renders at it (step 4).
- **Decoding must validate.** Today `TimeRange` and `ZoomTrack` synthesise `init(from:)`, which bypasses `init?(start:end:)` and `init(validating:)`. A hand-edited `project.json` could build the overlapping track the types promise cannot exist. The proposal gives both explicit decoders. The settings structs decode each key with `decodeIfPresent ?? default`, so a project saved before a new setting existed still opens. This is a latent defect in today's Timeline, independent of this design.
- **Zoom edits are total methods on `ZoomTrack`**: `removing`, `moving(toStart:within:)`, `resizing(edge:to:within:)`, `inserting(around:...)`, and `updating`. They clamp to neighbours and to `[0, duration]` instead of throwing. The type that owns the invariant owns the operations, so the zoom strip cannot hold a rejected edit. `init(validating:)` remains the only throwing door.

### Step 3: one composition, three consumers

```
Project ──▶ RenderScene.make(project, format, reusing: previous)       immutable, Sendable
              { timeline, CanvasLayout, pressedScale, SceneAssets }
                         │
MovieComposition.load(source)          (once per take: AVMutableComposition with screen + mic at t=0)
  .videoComposition(scene, fps)        (per edit, no I/O: frameDuration, renderSize, 709 tags,
                         │              SceneInstruction(scene), customVideoCompositorClass)
          ┌──────────────┼───────────────────┐
     AVPlayerItem   AVAssetReaderVideo-   AVAssetImageGenerator
      (preview)     CompositionOutput      (stills, later thumbnails)
                    + AVAssetWriter
                      (export)
          └──────────────┴───────────────────┘
                         ▼
                 StyledCompositor  (the only drawing entry point)
```

- **One builder, three consumers.** Preview, export, and stills get their `AVVideoComposition` from the same `MovieComposition.videoComposition(scene:frameRate:)`. Agreement between preview and export is structural. No two code paths have to be kept in step.
- **The instruction carries an immutable `RenderScene`.** The instruction is the only channel into a compositor that AVFoundation instantiates. The spike confirmed that the scene stored on a custom instruction reached all 600 requests. Nothing about a scene ever changes after construction, so compositor threads share it without locks.
- **VFR to CFR happens in the composition, not in a loop.** `frameDuration = 1/fps` makes AVFoundation request a frame at every multiple of the frame duration and hand over whichever source sample covers that time. Measured: 200 source frames over 10 s became 600 output frames spaced exactly 1/60 s apart. The export loop is then a plain pump with no drop or duplicate logic. `sourceTrackIDForFrameTiming` stays unset for this reason.
- **Audio** is the microphone track inserted at time 0, because media time 0 in both files is recording time 0. AVPlayer plays it in sync, and export decodes it to LPCM and re-encodes AAC at 48 kHz. Re-encoding sidesteps AAC priming and packet boundaries at the trimmed tail. For a voice track the quality cost is negligible.

### Step 4: one frame inside the compositor

```
startRequest(request)                      on AVFoundation's thread; returns immediately
  └─▶ work queue (concurrent, 2 in flight; stale generation ⇒ finishCancelledRequest)
        t      = RecordingTime(request.compositionTime)             the one CMTime bridge
        state  = scene.timeline.frame(at: t)                        0.33 µs, pure
        geo    = FrameGeometry(state, scene.layout, cursorInfo)     pure, top-left canvas px
        image  = FrameRecipe.image(source 420v, geo, layout, assets) Core Image recipe, pure
        RenderDevice.context.render(image → pooled BGRA buffer, BT.709)
        request.finish(withComposedVideoFrame:)
```

- **Geometry is pure and GPU-free.** `CanvasLayout` holds the content rect, radius, and shadow for (style, canvas, source). It is computed once per scene. `FrameGeometry` maps source pixels to canvas pixels with `q = content.origin + (p − viewport.origin) · k`, where `k = content.width / viewport.width`. The viewport and the content rect share the source's aspect, so one `k` serves both axes. Tests pin all of it without a GPU. Core Image's bottom-left origin appears in exactly one function, `FrameRecipe.flipped`.
- **Cursor transform.** `drawScale = k · (1 − (1 − pressedScale) · pressAmount)`, `rect.origin = q − hotspot · drawScale`, and `rect.size = declaredSize · drawScale`. The cursor scales with the camera like the rest of the screen, and the press pivots on the hotspot, so the tip stays on the click. It is skipped when `!isVisible` and multiplied by `opacity`. One rounded mask clips screen and cursor together, so the cursor leaves through the screen's edge instead of floating over the padding.
- **Cursor crispness comes from higher-resolution captures, with no format change.** The spike found that `NSCursor.arrow` carries 28×40, 56×80, 140×200, and 280×400 pixel representations, while the recorder stored the 56×80 one. The renderer always draws a PNG into its *declared* size and never uses the image's pixel size. So the recorder can store the largest representation (5× the screen pixels) under the same declaration, and old readers stay correct. A 4K export at 2× zoom needs about 1.85× the declared pixels, and a 280×400 capture supplies 5×. Takes recorded before the change upscale with Lanczos and are visibly soft at 2× zoom. That is accepted.
- **Style lengths are fractions of the canvas's shorter side.** A 1080p export, a native export, and the preview are one picture at three resolutions, and switching the preset never changes the look.
- **The backdrop is pre-rendered.** The gradient, shadow blur, and background image depend only on (style, canvas, source), so `SceneAssets` renders them once into a bitmap. Per frame, the backdrop is one texture read. While the user drags a zoom, `RenderScene.make(reusing:)` keeps the previous assets, because only the Timeline changed.
- **Lanczos for the screen content.** Shrinking a 3456 px screen into a 1400 px inset with bilinear sampling aliases text. In the spike, Lanczos cost 1.7 ms per 4K frame of serial latency over bilinear (10.5 against 8.8 ms), which the budget absorbs.
- **Colour.** Core Image works in extended linear sRGB and writes BGRA buffers converted to and tagged ITU-R BT.709. The video composition and the writer both declare 709 primaries, transfer function, and matrix. The source is 709 too (measured on the real take: bt709, bt709, bt709, video range). Preview and export reach the display through the same tagged buffers, so they match. Style colours are sRGB values that only the renderer interprets.
- **GPU path: Core Image on Metal, no hand-written shaders in v1.** Core Image fuses crop, resample, mask, and composite. It reads 4:2:0 YCbCr with the matrix from the buffer attachments and renders into AVFoundation's IOSurface-backed pool without copies. The measured throughput clears the brief (see below), so a Metal pipeline would add YUV conversion, colour management, and shader code for no requirement. Motion blur can arrive later as a Metal-language `CIKernel` inside `FrameRecipe` without changing the shape.
- **Concurrency without shared mutation.** The compositor's only mutable state is AVFoundation's render context and a cancellation generation, both in one `Mutex`. `cancelAllPendingVideoCompositionRequests` bumps the generation, so queued requests from before a seek finish as cancelled instead of rendering frames nobody will see.

### Step 5: an edit reaching the playing preview

```
ZoomStrip drag ─▶ editor.drag { $0.zooms = $0.zooms.moving(id, …) }     Project.edits didSet → new Timeline
              ─▶ preview.show(project)       coalesced to 30 Hz, latest wins
                   └─▶ RenderScene.make(reusing: scene)  ─▶  item.videoComposition = new composition
                       paused? zero-tolerance seek to the current time (open question 1)
gesture end   ─▶ editor.endDrag("Move Zoom") ─▶ one undo step ─▶ autosave after 1 s ─▶ project.json
```

- **Replace, never mutate.** An edit builds a new scene and assigns a new video composition to the existing `AVPlayerItem`. The player and the item survive, which is what the brief asks. The alternative, a mutable scene box that the instruction reads, makes the same composition time render differently depending on when AVFoundation happens to ask. That breaks determinism, and it puts two writers on one object. Per separate-before-serializing-shared-state, the sharing is removed rather than locked.
- **`PreviewPlayer` owns this rule**, so no view knows that an edit means "new scene, swap composition, refresh if paused". The editor calls `show(project)` after every change.
- **Preview renders at the export canvas.** The layer scales it to the view, so what plays is what exports. At the largest preset (3840×2160) a frame took 10.5 ms when rendered serially, and two requests in flight sustained 125 fps without a writer, about twice what 60 fps playback needs (measured, one run each).

### Step 6: the app's states

```
            startRecording()                 stop() or self-ended stream
   home ─────────────────────▶ recording ─────────────────────────────▶ editing(Editor)
    ▲  ◀────────── closeEditor() ─────────────────────────────────────────  │  ▲
    │                                                         export(to:)  ▼  │ dismissExport()
    └── open(take) from home or editing ───────────▶ editing        exporting(ExportJob{editor})
```

- **`StudioModel.phase` is an enum whose cases carry their own data**, per model-the-domain: `.home`, `.recording(LiveRecording)`, `.editing(Editor)`, `.exporting(ExportJob)`. No state holds a session and an editor together. Exporting holds the editor it returns to, and the job exports a `Project` value copied at start. Every intent opens with `guard case` on the phase, so a stale button press in the wrong phase is a no-op.
- **Recording goes through `RecordingSession` exactly as `osrec` does.** The app hides its window once `start` returns, and a `MenuBarExtra` carries Stop. Stop and a self-ended stream converge, because `RecordingSession.stop()` is idempotent. A finished take opens straight into the editor.
- **Launch runs `RecordingSession.recover(at:)` over the library**, which is idempotent and a no-op for finalised takes. Opening a take that throws `.needsRecovery` recovers and retries once.
- **Permissions.** Home shows each missing permission with "Open System Settings" (`Permission.settingsURL`), and re-checks on `didBecomeActiveNotification`, which fires when the user comes back from Settings. Screen Recording and Input Monitoring need a relaunch, so a granted-but-not-live state offers Relaunch.
- **TCC and rebuilds.** TCC keys a grant to the app's designated requirement. An ad hoc ("Sign to Run Locally") build's requirement is its cdhash, which changes on every rebuild, so each rebuild loses the grants. A stable Apple Development identity (a free personal team works) makes the requirement the bundle id plus the team, which survives rebuilds. The team id lives in a gitignored `App/Config/Local.xcconfig` included from the checked-in `Base.xcconfig`. Without an Apple ID, a self-signed code-signing certificate named there does the same. `tccutil reset ScreenCapture dev.openstudio.OpenStudio` starts over.
- **The Xcode project uses a synchronised folder** (`PBXFileSystemSynchronizedRootGroup`), so adding a file never edits `project.pbxproj`. With the app code in the package, the target has four files. That removes the churn argument for `xcodegen`, so the accepted "no generator" decision stands.

### Interface depth

Render's public surface is `Project` (with `open`, `edits`, `save`, and `regenerateZooms`), the `Edits`, `Style`, and `OutputFormat` values, `PreviewPlayer` (with `show`, `play`, `pause`, `scrub`, and `playhead`), `Export.run`, `Still.png`, and three error enums. Behind it sit composition building, VFR to CFR, compositor threading and cancellation, the Core Image recipe, colour management, the cursor transform, asset caching, the edit-to-preview rule, the reader and writer pump, audio muxing, and atomic saves. `RenderScene`, `SceneInstruction`, `StyledCompositor`, `MovieComposition`, `CanvasLayout`, and `FrameGeometry` are internal, so an agent cannot assemble its own composition and drift from the shared one. No AVFoundation type appears on the public API except `PreviewPlayer.player`, which an `AVPlayerLayer` needs.

**What it deliberately does not do.** It has no trims or speed changes. Composition time equals recording time, and the one place a time map would go is `RecordingTime(request.compositionTime)`. It has no motion blur, masks, webcam, or captions. It has no per-segment style, no cursor size setting, and no custom backgrounds beyond solid, generated gradient, and a picked image copied into the take.

### Spike results (measured)

Measured on 2026-10-14 on an Apple M2 Max with macOS 27.0.1, from `spike/main.swift` built with `swiftc -O`. The source is the D4 take `20261013-115409.osrec`: 3456×2234 HEVC, 10.000 s, 200 frames (variable rate). The camera is a synthetic 1× to 2× zoom sweep standing in for `Timeline.frame(at:)`, whose cost is 0.33 µs and does not matter here. The load average was 6 to 8 during the first runs and 3 during the repeats.

| Output | In flight | Writer | Fps | Real time | Runs |
|---|---|---|---|---|---|
| 3840×2160 @ 60, bilinear | 1 | HEVC | 96.6 | 1.61× | 1 |
| 3840×2160 @ 60, Lanczos | 1 | HEVC | 92.0 | 1.53× | 1 |
| 3840×2160 @ 60, Lanczos | 1 | none | 92.2 | 1.54× | 1 |
| 3840×2160 @ 60, Lanczos | 2 | HEVC | 100.8, 101.9, 102.3 | 1.68 to 1.70× | 3 |
| 3840×2160 @ 60, Lanczos | 4 | HEVC | 97.4 | 1.62× | 1 |
| 3840×2160 @ 60, Lanczos | 2 | none | 125.2 | 2.09× | 1 |
| 3840×2160 @ 60, Lanczos | 4 | none | 141.7 | 2.36× | 1 |
| 3456×2234 @ 60 (native), Lanczos | 2 | HEVC | 106.0 | 1.77× | 1 |
| 1920×1080 @ 60, Lanczos | 2 | HEVC | 277.5 | 4.63× | 1 |
| 1920×1080 @ 60, Lanczos | 2 | none | 363.2 | 6.05× | 1 |

- **Every run did the work.** Each produced 600 frames, reader and writer finished with status completed, and `ffprobe` on the 4K output reports HEVC 3840×2160, 600 frames, `r_frame_rate` 60/1, and bt709 for all three colour fields. An extracted frame at 4.2 s shows the gradient, the shadow, the rounded inset, the zoomed content cut at the viewport edge, and the cursor.
- **Limiter.** With one request in flight, the writer made no difference (92.0 against 92.2 fps), and 600 requests at 10.5 ms each account for the wall time. So the serial compositor was the limit. With two or four in flight, render alone reaches 125 to 142 fps, but the export stays near 100 fps. So the writer side (HEVC encode, or media-engine and GPU contention) caps the export. That limiter is inferred from these runs, not profiled. It is why `maxInFlight` is 2. Four bought nothing with the writer attached.
- **Against the brief.** A 4K60 export runs at 1.7× real time (three runs, spread 100.8 to 102.3 fps). Preview at 60 fps needs 60 renders a second, and render alone sustained 125 at 4K. Scrubbing was not measured (open question 2).

## Synthesis decision

Three runners (Opus, Fable, Sonnet) sketched the brief independently in their own worktrees. A Fable cross-judge scored them against a six-point rubric: Opus 29, Fable 20, Sonnet 19. I read all three end to end and picked the same base, Opus, for three reasons. It is the only candidate whose spike ran the real `AVVideoCompositing` path with the writer attached and measured the variable-to-constant frame rate conversion. Its edits reach the compositor as immutable scenes, with no shared mutable cell. Its sketch type-checks against the real `Timeline` and `Recording` products. The other candidates are kept in [`../rejected-render/fable/`](../rejected-render/fable/) and [`../rejected-render/sonnet/`](../rejected-render/sonnet/).

All three converged on one `AVVideoComposition` shared by preview and export, `frameDuration` for the frame-rate conversion, a reader and writer pump instead of `AVAssetExportSession`, edits saved inside the take, media URLs added to Timeline, and an app phase enum with payloads. That convergence is treated as settled.

**Grafted.**

1. **The `native` preset makes unzoomed text 1:1** (from Sonnet). Its canvas is `frame / (1 - 2 * padding)` on the shorter side, so at camera scale 1 each source pixel lands on one output pixel. It replaces "the source's own size" as the meaning of `--size native`.
2. **`project.json` records the take's `recordingID`** (from Sonnet). `Project.open` ignores a `project.json` whose id does not match the take, so a file copied between takes cannot apply the wrong zooms.
3. **`project.json` refuses newer versions** (from Fable). A project written by a newer build fails to open with a clear error, and is never rewritten with unknown fields dropped.
4. **Export writes `<name>.partial` and renames on success** (from Fable and Sonnet), so a failed or cancelled export never leaves a truncated MP4 under the final name.
5. **The pre-rendered backdrop is dithered** (from Sonnet's shader). A gradient in 8-bit BGRA bands. The dither is a deterministic function of pixel position, applied once when `SceneAssets` renders the backdrop, so it costs nothing per frame.
6. **The recording phase distinguishes starting, live, and finishing** (from Sonnet's `RecordingFlow`), so the record button cannot be pressed twice while `RecordingSession.start` is waiting for the first frame.

**Rejected.**

- Fable's `PlanBox`, a mutable cell read by the compositor. Frames rendered ahead keep the old plan with no flush, and a paused player never shows the edit. Per separate-before-serializing-shared-state, the sharing is removed rather than guarded.
- Sonnet's hand-written Metal pass. It is faster per draw (0.67 against 2.44 ms at 4K), but the measured export limit is the writer, so the speed buys no requirement, and the shader adds colour and YUV code to maintain.
- Sonnet's separate `Project` module and its 1920 px preview canvas. The module is a layer over `Render` with no capability of its own, and a smaller preview canvas makes preview equal export only up to scale.
- Fable's AAC passthrough. Re-encoding trims the microphone exactly at the video's end.

**Review notes carried into implementation.** The judge flagged that requests already in flight after a seek still render. The compositor checks the cancellation generation again just before rendering, not only when dequeuing.

## Tradeoffs accepted

- We accept that each edit makes AVFoundation drop its rendered-ahead preview frames (coalesced to 30 Hz) in exchange for immutable scenes, deterministic frames, and no shared mutable state between the editor and compositor threads.
- We accept rendering the preview at the full export canvas (up to 3840×2160) in exchange for the preview being literally the export. A smaller preview canvas would cost less GPU but would make "what you see" a different resolution of the same function.
- We accept Core Image's control over filter internals in exchange for fused passes, YUV and colour handling from buffer attachments, and no shader code to maintain. Bit-identical output across runs on one machine is expected and checked by the pixel test. It is not promised across GPU families.
- We accept re-encoding the microphone AAC in exchange for exact trimming at the video's end without AAC priming and packet-boundary errors.
- We accept that takes recorded before the cursor change look soft at 2× zoom in 4K exports, in exchange for keeping the recording format unchanged.
- We accept writing `project.json` inside the recorder's directory, in exchange for takes that carry their edits when moved. The cost is one rule the reader and recovery already follow: ignore unknown names.
- We accept a second package library (`Studio`) for the UI in exchange for an Xcode target of four files, a UI that type-checks under `swift build`, and app logic that `swift test` reaches.
- We accept the cursor being clipped by the screen's rounded edge, which matches the content it points at, in exchange for one mask instead of two.

## Alternatives considered

- **`AVPlayerItemVideoOutput` with a Metal view for preview, and a hand-run render loop for export.** Edits would show on the next display refresh with no flush, and the preview would draw at view size. It exposes more to callers. Someone has to pace frames against the audio clock, handle seeks, and keep a second render driver that matches the composition used for export. The shared drawing function would survive, but preview and export would run under two drivers, so "same pixels" would rest on a test instead of on construction. It lost on interface depth.
- **A mutable scene box shared between the editor and the instruction.** It has no composition swap and no frame flush. It makes a frame depend on when it was rendered, so determinism fails, and it creates a second writer on one object. Rejected per separate-before-serializing-shared-state.
- **A Metal pipeline with one fragment shader** that samples the YUV planes, computes an analytic rounded-rect mask and box shadow, and draws the cursor as a second quad. It probably has the highest ceiling, but the measured Core Image path already clears the brief with the writer as the limit, so the extra speed buys no requirement. It costs YUV-to-RGB conversion, colour tagging, and shader maintenance.
- **`AVAssetExportSession` with the custom composition.** Less code, and it muxes audio itself. It offers preset-only bitrate control, coarse progress, and no say in colour tags beyond the composition's. The spike's reader and writer pump is under 30 lines, and it gives per-frame progress, cancellation, and explicit encoder settings.
- **Edits beside the take** (`20261013-115409.osproj`). It never writes into the recorder's directory, but a Finder move, rename, or delete separates the take from its edits, and the library must pair files by name.
- **Renderer imports `RecordingFormat` for `RecordingLayout.screen`.** It needs no Timeline change, but a third module would depend on the wire module, and the renderer would hold two models of a take (`SourceRecording` and `RecordingLayout`) that can disagree.

## Implementation reconciliation

### D6: recorder cursor

This settles open question 3. The recorder now rasterises each cursor at the largest density its image offers. `size` and `hotspot` stay in screen pixels, so the declaration and the format are unchanged.

- `CursorRaster` (in `Sources/Recording/CursorRaster.swift`) is the pure plan. It takes the image's point size, hotspot, display scale, and representation pixel widths. It returns the PNG pixel size and the declared screen-pixel size and hotspot.
- The stored density is capped at 5× the screen pixels, and at 1024 px on the longer edge. 5× is the arrow's largest representation on a 2× display. It covers a 2× zoom in a 4K export from any source at least 1536 px wide. The edge cap bounds the PNG for oversized custom cursors. A resolution-independent representation rasterises at the cap.
- `CursorImage.render` draws into a bitmap of exactly the planned size. `NSImage` hands back its best representation, which can be larger than the cap, so the extra draw keeps the cap exact. It also makes the same cursor yield the same bytes, so dedupe within a take still gives one image id.
- The declared size is now `points × displayScale`, not the pixel size of whichever representation `NSImage` returned. They match for the arrow, the pointing hand, and the crosshair (measured with a probe). A cursor with only a 1× representation would have been declared at half its screen size on a 2× display (inferred: the probe shows `NSImage` returns its largest representation when the hint asks for more). Now it gets the right declaration and a 1× PNG that the renderer upsamples.

Measured on a real 3 s take on the built-in Retina display (scale 2×). The stored arrow PNG is 280×400 pixels. The previous code path yields 56×80 for the same cursor (measured with a probe of the old `cgImage` call at a 2× hint). The declaration stayed at 56×80 with hotspot (10, 10), and `osrec inspect --timeline` loads the take.

## Open questions and risks

1. **Does a paused `AVPlayer` recompose its current frame when `videoComposition` is replaced?** If it does, `PreviewPlayer.refreshCurrentFrame` (a zero-tolerance seek to the current time) is deleted. I did not measure this. The first editor build should check it with a paused item and a style change.
2. **How long are `screen.mov`'s keyframe intervals?** A long HEVC GOP makes each scrub decode from the previous keyframe. The recorder sets no `AVVideoMaxKeyFrameIntervalKey` today. If scrubbing stalls on long takes, should the recorder cap the interval at about 1 s, at some size cost?
3. **Should the recorder store the largest cursor representation now?** It is a small change in `Recording` (encode the 280×400 representation and keep the declared size), and it is the only route to a crisp cursor at 2× in 4K. I propose it as step 4 of the sequence.
4. **Should the app exclude itself from capture** with `SCContentFilter(display:excludingApplications:)` instead of hiding its window? Hiding is enough for v1, but a floating recording HUD would need exclusion, which means a `RecordingConfiguration` option.
5. **Is 30 Hz edit coalescing smooth enough while dragging a zoom?** Each swap flushes AVFoundation's frames ahead. If a playing preview stutters during drags, the fallback is to apply edits on gesture end while playing and live while paused.
6. **Does the 4K export cap move with H.264?** Only HEVC was measured. The writer side is the inferred limit, so H.264 may differ in either direction.
7. **What is the canvas aspect for 1080p and 2160p?** This design uses 16:9 canvases with the 1.55:1 source aspect-fitted inside, which gives wider side margins. Should the presets offer a source-aspect canvas as well?

## Next implementation step

Land the Timeline additions (media URLs, validating decoders, and total `ZoomTrack` edits) with their tests. Then build `CanvasLayout`, `FrameGeometry`, `FrameRecipe`, `RenderScene`, `StyledCompositor`, and `MovieComposition` far enough for `osrec export --still` to write a PNG of a real take.

### Proposed sequencing

1. Timeline additions, with tests: the decoders reject overlaps, and zoom edits are property-tested against `init(validating:)`.
2. Render core and `osrec export --still`. Pure geometry tests plus the pixel test, then stills from both real takes, inspected.
3. `Export.run` and `osrec export`. Measure 1080p, native, and 4K on real takes, and check mic sync on `20261013-153859.osrec`, the take with a microphone.
4. Recorder stores the largest cursor representation. Re-record, and compare a 2× zoom still against step 2.
5. `Project` persistence (`project.json`) with round-trip tests.
6. `Studio` and `App/`. Home and permissions, then recording, then the editor with preview and zoom strip, then export. Verify with `xcodebuild`, a launch, and a window screenshot.
