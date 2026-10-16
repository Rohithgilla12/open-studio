# System audio: record what the Mac plays, and mix it with the microphone

## Problem

People record a demo with sound: a video playing, an app's alerts, a call. That means three things: capture what the Mac plays alongside the screen, keep it in sync with the screen and the microphone, and let the person set the two levels after recording, in the preview and the export alike. The shape is not obvious for five reasons.

- The format has one clock (see [`../accepted/rationale.md`](../accepted/rationale.md), "one clock and one space, fixed at write time"). The microphone already arrives on it because it comes from the same `SCStream`. System audio comes from that stream too, but from a different audio device (the output mix), so the two audio sources have their own sample clocks under one host-time stamp.
- A take must survive a crash file by file (fragmented movies, append-only events, idempotent recovery), and a fault in one source must not end the others.
- Preview and export must give the same result by construction, not by tests kept in step (see [`../accepted-render/rationale.md`](../accepted-render/rationale.md), step 3). The camera kept that property by being a second track in the one composition ([`../camera/rationale.md`](../camera/rationale.md), step 4).
- Levels are an edit. The person decides them after hearing the take, and changes them again later, so they belong in `project.json`, not in the recording.
- Older builds must keep reading takes that do not use the new feature, as D8 and D9 arranged with content-derived format versions.

## Usage (caller's view)

The command line:

```
osrec record --system-audio --duration 5                    # what the Mac plays, beside the screen
osrec record --system-audio --mic default --duration 5      # both
osrec inspect <take>.osrec                                  # "system audio: 48000 Hz, 2 ch" and system-audio.mov's probe
osrec export <take>.osrec --out demo.mp4                    # levels from project.json, or both at full volume
osrec export <take>.osrec --out demo.mp4 --mute-mic         # or --mute-system
```

Library callers (`osrec`, `Studio`):

```swift
import Recording

let config = RecordingConfiguration(
    outputDirectory: library, target: .display(.main), microphone: .systemDefault, systemAudio: true)
let missing = Permissions.check().missing(for: config)       // system audio adds nothing to Screen Recording
let session = try await RecordingSession.start(config)
for await update in session.updates {
    if case .warning(.systemAudioLost(let at, let why)) = update { hud.note("system audio ended at \(at): \(why)") }
}
```

Timeline and Render read one optional URL and one edit value:

```swift
let source = try SourceRecording.load(from: take)
source.systemAudioMovie       // URL? like microphoneMovie; nil when the take has no system audio
source.hasSystemAudio

var project = try Project.open(take)
project.edits.audio.microphone.volume = 0.5     // linear gain, 0 to 1; 0.5 is about -6 dB
project.edits.audio.systemAudio.isMuted = true  // what --mute-system sets
project.edits.audio[.microphone]                // the same level, by source
```

The app: a System audio toggle on Home beside the Microphone picker. In the editor, an Audio section with a level slider and a mute toggle for each source the take has, and no section for a take with neither.

## Shape

### Step 1: one more file in the take, on the same clock

```
20261016-101500.osrec/
  recording.json     + "systemAudio": {sampleRate, channelCount}     (version 4)
  screen.mov         unchanged
  microphone.mov     unchanged
  system-audio.mov   new: fragmented, 1 s fragments, AAC 48 kHz stereo
  camera.mov         unchanged
  events.ndjson      unchanged
```

- **`system-audio.mov` is its own fragmented movie**, written by the same `MovieWriter` as the microphone. The name lives in `RecordingLayout` only. A separate file keeps a system-audio fault away from the screen and the microphone, and gives the same crash story: the file reads to its last whole fragment after a `kill -9`, and `recover(at:)` probes it like the microphone and the camera.
- **The manifest version stays the lowest that can express the take.** A manifest with `systemAudio` is version 4. One without is written as before (1, 2 with an area, 3 with a camera), so older builds still read every take that has no system audio. A version-3 manifest that names system audio is refused as unreadable. The reasons are the camera's: an older build would export the take without the sound and say nothing, and an older recovery would rewrite the manifest without the key and lose the sound for good.

### Step 2: the stream's third output, and a writer that keeps audio at its time

```
SCStream ─── .screen ──────────── PTS (host ns) ──┐
         ├── .microphone ──────── PTS (host ns) ──┤
         └── .audio (output mix) ─ PTS (host ns) ──┼──▶ CaptureSink actor (executor = the SCK queue)
                                                   │      origin = first complete screen frame
                                                   │      AudioTrackWriter(microphone.mov)
                                                   │      AudioTrackWriter(system-audio.mov)
                                                   │        drop buffers before the origin
                                                   │        write silence where delivery skipped time
                                                   └─     at stop: no samples ever → remove the file
```

- **Capture on the existing stream.** `capturesAudio = true`, `excludesCurrentProcessAudio = true`, `sampleRate = 48_000`, `channelCount = 2`, and a stream output of type `.audio` on the sink's queue. Buffers arrive on the host clock, on the same queue as screen frames, so the origin and every writer keep one owner and no lock, as for the microphone.
- **Media time 0 of `system-audio.mov` is recording time 0, by the microphone's rule.** The writer starts its session at the screen's first frame. Buffers before it are dropped. A first buffer that lands after the origin keeps its offset, because `AVAssetWriter` writes an empty edit before it (measured, below).
- **A gap in delivery is written as silence.** `AVAssetWriter` packs audio samples back to back and ignores a gap between their timestamps. Measured with a scratch writer: one second of tone, a second with no buffers, then one more second of tone read back as two seconds of continuous tone, with the third second's tone at 1 s instead of 2 s. A source that skips time would pull everything after the gap early, out of sync with the screen. `AudioContinuity`, a pure value, tracks the host time the file has reached and returns the silence a buffer needs in front of it when the buffer starts more than 20 ms later. The sink writes that many frames of zeros, in the buffer's own format, before it. The microphone has the same writer, so it gets the same fix (see Deviations).
- **A stream that delivers nothing leaves no file.** ScreenCaptureKit delivers buffers for silence too, so a whole take with no buffer at all is a failure, not a quiet take. `AudioTrackWriter.finish` then cancels the writer and removes the file, as D9 does for a camera that never delivered, and the session drops `systemAudio` from the final manifest, so the take keeps the version it would have had without it. A `systemAudioLost(at: 0, …)` warning is emitted and kept in the manifest.
- **A writer failure mid-take ends the track, not the take**, with a `systemAudioLost(at:message:)` warning, exactly like `microphoneLost`. The screen, microphone, camera, and events carry on.

### Step 3: Timeline hands over the URL

```
SourceRecording.load
  screenMovie        URL
  microphoneMovie    URL?    manifest.microphone != nil
  systemAudioMovie   URL?    manifest.systemAudio != nil      ◀── new, same rule
  cameraMovie        URL?    manifest.camera != nil
```

### Step 4: two audio tracks in the one composition, one mix built from the edits

```
MovieComposition.load(source)
  AVMutableComposition
    screen.mov video          at 0
    microphone.mov audio      at 0   (when recorded)     ┐
    system-audio.mov audio    at 0   (when recorded)     ┘ audioTracks: [AudioSource: trackID]
    camera.mov video          at 0   (when recorded)

MovieComposition.audioMix(edits.audio) -> AVAudioMix?      one input parameter per audio track,
                                                            volume = isMuted ? 0 : volume
   ├──▶ PreviewPlayer: item.audioMix                        set at load and on every audio edit
   └──▶ Export: AVAssetReaderAudioMixOutput.audioMix         over the audible tracks
               → one LPCM stream, 48 kHz → AAC, one track in the MP4
```

- **One builder, two consumers.** Preview and export get their `AVAudioMix` from the same `MovieComposition.audioMix(_:)`, as they get their video composition from the same `videoComposition(scene:frameRate:)`. The levels are a pure function of `Edits.audio`, so what plays is what exports.
- **An audio edit does not touch the picture.** `PreviewPlayer` swaps `item.audioMix` when only the levels changed, and leaves `item.videoComposition` alone, because swapping the composition drops AVFoundation's rendered-ahead frames. Dragging a level slider while playing does not stutter the picture.
- **The export has one mixed AAC track**, stereo when the take has system audio, and the microphone's channel count otherwise, so a take without system audio exports as it does today. A muted source, or one at volume 0, is left out of the reader, so it is not decoded. When every source is silent the MP4 has no audio track, the same as a take with no audio.

Why one track and not two? Players, browsers, and upload sites play the first audio track of an MP4 and ignore the rest, or offer the second only behind a menu that few people find. Two tracks would make the person's mix depend on the player, and the levels they set would apply nowhere. A second track only helps someone who wants to re-edit the export in another editor, and they can export twice with one source muted each time. One mixed track is chosen.

### Step 5: Studio and osrec

```
Home     Display ▾   Microphone ▾   Camera ▾   [ ] System audio
Editor:  Background │ Frame │ Camera │ Audio (Microphone: level, mute; System audio: level, mute) │ Zoom │ Output
```

- The toggle writes `RecordingPreferences.systemAudio`, which `StudioModel.configuration` passes through. The permission banner lists nothing new.
- The Audio section edits `edits.audio` through `Editor.drag` (sliders) and `Editor.apply` (mute toggles), so undo and autosave work with no new path. It shows a row only for a source the take has.
- `osrec export --mute-mic` and `--mute-system` set `isMuted` on the opened project before exporting, the way `--no-camera` hides the overlay. Without them the export honours `project.json`.

## Permissions

System audio through ScreenCaptureKit needs Screen Recording and nothing else, so `Permissions` is unchanged.

- Apple's sample [Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos) captures audio through `SCStreamConfiguration.capturesAudio` and a stream output of type `.audio`, and names one prompt: "The first time you run this sample, the system prompts you to grant the app Screen Recording permission."
- The [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) overview names one requirement for capture, Screen Recording permission with an `NSScreenCaptureUsageDescription`, for "screen content and audio". The [`capturesAudio`](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio) and [`excludesCurrentProcessAudio`](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/excludescurrentprocessaudio) pages name no other.
- The separate System Audio Recording permission, with its `NSAudioCaptureUsageDescription` key, belongs to Core Audio process taps: [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) says "To capture audio with a tap, you need to include the `NSAudioCaptureUsageDescription` key". This design does not use taps.

No real recording was made for this change, so the prompt behaviour is from the documentation, not observed.

## Sketches considered

Three structurally different places for the second audio source to live.

**Sketch A: `system-audio.mov` beside `microphone.mov`, mixed by an `AVAudioMix` at playback and export (chosen).** Each source has its own fragmented file. The composition carries both as tracks, and the mix comes from the edits.

**Sketch B: mix the microphone and system audio into one file at record time.** The sink sums the two streams into one `audio.mov`, at levels chosen before recording.

**Sketch C: a second audio track inside `screen.mov`.** The screen writer gains two audio inputs, and the take keeps one movie.

| | A: separate file, mix at render | B: mixed at record time | C: tracks inside screen.mov |
|---|---|---|---|
| Crash safety | Each file reads to its last fragment on its own; a failed audio writer leaves the screen untouched | One file for both sources: a fault in either ends both | A failed audio input fails the screen writer, so an audio fault can end the whole take |
| Sync | Each file starts at the origin; the composition aligns them at 0 | The sink must pair buffers from two sources by timestamp, wait for the slower one, and fill its gaps, live, on the capture queue | As A, inside one writer |
| Levels after recording | Any time, from `project.json`, undoable | Fixed forever; a muted microphone cannot be unmuted | As A |
| Drift between the two audio clocks | Each file follows its own device's samples against the host-time stamps; gaps are filled per file; the mix happens on decoded audio, where both are resampled to 48 kHz | The live mixer must resample one device to the other's clock or the sum drifts, which is the hard part of a mixer, done on the hot path | As A |
| File count | One more file | Same as today | Same as today |
| Older readers | Version 4 refuses the take | A changed meaning for `microphone.mov`: needs a bump too | An older reader exports the screen and the microphone and drops the track silently, so it needs a bump too |
| Cost of the change | One more writer and track, an `AVAudioMix` | A live mixer with its own buffering | Changes `MovieWriter` from one input to many, and the screen's heartbeat frame re-appends video only |

B fails the direction's core need, levels set after recording, and moves a mixer onto the capture queue. C saves a file but couples the screen to the riskiest new input, against the reason the microphone has its own file. A keeps every per-file property the format already has, and the mix is an `AVAudioMix`, which preview and export both take, so A is chosen.

**Export, two shapes considered.** One mixed stereo track (chosen, step 4), or two tracks with the levels as track volume. Two tracks are rejected in step 4.

## Decisions

- **Volume is a linear gain from 0 to 1**, the scale `AVAudioMixInputParameters.setVolume` takes, so 0.5 is about -6 dB. No boost above 1, because AAC from a normalised source would clip. Mute is separate from the volume, so unmuting brings back the level the person set.
- **Levels default to full volume, not muted**, and a `project.json` saved before this change opens with both at full volume, which is what it exported before.
- **Decoded levels are range-checked** like the style: a volume outside 0 to 1 makes `project.json` unreadable rather than clipping.
- **Stereo at 48 kHz**, the rate the microphone and the export already use, as directed.
- **20 ms gap tolerance.** About one 1024-frame buffer at 48 kHz. Timestamp jitter below it is ignored, so the writer never inserts slivers of silence into continuous audio, and a buffer that comes later than that is moved back to its time.

## Deviations from the decided direction

1. **The microphone gets the same gap fill and the same rule for a stream that never delivered.** The direction did not ask to change the microphone. The gap measurement above shows its writer has the same defect, and the fix lives in the writer they now share, so leaving the microphone out would mean two audio writers with different timing rules. A microphone that delivers nothing used to leave a 0-byte `microphone.mov` that the export reported as unreadable; it now leaves no file and a `microphoneLost` warning, and the take has no microphone.
2. **`SessionPhase` emits warnings while stopping.** The never-delivered warning is only known at stop, and the phase dropped warnings then (the gap D9 recorded in its item 8). Emitting them while stopping also delivers a microphone or camera failure found at stop.

## Tradeoffs accepted

- We accept a manifest version bump for system-audio takes (older builds refuse them) in exchange for no silent loss of the sound in an older build's export or recovery.
- We accept one more file per take in exchange for crash isolation and levels that stay editable.
- We accept one mixed track in the export in exchange for the person's levels applying in every player.
- We accept that drift between the output device's clock and the host clock is corrected only one way: a source that falls behind gets silence; one that runs ahead is not trimmed. Not measured on a real device.

## Alternatives considered

- **Sketches B and C**, above.
- **Core Audio process taps** instead of ScreenCaptureKit. A tap can pick processes and mixdowns, but needs its own permission and an aggregate device, and its clock would need converting like the camera's. The stream already delivers the output mix on the host clock, so taps add a permission and a clock for nothing the direction needs.
- **Two tracks in the export.** Rejected in step 4.

## Open questions

1. **Does the output device's clock drift against the host clock over a long take?** Each file follows its own samples. A source that runs fast would end slightly late, one that runs slow is pulled back by the gap fill. Measuring needs a long real recording.
2. **Should a window take record only its app's audio?** ScreenCaptureKit's audio follows the content filter, and a window target's filter includes only the window's app. That is probably what a person recording one app wants, but it is not verified.
3. **Per-source trim or offset.** A fixed offset fits sketch A as an insertion time, as for the camera. Nobody has asked for it.
