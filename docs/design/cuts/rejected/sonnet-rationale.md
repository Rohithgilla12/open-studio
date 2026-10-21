# Trim and cuts: one map between two clocks

## Problem

Every export is the whole recording. The user needs to remove time at the ends (trim) and in the middle (cuts), and see the same edited take in the preview, the export, stills, `osrec export`, and the editor, with undo, autosave, and reopen restoring the cuts exactly.

What makes the shape non-obvious: today there is one time. `RecordingTime` is every time, and `Compositor.swift` says a trim "would add its map here and only here". After a cut there are two, and they flow through different code. Zooms, events, springs, and `Timeline.frame(at:)` live on the recording's clock. AVPlayer, `AVAssetReader`, and `AVAssetImageGenerator` live on the composition's clock. A cut also changes the composition's timeline, not just the video composition, and the existing preview swaps `item.videoComposition` on an item that "never rebuilds". Constraints carried in: one builder and one compositor (so "same pixels" holds by construction), `Timeline.frame(at:)` pure and lock-free, recorder files never written, edits total like `ZoomTrack`'s, the camera's early end still working, and `project.json` readable by today's build where possible. Later speed ranges, masks, captions, and edit-by-transcript must read time through the same map.

## Usage (caller's view)

Command line. Cuts apply to every export because `Project.open` reads them:

```
osrec export take.osrec --out demo.mp4                       # project.json's cuts, as the editor shows
osrec export take.osrec --out demo.mp4 --cut 3.0-5.5 --cut 9.25-9.4   # replaces project.json's cuts, like the format flags
osrec export take.osrec --still 5000 --still-dir out         # the frame at 5 s of the EXPORTED video
osrec inspect take.osrec --timeline                          # adds: cuts 3, kept 11.350 s of 20.000 s
```

`--still` takes output milliseconds, because a still is a frame of the exported file and the person reading `demo.mp4` at 5 s expects that frame. `inspect --timeline` stays in recording time, because it prints the Timeline.

Library callers:

```swift
var project = try Project.open(take)
if let (list, id) = project.edits.cuts.cutting(TimeRange(start: .seconds(3), end: .seconds(5.5))!) {
    project.edits.cuts = list                       // total; nil only when nothing would be left
}
project.edits.cuts = project.edits.cuts.trimming(.start, to: .seconds(1))   // the take starts at 1 s
project.timeMap.duration                            // OutputTime, the edited length
project.timeMap.recording(at: .seconds(2))          // RecordingTime 5.5 s: what the viewer sees at output 2 s
project.timeMap.output(nearest: .seconds(4))        // 4 s is cut, so the junction, output 2 s

let png = try await Still.png(project, at: .seconds(2))   // OutputTime
let report = try await Export.run(project, to: url)       // report.duration is an OutputTime
project.timeline.frame(at: .seconds(5.5))                  // RecordingTime only; passing an OutputTime does not compile
```

The editor, for the user: the strip stays over the recording. Cuts show as hatched regions at their true width, so a cut is a thing you can see, select, resize, and put back.

```
 recording  |--kept--|//////cut//////|------kept------|//cut//|--kept--|
            [<  trim handle                                  trim handle >]
            zooms:   [2.0x]            [1.5x   (dims inside the hatch)]
                          ^ playhead (drawn at the playhead's recording time)
 transport  0:04.2 / 0:11.3        (output time, edited length)
```

- Cut: shift-drag a range on the strip, press Delete (or the Cut button). The new cut is selected with its edges ready to drag.
- Trim: drag the two handles at the ends of the strip, or press `[` and `]` to trim to the playhead.
- Restore: click a hatched region and press Delete. Undo does the same.
- A click inside a hatched region scrubs to the junction. Delete on a selected zoom still deletes the zoom; there is one selection.

## Shape

### Step 1: two clocks, two types, one converter

```
 RecordingTime --------------------------+
   Timeline, ZoomTrack, springs,         |
   events, RenderScene.image(at:),       |     TimeMap     (the only conversion)
   the strip, project.json               +---> recording(at: OutputTime) -> RecordingTime
                                         |     output(at:) / output(nearest:) -> OutputTime
 OutputTime ------------------------------+    outputEdge(of:) -> OutputTime
   AVPlayer time, compositionTime,
   Still(at:), Export, the transport
```

`OutputTime` is a separate struct from `RecordingTime` with the same representation and no initialiser between them, and it is not `Codable`, so an output time cannot reach disk. `RecordingTime.init(_ CMTime)` is deleted and replaced by two named bridges: `OutputTime(compositionTime:)` for everything AVFoundation hands over from a composition, and `RecordingTime(sourceMediaTime:)` for media read from a source movie before any cut (only `MovieComposition.load` uses it, for the camera's end). A call site that reads a time off AVFoundation without choosing a clock stops compiling. Per `type-system-discipline`: the wrong call fails the build, not a test.

Each API accepts exactly one clock. `Timeline`, `ZoomTrack`, `RenderScene.image(at:)`, and the strip's `StripScale` take `RecordingTime` and are unchanged. `PreviewPlayer.scrub` and `playhead()`, `Still.png`, and the transport take `OutputTime`.

### Step 2: the cut list is the stored intent, the map is derived

```
 Edits.cuts: CutList  --derives-->  TimeMap  --consumed by--> MovieComposition (asset, camera ranges, audio fades)
 (project.json)                     (pieces)                  StyledCompositor (via SceneInstruction)
                                                              PreviewPlayer, Editor, Still, Export
```

`CutList` stores the removed ranges, not the kept pieces, because what the user did (remove 3.0 to 5.5 s) is the stable quantity. It carries the recording's duration, so its invariants are checkable inside the type and no edit takes a duration argument: cuts sorted, inside the recording, disjoint, never touching (touching cuts merge), unique ids, every cut and every kept stretch at least 100 ms. A cut that leaves nothing, an overlap, and a cut outside the recording cannot be built. Edits are total and follow `ZoomTrack`: `cutting`, `restoring`, `resizing`, `trimming` clamp or return `self`. Only `init(validating:within:)` throws, for the file.

Trim is not a second concept. A cut that starts at 0 is the trimmed start; one that ends at the duration is the trimmed end. The trim handles are `trimming(_:to:)`, which creates, resizes, or removes the edge cut. One list, one validation, no way to trim and cut the same second twice.

`TimeMap` is a list of kept pieces (`source`, `outputStart`, `rate`), derived by `TimeMap(CutList)`, which cannot fail because the list already guarantees the invariants. `rate` is `Rate.unit` today and is in the arithmetic from the first day, so a speed range later adds a producer of non-unit rates and changes no caller. It is pure, `Sendable`, and costs one binary search per query.

### Step 3: where the map lives and who calls it (question 2)

```
 Project.timeMap  ---->  MovieComposition.load(source, timeMap)  /  .recut(timeMap)
                                |
                                +-- asset: full tracks inserted, then removeTimeRange per cut (last first)
                                +-- instructionRanges: camera.end -> timeMap.outputEdge(of:)
                                +-- audioMix: levels + AudioFades.ramps(for: timeMap)
                                +-- SceneInstruction(timeMap:)  ---> compositor:
                                        t = instruction.timeMap.recording(at: OutputTime(compositionTime:))
                                        scene.image(source:camera:at: t)       // scene, Timeline unchanged
```

`MovieComposition` owns the map. The asset it built, the compositor's conversion, the camera boundary, and the fades all use that one value, and `RenderScene` does not know cuts exist. A scene therefore cannot disagree with its asset about the cuts, which is the same by-construction argument the accepted render design makes for one builder.

Each caller:

- Compositor: `recording(at:)`, the line the old comment promised.
- Camera instructions: `outputEdge(of: camera.end)`. A cut before the camera's end moves the boundary earlier; a cut across it makes the junction the boundary (the camera's last frame is the last frame before the cut); a cut after changes nothing; a camera that ended inside a trimmed start gives output 0 and takes the existing no-camera branch.
- Audio: `splices` give the fade positions; there is one list of splices.
- Export: `MovieComposition.load(source, timeMap: project.timeMap)`; `framesTotal` already counts from `movie.duration`, now the output duration.
- Stills: `Still.png(at: OutputTime)`, clamped one frame before `movie.duration` as now.
- Editor: `playheadRecording = timeMap.recording(at: playhead)` for drawing, `output(nearest:)` for strip clicks, `output(at:) == nil` to refuse a new zoom inside a cut.

The composition is built by inserting every track whole, as today, and then calling `removeTimeRange` once per cut, last cut first. Removing from the composition rather than inserting per kept piece per track keeps all tracks in step by construction: one call moves every track whatever its extent. `scaleTimeRange` on the same composition is how a rate would land later, after the removals; that part is not measured.

### Step 4: what a cut does to zooms and the camera (question 3)

Zooms, springs, and the cursor stay in recording time and are never rewritten. A zoom inside a cut stays stored and is invisible; a zoom across a cut edge shows only its kept part; a zoom across a whole kept range just applies. Undoing the cut brings back every zoom unchanged, because nothing touched them.

The camera does not carry its spring across a cut. `Timeline.frame(at:)` is evaluated at the recording time of the frame being drawn, so the first frame after a cut shows the camera state that belongs to the content on screen. The screen content jumps at a cut anyway, and a zoom that follows the pointer needs to be where the pointer is. The cost is a visible jump in zoom and position at a cut when the two sides differ. The alternative below explains why carrying it is worse.

### Step 5: how an edit reaches a playing preview (question 4)

The measurements decide this. An `AVPlayerItem` does not follow its composition: mutating the `AVMutableComposition` under a live item moved the asset's duration from 20.0 to 18.0 s and left `item.duration` at 20.0 s. A cut therefore needs a new item. Building the composition and item is cheap, and the AVPlayer and its layer stay the same.

```
 Editor.apply / drag  -->  PreviewPlayer.show(project, anchor:)
                               | (coalesced, latest wins, 33 ms)
                               +-- map unchanged: swap item.videoComposition / audioMix (as today)
                               +-- map changed:   rebuild
                                      at = anchor ?? oldMap.recording(at: player time)
                                      movie = movie.recut(newMap); new item; player.replaceCurrentItem
                                      seek(newMap.output(nearest: at), zero tolerance); resume if playing
```

The playhead is anchored on a recording time across the rebuild. A cut that covers it lands it at the junction. Undoing the cut puts it back, because the recording time never changed. During a trim-handle or cut-edge drag the editor passes the recording time of the frame to show as `anchor`: for a trim-in handle, the new first frame; for a start edge of a cut, the last frame before it; for an end edge, the first frame after it. The preview shows that frame as the output will have it. It is the real composition rebuilt as fast as a rebuild finishes (one in flight, latest wins), with no second item and no second preview mode.

### Step 6: what the strip shows (question 5)

Over recording time, with cuts hatched at their true width. Reasons: every other edit (zooms, their edges, the playhead's meaning) is already in recording time, so nothing converts; a cut is something the user can see, select, resize, and restore; zooms hidden by a cut stay reachable, dimmed; and the strip's maths (`StripScale`) does not change. The cost is that a take that is mostly cut is mostly hatch, and the transport's duration disagrees with the strip's length. Rejected: the output-time strip, where cuts collapse away. It makes zoom edits convert coordinates, makes a zoom inside a cut unreachable, and needs a scar to click to restore a cut.

### Step 7: on disk (question 6)

```json
"cuts": [ { "id": "…", "range": { "start": 3000000, "end": 5500000 } } ]
```

Recording-time microseconds, the zooms' unit. The key is written only when there is a cut, and then `version` is 2. A take with no cuts writes today's bytes at version 1, so today's build still opens it. A file with cuts is version 2 because an older build would otherwise open it, export the whole take, and on its next autosave rewrite the file without the cuts. Refusing (`projectFromNewerVersion`) is the safe outcome. The recording format already makes this choice for system audio. The header is read first, as now.

Validation at read: decode, then `CutList(validating:within: source.duration)`, throwing `ProjectError.invalidCuts(CutListError)` for outside the recording, overlap, touching, duplicate id, or a stretch shorter than 100 ms. Zooms are checked against the same duration. A later `speeds` key is additive in the same way and does not change cuts.

### Audio at a cut

The video cuts hard. The audio dips: a fade out over the 30 ms before the splice, silence at the instant, a fade in over the 30 ms after. No audio moves, so audio and video stay in step. A trimmed start fades in and a trimmed end fades out; the recording's own start and end do not. The listener hears a 60 ms dip centred on each cut instead of a click. The fades are `AVAudioMix` volume ramps built from `TimeMap.splices`, so preview and export get the same mix. Why 30 ms is in the measurements.

### Interface depth

Public surface added: `OutputTime`, `Cut`, `CutList` (four edits, `kept`, `timeMap`), `TimeMap` (five queries), `MovieComposition.load/recut`, and one `anchor:` parameter on `PreviewPlayer.show`. It hides piece search, the rate arithmetic, slivers and merging, the composition's removal order, the camera boundary, the fade placement, the item replacement, and the playhead anchoring. A caller never coordinates two calls to complete one operation: the editor calls `cutting` and `apply`; the player decides whether that needs a rebuild. Internals that must not leak: `TimeMap`'s piece initialiser is not public (only `CutList` derives one), so a hand-built map cannot disagree with a cut list, and `Edits.cuts` holds the only copy of the cuts, so there is no hand-synced list of kept and removed ranges.

## Measurements

Spike: `docs/design/cuts/candidate/spike/cuts-spike.swift` (macOS 27 SDK, Apple Silicon, `swiftc -O`). It writes a synthetic 20 s, 100 fps screen movie and a 12 s camera movie whose frames encode their own millisecond in 16 black and white blocks, plus a 437 Hz tone in an LPCM movie. The cuts are 0 to 1 s, 3.0 to 5.5 s, 9.25 to 9.4 s, and 15 to 20 s, so the take is 11.350 s. The camera ends at 12 s of source, which falls in a kept range. Not run on a real take.

| Question | Measured |
| --- | --- |
| Duration after `removeTimeRange` for four cuts | 11.350 s against 11.350 s expected, 0 us error. Before clamping the tone (which ran 10.7 ms past the video) the composition was 10.7 ms long: `composition.duration` is the longest track, so the loader's existing clamp is load-bearing. |
| Source time the compositor receives, `AVAssetReader` over the cut composition at 30 fps | 341 requests, no missing source frame. Decoded source time against `map.recording(at:)`: at most 6.7 ms apart, inside the 10 ms source frame spacing. The camera decoded the same source time as the screen on every frame (0 ms difference), and was present exactly while the map said the recording was before its 12 s end (0 wrong of 341). |
| Camera instruction boundary | Output 8.350 s, equal to `outputEdge(of: 12.0)`: 2 + 3.75 + 2.6. |
| Audio step at the splice at 9.4 s (437 Hz, 0.5 amplitude, natural step 0.0286) | No ramp 0.975; 2 ms 0.898; 8 ms 0.664; 20 ms 0.196; 25, 30, 35, and 43 ms 0.0286. The gain observed at the splice for 20 ms was about 0.2, not 0, so the mixer applies ramps in coarse slices (inferred, about 1024 frames or 21 ms at 48 kHz). The splice at 3.0 to 5.5 s had no click in any variant because the tone is at a zero crossing on both sides; the tone's phase, not the cut, saved it. Sample count equals composition duration exactly (544 800 at 48 kHz). |
| Mutating a composition under a live item | Asset duration 20.0 to 18.0 s; `item.duration` stayed 20.0 s. A new item is required. |
| New composition and item (cheap) | 0.9 ms median, 2.9 max (12 rounds). |
| `replaceCurrentItem` plus seek to first compositor request, paused | 21.1 ms median, 29.4 max. To `readyToPlay`: 19.2 ms median, 25.3 max. |
| Same, while playing | 72.0 ms median, 106.3 max. |
| Composition build with N cuts | 0 cuts 0.02 ms, 10 cuts 0.09 ms, 100 cuts 0.73 ms, 1000 cuts 26 ms (best of 5). |

Not measured, so inferred: the styled compositor's render cost on top of the 21 ms (a 4K frame was about 11 ms in the earlier export measurements, which would put a drag's cadence near 40 ms per rebuild); whether `AVPlayer`'s own audio path ramps in the same slices as the reader's (both use `AVAudioMix`, and the design builds one mix for both); the camera's late-start edit list through `removeTimeRange` (the spike's camera starts at 0); and `scaleTimeRange` for a future rate.

## Synthesis decision

Single candidate, filled in by the arena.

## Tradeoffs accepted

- We accept a visible zoom and position jump at a cut where the two sides differ, in exchange for `Timeline` staying pure, in recording time, and untouched, and for the camera always matching the content on screen.
- We accept a 60 ms audio dip at every cut in exchange for no click. A shorter fade does not reach silence in the mixer (measured).
- We accept a player item rebuild on every map change (21 ms paused, 72 ms playing, measured), in exchange for one builder, one compositor, and an asset that is correct by construction. A playing preview has a short gap when a cut is made.
- We accept a recording-time strip that shows removed time at its true width, in exchange for no coordinate conversion in any zoom edit and a cut the user can see and restore.
- We accept a file version bump to 2 when cuts exist, in exchange for no older build silently exporting the uncut take and dropping the cuts on autosave. Takes without cuts stay readable.
- We accept a 100 ms floor on cuts and kept stretches in exchange for no empty or sliver pieces in the composition, and for fades that cannot overlap. A user cannot cut 50 ms.
- We accept `Rate` and the rate arithmetic in `TimeMap` with only `.unit` constructed, in exchange for speed ranges later changing no caller. It looks like premature generality and is the one place it is cheap.
- We accept that a cut rebuilds the whole composition (26 ms at 1000 cuts, measured) in exchange for not tracking which cut changed.

## Alternatives considered

- **Output-time Timeline (carry the spring across the cut).** Remap zooms and pointer events into output time and build `Timeline` over that. Smooth camera across a cut, but a zoom that follows the pointer needs the camera where the pointer is, and the pointer jumped; the camera would pan after the cut while the content already changed, with the cursor off screen. It rewrites stored zooms on every cut and undo, makes `Timeline` depend on cuts, and puts a second time inside the one module that should have one. It hides little and exposes the remapping to every producer (masks, captions). Lost on depth and on correctness.
- **Kept-pieces list on disk (`clips`, an edit decision list).** The usual video-editor shape and a close contender. Lost because the default must write the take's duration into the file, restoring a cut means recomputing gaps, and a rate per kept piece conflates what was removed with what was sped up. Cuts and a future `speeds` list in recording time compose independently, and the kept pieces are derived once in `TimeMap`.
- **A separate `trim` beside `cuts`.** Two concepts, two validations, and a trimmed range that a cut can overlap. Lost on "two ways to do one task". One list with trim as an edge cut loses nothing the user can do.
- **Preview skips cuts by seeking** (player time observer jumps over cuts, composition uncut). One composition for export and another behaviour for preview: the two paths the constraint forbids, plus audible gaps. Lost.
- **Mutate the composition under the live item.** Measured not to work (`item.duration` stayed stale). Lost.
- **A second, uncut item for handle drags.** Shows the dragged edge by scrubbing the full take, but needs two items and a mode switch, and the viewer sees an uncut take while editing. The rebuilt-item drag shows the frame as the output will have it with no second path. Lost.
- **Output-time strip.** See step 6.
- **Audio crossfade with overlapping handles.** Needs audio from inside the cut on both sides and shortens the audio by the overlap, so audio and video drift by the fade length per cut. Lost for sync; the dip keeps every sample where it was.
- **Insert each kept piece per track instead of removing ranges.** More calls, and per-track piece extents (an audio track shorter than the video, a camera that ends early) each need their own clipping. `removeTimeRange` has one rule for all tracks.

## Implementation reconciliation

Not started. To be filled during implementation with accepted deviations and their acceptance sources.

## Open questions and risks

- Should the camera ease across a cut after all, for example a settle over 200 ms when the two sides differ by more than a threshold? It would be a `TimelineSettings` option over the recording-time Timeline, not a change of clock.
- A 60 ms audio dip is audible on speech with a short cut. Is it acceptable, or should the user choose a hard splice for a cut? The mixer's slice size sets the floor, not taste.
- Should cut edges snap to the source's video frames or to zoom edges? The design stores microseconds and does not snap.
- Is 100 ms the right floor, given three frames at 30 fps?
- A mostly-cut take is mostly hatch. Is a "fit to kept" strip zoom needed in the first version?
- Does `AVPlayer`'s playback ramp in the same slices as the reader? Needs an audible check on the preview before the fade length is final.
- The camera's late-start edit list through `removeTimeRange` is untested.
- `osrec export --cut` replaces project.json's cuts for one export, like the format flags do. Is replacing right, or should it be refused when project.json has cuts?
- Should `--still` accept recording time too, for scripts that locate a moment from `inspect --timeline`?

## Next implementation step

Add `OutputTime`, `Rate`, `Cut`, `CutList`, and `TimeMap` to `Sources/Timeline` with their tests (invariants, total edits, `recording` and `output` round trips, `outputEdge`), and delete `RecordingTime.init(_ CMTime)` so the compiler lists every call site that must name a clock.
