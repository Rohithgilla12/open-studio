# Editing polish: aspect, backgrounds, and cursor

Design note for track B1. The brief is `docs/design/brief-editing-polish.md`. It decides where each addition lives, how `project.json` stays readable, and which shapes were rejected. It was written and committed before the code.

## The rule for placing a field

`Edits` already has three homes for render-time choices. Each addition goes to the one whose job it matches.

```
Edits
  ├─ format: OutputFormat      what the export file is: canvas size, frame rate, codec
  ├─ style: Style              how the canvas around the screen looks; time-independent pixels
  └─ settings: TimelineSettings  pure functions of time: springs, presses, hides
```

- **Aspect is part of the canvas size**, so it goes in `OutputFormat`, beside `size`.
- **Background presets are values of the existing `Background`**, so they add nothing to `Style`.
- **The three cursor controls go in `CursorSettings`.** `pressedScale`, the drawn cursor's press shrink, already lives there. The renderer reads it from the settings, and `CursorState` documents the draw-scale formula. Hide joins the typing and idle hides, which already decide `CursorState.opacity`. The click effect needs the clicks, the cuts, and the time map, and only `Timeline` holds all three.

## 1. Aspect presets

```swift
public enum CanvasAspect: String, CaseIterable, Codable {
    case fit                      // today's canvas: the 16:9 box, or an area's shape inside it
    case widescreen = "16:9", vertical = "9:16", square = "1:1", standard = "4:3", portrait = "4:5"
}
OutputFormat { size: CanvasPreset, aspect: CanvasAspect, frameRate, codec }
```

Step 1. The preset fixes the canvas's shorter side, and the aspect fixes its shape.

```
size    shorter side         aspect      1080p          4K
hd1080  1080                 16:9        1920 x 1080    3840 x 2160
uhd2160 2160                 9:16        1080 x 1920    2160 x 3840
                             1:1         1080 x 1080    2160 x 2160
                             4:3         1440 x 1080    2880 x 2160
                             4:5         1080 x 1350    2160 x 2700
```

Step 2. The take's content is fitted into that canvas by the existing `CanvasLayout`, with the padding, corners, and shadow. Nothing else changes.

```
take            fit                               an explicit aspect
entire screen   the 16:9 box                      the aspect's box
area            the area's shape inside 16:9 box  the aspect's box, area fitted inside
native          source grown by the padding       the same; native ignores the aspect
```

- **`fit` is a case, and it is the default.** A file saved before this unit has no `aspect` key, and it must keep rendering at today's size. For an area take today's canvas is the area's shape, not 16:9. A default of `16:9` would quietly re-shape every saved area project. With `fit`, a missing key decodes to exactly today's canvas.
- **The zoom camera needs no change.** It frames a viewport of the source's shape, and `CanvasLayout` fits that shape into any canvas. In a vertical canvas the content is a band across the middle, and a zoom fills that band with the clicked region. The brief's "a vertical canvas keeps the zoom camera useful" holds without new code. Filling a vertical canvas with a vertical crop of the screen is a different feature (a crop track), and it is not in this unit.
- **Native ignores the aspect.** Native's promise is that unzoomed source pixels land 1:1. Padding is a fraction of the canvas's shorter side, so growing the native box to another aspect changes the inset and pushes the fit off 1. It also makes very large canvases. A 9:16 canvas around a 4114-pixel-wide native box is 7314 pixels tall, past what the hardware encoders accept (inferred from the published limits, not measured). The inspector disables the aspect picker while Native is selected.

## 2. Background presets

```swift
public struct BackgroundPreset: Sendable, Hashable, Identifiable {
    public let name: String          // "Dusk", "Graphite": for the swatch's accessibility label
    public let background: Background
}
extension Background { public static let presets: [BackgroundPreset] }
```

- **A preset is a value, not a name, in `project.json`.** Picking one writes its `Background` (`{"type": "gradient", ...}` or `{"type": "solid", ...}`). The app may later retune a preset's colours without re-colouring anyone's saved project, and a file never names a preset this build does not know. The swatch row shows a preset as selected when the style's background equals its value.
- **The presets move from `Studio` into `Render`.** Today the swatch list is a static array in `EditorView.swift`, and the names come from a `switch` on three gradients. In `Render` the list is one table that tests can round-trip, and the view draws it with no logic of its own. `Gradient.presets` and `Background.name` are deleted.
- **Every preset is generated in code**: two-stop linear gradients and solid colours. No image ships.
- **Validation.** No field is new, but colours now come from a list a person can extend by hand in `project.json`. `Style.problem` rejects a colour component outside `[0, 1]` and a non-finite gradient angle.

## 3. Cursor size, hide, and click effect

```swift
CursorSettings {
    ...existing smoothing, pressedScale, typing and idle hides...
    var size: Double = 1          // scale on the redrawn cursor; sizeRange 0.5...3
    var isHidden = false          // never drawn; clicks still show if the effect is on
    var showsClicks = false       // the click ring
}

public struct ClickPulse: Sendable, Hashable {
    public let position: Point    // source pixels, where the button went down
    public let progress: Double   // 0 at the press, 1 when the ring has faded
}
FrameState { camera, cursor, clicks: [ClickPulse] }
```

Step 1. Timeline answers "which clicks are showing, and how far along".

```
down events ── drop those inside a cut ──> kept downs (recording time, sorted)
frame(at: o):  r = map.recording(at: o)
               clicks = kept downs d with 0 <= r - d < clickDuration (450 ms)
               progress = (r - d) / clickDuration
```

Step 2. The compositor draws each pulse as a ring at the click.

```
FrameGeometry  ring centre = canvasPoint(position)       pure, top-left canvas px
               ring radius grows with progress, opacity falls with it
FrameRecipe    ring under the cursor, inside the content mask, so it zooms and clips with the screen
```

- **The clock is the recording instant**, per the cuts design's time rule: presses and the cursor image are step functions of `map.recording(at: o)`, and the ring is press state. Two consequences follow, and the brief asks for both. A click inside a cut never draws, because its down is dropped. A ring still growing when a cut begins is cut with the content, as a press is.
- **Overlapping rings are a list.** A double click 400 ms apart has two rings alive at once. An optional single pulse would drop the first one early.
- **The ring scales with the camera and the cursor size.** Its radius is a multiple of the drawn cursor's height, in canvas pixels. A 2x zoom makes it twice as large, as it does the cursor.
- **Hide is a Timeline answer.** `isHidden` gives `opacity` 0 and `isVisible` false, the same path the typing hide takes, so the renderer's existing skip covers it. The click ring is separate, so "show clicks, hide the cursor" works.
- **The duration is a constant, not a setting.** The brief asks for a short ring. A duration field would be a setting nothing sets.
- **Validation at read.** `size` must be in `CursorSettings.sizeRange`. The Booleans need none.

## `project.json`

Every addition is an additive key with a default that renders today's frame: `output.aspect` is `fit`, `settings.cursor.size` is 1, `isHidden` and `showsClicks` are false. Each decoder reads its key with `decodeIfPresent ?? default`, as the settings decoders already do. So the version rule is unchanged: 1 without cuts, 2 with them.

A build from before this unit ignores the new keys. It exports a 16:9 or fitted canvas with a normal cursor and no rings, and its autosave drops the keys. That is a lost preference, not a wrong file. Cuts bumped the version because an older build would export what the user removed. A cursor shown at its normal size and a 16:9 canvas reveal nothing the recording does not, which is the same judgement the camera overlay's additive `style.camera` key made.

## Alternatives rejected

- **Aspect folded into `CanvasPreset`** (`hd1080Vertical`, `uhd2160Square`, and so on). Fifteen cases for two independent choices, and every switch on the preset grows. Two fields keep resolution and shape independent.
- **A default aspect of `16:9`, with a missing key meaning `16:9`.** It re-shapes saved area projects, and the user did nothing to cause it.
- **Native honouring the aspect.** See section 1. The aspect picker is disabled for Native instead.
- **Storing a preset's name** (`{"type": "preset", "name": "dusk"}`). Smaller files, but retuning a preset would change old exports, and an unknown name would need a refusal path. A value has neither problem.
- **Cursor controls in `Style`** (a `Style.cursor` struct). `Style` is the time-independent canvas. Hide and the click ring are functions of time and of the cuts, which `Timeline` owns, and the press scale they sit beside already lives in `CursorSettings`. Splitting cursor drawing across two structs would mean two places to look.
- **Ring clock on output time.** It keeps a ring animating smoothly across a join, but it would draw the tail of a click the viewer never saw, and the brief makes the press rule the contract.
- **Ring computed in the renderer from the source's button events.** The renderer would need the cuts and the map to drop clicks inside cuts, a second copy of the time rule outside `Timeline`.
- **A click-ring colour and size in the inspector.** Not asked for. The look is fixed in `FrameRecipe` until a user needs to change it.
