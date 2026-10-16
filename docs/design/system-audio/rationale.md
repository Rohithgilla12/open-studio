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
- **A gap in delivery is written as silence.** `AVAssetWriter` packs audio samples back to back and ignores a gap between their timestamps. Measured with a scratch writer: one second of tone, a second with no buffers, then one more second of tone read back as two seconds of continuous tone, with the third second's tone at 1 s instead of 2 s. A source that skips time would pull everything after the gap early, out of sync with the screen. `AudioContinuity`, a pure value, tracks the host time the file has reached and returns the silence a buffer needs in front of it when the buffer starts more than one 1024-frame buffer (about 21 ms) later. The sink writes that many frames of zeros, in the buffer's own format, before it. The microphone has the same writer, so it gets the same fix (see Deviations).
- **A stream that delivers nothing leaves no file.** ScreenCaptureKit delivers buffers for silence too, so a whole take with no buffer at all is a failure, not a quiet take. `AudioTrackWriter.finish` then cancels the writer and removes the file, as D9 does for a camera that never delivered, and the session drops `systemAudio` from the final manifest, so the take keeps the version it would have had without it. A `systemAudioLost(at: 0, …)` warning is kept in the manifest and returned in `FinishedRecording.warnings`.
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
- **One buffer of gap tolerance.** One 1024-frame buffer at 48 kHz, about 21 ms. Timestamp jitter below it is ignored, so the writer never inserts slivers of silence into continuous audio, and a buffer that comes later than that gets silence in front of it, so it plays at its own time.

## Deviations from the decided direction

1. **The microphone gets the same gap fill and the same rule for a stream that never delivered.** The direction did not ask to change the microphone. The gap measurement above shows its writer has the same defect, and the fix lives in the writer they now share, so leaving the microphone out would mean two audio writers with different timing rules. A microphone that delivers nothing used to leave a 0-byte `microphone.mov` that the export reported as unreadable; it now leaves no file and a `microphoneLost` warning, and the take has no microphone.
2. **`FinishedRecording` carries the warnings found while finishing.** The never-delivered warning is only known at stop, when `SessionPhase` no longer passes warnings on (the gap D9 recorded in its item 8). Instead of changing the phase, the sink returns those warnings from `finish`, the session writes them into the final manifest, and `FinishedRecording.warnings` hands them to the caller. A microphone or camera that fails to finish at stop now reaches the manifest the same way. The app shows an alert when a take that asked for system audio ends without it, and `osrec record` prints them.

## Tradeoffs accepted

- We accept a manifest version bump for system-audio takes (older builds refuse them) in exchange for no silent loss of the sound in an older build's export or recovery.
- We accept one more file per take in exchange for crash isolation and levels that stay editable.
- We accept one mixed track in the export in exchange for the person's levels applying in every player.
- We accept that drift between a device's clock and the host clock is corrected only one way. A source whose clock runs slow falls behind the host clock, and each time it is one buffer behind, it gets one buffer of silence: at 100 ppm, about 21 ms of silence every 3.6 minutes, which may be heard as a short dropout. In exchange its sync never drifts by more than one buffer. A source that runs fast is not trimmed, so it ends slightly late. Not measured on a real device.

## Alternatives considered

- **Sketches B and C**, above.
- **Core Audio process taps** instead of ScreenCaptureKit. A tap can pick processes and mixdowns, but needs its own permission and an aggregate device, and its clock would need converting like the camera's. The stream already delivers the output mix on the host clock, so taps add a permission and a clock for nothing the direction needs.
- **Two tracks in the export.** Rejected in step 4.

## Open questions

1. **Does a device's clock drift against the host clock over a long take, and is the drift correction heard?** Each file follows its own samples. A source that runs fast ends slightly late. One that runs slow gets a buffer of silence each time it falls a buffer behind (Tradeoffs accepted). If that is audible in a long real take, the next step is to spread the correction (one frame at a time) instead of one block. Measuring needs a long real recording.
2. **Should a window take record only its app's audio?** ScreenCaptureKit's audio follows the content filter, and a window target's filter includes only the window's app. That is probably what a person recording one app wants, but it is not verified.
3. **Per-source trim or offset.** A fixed offset fits sketch A as an insertion time, as for the camera. Nobody has asked for it.

## Implementation reconciliation

### D10

Implemented on 2026-10-16. Each entry is a place where the code departs from the sketch above, or a result.

1. **The gap measurement.** A scratch `AVAssetWriter` (AAC, 48 kHz stereo, 1 s fragments) was given 1024-frame buffers of a 1 kHz tone for 0 to 1 s and 2 to 3 s, with nothing in between. It read back as 2.005 s of continuous tone, with the tone that was stamped at 2 s playing at 1 s. A first buffer stamped 0.5 s after the session start read back with a 0.512 s empty edit in front of it, so only gaps after the first sample need filling. `AudioTrackWriterTests.audioAfterAGapInDeliveryStaysAtItsTime` pins the fix for interleaved float, non-interleaved float (what ScreenCaptureKit delivers), and interleaved 16-bit input; with the fill turned off it fails.
2. **`FinishedRecording.warnings`** replaces the `SessionPhase` change first planned, as recorded in Deviations.
3. **`TrackOutcome` is shared** by `CameraTrackWriter` and the new `AudioTrackWriter`, so the camera, the microphone, and system audio report "never delivered" the same way.
4. **A buffer that is not linear PCM is still written**, without gap filling, rather than dropped. ScreenCaptureKit delivers linear PCM, so this path is not expected to run.
5. **Muted sources are not decoded by the export**, and an export where every source is silent has no audio track. The preview keeps every track and sets a silent one's volume to 0, because changing the item's tracks would rebuild it.
6. **A mixed export is stereo, and a microphone-only export keeps the microphone's channel count**, so a mono microphone take still exports mono AAC at 128 kbps, as before.
7. **Takes without system audio export as before.** The D4 take and a copy with a synthetic mono microphone were exported at 1080p60 by `main` and by this branch. Each pair has the same size and differs in the same 7 (no audio) or 11 (microphone) bytes: the creation and modification times in `mvhd`, `tkhd`, and `mdhd`, and one byte in `mdat`. Two exports by `main` of the microphone take differ in exactly the same 11 bytes, so the difference is run to run, not the branch.
8. **A slow clock is held in step.** `aSourceWhoseClockRunsSlowStaysWithinOneBufferOfTheHostClock` stamps 1024-frame buffers 1024/47 520 s apart (a clock 1% slow, exaggerated so 5 s shows it) and checks that the audio written ends within one buffer of the host time. Without the fill it ends about 50 ms early and the test fails.
9. **The export's mix names only the tracks it reads.** `AVAssetReaderAudioMixOutput` documents that it throws for a mix naming a track it was not created with, and the export leaves silent sources out of the reader. `MovieComposition.audioMix(_:audibleOnly:)` builds the export's mix from the audible tracks and the preview's from every track, with the same volumes. Found by the review.
10. **The app alerts for a microphone that never delivered too**, since this change removes its file the same way. Found by the review.


**Verified on 2026-10-16** (Apple M2 Max, macOS 27.0.1, Xcode 27.0). `swift build` and `swift test` pass with 359 tests (329 before), in three full runs with no failure. No test records or plays anything: the recording path is driven with synthetic sample buffers through `AudioTrackWriter`, and recovery through a crashed take whose `system-audio.mov` was left unfinished mid-write. The audio tests export a generated take whose microphone plays 440 Hz from 0.5 s and whose system audio plays 1 kHz from 1 s, read the MP4 back, and measure each tone with the Goertzel algorithm: both tones at 0.40 amplitude in both channels, nothing before their starts, onsets at 0.4975 s and 0.9975 s (one buffer is 21 ms), a muted source at 3 x 10^-6 or less, and a microphone at volume 0.5 down 6.03 dB with system audio moved 0.0005 dB. `xcodebuild` builds the app, and window captures of a background launch show Home with the System audio toggle beside the Microphone picker (the permission banner lists Screen Recording and Input Monitoring only) and the editor on a synthetic take with the Audio section.

**Measured: system audio costs no measurable export speed at 4K60.** The D4 take `20261013-115409.osrec` (3456 x 2234, 10 s), copied, once as it is, once with a synthetic `system-audio.mov`, and once with both a synthetic microphone and system audio (`Experiments/synthetic-audio`), exported at 3840 x 2160, 60 fps, HEVC, release build, the sides interleaved, in two sessions of five rounds:

| Export | Real time, per run | Median |
|---|---|---|
| No audio | 1.48, 1.62, 1.63, 1.63, 1.52; 1.57, 1.62, 1.62, 1.63, 1.64 | 1.62x |
| System audio | 1.60, 1.61, 1.60, 1.60, 1.58; 1.59, 1.61, 1.61, 1.61, 1.61 | 1.61x |
| Microphone and system audio, mixed | 1.61, 1.61, 1.61, 1.60, 1.61; 1.59, 1.61, 1.52, 1.59, 1.61 | 1.61x |

Every run wrote 600 frames, and `ffprobe` shows the mixed exports with one 48 kHz stereo AAC stream of 10.000 s beside the video, and the take without audio with none. The gap between the medians (0.01x) is smaller than the spread within each side (up to 0.15x). The limiter is the one D5 and D9 found, the per-output-frame compose and encode chain at about 96 fps: decoding, mixing, and encoding 10 s of audio adds about 0.1 s of user CPU (2.1 s against 2.2 s), inside that chain's slack. Other sessions kept the load average between 5 and 137 throughout, which is why the sides were interleaved; the low runs (1.48, 1.52) fall on both sides.

**Not verified.**
- Capture from a real stream: whether ScreenCaptureKit delivers buffers through silence (the direction says it does), its audio buffer sizes and timestamp jitter, drift of a real device against the host clock and whether the correction is heard, `excludesCurrentProcessAudio` with the preview playing during a take, which audio a window target's app filter captures, and the absence of any extra prompt.
- The preview playing with the mix: the item's `audioMix` carries the levels (tested), but nothing was played out loud.
