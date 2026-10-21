# Design brief: trim and cuts

## Goal

A take can be recorded, zoomed, styled, and exported, but every export is the whole recording. This unit lets the user remove time:

1. **Trim.** Move the start and the end of the take inward, so the dead seconds before and after the demo are gone.
2. **Cut.** Remove any number of ranges from the middle, such as a mistake or a long wait.

Preview, export, stills, `osrec export`, and the editor all show the edited take. Undo, autosave, and reopening the take bring the cuts back exactly.

Speed changes (playing a range at 2x) are out of scope. The time map you design must be able to carry a rate per range later without a format break or a rewrite of its callers. Masks, captions, and edit-by-transcript come later and read time through the same map, so the design must not block them.

## Grounding: what exists today

These facts are traced from the code on `main`. Read the files to confirm details.

**One time today.** `RecordingTime` (`Sources/Timeline/Primitives.swift`) is integer microseconds from the first video frame. Every layer uses it for every time: zoom ranges, event times, the compositor's request time, the player's playhead, the editor strip, `Still.png(at:)`. Composition time equals recording time, and `Sources/Render/Compositor.swift` says so in one comment: "a trim would add its map here and only here".

**Timeline** (`Sources/Timeline/Timeline.swift`). `Timeline(source:zooms:settings:)` precomputes spring tracks. `frame(at:)` is a pure function of time, about 0.33 µs, safe from any thread in any order. `ZoomTrack` (`ZoomEdits.swift`) holds sorted, non-overlapping segments in recording time, and every edit is total: it clamps, never throws. Auto-zooms come from clicks, in recording time.

**One composition builder** (`Sources/Render/MovieComposition.swift`). `MovieComposition.load(source)` builds one `AVMutableComposition` with the screen track, one audio track per `AudioSource` (microphone, system audio), and the camera track. Each is inserted at 0 for its full duration. It is the only builder; preview, export, and stills all call it so they cannot drift. Its comment says "The asset never changes after an edit; only the video composition does." The camera can end early (unplugged), so `instructionRanges` splits the video composition into a range that requires the camera track and a range that does not.

**Audio** is mixed by one `AVAudioMix` with one input parameter per track, levels from `Edits.audio`. The export passes only audible tracks, because a reader output refuses a mix naming a track it does not read.

**Compositor** (`Compositor.swift`). AVPlayer, AVAssetReader, and AVAssetImageGenerator all instantiate `StyledCompositor` from the same `AVVideoComposition`. It receives a `SceneInstruction` carrying an immutable `RenderScene`, converts `request.compositionTime` to `RecordingTime`, and draws `scene.image(source:camera:at:)`, which queries `Timeline.frame(at:)`.

**Preview** (`Sources/Render/PreviewPlayer.swift`). Owns one `AVPlayer` and one `AVPlayerItem`, "never rebuilt". `show(project)` coalesces edits (33 ms, latest wins) and swaps `item.videoComposition` or `item.audioMix`. Measured: a paused item recomposes its current frame within 300 ms of a swap. Scrubbing uses seek chasing. `playhead()` streams the player time as `RecordingTime`.

**Export** (`Sources/Render/Export.swift`) reads the composition with `AVAssetReader` (video composition output plus an audio mix output), writes HEVC or H.264 plus AAC, and counts `framesTotal` from `movie.duration`. **Stills** (`Still.swift`) use `AVAssetImageGenerator` with zero tolerances and clamp `t` to one frame before the duration.

**Project** (`Sources/Render/Project.swift`). `Edits` is the one value the user changes: zooms, settings, style, output format, audio levels. Undo keeps the previous value; autosave encodes the current one. `project.json` is version 1; additive keys keep the version; the header is checked first; a file from another take is ignored; a newer version is refused; zooms outside the duration are rejected at read.

**Editor** (`Sources/Studio/Editor.swift`, `EditorView.swift`, `ZoomStrip.swift`). `Editor.apply` and `drag`/`endDrag` wrap every change in one undo step and push the project to the preview. `ZoomStrip` maps x to time with `StripScale(width:duration:)` over the full recording. Zoom moves and resizes are clamped against `duration`.

**osrec** (`Sources/osrec`) exports with `project.json` when it exists, and prints the timeline with `inspect --timeline`.

## Constraints

- Preview, export, and stills keep one builder and one compositor. "Same pixels for the same output time" must hold by construction, not by keeping two code paths in step.
- `Timeline.frame(at:)` stays pure and lock-free.
- The recorder's files are never written. Edits live only in `project.json`.
- `project.json` stays readable by today's build where possible. If cuts force a version bump, say why.
- A cut that leaves nothing, overlapping cuts, and cuts outside the recording are unrepresentable or rejected at the boundary. Editing operations stay total, like `ZoomTrack`'s.
- Audio, screen, and camera stay in sync across every cut. Say what the listener hears at a cut boundary.
- The camera's early end still works when a cut falls before, across, or after it.
- macOS 15, Swift 6.2, strict concurrency. 359 tests pass today (`swift test`); the app builds with `xcodebuild -project App/OpenStudio.xcodeproj -scheme OpenStudio`.

## Questions your design must answer

1. **Which times are which.** Zooms, events, and springs are in recording time. The player, the export, and the strip see output time. How do the types stop one being passed as the other?
2. **Where the map lives** and who owns it. What the compositor, the audio, the camera instructions, export, stills, and the editor each call.
3. **What a cut does to zooms.** A zoom can lie inside a cut, across a cut edge, or across a whole kept range. Does the camera jump at a cut, or carry its spring across it? What happens to the stored zoom when a cut later removes part of it, and when the cut is undone?
4. **How an edit reaches a playing preview.** A cut changes the composition's timeline, not just the video composition. Rebuild the asset and replace the item? Something else? Where does the playhead land after a cut, and what does the user see during a trim-handle drag?
5. **What the editor shows.** The strip over output time (cuts collapse away) or over recording time (cuts shown as removed regions you can restore). How the user makes a cut, trims, selects, and removes a cut. Choose for the user, and justify it.
6. **The on-disk shape** of cuts in `project.json`, and its validation.

## Deliverable

A candidate design package under `docs/design/cuts/candidate/` in your own worktree: `rationale.md` shaped per the architect rationale template, and `sketch/` with Swift type and signature sketches (`fatalError("not implemented")` bodies, `// TODO` pseudocode for tricky logic). Do not change files outside `docs/design/cuts/candidate/`. You may write throwaway spikes under `docs/design/cuts/candidate/spike/` to measure an AVFoundation behaviour your design depends on (for example, how long replacing a player item takes, or whether an `AVMutableComposition` with gaps removed plays its audio without a click). Report what you measured and how.
