# Candidate design (fable): trim and cuts

Sketch: `sketch/` (Swift, bodies `fatalError("not implemented")`, TODO pseudocode where the logic is not obvious). Spike: `spike/main.swift`, numbers under [Measured](#measured).

## Problem

Remove time from a take: trim both ends, and cut any number of ranges from the middle. Preview, export, stills, `osrec`, and the editor must all show the edited take, and the cuts must round-trip through undo, autosave, and `project.json`. Five things about the existing system make the shape non-obvious.

- There is one clock. `RecordingTime` is microseconds from the first screen frame, and zooms, events, springs, the compositor's request time, the player's playhead, the strip, and `Still.png(at:)` all use it. A cut creates a second clock, and the types have to keep the two apart.
- The composition is built once per take and "never changes after an edit", and the preview's `AVPlayerItem` is "never rebuilt". A cut changes the asset's timeline, not the video composition, so one of those two sentences has to go.
- `Timeline.frame(at:)` must stay pure and lock-free, and preview, export, and stills must keep one builder and one compositor.
- The camera can end early, the audio tracks can be shorter than the screen, and every one of them has to stay in sync across a cut.
- Masks, captions, edit-by-transcript, and speed changes come later and read time through whatever map this unit designs.

## Usage (caller's view)

The editor, through `Editor`:

```swift
editor.dragCut(anchor: a, to: t)        // per mouse event on the cut lane: carves [a, t) live
editor.endDrag()                        // one undo step; the preview swaps to the cut take once
editor.dragTrim(.start, to: t)          // the left handle
editor.restoreCut(id)                   // puts the time back
editor.scrub(toRecording: t)            // a click on the strip lands on the nearest kept time
editor.playheadInRecording              // where to draw the playhead on the strip
```

Library callers (`osrec`, `Studio`):

```swift
var project = try Project.open(take)
project.edits.cuts = project.edits.cuts.removing(TimeRange(start: .seconds(3), end: .seconds(6))!)!.cuts
project.map.outputDuration                       // 7 s of a 10 s take
project.map.recording(at: .seconds(4))           // 7 s: the frame the viewer sees at 4 s
project.timeline.frame(at: OutputTime.seconds(4)) // camera and cursor on the output clock
try project.save()                               // project.json version 2, cuts as recording-time ranges

let report = try await Export.run(project, to: url)   // report.duration is an OutputTime
let png = try await Still.png(project, at: OutputTime.seconds(4))
```

The command line:

```
osrec export take.osrec --out demo.mp4            # cuts from project.json
osrec export take.osrec --still 4000              # the exported movie's frame at 4.000 s
osrec export take.osrec --out whole.mp4 --no-cuts # the recording with the saved zooms, nothing removed
osrec inspect take.osrec --timeline               # prints the cuts and the output duration
```

## Shape

### Step 1: two clocks, one bridge

```
   RecordingTime ───────────── TimeMap ───────────── OutputTime
   zooms, cuts, events,        derived from Cuts,    composition, player, export,
   springs' inputs, the strip  the only converter    stills, Timeline.frame(at:)
```

- `Instant` is a protocol with the arithmetic `RecordingTime` has today. `RecordingTime` and the new `OutputTime` conform, `Span<Time: Instant>` replaces `TimeRange` (which stays as the recording-clock alias, so zooms and `project.json` do not change), and nothing converts between the clocks except `TimeMap`. Passing one as the other does not compile, per type-system-discipline. Render keeps `OutputTime(CMTime)` as its one bridge from AVFoundation; `RecordingTime(CMTime)` is deleted from Render, and `RecordingTime.cmTime` survives only for inserting source ranges.
- `Cuts` is the stored edit: sorted, disjoint cuts with ids, at least 200 ms apart, inside the recording, leaving at least 200 ms in total. A trim is a cut touching 0 or the duration, derived, never a second field to keep in step. Every edit is total (`removing`, `resizing`, `trimming`, `restoring`), clamps or merges instead of throwing, and `init(validating:within:)` is the only throwing door, as for `ZoomTrack`. A cut that leaves nothing is unrepresentable, overlapping cuts are merged, and cuts outside the recording are clamped by edits and rejected at the file boundary.
- `TimeMap` is derived from `Cuts` and never stored. It is a non-empty list of segments `{output, source, rate}` laid end to end from output 0. `rate` is `.normal` today and is the hook for speed: a later rate is a new segment value here and a `scaleTimeRange` in the composition, and no caller changes because callers ask the map (`recording(at:)`, `output(at:)`, `outputAtOrAfter(_:)`, `output(_ range:)`) and do no arithmetic of their own. The format gains a `speed` key later, additive.

### Step 2: the Timeline runs on the output clock

```
SourceRecording (recording clock)
      │  TimeMap.edited(source)   once per Timeline: instants inside a cut dropped,
      ▼                           held state restamped at each segment's start
EditedEvents (output clock) ──┬──▶ CameraTrack(events, zooms mapped: clipped and collapsed)
zooms (recording) ─ map.output(range) ┘           CursorTrack(events)
      ▼
Timeline.frame(at: OutputTime)   pure, lock-free, one more immutable table
```

- The springs, the pointer groups, the typing and idle detection, and the press intervals see the edited events and never learn a cut happened, so the camera carries its spring across a cut instead of jumping, and the cursor glides from where it was to where it is over its usual settle time. The screen content itself cuts, which is what the user asked for. This answers the accepted design's open question "clock for edits" with output time.
- A zoom inside a cut contributes nothing, a zoom across a cut edge is clipped, and a zoom spanning a cut becomes one shorter zoom. The stored zoom is never touched, so undoing the cut brings it back whole, per "derive instead of sync".
- `PointerSample`, `ButtonEvent`, and `CursorChange` become generic over `Instant`. Six files name them today, mostly as annotations.

### Step 3: one builder, three consumers, now with an edit list

```
Footage.load(source)                 once per take, the only I/O: tracks, their ends, warnings
   │
   ├─ .edited(map) ─▶ EditedMovie   per cuts change, no I/O (0.03 ms for 2 segments, 0.6 ms for 100)
   │                    AVComposition: for each track, for each segment, insert source ∩ [0, track.end) at output.start
   │                    cameraEnd = map.outputAtOrAfter(camera.end)
   │                    .videoComposition(scene, fps)   instructions split at cameraEnd
   │                    .audioMix(levels)               level, plus a 50 ms ramp to 0 and back at every splice
   │
   ├──────────────┬──────────────────┐
AVPlayerItem   AVAssetReader     AVAssetImageGenerator
```

- The composition's edit list is the cut. The compositor is unchanged in shape: composition time is output time by construction, and the timeline already runs on it, so the one line that bridged `CMTime` reads `OutputTime(request.compositionTime)` and no map is consulted per frame. Measured: the reader handed the compositor the source frame for the mapped recording time at all 420 requests across a splice (frame 180, then 361), with PTS spaced exactly 1/60 s and `ceil(duration × fps)` frames, so `framesTotal` keeps its formula.
- Audio, screen, and camera stay in sync because one loop inserts every track by the same segments. A track shorter than the take (a lost microphone, an unplugged camera) is intersected per segment, and a segment with nothing to insert leaves a gap, which plays as silence or no camera frame.
- The camera's early end reduces to one time. A cut before, across, or after it all give `map.outputAtOrAfter(camera.end)`, and the instruction ranges split there as they split at `camera.end` today.
- What the listener hears at a cut. `AVAudioMix` applies a volume ramp at about one 1024-sample block of granularity (measured below), so a ramp shorter than a block is still a click. Each splice gets a 50 ms ramp to silence before it and a 50 ms ramp back after it, which turned a 0.797 sample step into 0.002. The listener hears a 100 ms dip at each cut, not a click. A trimmed start gets the fade-in only, a trimmed end the fade-out only. The ramps live in the one `audioMix`, so preview and export dip identically.

### Step 4: an edit reaching the playing preview

```
zoom or style edit ─▶ preview.show(project) ─▶ swap item.videoComposition (as today, item kept)
cut edit           ─▶ preview.show(project) ─▶ footage.edited(map) ─▶ new AVPlayerItem ─▶ replaceCurrentItem
                                               seek to map.outputAtOrAfter(recording time under the playhead)
cut-handle drag    ─▶ preview.showSource(at: t) ─▶ first call: uncut item, paused (one swap)
                                                   each call: zero-tolerance seek, chased
drag end           ─▶ preview.show(project)     ─▶ back to the edited item, playhead lands as above
```

- A cut replaces the item, because the asset's edit list is the cut and an `AVComposition` given to an item is immutable. Measured on the real 3456x2234 HEVC take, `replaceCurrentItem` plus a zero-tolerance seek shows the new frame in 54 to 80 ms (three runs, 18 swaps). A plain zero-tolerance seek on the same item shows one in 7 to 48 ms. So one swap per gesture is invisible, and a swap per drag step would cap a drag near 12 updates a second.
- During a drag the player shows the whole recording, paused, scrubbed to the handle by recording time. The user watches the frames they are removing, which is how you find the moment the demo starts, and they get the existing seek chasing at 7 to 48 ms a frame. The uncut item is built once per gesture with a scene for `cuts = none`, reusing the assets. `show` always returns to the edited item, so a zoom edit, an undo, or a save during a drag cannot leave the source item showing.
- Where the playhead lands, one rule, owned by `PreviewPlayer`: the first output time whose recording time is at or after the recording time that was under the playhead. A cut around the playhead lands it on the first frame after the cut, which is where playback would continue; a cut elsewhere leaves the frame on screen unchanged; undoing a cut lands it on the same recording time. `playhead()` yields the landing, so the editor and the strip follow without knowing the rule.

### Step 5: what the editor shows

```
   ┌─ cut lane ──────────────────────────────────────────────────────────────┐
   │▐▌ kept ░░░░░ cut ░░░░░ kept                        kept ▐▌               │  trim handles at the ends
   └─────────────────────────────────────────────────────────────────────────┘
   ┌─ zoom strip ────────────────────────────────────────────────────────────┐
   │   [ 2.0x ]        [ 2.0x, dimmed: inside the cut ]     [ 2.0x ]          │
   └─────────────────────────────────────────────────────────────────────────┘
        ▲ playhead at map.recording(at: playhead), across both lanes          transport: 0:04.2 / 0:07.0 (output)
```

- The strip spans the recording, and cuts show as hatched regions. Three reasons. Zooms are stored in recording time and stay editable under a cut; on an output-clock strip every zoom block would jump at every cut, and the block for a zoom inside a cut would have nowhere to be. A restore needs a thing to point at. And the playhead needs one conversion, `map.recording(at:)`, done in `Editor`. The cost is that the strip's length is the recording's, not the export's, so the transport shows output time beside the playhead.
- Drag to cut. Dragging across kept time on the cut lane carves a cut live and the preview follows the moving edge; releasing makes one undo step. A click scrubs. Trimming is the same gesture from a handle at either end. A cut's edges drag, a cut sweeping into a neighbour merges it, and selecting a cut and pressing Delete restores it. No mark-in, mark-out, or split mode, so there is one way to make a cut and one way to undo it.

### Step 6: on disk

```json
{ "format": "open-studio.project", "version": 2, "recordingID": "…",
  "zooms": [ … ],
  "cuts": [ { "id": "…", "range": { "start": 3000250, "end": 6000750 } } ],
  "settings": { … }, "style": { … }, "output": { … }, "audio": { … } }
```

- Cuts are recording-time ranges with ids, the same shape as a zoom's range. `version` is the lowest that can express the file: a file without cuts is written exactly as today, version 1; a file with any cut is version 2. Today's build refuses a version 2 file with `projectFromNewerVersion`, and `--auto-zooms` still exports. The alternative, an additive key at version 1, would have today's build open the take, show the whole recording, and drop the cuts on its next autosave. That is the silent loss the project file's rules exist to prevent, and the reason the camera and system audio bumped their manifest.
- Validation at the boundary, per boundary-discipline. `ProjectFile` decodes `cuts` as wire values and builds `Cuts(validating:within: duration)` in `read`, which rejects overlap, a cut outside the recording, a duplicate id, and a file that leaves nothing (`ProjectError.invalidCuts`). Inside the system `Cuts` and `TimeMap` are trusted.

### Interface depth

Public, Timeline: `OutputTime`, `Span`, `Cut`, `Cuts` with four total edits, `TimeMap` with five queries, and `Timeline.map`. Public, Render: `Edits.cuts`, `Project.map`, `PreviewPlayer.showSource(at:)`, and the clock change on `scrub`, `playhead`, `Export`, and `Still`. Behind that sit the edit-list build, the per-track intersection with early ends, the camera split, the splice ramps, the item replacement, the source-scrub mode, and the playhead landing rule. `Footage` and `EditedMovie` are internal, so nobody can build a second composition and drift from the shared one. The compositor, `RenderScene`, `FrameGeometry`, and the springs do not change.

What it deliberately does not do: speed changes (the map carries the rate, nothing reads it), thumbnails on the cut lane, ripple-editing zooms when a cut moves, and a per-cut audio choice.

## Measured

Spike at `spike/main.swift`, built with `swiftc -O`, run on 2026-10-21 on an Apple M2 Max, macOS 27.0.1, load average 4 to 8 from other sessions. The synthetic take is 10 s of HEVC at 60 fps whose frame k paints a bar 4k pixels wide, so a decoded frame names its index, plus a 1 kHz AAC tone. The cut is `[3.00025 s, 6.00075 s)`, a peak and a trough of the tone, the worst splice for a click. The real take is `20261013-153859.osrec` (3456x2234 HEVC, 5 s, microphone), copied, with a cut at 1.5 to 3 s.

| What | Result |
|---|---|
| A. Composition build, two tracks | 2 kept ranges 0.03 ms, 20 ranges 0.14 ms, 100 ranges 0.6 ms (median of 5, same on both takes) |
| B. Reader over the cut composition | 420 frames for 6.9995 s (= ceil), 420 requests, 0 wrong source frames, PTS spacing exactly 1/60 s; at the splice 2.98333→179, 3.00000→180, 3.01667→361 |
| C. Audio, no mix | 335 976 samples, exactly the expected count; max sample step at the splice 0.797, elsewhere 0.055 |
| C. Audio, 2 / 5 / 20 ms ramps | step 0.735 / 0.640 / 0.162; a 5 ms ramp's envelope falls linearly from −21 ms to +21 ms around the splice |
| C. Audio, 50 / 100 ms ramps | step 0.002 / 0.001; the 50 ms envelope is at 30% level 30 ms out and 0 at the splice |
| D. Zero-tolerance seek, same item | synthetic 3 to 5 ms; real take 7, 20, 30, 39, 48 ms (five targets, three runs within 2 ms) |
| D. `replaceCurrentItem` + zero-tolerance seek | synthetic 15 to 27 ms; real take 54 to 80 ms (six swaps a run, three runs), the frame shown is the expected one on every synthetic swap |

Limiters, inferred. D's seek spread follows the target's distance from the previous HEVC keyframe (the recorder sets no keyframe interval, accepted-render open question 2), and the swap cost is that plus the new item's pipeline. C's ramp granularity is AVFoundation's audio mixing block, not measured directly; the envelope's ±21 ms width matches 1024 frames at 48 kHz. B and C were run once each on the synthetic take and repeated on the real take with identical counts. Not measured: an `AVPlayerLayer` on screen during a swap (the harness is headless, like the accepted design's), ramps on speech rather than a tone, and the cost of `TimeMap.edited` on a 30-minute take (one linear pass, inferred to sit inside today's 10 ms rebuild).

## Synthesis decision

*Filled in by arena.*

## Tradeoffs accepted

- We accept a 100 ms dip to silence at every cut in exchange for no click, because the mix ramps at block granularity and a tap processor is the only sample-accurate alternative.
- We accept replacing the player item on every cut, 54 to 80 ms once per gesture, in exchange for the cut living in the asset's edit list, which is what makes preview and export share it by construction.
- We accept that the preview shows the uncut recording during a handle drag, with the uncut timeline's camera (slightly different from the edited one near the cut), in exchange for the user seeing the frames they are removing at seek speed.
- We accept making three event types generic over the clock, touching six files, in exchange for a compiler that refuses a recording time where an output time is due inside Timeline as well as at its surface.
- We accept a project.json version bump for takes with cuts in exchange for no silent loss of cuts in an older build.
- We accept that the strip's length is the recording's, not the export's, in exchange for cuts the user can see, resize, and restore, and zoom blocks that never jump.
- We accept that `Cuts` carries the recording duration, a fact `SourceRecording` also holds, in exchange for invariants that are checkable on the value alone; `Project` builds it from one source so they cannot disagree.

## Alternatives considered

- **Cuts applied by the player and the export loop, with the asset whole.** Boundary time observers that seek past each cut, and an export that reads range by range. Two drivers of the same edit, a gap at every seek in the preview, and "same pixels" resting on keeping them in step. Exposes the cut to every consumer; hides nothing.
- **Springs in recording time, with the timeline cut after the fact.** No generic event types, no mapping step. The camera jumps at every cut that falls while it moves, and the cursor teleports. The mapping step is one linear pass and gives a continuous camera, so it loses on experience for a small saving.
- **Replace the item on every coalesced drag step.** Measured at 54 to 80 ms a swap on the real take, so a drag would update at most about 12 times a second and show only kept frames. Source scrubbing updates at seek speed and shows the frames being removed.
- **Stored kept ranges instead of cuts.** Makes "leaves nothing" unrepresentable as a non-empty list, and matches the map's shape. But the user selects, drags, and restores a cut, not a kept piece, so every editor operation would translate, and a restore would have no id to name. The map keeps the kept shape; the edit keeps the user's.
- **An `MTAudioProcessingTap` for a sample-accurate 5 ms fade.** Shorter dip, shared by preview and export since the tap sits on the mix parameters. A C callback API with its own threading rules for a 95 ms shorter dip; deferred, listed under open questions.
- **Strip over output time, cuts collapsed.** Rejected in step 5.
- **Additive `cuts` key at version 1.** Rejected in step 6.

## Implementation reconciliation

*Empty until implementation.*

## Open questions and risks

1. Is a 100 ms dip at each cut acceptable on speech, or should the tap processor's 5 ms fade be built now? Measured on a tone only.
2. Does an on-screen `AVPlayerLayer` flash between items on `replaceCurrentItem`? The harness is headless. If it does, the fix is to hold the last frame in the layer (`AVPlayerLayer` keeps its contents until the new item renders in practice, but that is a guess) or to keep two players and swap the layer.
3. Should a drag on the cut lane snap to the nearest output frame, so a cut never splits a frame? The composition handles sub-frame edits (measured, 6.9995 s gave 420 frames), so this is a feel question, not a correctness one.
4. Should the cut lane show thumbnails, so the user can aim without scrubbing? `Still` over the uncut movie provides them; cost unmeasured.
5. Should `osrec export --still` also accept a recording time (`--still-source <ms>`) for debugging a cut? Not needed by the app.

## Next implementation step

Land `Instant`, `Span`, `OutputTime`, `Cuts`, and `TimeMap` in Timeline with property tests (every total edit against `init(validating:within:)`, `recording(at:)` against `output(at:)` round trips on kept times, `edited` keeps the held state at each segment start), then make the event types generic and give `Timeline` its `map`, so `frame(at: OutputTime)` is testable before any AVFoundation code changes.
