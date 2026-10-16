# Camera: record the person beside the screen, and draw them in a corner

## Problem

People want their face in the corner of a screen recording. That means three things: pick which camera, record it beside the screen and the microphone, and draw it over the styled screen in the preview, the export, and stills. The shape is not obvious for five reasons.

- The format has one clock (see [`../accepted/rationale.md`](../accepted/rationale.md), "one clock and one space, fixed at write time"). The screen and the microphone share it because both come from one `SCStream`. A camera comes from `AVCaptureSession`, a second capture graph with its own clock and its own queue.
- A camera can vanish mid-take. A USB cable comes out, or an iPhone used as a Continuity Camera walks away. The screen recording must not end with it.
- The renderer draws every frame as a pure function of (source frame at t, timeline state, style, size), on AVFoundation's threads, out of order (see [`../accepted-render/rationale.md`](../accepted-render/rationale.md), steps 3 and 4). A second picture source must keep that property and keep preview, export, and stills on one drawing path.
- "Camera" already has a meaning in this codebase. `CameraTrack`, `CameraState`, and `CameraSettings` in Timeline are the virtual camera that zooms and pans over the screen. The new thing is footage of a person.
- Older builds must keep reading takes that do not use the new feature, as D8 arranged for areas (see [`../capture-targets/rationale.md`](../capture-targets/rationale.md), step 1).

## Usage (caller's view)

The command line:

```
osrec cameras                                     # ids and names, the system's preferred one marked
osrec record --camera default --duration 5        # the system's preferred camera
osrec record --camera <uniqueID> --mic default    # a specific camera, with the microphone
osrec inspect <take>.osrec                        # "camera: FaceTime HD Camera, 1920x1080 @ 30 fps" and camera.mov's probe
osrec export <take>.osrec --out demo.mp4          # the overlay from project.json, or the default corner
osrec export <take>.osrec --out demo.mp4 --no-camera
```

Library callers (`osrec`, `Studio`):

```swift
import Recording

let cameras = CaptureSources.cameras()            // built-in, USB, Continuity Camera; never Desk View
let config = RecordingConfiguration(
    outputDirectory: library,
    target: .display(.main),
    microphone: .systemDefault,
    camera: .device(uniqueID: cameras[0].id))     // or .systemDefault, or .none (the default)
let missing = Permissions.check().missing(for: config)   // includes .camera only when one is selected
let session = try await RecordingSession.start(config)   // throws .cameraNotFound before writing anything
for await update in session.updates {
    if case .warning(.cameraLost(let at, let why)) = update { hud.note("camera ended at \(at): \(why)") }
}
```

Timeline and Render read one optional URL and one style value:

```swift
let source = try SourceRecording.load(from: take)
source.cameraMovie        // URL? like microphoneMovie; nil when the take has no camera
source.hasCamera

var project = try Project.open(take)
project.edits.style.camera.corner = .bottomLeft
project.edits.style.camera.size = 0.3            // fraction of the canvas's shorter side
project.edits.style.camera.shape = .circle       // or .roundedRectangle
project.edits.style.camera.mirrored = false
project.edits.style.camera.isVisible = false     // what --no-camera sets
```

The app: a Camera picker on Home next to Microphone, refreshed as cameras come and go. In the editor, a Camera section in the style inspector (show, corner, size, shape, mirror), present only for a take that has a camera.

## Shape

### Step 1: one more file in the take, on the same clock

```
20261016-101500.osrec/
  recording.json     + "camera": {deviceName, pixelWidth, pixelHeight, frameRate}   (version 3)
  screen.mov         unchanged
  microphone.mov     unchanged
  camera.mov         new: fragmented, 1 s fragments, H.264 or HEVC, ≤ 1920 x 1080, ≤ 30 fps
  events.ndjson      unchanged
```

- **`camera.mov` is its own fragmented movie**, written by the same `MovieWriter` as the other two. The name lives in `RecordingLayout` only. A separate file keeps a camera fault away from `screen.mov`, which is the reason the microphone has its own file. Fragmenting gives the same crash story: the file reads to its last whole fragment after a `kill -9`, and `recover(at:)` probes it like the microphone.
- **The manifest version stays the lowest that can express the take.** A manifest with `camera` is version 3. One without is written as before (1, or 2 with an area), so older builds still read every take that has no camera. A version-2 manifest that names a camera is refused as unreadable. Why not leave `camera` as an ignorable key, as the format allows for additive keys? Two failures. An older build would export a camera take without the person in it and say nothing. And an older build's recovery rewrites the manifest without keys it does not know, so a crashed camera take recovered by an older build would lose its camera for good.

### Step 2: the camera's clock joins the host clock at the writer

```
SCStream ──────────────── screen PTS (host ns) ──┐
         └─ microphone ── PTS (host ns) ─────────┤
                                                 ├──▶ CaptureSink actor (executor = the SCK queue)
AVCaptureSession ── PTS on synchronizationClock  │        origin = first complete screen frame
   AVCaptureVideoDataOutput, delegate queue ─────┘        every writer: startSession(at: origin)
   = the same SCK queue                                    camera PTS: CMSyncConvertTime(→ host clock)
```

- **The camera delivers onto the sink's own queue.** `AVCaptureVideoDataOutput.setSampleBufferDelegate(_:queue:)` takes the `DispatchSerialQueue` that is the `CaptureSink` actor's executor, so camera frames enter with `assumeIsolated` like screen frames. The origin, the writers, and the "camera ended" state then have one owner and no lock.
- **Media time 0 of `camera.mov` is recording time 0, by the microphone's rule.** The camera writer starts its session at the same host time as the screen and the microphone. Camera frames before it are dropped. The one step the microphone does not need is the clock: `AVCaptureSession` stamps buffers on its `synchronizationClock`, which is usually the host clock but is not promised to be. `CMSyncConvertTime` moves each PTS to `CMClockGetHostTimeClock()`, whose nanoseconds are `CLOCK_UPTIME_RAW` (the clock D1 measured). A buffer whose PTS changes is retimed with `CMSampleBuffer(copying:withNewTiming:)`.
- **Format: the largest native size inside 1920 x 1080 that reaches 30 fps.** A pure function picks the device format: among formats that fit inside the cap and support 30 fps, the largest; failing that, the largest that fits; failing that, the smallest format, with the writer scaling it into the cap. The frame rate is pinned to 30 fps, or the format's best rate when that is lower. The codec follows the screen's.
- **A lost camera ends its track, not the take.** A runtime error, an interruption, or `AVCaptureDevice.wasDisconnectedNotification` sends the sink `cameraLost`. The sink stops appending, records `cameraLost(at:message:)` in the manifest's warnings as it does for the microphone, and at stop finishes `camera.mov` one frame after its last sample, so the file ends where the camera did and the export shows no frozen face. The screen and events carry on.
- **The track's life is a value.** `CameraTrack` (waiting for the origin, recording since the last sample, ended) decides which buffers to keep and where the file ends. It is pure, and `CameraTrackWriter` wraps it around a `MovieWriter`, so tests drive the whole recording path with synthetic sample buffers and read the movie back. No test opens a camera.

### Step 3: Timeline hands over the URL

```
SourceRecording.load
  screenMovie       URL
  microphoneMovie   URL?    manifest.microphone != nil
  cameraMovie       URL?    manifest.camera != nil         ◀── new, same rule
```

- `cameraMovie` follows `microphoneMovie`, with `hasCamera` derived from it. Timeline needs nothing else about the camera, because the overlay's aspect comes from the decoded camera frame at draw time (step 5).
- The name stays `camera` because the direction and the file use it, though Timeline's `CameraState` is the zoom. Every new symbol in Render says `CameraOverlay` or `cameraTrackID`, never `camera` alone, and the editor section is titled Camera beside a Zoom section, so a reader of one file is not misled.

### Step 4: the camera is a second track in the one composition

```
MovieComposition.load(source)
  AVMutableComposition
    track 1  screen.mov video       at 0
    track 2  microphone.mov audio   at 0   (when recorded)
    track 3  camera.mov video       at 0   (when recorded)   ◀── new
videoComposition(scene, fps)
  SceneInstruction { screenTrackID, cameraTrackID?, scene }
    requiredSourceTrackIDs = [screen] + [camera if the scene draws it]
```

- **Both pictures reach the compositor in one request.** `request.sourceFrame(byTrackID:)` returns the screen frame and the camera frame for the same composition time. AVFoundation hands over the sample whose time range covers t, which is "the latest camera frame at or before t", exactly what a 30 fps camera under a 60 fps output needs. Preview, export, and stills get it from the same builder, so they agree by construction, as they already do for the screen.
- **A hidden or absent camera costs nothing.** The camera track is listed in `requiredSourceTrackIDs` only when the scene draws it, so AVFoundation does not decode it for `--no-camera` or a hidden overlay. A take without a camera builds the composition it builds today, and the existing pixel tests do not change.
- **No camera frame at t draws no overlay.** Before the first camera frame, or after a camera that was lost, the track has no sample, and the overlay is skipped for that frame.

### Step 5: one frame, drawn in order

```
startRequest
  screen = sourceFrame(screenTrackID)                    (as today)
  camera = sourceFrame(cameraTrackID)?                   (new)
  geometry       = FrameGeometry(frame, layout, cursor)  (as today)
  overlay        = CameraOverlayGeometry(style.camera, canvas, camera.extent)   pure, top-left px
  image = backdrop ◀ masked(screen ◀ cursor) ◀ masked(mirrored, aspect-filled camera)
```

- **Draw order is screen, cursor, camera.** The camera is composited after the content mask, so it is not clipped by the screen's rounded edge and may sit over the padding.
- **The overlay's geometry is pure.** `CameraOverlayGeometry` takes the overlay style, the canvas size, and the camera frame's pixel size, and returns the overlay rectangle, its corner radius, and the scale that aspect-fills the camera into it. A circle is a square of side `size × shorter side`, showing the camera's centre. A rounded rectangle has the camera's aspect and height `size × shorter side`, so it shows the whole camera frame. The inset from the canvas edges is `inset × shorter side`. Lengths are fractions of the canvas's shorter side like every other style length, so the overlay looks the same at 1080p, 4K, native, and in the preview.
- **Mirrored is a horizontal flip of the camera image before the fill**, on by default because that is how people see themselves in every video call.
- **The overlay style does not invalidate the backdrop.** `SceneAssets.Key` stops keying on the whole `Style` and keys on the parts the backdrop uses (background, padding, corners, shadow), so dragging the camera size slider does not re-dither a 4K backdrop.

### Step 6: Studio and osrec

```
Home   Display ▾   Microphone ▾   Camera ▾ (None, cameras…)   ◀── refreshed on connect / disconnect
Editor inspector:  Background │ Frame │ Camera (show, corner, size, shape, mirror) │ Zoom │ Output
```

- The picker writes `RecordingPreferences.camera`, which `StudioModel.configuration` passes through, as it does the microphone. The permission banner lists Camera only when a camera is chosen.
- The inspector edits `edits.style.camera` through `Editor.apply` and `Editor.drag`, so undo and autosave work with no new path.
- `osrec export --no-camera` sets `isVisible = false` on the opened project before exporting, the same way `--size` overrides the format.

## Sketches considered

Two structurally different ways for camera pixels to reach the compositor.

**Sketch A: a second track in the one AVComposition (chosen).** `camera.mov` is inserted at time 0 into the composition that already holds the screen and the microphone. The compositor receives both frames in one `AVAsynchronousVideoCompositionRequest`, and the scene draws the overlay.

**Sketch B: a separate camera reader feeding the scene.** The composition stays screen-only. A `CameraFrames` source owned by the scene supplies a camera image for any t, from an `AVAssetReader` (sequential), an `AVAssetImageGenerator` (random access), or, in the preview, an `AVPlayerItemVideoOutput` on a second, muted player kept in step with the first.

| | A: second composition track | B: separate reader in the scene |
|---|---|---|
| Sync | AVFoundation picks the camera sample covering t, the same rule it uses for the screen | Each consumer must map t to a camera frame itself; a second player drifts and needs re-syncing on every seek |
| Scrubbing | A seek decodes both tracks at the new time | A sequential reader cannot seek cheaply; an image generator per request costs a decode from the last keyframe |
| Determinism | Output is a function of (frames at t, scene); compositor threads share nothing new | The scene holds a reader with a cursor, which is shared mutable state on compositor threads, or a cache whose contents depend on request order |
| Preview, export, stills | One builder, one compositor, as today | Three camera feeds (player output, reader, generator) kept in step by tests |
| Performance | One more hardware decode of a ≤1080p30 stream per output frame, skipped when hidden | The same decode, plus copies across the scene boundary, plus generator overhead at random access |
| Cost of a change | One optional track ID on the instruction | A new stateful component in a type that is immutable today |

B only wins if the camera needs frames the composition cannot express, such as a time offset per frame. Nothing in the direction needs that, and a fixed offset, if one were ever needed, is an `insertTimeRange(at:)` argument in A. A keeps "a frame is a function of its inputs" true by construction, so it is chosen.

**Recording, two shapes considered.** The camera writer could live in its own actor with its own queue, told the origin once the screen's first frame lands. Or the camera could deliver onto the sink's queue. A separate actor needs the origin handed across, and frames that arrive before the hand-over must be buffered or dropped by a rule that depends on timing between two queues. Delivering on the sink's queue gives one owner of the origin and every writer, at the cost of camera appends sharing a serial queue with screen appends. Appends are cheap (the encoder runs asynchronously), so the shared queue is chosen.

## Decisions

- **Corner plus inset, not a normalised point.** Four corners cover what people ask for in a screen recording, need no drag gesture in the preview, and stay put when the output size changes. The inset is stored in the style (default 0.03 of the shorter side) so a hand-edited `project.json` can move it, but the inspector does not show it.
- **Size is a fraction of the canvas's shorter side**, default 0.25, allowed from 0.1 to 0.5. "Fraction of the canvas" in the direction is read in the unit every other style length already uses.
- **Shapes.** A circle shows the centre square of the camera. A rounded rectangle shows the whole frame at the camera's aspect, with a corner radius of 12% of its shorter side.
- **The camera follows the screen's codec** and is capped at 1920 x 1080 and 30 fps, as directed.
- **A camera that fails to start fails the take's start**, with `.cameraNotFound` for a missing device and `.captureFailedToStart` for one that cannot be configured, exactly as a missing microphone does. A camera that fails after the first frame is a warning.
- **System default is `AVCaptureDevice.systemPreferredCamera`**, which follows the person's choice in Control Centre and Continuity Camera's automatic switching, filtered through the same discovery as the list, so it is never Desk View.
- **Home lists None plus each camera**, as directed. `osrec` also accepts `default`, which the app does not offer.

## Deviations from the decided direction

None yet. Implementation reconciliation below records any.

## Tradeoffs accepted

- We accept a manifest version bump for camera takes (older builds refuse them) in exchange for no silent loss of the camera in an older build's export or recovery.
- We accept camera appends on the screen's serial queue in exchange for one owner of the origin and every writer. A 30 fps append is a fraction of a millisecond against a 16 ms frame interval at 60 fps.
- We accept that the overlay is hidden for frames with no camera sample (before the camera's first frame, after a lost camera) in exchange for never showing a frozen face.
- We accept a centre crop for the circle in exchange for a shape that needs no framing control in v1.

## Alternatives considered

- **Sketch B**, above.
- **Burning the camera into `screen.mov` at record time.** It needs no render change, but it fixes the position, size, and shape forever, doubles the recorder's GPU work during the take, and puts compositing on the hot path the recorder keeps free.
- **The camera as a third output of `SCStream`.** ScreenCaptureKit has no camera output on macOS 15, so there is no shared clock to borrow, and the camera needs `AVCaptureSession` anyway.
- **An ignorable `camera` key with no version bump.** Rejected in step 1.

## Open questions

1. **Should the person be able to drag the overlay in the preview?** A normalised point would allow it. Corners are enough for v1, and the style value can grow a point later without changing the meaning of the corner.
2. **Should the camera switch mid-take?** Continuity Camera's automatic switching changes `systemPreferredCamera`, but the session keeps the device it started with. Following the switch would need a new writer or a format change mid-file.
3. **Should the camera have its own trim or offset?** A fixed offset fits sketch A as an insertion time. Nobody has asked for it.

## Implementation reconciliation

To be written by D9 as the work lands.
