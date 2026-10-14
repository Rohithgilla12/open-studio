# Design brief: renderer, export, and the first app

## Goal

The recording and timeline core is built and verified (see `docs/design/accepted/rationale.md` and `README.md`). Nothing turns it into a picture yet. This unit makes open-studio something a person can use:

1. **Renderer.** Draws each output frame from a recorded take. It shows the screen video cropped to the camera viewport and the cursor redrawn on top, inside a styled canvas (background, padding, rounded corners, shadow).
2. **Export.** Writes an MP4 with the microphone audio. `osrec export <take> --out <file>.mp4` comes first, so a zoomed video exists before any UI.
3. **App.** A SwiftUI macOS app with three jobs. It records (display and microphone pickers, record and stop). It edits (a preview player plus a strip of zoom segments you can delete and drag). It exports (a preset, a progress bar, and reveal in Finder).

Masks, share links, transcription, webcam, and motion blur are out of scope. The design must not block them.

## Grounding: what exists today

These facts are traced from the code on `main`. Read the files to confirm details.

**Recording directory** (`Sources/RecordingFormat/Layout.swift` is the only place file names appear):

```
recording.json     manifest; status .recording or .finalized(duration, termination)
screen.mov         fragmented QuickTime, HEVC (or H.264), display pixels (e.g. 3456 x 2234), cursor hidden
microphone.mov     fragmented QuickTime, AAC, present only when recorded with --mic
events.ndjson      input and cursor events
cursors/<id>.png   cursor bitmaps; hotspot and size are in screen pixels
```

- `screen.mov` has a **variable frame rate**. ScreenCaptureKit sends a frame only when the screen changes, and the recorder repeats the last frame once per second. A still 5 s take has 57 frames and a busy one 121 at a 60 fps cap. Real takes are in the session scratchpad, and the person's own take is `20261013-153859.osrec` in the repo root (gitignored).
- Media time 0 in both movies is recording time 0. Every Timeline time is microseconds from the first video frame.

**Timeline public API** (`Sources/Timeline/`):

```swift
let source = try SourceRecording.load(from: url)        // throws(SourceLoadError); reads metadata only, never media
let zooms = AutoZoom.track(for: source)                  // ZoomTrack: sorted, non-overlapping, validated
let timeline = Timeline(source: source, zooms: zooms, settings: .default)  // Sendable, immutable
let f: FrameState = timeline.frame(at: .seconds(1.25))   // pure; any thread, any order; ~0.33 µs

f.camera.viewport          // Rect in source pixels, always inside the frame
f.camera.scale, .center, .centerVelocity, .scaleVelocity
f.cursor.position          // hotspot, source pixels, smoothed
f.cursor.image             // CursorImageID? -> source.cursorImages[id]: relativePath, hotspot, size (screen px at 1x)
f.cursor.pressAmount       // 0...1; draw scale = 1 - (1 - pressedScale) * pressAmount
f.cursor.opacity, .isVisible, .isPressed, .velocity

source.directory, .duration, .frameSize, .hasMicrophone, .cursorImages
ZoomSegment { id, range: TimeRange, scale, focus: .followPointer | .fixed(x, y) }
ZoomTrack(validating:) throws(ZoomTrackError)            // .overlap, .scaleBelowOne
TimelineSettings { autoZoom, camera (spring .screenFocused, leadIn), cursor (smoothing preset, pressedScale, fades) }
```

- Timeline imports `RecordingFormat` with `internal import`. Wire types and file names are not visible to Timeline's callers. A renderer that needs `screen.mov`'s URL must get it through a public API. Today none exists. Decide where it belongs.
- Zoom segments are edit state. Timeline never generates them itself. The editor owns them, and builds a new `Timeline` after each edit.

**Packaging decision already accepted** (`docs/design/accepted/rationale.md`, Packaging): libraries and `osrec` stay in SwiftPM at the root. The app is a thin, checked-in Xcode project in `App/` that depends on the package by local path. It owns the bundle id, usage strings, entitlements, and signing. The rationale rejected a project generator, but `xcodegen` is installed here. Challenge that choice only with a reason. The toolchain is Xcode 27.0, Swift tools 6.2, and macOS 27 on Apple Silicon. Deployment target is macOS 15.

**Measured gotchas from the last unit:**
- The macOS 27 SDK deprecates `expectsMediaDataInRealTime` and `AVAssetWriterInputPixelBufferAdaptor` for Swift. The recorder keeps the classic path because it must run on macOS 15.
- Bare `git` is rewritten by a shell hook. Use `/usr/bin/git`.

## The render path

The earlier brief named the intended path. It's an `AVVideoComposition` with a custom `AVVideoCompositing` compositor. `AVPlayer` uses it for preview, and an export pipeline uses it for output.

- The compositor class is created by AVFoundation, not by you. Data reaches it through a custom `AVVideoCompositionInstruction` or equivalent. AVFoundation calls `startRequest(_:)` on its own threads, ahead of playback, and out of order while scrubbing.
- Preview and export must produce the same pixels for the same time and edit state.
- Edits (deleting a zoom, changing style) must reach a playing preview without rebuilding the player.

You may challenge the path, for example with an `AVPlayerItemVideoOutput` and a Metal view for preview. If you do, show that preview and export still share one drawing function, and say what you give up.

## Constraints

- **Look (v1).**
  - A background: solid colour, gradient, or image. Ship generated defaults only. Do not use Screen Studio wallpapers or assets.
  - Padding around the screen content, rounded corners, and a drop shadow.
  - The screen content is the camera viewport, scaled into the inset rect.
  - The cursor is drawn from the recorded PNGs at the camera-mapped hotspot. Its size scales with camera zoom and press amount, and it uses `opacity`. It is skipped when `!isVisible`.
  - The cursor must stay crisp at 2x zoom. Say how: higher-resolution assets, vector, or accepted softness.
- **Output.**
  - MP4, H.264 or HEVC, at constant frame rate (30 or 60) from a variable-rate source.
  - Presets at least for 1080p and the source's native size.
  - Microphone audio muxed and in sync.
  - Colour: the source is SDR HEVC from ScreenCaptureKit. State the colour space you tag and render in, so preview and export match.
- **Performance.**
  - Export of a 4K60 output at or faster than real time on Apple Silicon.
  - Preview plays at 60 fps and scrubs without stalls.
  - Name the GPU path (Core Image, Metal, or both) and why.
- **Determinism.** A rendered frame is a pure function of (source frame, timeline frame state, style, output size). No state carries between frames.
- **App state.**
  - Recording, editing, and exporting are distinct states with their own data. Make illegal combinations unrepresentable.
  - Edit state (zooms, timeline settings, style) persists next to the take and survives an app restart. Decide where: inside the `.osrec` directory or beside it. Never mutate the recording's own files, because the recorder's directory is its crash-safety contract.
  - The app records through `Recording.RecordingSession` exactly as `osrec` does.
- **Permissions in the app.** Screen Recording and Input Monitoring attach to the app bundle. Show what is missing with a way to open System Settings. Note that ad hoc signed rebuilds can lose TCC grants, and say how a developer avoids that.
- **Clean room.** Reimplement behaviour. No Screen Studio code, assets, shaders, or wallpapers.
- **Verification surfaces.**
  - `swift build` and `swift test`, including pure geometry tests (viewport to output rect, cursor transform) and a GPU pixel test if it's cheap.
  - `osrec export` on real takes. Extract frames to PNG and inspect them. Measure export speed.
  - `xcodebuild` builds the app. Launch it, and capture its window as a screenshot.

## Proposed layout (may be challenged)

```
Sources/Render/        styled frame drawing, the AVVideoCompositing compositor, export pipeline
Sources/osrec/         + export subcommand
Tests/RenderTests/
App/OpenStudio.xcodeproj, App/OpenStudio/   SwiftUI app
```

## Proposed sequencing (may be challenged)

1. Render plus `osrec export`. The first visible result is an MP4 of an existing take.
2. The app: recorder, editor with preview and zoom strip, and export.
