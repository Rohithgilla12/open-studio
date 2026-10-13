# Design brief: native recorder and timeline core

## Goal

open-studio is a clean-room, open-source take on the recording-plus-auto-zoom workflow of tools such as Screen Studio. The behaviour it matches comes from private teardown notes that are not published. Every constant this design depends on is listed under Constraints.

**Decision (2026-10-13):** the app is fully native Swift (SwiftUI, AVFoundation, ScreenCaptureKit, and Core Image or Metal). There is no Electron and no TypeScript. An earlier proposal recommended Electron. That recommendation is superseded.

This first unit ships two Swift modules, and the on-disk contract between recording and editing. The editor UI, renderer, export, and share links come later. The design must not block them.

1. **Recording** captures one display with ScreenCaptureKit, with the cursor hidden from the video, for macOS 15 and later.
   - It also captures input events through a listen-only CGEventTap, and cursor images and hotspots as the system cursor changes.
   - The microphone is optional.
   - It writes a recording directory.
   - A thin CLI harness (`osrec`) drives it from a terminal for verification. The SwiftUI app will drive the same library later.
2. **Timeline** is pure Swift with no AppKit, AVFoundation, or I/O in its core.
   - It loads a recording directory's metadata into a domain model.
   - It generates automatic zoom segments from clicks.
   - It answers per-frame questions for a renderer: where the camera is and how far it is zoomed at time t, and where the cursor is, which image it shows, and whether it is pressed or visible at time t.

## The renderer this must serve (later unit, design for it now)

Preview and export should share one render path. The intended path is an `AVVideoComposition` with a custom `AVVideoCompositing` compositor. `AVPlayer` uses it for preview and `AVAssetExportSession` or `AVAssetReader`/`AVAssetWriter` uses it for export. That compositor's `startRequest(_:)` is called per output frame with `request.compositionTime`. AVFoundation may call it on background threads, ahead of playback, and out of order when the user scrubs. So:

- **Deterministic seeking.** `camera(at:)` and `cursor(at:)` must return the same value regardless of query order or thread. That rules out hidden mutable spring state carried between calls. Value types and `Sendable` throughout.
- **Per-frame cost** must be small enough for 60 fps at 4K with headroom.

## Constraints

- **The recording directory is the contract** between the recorder and everything after it. It needs a version, and one clock for every timestamp (video PTS and input events must line up). The load step parses and validates it.
- Recording must survive a crash or force-quit. If the process dies at second 40 of a 60 s take, the data written so far stays usable, or at least recoverable.
- **Process boundary.** Decide whether capture runs in the app process or in a helper process, and justify it. Consider crash isolation, macOS privacy permissions (TCC attaches Screen Recording and Input Monitoring to the responsible app bundle), simplicity, and testability. The CLI harness must work for verification either way.
- **Permissions.** Screen Recording, plus Accessibility or Input Monitoring for the event tap. They must be checkable before recording starts, with a clear error when missing.
- **Packaging.** Decide between a SwiftPM-only layout and an Xcode project or generator, given that the app needs a bundle identity and entitlements later. Keep `swift build` and `swift test` working for the library modules.
- **Clean room.** Reimplement behaviour, not code. Do not reuse Screen Studio assets, models, or shaders.
- **Behaviour to match, from the teardown:**
  - Click windows run from t−300 to t+2500 ms and merge when the gap is 2500 ms or less.
  - Zoom is 2×.
  - The camera follows a time-weighted centroid of click groups bounded by half the visible viewport.
  - The default camera spring is k=125, c=12, m=1.5.
  - Cursor presets: Smooth 470/70/3, Medium 340/60/3, Rapid 530/40/1.
  - The cursor shake filter threshold is 500 px.
  - The cursor fades while typing (3 or more keyDowns within 1800 ms).
- One developer must be able to build and verify this unit. Verification surfaces are `swift build`, `swift test` on Timeline with a committed recorded fixture, and a real 5-second recording on an Apple Silicon Mac through the CLI harness.

## Repository layout (proposed, may be challenged)

```
Package.swift            libraries: Recording, Timeline; executable: osrec
Sources/Recording/
Sources/Timeline/
Sources/osrec/
Tests/TimelineTests/
Fixtures/recordings/     small committed recordings for tests
App/                     SwiftUI app, later unit
docs/
```
