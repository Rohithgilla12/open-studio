# Trim and cuts

Accepted design for unit 4. The brief is `docs/design/brief-cuts.md`. `sketch/` holds the type sketch, `spike/main.swift` the measurements, and `rejected/` the other two candidates. Where the sketch and this document disagree, this document wins: the grafts listed under Synthesis decision were folded into the prose, not into the sketch.

## Problem

Every export today is the whole recording. This unit lets the user move the take's start and end inward and remove any number of ranges from the middle, and every surface (preview, export, stills, `osrec export`, the editor) shows the edited take. Undo, autosave, and reopening bring the cuts back exactly.

The shape is not obvious because one assumption runs through every layer: composition time equals recording time. `RecordingTime` is the zoom ranges' clock, the events' clock, the compositor's request time, the playhead, and the strip's axis. A cut splits that into two clocks, and every caller has to be on the right one. Phase A surfaced these constraints:

- One composition builder and one compositor serve preview, export, and stills. Same pixels for the same output time must hold by construction.
- `Timeline.frame(at:)` stays pure and lock-free. Springs are precomputed knots solved in closed form, and `SpringTrack` already collapses several changes at one time to the last.
- A cut changes the asset's timeline, not just its video composition. So the preview's claim that the item is never rebuilt no longer holds.
- The recorder's files are never written. Edits live in `project.json`, whose rule is that additive keys keep the version and a change of meaning bumps it.
- Zooms, auto-zoom clicks, and every event are recorded in recording time. The camera can end early, and a microphone, system audio, or camera track can start late through an empty edit in its own edit list (measured in the camera and system-audio designs).
- Speed changes come later and must fit the same map without a format break or a caller rewrite. Masks, captions, and edit-by-transcript read time through the same map.

## Usage (caller's view)

The editor adds a cut from a drag across the strip's ruler and restores it with Delete:

```swift
// TimelineStrip ruler gesture, one call per mouse event; endDrag makes it one undo step.
editor.markCut(from: scale.time(atX: drag.startLocation.x), to: scale.time(atX: drag.location.x))

// Trim handles at the strip's ends.
editor.trim(.start, to: scale.time(atX: x))

// Delete key with a cut selected.
editor.deleteSelection()          // .cut(id) restores it, .zoom(id) deletes the zoom
```

The editor's transport and strip read one playhead value in both clocks:

```swift
Text("\(TimeText.text(editor.playhead.output)) / \(TimeText.text(editor.outputDuration))")
PlayheadMarker().offset(x: scale.x(at: editor.playhead.recording))
```

The renderers build from one project value and never convert time themselves:

```swift
let media = try await SourceMedia.load(project.source)                 // I/O, once
let movie = MovieComposition(media: media, map: project.timeline.map)  // 0.4 ms for 100 cuts
// compositor:  let t = OutputTime(compositionTime: request.compositionTime)
//              scene.image(source: ..., camera: ..., at: t)          // Timeline.frame(at: OutputTime)
```

`osrec export --still 12000 take.osrec` writes the frame 12 s into the exported movie, not 12 s into the recording. `osrec inspect --timeline` prints the kept segments and joins before sampling frames.

## Shape

The design in one sentence: cuts are stored in recording time as the user's intent, one derived `TimeMap` converts between the clocks, and the map enters the system at exactly two builders. The composition builder lays the kept spans end to end, so composition time is output time. The Timeline builder retimes its springs onto output time. Everything downstream of those two builders, the compositor included, speaks output time and converts nothing.

Step 1. The two clocks and the map.

```
recording   0 ...[ kept A ).....cut.....[ kept B )....tail trim....| d
                  |        \           /         |
output            0 [ kept A )[ kept B )| duration
                              ^ join
TimeMap: recording(at: OutputTime) -> RecordingTime            total
         output(at: RecordingTime) -> OutputTime?             nil if cut
         output(collapsing: RecordingTime) -> OutputTime      inside a cut: its join
```

Step 2. Where the map enters. It is derived once and read by two builders.

```
Edits.cuts ──> Timeline(source, zooms, settings, cuts) ──> timeline.map
   (recording time,                │                          │
    the stored intent)             │ retimes spring changes    │ inserts kept spans
                                   v                          v
                          Timeline.frame(at: OutputTime)   MovieComposition(media, map)
                                   ^                          │ asset in output time
                                   │                          v
                           StyledCompositor  <───── AVPlayer / AVAssetReader / AVAssetImageGenerator
                    OutputTime(compositionTime:)     (preview, export, still: same builder)
```

Step 3. How a cut reaches a playing preview.

```
editor.drag("Cut") ─> Editor.project.edits.cuts changes ─> preview.show(project, landingAt: edge)
                                                               │ coalesced 33 ms, latest wins
                        map unchanged? ── yes ──> swap videoComposition / audioMix (today's path)
                              │ no
                              v
              MovieComposition(media, newMap)   0.06 ms (10 cuts)
              AVPlayerItem + videoComposition + audioMix
              player.replaceCurrentItem(with:)
              seek(newMap.output(collapsing: landing ?? old.recording(at: now)))
              restore rate                       build to first frame 55 ms median
```

### 1. Which times are which

`OutputTime` is a new struct beside `RecordingTime`, with the same integer microseconds and no initializer from it. It is not `Codable`, so an output time cannot reach `project.json` (grafted from the Sonnet candidate). The only conversions are the three `TimeMap` functions. Each layer's clock follows:

| Recording time | Output time |
|---|---|
| zooms, events, cursor changes, clicks, cuts, the strip's x axis, `StripScale` | `Timeline.frame(at:)`, compositor request time, the player's time, `Still.png(at:)`, `ExportReport.duration`, `osrec --still`, the transport label |

The CMTime bridges are named by clock: `OutputTime(compositionTime:)` and `.compositionTime` for the composition, and `RecordingTime.mediaTime` for the source ranges only the builder inserts. Today's `RecordingTime(_: CMTime)` is deleted, because it is the one conversion that would read a composition time as a recording time and compile (per type-system-discipline). The playhead travels as `Playhead(output:recording:)`, converted by the player with the map of the item that produced the tick. Neither the strip nor the transport ever converts.

### 2. Where the map lives and who calls it

`Edits.cuts` is the single source. `Project`'s existing `edits.didSet` rebuilds `Timeline`, which derives `timeline.map`. That is the only map instance, so there is no `Project.map` to drift (single source of truth, derived not synced). The callers are:

- **Compositor.** It calls nothing on the map. Composition time is output time, and it passes `OutputTime` to `scene.image(at:)`. The render design's comment, "a trim would add its map here and only here", is retired. The composition must drop the cut ranges anyway, or the player would play them, so the map has to live in the builder. Once it lives there, the compositor needs nothing.
- **Timeline.** `frame(at: o)` evaluates step state (cursor image, presses, typing and idle fades) at `map.recording(at: o)` and springs at `o`. It costs one more binary search per query (inferred sub-microsecond, not measured).
- **Composition builder.** `MovieComposition(media:map:)` inserts every track whole, exactly as `load` does today, then calls `removeTimeRange` once per cut, last cut first. One call moves every track, so lost, late, and short tracks need no per-track clipping (grafted from the Sonnet candidate, which measured it with an early-ending camera: 0 wrong frames of 341, 0 ms camera-to-screen skew).
- **Audio.** `audioMix(levels)` adds a ramp pair at every `map.joins` entry and a fade at a trimmed start or end.
- **Camera instructions.** `camera.end` becomes `map.output(collapsing: cameraEnd)`. Kept camera media is contiguous in output time from 0 to there, whether the loss falls before, inside, or after a cut, so today's two-range split is unchanged (inferred from the construction, not spiked with a camera).
- **Export and stills.** Both build from `project.timeline.map`. `framesTotal` and the still clamp already derive from `movie.duration`, which is now output time.
- **Editor.** It reads `edits.cuts` to draw, calls `Cuts` total edits, and reads `map.duration` for the label.

`SourceMedia` is split out of today's `MovieComposition.load`. It opens the movies once and retains the `AVURLAsset`s, because a track does not keep its asset alive. Measured in the spike, inserting from a track whose asset was released fails with -11800 and -12780 for every range. The preview keeps one `SourceMedia` for the editor's life and rebuilds compositions from it.

### 3. What a cut does to zooms

A cut never writes the zoom track. A stored zoom inside, across, or covering a cut is unchanged, so undoing or restoring the cut is exact by construction. Nothing needs restoring.

The effect follows one time rule, stated once in `Timeline`. What output frame `o` shows is the recording at `map.recording(at: o)`. Every spring chases the target it would chase at that recording instant, but is solved over output time. The mechanism is one function, `Retiming.apply`. The camera and cursor builders produce their `TargetChange` lists in recording time exactly as today. Then each change moves to `map.output(collapsing:)`. The map is monotone, so the lists stay sorted. Changes that collapse onto one join reduce to the last, and that one is dropped when it repeats the change already in effect. With no cuts nothing collapses, and today's tracks come out bit for bit. The cases follow:

- **A zoom wholly inside a cut** leaves no knot, so it has no effect on any kept frame. The test compares against the same take with the zoom deleted.
- **A zoom across a cut edge.** Its zoom-in or zoom-out change collapses onto the join, so the camera starts easing in or out at the join.
- **A zoom across a whole kept span** zooms in after the first join and out after the second.
- **The camera does not jump at a cut.** It carries its spring. Position and velocity are continuous at the join, and only the screen pixels cut. This is a deliberate product call (per experience-first). A zoomed camera that teleports to a different region of the screen at 2x leaves the viewer unsure where they are. A camera that pans there reads as intentional.
- **The cursor snaps at a cut.** The cursor stands for the user's hand, so a glide after a hard cut reads as lag, not as motion. `Retiming` inserts a rest knot at each join for the cursor position spring only: it starts the kept span at rest on the position the recording had there. (Settled by the cross-judge, which ruled on this design's own open question.)
- **Idle and typing hides follow the output clock.** `typingIntervals` and `idleIntervals` measure durations, so they run over the activity and key times mapped through `map.output(at:)`, dropping instants inside cuts, and `opacity` is evaluated at output time. A cut that removes a long wait therefore does not leave the cursor hidden after the join. Presses and the cursor image stay step functions of the recording instant. (Grafted from the Fable candidate's edited-events idea, without making the event types generic.)
- **A head trim.** Changes landing on output 0 fold into the initial value, so the edited take starts at rest on the zoom and pointer in effect where it now begins.
- **Speed later.** Only the map changes, so camera moves keep their pace in a 2x range instead of running at double speed.

Zooms inside cuts stay drawn on the strip, above the hatching, and stay editable. They are inert, not hidden.

### 4. How an edit reaches a playing preview

A cut changes the asset, so the preview replaces the item. It does this only when `timeline.map` changed. Picture and audio edits keep today's swap on the same item. `PreviewPlayer` keeps the player, owns the `(item, movie.map)` pair, and does every conversion with that pair. A tick from the old item is never read with the new map during the coalescing window.

Measured on the real 5 s 3456×2234 HEVC take, from composition build to the first decoded frame at the landing time through `AVPlayerItemVideoOutput`:

- **Paused:** 55 ms median, 56 ms p90.
- **Playing:** 62 ms median, 106 ms p90.
- **First replacement in the process:** 230 ms.
- **Control, a zero-tolerance seek inside one item:** 25 ms median, so replacement adds about 30 ms.

The playhead keeps the recording instant under it: `new.output(collapsing: old.recording(at: now))`. If that instant was just cut, it lands on the join, which is the first frame after the cut.

During a trim-handle or cut-edge drag, the preview does not rebuild per step (grafted from the Fable candidate). On the drag's first step `PreviewPlayer.showSource(at:)` pauses and swaps once to an uncut item, built from the same `SourceMedia` with `TimeMap.identity` and the current scene, and every step after that is a chased zero-tolerance seek to the handle's recording time: 7 to 48 ms a frame on the real take, against 55 ms per item swap. The user watches the exact frames they are removing or keeping, which is how you find the moment the demo starts. `endDrag` calls `show(project)`, which swaps back to the edited item once and lands by the rule above. So a gesture costs two item swaps, not eleven a second. The uncut item's spring state near the edge differs slightly from the edited take's, which is acceptable during a drag. `show` always returns to the edited item, so a zoom edit, an undo, or a save mid-drag cannot leave the uncut item showing. The strip's hatched region and the duration label update on every mouse event, because they read `Edits` directly.

`PreviewPlayer.player` stops being public. Callers get `surface: CALayer` and `isPlaying`. The spike did not measure whether an `AVPlayerLayer` shows a blank frame during the 55 ms swap. If it does, a second double-buffered player fits behind `surface` with no caller change.

### 5. What the editor shows

The strip stays over recording time, and cuts are hatched, dimmed regions you can see, select, resize, and restore. This choice is for the user, for four reasons:

- **Zooms stay put.** They are stored in recording time, so they do not slide when you cut. Over output time, a zoom across a cut would straddle a seam, and a zoom inside a cut would vanish while still existing in the data.
- **Restoring needs a target.** A removed range has width to click and Delete. A collapsed one has none.
- **The scale stays fixed during a trim drag.** Over output time, the axis rescales under the pointer as the duration changes, and the handle runs away from the mouse.
- **The cost is small.** The strip shows time the viewer never sees. The hatching marks it, and the label states output time and output duration.

The interactions are these:

- **Cut.** Drag across a new 16 pt ruler row above the zooms. The step computes from the cuts before the drag began, so dragging back shrinks the new cut.
- **Trim.** Drag the handles that sit at both ends of the strip at all times, or press `[` and `]` to trim the start or end to the playhead (grafted from the Sonnet candidate).
- **Select and restore.** Tap a removed region, then press Delete. Delete restores a selected cut or deletes a selected zoom, through one `Selection` enum.
- **Resize.** Drag a cut's edges. An edge dragged to the recording's start or end becomes a trim.
- **Scrub and play.** Scrubbing into a removed region lands on its end. During playback the marker jumps across each region, as the viewer's time does.

### 6. On-disk shape and validation

`project.json` gains `"cuts": [{ "id": "...", "range": { "start": µs, "end": µs } }]` in recording microseconds. That is the same `{id, range}` shape as a zoom, and trims are the cuts touching 0 or the duration. Ids are stored because a cut is a selectable, draggable object. A SwiftUI `ForEach` keyed on `range.start` would recreate the view and kill the gesture mid-drag.

The version is the lowest one whose reader renders the file correctly, decided in one function, `ProjectFile.version(for:)`:

- **No cuts: version 1.** Today's build keeps opening the file.
- **Cuts: version 2.** Today's build ignores unknown keys, so it would export the removed ranges, and its autosave would rewrite the file without them. The deleted mistake, or the password typed on screen, would come back. That changes what the file means, which the file's own rule says bumps the version. Today's build already refuses a newer version without rewriting it.
- **Speeds: version 3, later.** It is written only when speeds are present.

Validation happens at the boundary, in `ProjectFile.read`, after today's header checks. `Cuts(validating:within: duration)` rejects these cases with `ProjectError.invalidCuts`, and never repairs them:

- a cut outside the recording;
- overlapping cuts;
- a kept span shorter than `Cuts.minimumKept` (200 ms);
- nothing kept;
- a duplicate id.

Every edit inside the app is total, like `ZoomTrack`'s. Nearby cuts merge, kept spans clamp to the minimum, and an edit that would keep nothing returns the cuts unchanged. The 200 ms minimum is tied to the audio, because two 30 ms ramps must fit in every kept span.

### What the listener hears at a cut

Every track gets the same kept spans, so screen, microphone, system audio, and camera stay in sync.

- **Video is frame-exact.** 441 of 441 output frames carried exactly the source frame the map predicts, across a frame-aligned join, an unaligned join, and head and tail trims.
- **Audio stays sample-accurate.** The sample count was within 2 samples (42 µs) of the kept duration.
- **A hard join clicks.** On a 440 Hz sine, the largest sample step at a join was 0.42, against the sine's own 0.029.

The listener hears a dip. The audio fades to silence over the last 30 ms before each join and back in over the first 30 ms after, through the one `AVAudioMix`. A trimmed start fades in and a trimmed end fades out the same way. The mix applies ramps at a coarse granularity. 5, 10, and 20 ms ramps still left gains of 0.80, 0.60, and 0.16 at the join. 30 ms reached 0.02, with a largest step of 0.009, smaller than the sine's own. Ramps hold their end value: one ramp to 0 silenced the rest of the take. So each dip is a pair.

### Interface depth

The public additions are these:

- `OutputTime` and `Playhead`.
- `Cuts`, with its validating door and four total edits.
- `TimeMap`, with three conversions, `duration`, and `joins`.
- `Timeline(cuts:)` and `timeline.map`.
- `PreviewPlayer.show(_:landingAt:)`, `surface`, and `isPlaying`.
- Editor's `markCut`, `trim`, `resizeCut`, `restoreCut`, and `Selection`.

That surface hides these:

- the complement from cuts to kept spans;
- spring retiming and its collapse rule;
- per-track clipping for lost and late tracks;
- join fades and their measured length;
- item replacement, landing, and the item-to-map pairing;
- the version rule.

`SourceMedia`, `MovieComposition`, and `Retiming` stay internal, so no caller can build its own composition or retime its own springs.

### Spike results (measured)

Measured on 2026-10-21 with `docs/design/cuts/candidate/spike/main.swift`, built with `swiftc -O -swift-version 5` on this Mac (Apple Silicon, macOS 27). The inputs were the repo-root take `20261013-153859.osrec` (5 s, 3456×2234 HEVC, AAC microphone at 48 kHz, read only) and two synthetic movies the spike writes: a 10 s 440 Hz AAC sine and a 10 s 30 fps H.264 movie whose frames code their own index in two flat grey fields.

- **`audio`.** It reads the cut sine through `AVAssetReaderAudioMixOutput` as float LPCM. It compares each sample with the analytic sine at `map.recording(at:)` and measures the gain envelope around each join as one-period RMS. A first pass with 1 ms peak windows was wrong, because the window is shorter than one period, and it was discarded.
- **`frames`.** A passthrough custom compositor decodes the source frame index of every request and compares it with the map.
- **`replace`.** The real take plays through `AVPlayer` with a passthrough custom compositor. It runs 24 replacements per state, alternating four cut sets, and reports the last 20. A 1 ms poll of `hasNewPixelBuffer` sets the floor of resolution. The real `StyledCompositor` adds its own render time, about 10.5 ms per frame at 4K from the render design's measurement, which the passthrough compositor here does not pay.
- **`seek`.** The same wait without replacement, as the control.
- **`build`.** The composition build alone, median of 20, at 0, 10, 100, and 500 cuts: 0.021, 0.060, 0.427, and 2.27 ms.

These are not measured: the blank-frame question for `AVPlayerLayer`, whether `AVPlayer` applies the 30 ms ramps as cleanly as the reader does, and the camera with cuts.

## Synthesis decision

Three runners designed against `docs/design/brief-cuts.md` in separate worktrees: Opus (this package), Fable (`rejected/fable-rationale.md`), and Sonnet (`rejected/sonnet-rationale.md`). A Fable cross-judge scored them blind against the six-criterion rubric in the lead's notes. It recommended this candidate as the base, and so did the lead's own reading. The first Sonnet run produced nothing, because its worktree predated the brief's commit. It was relaunched and finished.

All three converged on most of the shape: a separate `OutputTime` type, cuts stored as `{id, range}` in recording time with trims as edge cuts, a derived map, item replacement on a cut, a strip over recording time with hatched cuts, an `AVAudioMix` dip at each join, and `project.json` version 2 only when cuts exist. Convergence across three model families is the strongest signal the arena gives, so none of those were reopened.

**Why this base.** The one divergence that cannot be grafted later is the springs' clock. Sonnet kept springs in recording time and mapped time in the compositor. That leaks removed content into kept frames: on main, `CameraTrack` places targets at `start - leadIn` and at `range.end`, so a zoom wholly inside a cut leaves its zoom-out tail settling after the join, and a zoom whose lead-in was cut appears fully zoomed at the join (verified by the judge against `CameraTrack.swift`). Fable and Opus both solve springs over output time. Opus does it with one internal pass over the existing `TargetChange` lists, which reproduces today's tracks bit for bit with no cuts. Fable makes three event types generic over the clock across seven files. Opus's shape is the smaller change with the same behaviour.

**Grafted.**
- From Sonnet: build the composition by inserting whole tracks, then `removeTimeRange` last first. It is one rule for every track, and the only approach measured with an early-ending camera.
- From Sonnet: `OutputTime` is not `Codable`.
- From Sonnet: `[` and `]` trim to the playhead.
- From Fable: during a trim or cut-edge drag, scrub an uncut item, and swap items once at the end of the gesture. That is two swaps per gesture instead of about eleven a second, and the user sees the frames being removed.
- From Fable: run idle and typing detection over the output clock, so a removed wait does not leave the cursor hidden after the join.
- Cross-judge ruling on this candidate's open question 3: the cursor snaps at a join, and the camera carries.

**Rejected.**
- Sonnet's `Rate` field in `TimeMap` from the first day. Callers already ask the map and do no arithmetic, so a rate lands later inside `TimeMap` and the builder with no caller change. A field nothing sets is dead weight now (per laziness-protocol).
- Fable's 100 ms dip (50 ms per side). Fable tested only 20 and 50 ms. Opus reached 0.02 gain at 30 ms, and Sonnet reached the tone's natural step at every length from 25 to 43 ms. The fade stays one named constant at 30 ms per side, pinned by an export click test.
- Fable's `Instant` and `Span` generics, for the reason above.
- Fable's `--no-cuts` export flag. `--auto-zooms` already ignores `project.json`. Add the flag when a caller needs it.

**Claims corrected in review.** This package claimed a measured 0.457 s microphone empty edit, which its spike does not show. The behaviour is documented in the camera and system-audio designs, and the line now cites those. Sonnet's 21 ms item swap was a synthetic movie timed to the first compositor request. The real-take numbers from Opus and Fable, 54 to 80 ms to a shown frame, are the ones this design uses.

## Tradeoffs accepted

- We accept rebuilding the player item on every cut edit, about 55 ms and 30 ms more than a seek, in exchange for one builder whose asset is the edited take for preview, export, and stills alike.
- We accept a second, uncut item that the preview shows only during a trim or cut-edge drag, in exchange for seek-speed feedback and two item swaps per gesture. `PreviewPlayer` owns the mode, and `show` always leaves it.
- We accept a 60 ms audio dip at every join, in exchange for no click and no second audio track per source. The dip is audible on music, and inaudible as a click on speech.
- We accept that springs carry across cuts, a pan or glide right after a jump cut, in exchange for a camera that never teleports and zooms inside cuts that have exactly no effect. A future reader might mistake the cursor glide for lag. It is the same rule as the camera, on purpose.
- We accept a strip that spends width on removed time, in exchange for zooms that never move when you cut and cuts you can see and restore.
- We accept an older build refusing any project with cuts, in exchange for never exporting what the user removed.
- We accept a runtime `precondition` that the scene's map equals the composition's, rather than a type, because every call site builds both from one `Project` value. The check catches the one way they could differ.

## Alternatives considered

- **A recording-time Timeline with the map in the compositor.** This is the render design's comment. It is the smallest diff and hides nothing new. It loses on behaviour. The camera jumps at every cut, and a zoom inside a cut leaks its zoom-out tail into the kept frames after it, because at the cut's end the recording-time spring is still settling from a zoom the viewer never saw. Speed ranges would also run camera moves at 2x. It also does not stay in one place, because the composition still has to drop the cut ranges.
- **A full-length asset with playback skipping cuts.** A boundary time observer would seek over each cut in preview, and the export would read kept ranges separately. That avoids item replacement. It splits preview and export into two paths, which breaks the one-builder rule, and it skips audio with a seek glitch at each cut.
- **Storing kept segments, with a rate per segment, instead of cuts.** Speed would become a field on the same records. A cut would then be the gap between two records, so restoring means merging records, and selecting a cut means selecting a gap. Cut edits and speed edits would also be entangled in one list. Storing the intent (cuts, later speeds) and deriving the map keeps each edit simple and the callers on one type.
- **Clipping or deleting zooms when a cut covers them.** This throws information away. Restoring a cut later, not through undo, could not bring the zoom back.
- **A strip over output time.** See section 5.
- **A/B-roll audio crossfades.** Alternating kept spans onto two tracks per source, with overlap, gives a true crossfade with no dip. It doubles the audio tracks, makes each source a list of track ids, and complicates the export's audible-only mix. The measured dip is clean enough to make that cost unjustified now.

## Implementation reconciliation

What the implementation (D11, branch head after this section) does differently from the text above, and why. Every item is a change in detail, not in shape; the file format and every signature other layers call are as designed.

- **`CutsError.overlap(UUID, UUID)` was added.** The sketch folded overlapping cuts into `keptTooShort`, but the file-validation rule lists overlap as its own case, and `ZoomTrackError.overlap` is the nearest precedent. Touching cuts (gap 0) are `keptTooShort(after:)`, since the kept span between them would be empty.
- **`Retiming` takes the `Cuts` as well as the map.** "Inside a cut" is decided with `cuts.cut(containing:)`, not `map.output(at:) == nil`, because the map's half-open spans also return nil for a change at exactly the recording's end, and dropping that change would change today's tracks through `rescaleShortIntervals`. Only changes from inside the head trim fold into the initial value; a change at exactly the trim's end springs in, as a change at 0 does today.
- **The cursor snap is a `snap` flag on `TargetChange`.** `SpringTrack` sets the knot's position to its target and its velocity to zero when the flag is set. `Retiming` appends one snapped change per join, on the target of the last change at or before the recording instant the join shows, sorted after any change at the same time.
- **Typing and idle intervals are computed in integer microseconds, not seconds.** The output clock's instants come from `map.output(at:)`; computing `last + window` in `Double` seconds differed by one ulp from today's integer sum and broke the bit-identity check.
- **`MovieComposition.duration` is the asset's duration, capped at `map.duration`.** For a recovered take whose screen movie is a frame short of the manifest, the composition is that much shorter, as today. On every other take it equals `map.duration`.
- **`RecordingTime(mediaTime:)` exists beside `.mediaTime`.** `SourceMedia` reads each track's end from its asset, and that is a recording-clock read. The deleted bridge is the composition-time one.
- **The preview's `isPlaying` is derived from the player's rate**, not stored, and `surface` is the `AVPlayerLayer` itself. `item` and `player` stay internal for the tests.
- **`Editor.drag` chooses what the preview shows through a private `PreviewStep`**: the edited project with a landing, or the uncut source at the handle. `endDrag` always calls `show(project)` so a gesture that changed nothing still leaves the uncut item. `openDrag` is set on a gesture's first step even when that step changes nothing, for the same reason.
- **Audible-only mixes and ramps.** A muted source gets ramps from 0 to 0; harmless, and it keeps one code path.
- **The no-cuts bit-identity test pins a hash of main's frames from a debug build.** An `-O` build of the same code on main differs at the last bit in 9 of 2880 frames of the committed fixture, so the pin is for the build `swift test` uses. The determinism check (`osrec inspect --check-determinism`) still passes within either build.
- **Measured on the real take `20261013-153859.osrec`** (5 s, head trim [0, 0.8 s), cut [2 s, 3 s)): the exported MP4 is 3.200 s with 192 frames at 60 fps and 3.199979 s of audio; the stills at output 1180 ms and 1220 ms are byte-identical to the uncut take's stills at 1980 ms and 3020 ms; `inspect --check-determinism` passes over the cut timeline (193 frames, 59 distinct). Open question 1 (a blank frame during the swap) and 2 (how `AVPlayer` renders the ramps) remain unmeasured in the app.

### Fix round (D12)

An independent review of the D11 commits found five defects. Each was checked against the code before any change; the tests named here fail on the D11 head and pass after.

- **A style edit during a trim drag trapped the preview (real).** `PreviewPlayer.apply` decided "same map" before awaiting its detached scene build. A `showSource` during the await swapped in the uncut item, and the picture-only branch then called `videoComposition(scene:)` with a cut scene against the identity map, firing the precondition. The decision is now `needsItem(for:)` and is made again after the build. `CutsPreviewSpec.aSourceScrubDuringAStyleEditsBuildDoesNotTrap` crashed the test process on D11.
- **A collapsed zoom-out flashed the camera at a join (real).** With zooms [2 s, 5 s) and [6.05 s, 8 s) and a cut [4 s, 6 s), the zoom-out landed on the join 50 ms before the zoom-in and `rescaleShortIntervals` squeezed it to settle in that gap: 2x to 1x to 2x. Two rules fix it, both in the retiming pass. `Retiming` marks a change it moved onto a join as `collapsed`, and `SpringTrack` does not rescale the interval on either side of one, because that interval is the cut's doing, not the user's timing. That alone still dipped to 1.79x (measured by the test), so a collapsed change whose target the next kept change restores before its spring would settle is dropped, and the restorer with it when it would only restate the change in effect (a restatement still ends the interval the rescale measures, which squeezed a 60 ms pan when the first rule ran alone). With no cuts nothing is marked and the pinned hash is unchanged. `TimelineCutSpec.aChangeCollapsedOntoAJoinIsNotSqueezedAgainstItsNeighbours` covers the zoom-in 50 ms after the join and a follow-centre change 10 ms either side of one: scale stays at 2x, and scale and centre speeds stay within the unsqueezed spring's.
- **`[` and `]` left a sliver before an earlier cut (real).** `Cuts.trimming` clamps against the first other cut, so with a cut at [2 s, 4 s) and the playhead at 4.5 s, `[` trimmed to 1.8 s and kept 200 ms before the old cut. `Editor.trimToPlayhead` now cuts [0, t) or [t, duration) through `cutting`, which merges every cut the trim covers. Handle drags keep clamping. `CutEditSpec.trimToPlayheadAbsorbsTheCutsItPassesWhileAHandleDragClamps`.
- **Playhead races around an item swap (real, one observed).** The new item's first periodic tick arrived at 0 before the landing seek completed and flashed the marker to the start; `CutsPreviewSpec.ticksAcrossACutAppliedDuringPlaybackNeverFlashToTheStart` recorded `Playhead(output: 0, recording: 0)` after the swap on D11. The same shape covered the two races the review inferred: a tick the replaced item queued being read with the new map, and an edit reading `player.currentTime()` while the previous landing was in flight. `PreviewPlayer` now keeps the seek in flight and the seek queued behind it as `OutputTime`s, and `now` is `queued ?? inFlight ?? item.currentTime()`. Ticks and `apply`'s landing both read `now`, so a seek's target counts from the moment it is requested, and the delivered observer time is unused. The replaced `playheadTicksCarryBothClocks` derived its expectation from the map the player converts with; the new test checks against the cut's arithmetic (output before the cut is the recording, after it the recording less the removed second).
- **The trimmed-start fade (not real).** `audioMix` sets `setVolume(gain, at: .zero)` and starts a ramp from 0 at zero. Measured through the export reader over a tone take trimmed at [0, 1.0037 s): the loudest sample in the first 3 ms is under 0.06 of a 0.4 tone, the amplitude is under 0.15 over the first 10 ms, between 0.1 and 0.3 over the next 10 ms, 0.4 from 50 ms, and no sample step through the fade exceeds the tone's own. The ramp wins. `CutsRenderSpec.aTrimmedStartFadesInFromSilence` pins what the listener hears; no production change.
- **The no-cuts pin now has a compiler-independent half.** `noCutsIsTodaysTimeline` keeps its hashes and names the toolchain they were printed on (Apple Swift 6.4, swiftlang-6.4.0.34.1, arm64, debug). `noCutsLeavesEveryTargetChangeWhereItWas` runs the real camera and cursor change builders (`CameraTrack.targetChanges`, `CursorTrack.positionChanges`, extracted from the inits) over the committed fixture and checks `Retiming.apply` with no cuts returns them exactly, time, target, spring, and order.
- **Two comments.** The `rate` note in `TimeMap.Segment` described the rejected speed field and is gone. `PreviewPlayer`'s "no seek after a composition swap" comment cited this design's open question 1 (the blank frame); the 300 ms recompose was measured in the render design, so it cites the accepted-render rationale's open question 1.

### Fix round (D13)

A re-review of the D12 commits found one regression and three smaller gaps.

- **The collapsed-change drop stranded the cursor (real, a D12 regression).** The drop pass also ran for the cursor, but the join snap looks up its target in the raw changes. With pointer samples at 0 s (300, 200), 5 s and 5.5 s (900, 700), and 6.1 s (300, 200), and a cut [4 s, 6 s), the pass dropped the collapsed move and the change 100 ms after the join that undoes it. The snap then restored (900, 700) and nothing moved the cursor back. The pass now runs only without `snapsAtJoins`. The cursor never rescales, and the snap already resolves the join, so the pass was only ever needed for the camera. `TimelineCutSpec.aCursorMoveUndoneJustAfterAJoinStillReturns` fails on D12. The input the review gave, with no sample at 5.5 s, does not reproduce the regression: `ShakeFilter` drops a one-sample excursion that returns, so the test's pointer rests at 5.5 s.
- **A build in flight when a drag began swapped the uncut item out (real).** `apply` now notes which item was up before its scene build and returns after the build if a drag swapped in the uncut item meanwhile. The drag's own `show` at `endDrag` carries the latest project and brings the edited item back. `CutsPreviewSpec.aDragThatBeginsDuringABuildKeepsTheUncutItemUp` fails on D12: the item is swapped and the scrubbed frame is gone.
- **The landing-seek test passed on the D11 code.** The 33 ms coalescing interval meant the cut's landing seek always finished before the undo read the playhead. It passed 6 of 6 runs against D11's `PreviewPlayer`. `editInterval` is now an instance property, and the test sets it to zero, so the undo reads the playhead one scene build after the swap. It now fails 5 of 5 runs on D11 and passes 5 of 5 on this head.
- **A seek on a failed item (completion not guaranteed, no change).** The header documents completion for an interrupted seek or a seek outside the seekable ranges, but says nothing about a failed item. A probe confirmed this. For a missing file, a seek issued after the item failed never completed within 5 s. A seek issued while the item was loading, as the landing seek is, completed at once. A stuck `inFlight` has no effect anyone could notice. A failed item cannot show a frame or recover (the header says a new instance is needed). `now` reads `queued` before `inFlight`, so the playhead still follows the latest scrub. `replace` clears both. The real gap is that a failed item is never surfaced or rebuilt, which is separate from the seek state.

## Open questions and risks

1. Does an `AVPlayerLayer` show a blank or black frame during the roughly 55 ms between `replaceCurrentItem` and the new item's first frame? The spike ran headless. If it does, should `PreviewPlayer` double-buffer two players behind `surface`?
2. Does `AVPlayer` render the 30 ms ramps as cleanly as `AVAssetReaderAudioMixOutput` did? Its render slice may differ. A tap on the preview's output, or a listen, would settle it before the fade length is final.
3. Resolved: the cursor snaps at a join, and the camera carries (see Synthesis decision).
4. Should Regenerate Zooms skip clicks inside cuts? Zooms there are inert but clutter the strip.
5. For a long take trimmed to a short one, should the strip offer a fit-to-kept zoom? Recording-time drawing spends most of its width on hatching then.
6. Is 200 ms the right minimum kept span? The floor from the audio is 60 ms. Above that it is a product call.

## Next implementation step

Add `OutputTime`, `Cuts`, and `TimeMap` with `TimeMapSpec` and `CutsSpec` passing. Then thread `Retiming` through `CameraTrack` and `CursorTrack`, with the no-cuts determinism test proving today's frames are unchanged. Migrate the `frame(at:)` call sites with a codemod that rewrites `frame(at: RecordingTime` arguments to `OutputTime`.
