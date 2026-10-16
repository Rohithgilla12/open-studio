# Capture targets: entire screen, an area, or one window

## Problem

Today a take is always a whole display. People also want to record a part of the screen, or a single window with everything in front of it hidden. The shape is not obvious for four reasons.

- The recording format has one coordinate space, screen video pixels of the captured display, shared by `screen.mov`, every event, and every cursor declaration (see [`../accepted/rationale.md`](../accepted/rationale.md), "one clock and one space, fixed at write time"). Any choice that crops the video at capture time splits that space in two.
- Auto-zoom, camera follow, and the cursor already filter pointer data to "on the recorded display" with `frameSize.contains`. An area makes "on the recorded thing" a smaller rectangle inside the frame.
- The renderer maps source pixels to the canvas with one scale factor because the viewport and the content rect share the source's aspect (see [`../accepted-render/rationale.md`](../accepted-render/rationale.md), step 4). An area changes what "the source's aspect" means.
- A window moves. A v1 crop that does not follow it must not block a later one that does.

## Usage (caller's view)

The command line:

```
osrec windows                                    # ids, app, title, frame, display
osrec record --area 100,80,1280,720 --duration 5 # display points, origin top-left of the main display
osrec record --area 0,0,800,600 --display 2      # an area of another display
osrec record --window 4127 --duration 5          # one window; others hidden, crop fixed at start
osrec inspect <take>.osrec                       # prints "area: 200,160 2560x1440 px" for an area take
osrec export <take>.osrec --out demo.mp4         # canvas takes the area's shape
```

Library callers (`osrec`, `Studio`):

```swift
import Recording

let windows = CaptureSources.windows()           // no ScreenCaptureKit call, so no permission prompt
let config = RecordingConfiguration(
    outputDirectory: library,
    target: .area(.main, CGRect(x: 100, y: 80, width: 1280, height: 720)),   // or .display(.main), .window(id)
    microphone: .systemDefault)
do {
    let session = try await RecordingSession.start(config)
} catch .areaTooSmall(let width, let height) { ... }      // typed, before anything is written
  catch .areaOutsideDisplay { ... }
  catch .windowNotFound(let id) { ... }
```

Nothing downstream asks what kind of target a take had. Timeline and Render read one optional rectangle:

```swift
let source = try SourceRecording.load(from: take)
source.area          // Rect? in screen pixels; nil for an entire-screen take
source.visibleRect   // area ?? the whole frame: what the take shows, and what bounds the camera
project.canvasSize(for: project.edits.format)   // the one canvas rule, shared by preview, export, the editor, and osrec
```

The app: a target picker on Home (Entire Screen, Area, Window). Area opens an overlay on the chosen display to drag a rectangle; Window lists windows with their app icons. Record, the menu bar Stop, and opening the editor afterwards are unchanged.

## Shape

### Step 1: the movie stays whole, the area is a rectangle beside it

```
display pixels (3456 x 2234)
┌──────────────────────────────────────────────┐
│ screen.mov: every pixel, as today            │
│        ┌───────────────────┐                 │
│        │ area (manifest)   │  ◀── clicks,    │
│        │ 200,160 2560x1440 │      cursor,    │
│        └───────────────────┘      events:    │
│                                   unchanged  │
└──────────────────────────────────────────────┘
```

- **Crop at render, not at capture.** The recorder keeps writing the full display, so `screen.mov`, `events.ndjson`, and the cursor declarations stay in one space: display pixels, origin top-left. The chosen area is one more manifest key, `area: [x, y, width, height]` in the same pixels.
- **The manifest version is the lowest that can express the take.** A manifest with an `area` is version 2. One without is still written as version 1. Readers accept 1 and 2 and refuse anything newer, as today. A version-1 manifest that names an area is refused as unreadable, because no version-1 writer knows the key. A version-1 reader asked to open an area take refuses it instead of ignoring the key, which matters: ignoring it would show the whole display, including whatever the person cropped out on purpose. An entire-screen take written by this build still opens in an older build.

### Step 2: the target is resolved once, at the boundary

```
CaptureTarget                       resolve (async, at start)                 recorded
──────────────                      ───────────────────────────               ─────────────────────────
.display(sel)            ──▶  display                  filter: display       area: nil
.area(sel, rect pt)      ──▶  display, clip + snap     filter: display       area: rect in px
.window(id)              ──▶  window's display,        filter: display,      area: window frame in px
                              window frame → clip+snap   owning app included
```

- **`RecordingConfiguration.target: CaptureTarget` replaces `display`.** The enum makes "a window and also an area" unrepresentable. Every caller (osrec, Studio, tests) moves in the same change, and the old field is gone.
- **One pure function turns points into the recorded area.** `CaptureArea.pixels(of:displayPointSize:scale:)` intersects the rectangle with the display, refuses an empty intersection (`.areaOutsideDisplay`), snaps outward to whole pixels, and refuses anything under 64 pixels a side (`.areaTooSmall`). The window case goes through the same function after converting its global frame to display-local points. The function is unit-tested without a display.
- **A window target is the area mechanism plus a different filter.** The stream uses `SCContentFilter(display:including:exceptingWindows:)` with the window's owning application, so windows of other apps are hidden but coordinates stay in display space. The area is the window's frame at start. See the trade-off under Decisions.
- **Window enumeration does not touch ScreenCaptureKit.** `CaptureSources.windows()` reads `CGWindowListCopyWindowInfo`, which shows no permission prompt, for the same reason the display picker lists `NSScreen` (D7). Without Screen Recording permission macOS withholds window titles, so a row falls back to the app name. `start` looks the id up in `SCShareableContent` and throws `.windowNotFound` if it is gone.

### Step 3: Timeline treats the area as the frame the camera lives in

```
before                                  after
frameSize.contains(click)       ──▶     visibleRect.contains(click)        (AutoZoom, camera samples)
viewport ⊆ (0, 0, frameSize)    ──▶     viewport ⊆ visibleRect             (CameraTrack clamp)
scale 1 = whole frame           ──▶     scale 1 = visibleRect exactly
fixed focus in frame fractions  ──▶     fixed focus in visibleRect fractions
```

- **`SourceRecording.visibleRect` is the one rectangle.** It is `area` or the whole frame, so for an entire-screen take every number is what it was, and the existing tests pass unchanged.
- **The cursor is not filtered by the area.** The cursor's own "on this display" test stays the frame. Its hotspot can sit just outside the area while the arrow's body points into it, and the renderer's rounded mask already clips the cursor with the screen, so it leaves through the edge like the content it points at.

### Step 4: Render gives the canvas the area's shape

```
RenderScene.make
  canvas  = project.canvasSize(for: format)       ◀── the one rule
  layout  = CanvasLayout(style, canvas, source: visibleRect.size)
FrameRecipe: crops source to camera.viewport      ◀── unchanged: the viewport is in display pixels already
```

- **FrameRecipe does not change.** The viewport is a rectangle in display pixels inside the area, and the recipe already crops the source frame to the viewport. `CanvasLayout` is given the area's size instead of the frame's, so the content rect has the area's aspect, and one scale factor still serves both axes.
- **Canvas rule.** For an entire-screen take the presets are what they were: 1920 x 1080, 3840 x 2160, or native. For a take with an area, 1080p and 2160p become the largest even canvas with the area's aspect that fits inside the preset's box, and native is the area grown by the padding. `Project.canvasSize(for:)` is the one place this lives; the four callers that computed a canvas (scene, editor aspect, format inspector, osrec) all call it.

### Step 5: Studio

```
Home ── target picker ─┬─ Entire Screen ── Record ───────────────────────────▶ recording (unchanged)
                       ├─ Area ── Record ─▶ overlay on the display ─ Return ──▶ recording
                       │                     (drag, handles, W x H px)  Esc ──▶ Home
                       └─ Window ── list (icon, app, title) ── select ── Record ▶ recording
```

- The phase machine is unchanged. The picker and the overlay produce a `CaptureTarget`, and `startRecording()` passes it through `RecordingConfiguration` as it passes the display today.
- The last area per display is a preference, offered next time. A window id is never remembered, because ids do not survive the window.

## Sketches considered

Two structurally different places for the area, and two shapes for the API.

**Sketch A: the area is Timeline's content rect (chosen).** Coordinates stay in display pixels end to end. `SourceRecording` carries `area`; `AutoZoom`, `CameraTrack`, and the canvas read `visibleRect`; `FrameRecipe` is untouched because the viewport is already in display pixels.

**Sketch B: translate at load, crop before the recipe.** `SourceRecording.init` subtracts the area's origin from every pointer sample and button, and reports `frameSize` as the area's size. Timeline then needs no change at all: its existing `frameSize.contains` filter already drops clicks outside the area. `FrameRecipe` gains a pre-crop of the source frame to the area before the viewport crop.

| | A: area in Timeline | B: translate at load |
|---|---|---|
| Timeline change | three call sites read `visibleRect` instead of the frame; the clamp gains an origin | none |
| Coordinate spaces in memory | one (display pixels) | two: area-local in Timeline, display pixels in the movie, joined by an offset Render must re-add |
| `Point`'s documented meaning ("screen video pixels") | holds | false for every Timeline point |
| Cursor at the area edge | drawn and clipped by the mask, as on screen | hidden as soon as the hotspot leaves the area |
| A window that moves (later follow-crop) | `visibleRect` becomes a function of time; the camera bounds per time, events untouched | the offset becomes a function of time, so every spring would run in a moving frame; the knot tables stop being valid |
| An editable crop later (`Edits.crop`) | a parameter to `Timeline.init` | a second `SourceRecording` built by re-translation, though the type is load-only today |

B is smaller today and wins only on lines changed. It reintroduces, in memory, the second coordinate space the format decision avoided on disk, and both foreseeable follow-ups (follow-crop, editable crop) fight it. A keeps one space, so it is chosen.

**API shape: a target enum (chosen) against separate fields.** The alternative keeps `display` and adds `area: CGRect?` and `window: CGWindowID?`. That admits a window plus an area, or a window plus a display that disagrees with the window's own display, and each needs a runtime rule. The enum makes those states unrepresentable, at the cost of migrating every caller now, which is a handful of lines.

## Decisions

- **Window filter includes the owning application, not only the window.** Menus, pop-ups, sheets, and tooltips are separate windows owned by the same app. With `including: [window]` a demo that opens a menu records the menu as missing. Including the app shows them. The cost: another window of the same app that overlaps the target shows inside the crop. Out-of-process panels (for example the open and save panel of a sandboxed app, which runs in a separate service process) do not show either way. If the window has no owning application, the filter falls back to the window alone.
- **No editable crop in v1** (`Edits.crop` is not added). Because the movie is whole, an editable crop is possible later without a format change, and that is the main reason crop-at-render was chosen. But with no editor UI to change it, a v1 field would be settable only by hand-editing `project.json`, and it would add a validation rule, a project-file key, and a regenerate-zooms interaction (generated zooms depend on which clicks fall inside the area) for no user-visible feature. Sketch A keeps the door open: the crop becomes a parameter to `Timeline.init` that defaults to `source.visibleRect`.
- **64 pixels a side is the smallest area**, measured in screen pixels after clipping and snapping, because the output resolution is what a too-small area ruins. On a 2x display that is 32 points.
- **Fixed zoom focus is a fraction of the visible rect**, not of the frame, so `fixed(x: 0.5, y: 0.5)` is the centre of what the viewer sees. For an entire-screen take the two are the same.

## Deviations from the decided direction

1. **Version 1 is still written for entire-screen takes.** The direction asked for a version bump with back-compat. The manifest's version is now derived from its content, so only takes that need the new key carry version 2. The stated reason for the bump (an old reader must not silently show the whole frame of an area take) is preserved, and old builds keep reading entire-screen takes.
2. **Three existing tests change their "too new" version from 2 to 3** (`ManifestTests.newerVersionIsRejectedBeforeItsShapeIsRead`, `ReaderTests.newerVersionDirectoryIsRejected`, `LoadTests.rejectsNewerFormatVersion`). They encoded "2 is newer than this reader", which the bump makes false on purpose. They now use `FormatVersion.current + 1`. No entire-screen Timeline or Render test changes.
3. **The canvas follows the area only for takes that have one.** Entire-screen takes keep the 16:9 boxes, as the direction requires. So an area that covers the whole display renders at the area's shape, and an entire-screen take of the same display renders in the 16:9 box. This is the asymmetry open question 7 of the render rationale already asks about, now with a concrete second case.

## Tradeoffs accepted

- We accept full-display files for area and window takes (a 1280 x 720 area of a 3456 x 2234 display still writes 3456 x 2234 HEVC) in exchange for one coordinate space, an area that can be widened later, and no change to the recorder's hot path. `SCStreamConfiguration.sourceRect` would shrink the file and fix the crop forever, and every event would need a second conversion.
- We accept that a window take's crop is the window's frame at start and does not follow a move or resize, in exchange for a v1 with no new event type. A later follow-crop adds window-frame events and turns `visibleRect` into a function of time; nothing in the format or Timeline blocks it.
- We accept that the canvas rule differs between an entire-screen take and an area covering the whole screen (deviation 3) in exchange for leaving every entire-screen export byte-identical.
- We expect black where the captured app draws nothing inside its window frame (the window's rounded corners, if the style's corner radius is smaller), because ScreenCaptureKit fills uncaptured pixels with its background colour. This is inferred from the filter's documented behaviour; no window take has been recorded yet (see Implementation reconciliation).

## Alternatives considered

- **`SCStreamConfiguration.sourceRect`.** Smaller files and less encode work. It fixes the crop at capture, so no later widening or follow-crop, and forces every event, the cursor, and the camera into a second, area-local space. Rejected by the direction, and the sketch comparison above shows the same cost in memory.
- **`SCContentFilter(desktopIndependentWindow:)` for windows.** It captures the window alone at its own size, wherever it moves, which would give follow-crop for free. But the stream's coordinates become the window's, not the display's, so events need a per-frame mapping from display space into a moving window, and a resize changes the stream's size mid-take. Rejected for v1 for the same one-space reason.
- **Including only the target window.** Simpler and stricter, but menus and sheets vanish. Rejected (see Decisions).
- **`Edits.crop` in v1.** See Decisions.

## Open questions

1. **Should Entire Screen use the display's shape too?** With area takes following their area, the 16:9 box for entire-screen takes is the odd one out. Changing it changes every existing export, so it is left for a separate decision.
2. **Should a recording show the area's outline on screen?** The overlay closes when recording starts, so nothing marks the area during the take. A click-through outline window, excluded from capture, would help, and would need the exclusion option from render open question 4.
3. **Follow-crop for windows.** Record `windowFrame` events and make `visibleRect` a function of time. The camera clamp and the canvas rule then need a policy for a window that changes aspect.

## Implementation reconciliation

### D8

Implemented on 2026-10-16. Each entry is a place where the code departs from the sketch above, or a result.

1. **`CaptureSources.windows()` is synchronous and never throws**, because it reads `CGWindowListCopyWindowInfo`. Its parsing (`windowInfo(from:displays:ownProcess:)`) and the display choice are pure and unit-tested with synthetic window-list entries.
2. **`RecordingError` gains `areaOutsideDisplay`, `areaTooSmall(width:height:)`, and `windowNotFound`.** A window that straddles displays records on the one holding most of it, and is clipped to that display like an area.
3. **Studio's picker is a `CaptureKind` preference** (screen, area, window) plus the last area per display in display points. A window id lives on the model only. `StudioModel.record()` is the one entry point: for Area it shows the overlay through `StudioServices.selectArea`, saves the confirmed area, then starts. `readiness` (ready, busy, needs a window, needs permissions) replaces the boolean check. The overlay orders itself out and waits 100 ms before the recording starts.
4. **`-SelectArea` never records.** The first check launched the overlay on the machine while the person was using it. The overlay takes key focus, a keystroke confirmed it, and the app tried to start a recording; Input Monitoring was missing for that build, so `start` refused before writing anything, and no take was created (checked: the library listing was unchanged). In that mode, confirming now only saves the area. The person's preferences were restored to their earlier values.
5. **Window list thumbnails are skipped.** `SCScreenshotManager` would show the Screen Recording prompt before the person chose to record, and `CGWindowListCreateImage` is unavailable on macOS 15 and later.
6. **Known duplication.** The overlay's pixel label rounds with one `backingScaleFactor`, while `CaptureArea.pixels` uses a scale per axis and snaps outward, so the label can under-report by a pixel but never lets a too-small area through. `.main` is resolved to a display id in both Studio and Recording.

**Verified on 2026-10-16** (Apple M2 Max, macOS 27.0.1). `swift build` and `swift test` pass with 286 tests (229 before). `RecordingFormatTests.healthSeesALockHeldThroughAnotherDescriptorInThisProcess` failed once under the full parallel run and passed in the three full runs after it, the same open issue D5 recorded. `xcodebuild` builds the app. A window capture of the built app shows Home with the target picker, and the window list with app icons, titles, and sizes in pixels. The overlay was checked as an offscreen render of its view (dimmed display, clear selection with eight handles, "1920 × 1080 px", Cancel and Record), not as a window capture, after the incident in entry 4.

**Area render on a real take.** The D4 take `20261013-115409.osrec` (3456 x 2234, clicks at (100, 240), (100, 300), and (3380, 1960) px) was copied and given the area (0, 0, 1600, 1000). `osrec inspect` prints the area, and auto-zoom finds one segment, [719.7, 4578.9] ms, instead of the two the whole frame gives, because the far click is outside the area. `osrec export` wrote 600 frames at 1728 x 1080 (the area's 1.6 aspect inside the 1080p box). At 2500 ms the camera is at scale 2.0000 with its viewport at (0, 37.4) + 800 x 500, inside the area, and at 5400 ms it is back to exactly (0, 0) + 1600 x 1000. Stills at 500, 2500, and 8100 ms show only the top-left of the display, with the menu bar ending at Help and no status items, the cursor on the click position, and no cursor at 8100 ms, when the pointer is at (3378, 1963), outside the area.

**Not verified.**
- A new recording with `--area` or `--window`. The process running this work has Screen Recording but not Input Monitoring, which `osrec record` requires, and TCC was not to be changed. So the recorder writing `area`, the window filter hiding other apps, and the window's corners are untested on a live capture.
- The overlay as a real window (drawing over the desktop, focus, cursors, the 100 ms gap before the first frame).
