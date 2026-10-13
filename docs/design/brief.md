# Design brief: osrec recorder and timeline core

## Goal

open-studio is a clean-room, open-source take on the recording-plus-auto-zoom workflow described in `docs/20261013-screen-studio-teardown.md`. Read that document first. It is the grounding for this design.

This first unit ships two components and the contract between them. The Electron editor, renderer, export, and share links come later. The design must not block them.

1. **osrec** is a Swift command-line sidecar for macOS 15 and later. It records one display with ScreenCaptureKit, with the cursor hidden from the video. It also records input events through a listen-only CGEventTap, and cursor images and hotspots as the system cursor changes. The microphone is optional. It writes a recording directory.
2. **@open-studio/timeline** is a pure TypeScript package with no DOM and no Node APIs in its core. It parses a recording directory's metadata into a domain model, generates automatic zoom segments from clicks, and answers per-frame questions for a renderer:
   - where the camera is and how far it is zoomed at time t
   - where the cursor is, which image it shows, and whether it is pressed or visible at time t

## Constraints

- The recording directory format is the contract between Swift and TypeScript. It needs a version, one clock for every timestamp, and a parse step at the TypeScript boundary.
- **Deterministic seeking.** `cameraAt(t)` must return the same value regardless of the order in which times are queried. That rules out hidden mutable spring state carried between calls. A renderer calls it once per frame at 60 fps during preview, and frame by frame during export.
- Recording must survive being killed. If osrec dies at second 40 of a 60 s take, the data written so far stays usable, or at least recoverable.
- **Control protocol.** The parent process (later Electron) starts osrec, sends config, learns when capture is ready, pauses and resumes, and stops. Choose the protocol and justify it. Screen Studio uses stdin JSON, NDJSON on stdout, and POSIX signals. You may keep or reject that.
- Permissions: Screen Recording, plus Accessibility or Input Monitoring for the event tap. The parent must be able to check them before recording.
- **Clean room.** Reimplement behaviour, not code. Do not reuse Screen Studio assets, models, or shaders.
- **Behaviour to match, from the teardown:**
  - Click windows run from t−300 to t+2500 ms and merge when the gap is 2500 ms or less.
  - Zoom is 2×.
  - The camera follows a time-weighted centroid of click groups bounded by half the visible viewport.
  - The default camera spring is k=125, c=12, m=1.5.
  - Cursor presets: Smooth 470/70/3, Medium 340/60/3, Rapid 530/40/1.
  - The cursor shake filter threshold is 500 px.
  - The cursor fades while typing (3 or more keyDowns within 1800 ms).
- One developer must be able to build and verify this unit. Verification surfaces are `swift build`, a real 5-second recording on an Apple Silicon Mac, and vitest on the timeline package using a recorded fixture.

## Repository layout (proposed, may be challenged)

```
native/osrec/            SwiftPM executable
packages/timeline/       TypeScript, vitest
fixtures/recordings/     small committed recordings for tests
docs/
```
