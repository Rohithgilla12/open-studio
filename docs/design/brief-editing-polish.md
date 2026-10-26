# Brief: editing polish (track B1)

## Goal

The editor can zoom, style, trim, and cut, but the result still looks less finished than other recorders' output, in ways a user notices at once. This unit adds four things.

1. **Aspect-ratio presets.** Export for where the video goes: 16:9 (today), 9:16 vertical, 1:1 square, 4:3, and 4:5. The recording sits inside the canvas with the existing padding, background, corners, and shadow. A vertical canvas keeps the zoom camera useful, since the camera already frames a viewport.
2. **Background presets.** A row of built-in backgrounds, gradients and a few solid colours, generated in code (no third-party images), plus the existing custom image. Picking one is one click and one undo step.
3. **Cursor controls.** Cursor size (a scale on the redrawn cursor), a click effect (a short ring that grows and fades at each click, drawn in the compositor), and "hide cursor" for takes where it distracts. These apply at render; the recording is unchanged.
4. **An inspector that holds them.** These controls live in the editor's existing inspector sections, matched to how Style and Camera are laid out today.

Speed segments are track B2. Do not build them, but do not block them: `TimeMap` will gain a rate per segment.

## Grounding

Confirm these in code.

- **Canvas** (`Sources/Render/OutputFormat.swift`): `OutputFormat.size` is a `CanvasPreset`, one of `hd1080`, `uhd2160`, or `native`. `canvasSize(for:padding:)` and `canvasSize(forArea:padding:)` give even sizes. An area take gets a canvas of the area's shape inside the preset's box. `project.json` stores `output`.
- **Style** (`Sources/Render/Style.swift`): `background` is `.solid`, `.gradient`, or `.image(ProjectAsset)`. It also holds padding, cornerRadius, shadow, and camera (`CameraOverlay`). Validation lives in `Style.problem` in `Project.swift`.
- **Drawing** (`Sources/Render/RenderScene.swift`, `FrameRecipe.swift`, `Geometry.swift`): one compositor for preview, export, and stills. `FrameGeometry` places the cursor from `frame.cursor` and `pressedScale`. Cursor images are cached in `RenderScene`.
- **Cursor state** (`Sources/Timeline/CursorTrack.swift`, `Settings.swift`): `CursorSettings` has smoothing, `pressedScale`, typing and idle hide. Clicks are `ButtonEvent`s in the source.
- **Time** (`docs/design/cuts/rationale.md`): `Timeline.frame(at: OutputTime)`. A click effect must use the clock the cuts design gives step state (presses follow the recording instant), so a click inside a cut never draws.
- **Editor** (`Sources/Studio/EditorView.swift`, `Editor.swift`): `Editor.apply` and `drag`/`endDrag` give one undo step per change or gesture, and `PreviewPlayer.show` pushes edits live.

## Rules for this unit

- Write a short design note first, at `docs/design/editing-polish/rationale.md`. Cover the data shape for each addition and where it lives (`OutputFormat`, `Style`, or `TimelineSettings`), how `project.json` stays readable (additive keys keep version 2; say why any change of meaning needs a bump), and the alternatives you rejected. Commit it before the code.
- Preview, export, and stills keep one compositor. Every addition is a pure function of the frame and the edits.
- New `project.json` fields are validated at read, like `Style.problem`.
- Tests: canvas sizes for every preset with and without an area; a click effect present at a click and absent inside a cut and outside its duration; cursor scale and hide in a rendered still; background presets round-trip through `project.json`.
- Comments only for a non-obvious why, never banner comments. Do not launch the Studio app.
