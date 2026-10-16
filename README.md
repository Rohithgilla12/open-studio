# open-studio

A native macOS screen recorder that zooms in on your clicks. Written in Swift, with no Electron.

This repository has the recording, timeline, and rendering core, a command-line harness, and a first editor app.

- **Recording** captures one display, an area of it, or one window with ScreenCaptureKit, and hides the cursor from the video. It also records input events, cursor images, and optionally the microphone, what the Mac plays, and a camera. A crash or force-quit keeps everything written up to the last second.
- **Timeline** reads a recording and works out the automatic zooms from your clicks. It then gives the camera position, zoom, and cursor state for any frame. Its answers are pure functions of time, so a renderer can ask from any thread in any order and get identical results.
- **Render** draws each output frame: the screen zoomed to the camera, the cursor redrawn on top, a background with padding, rounded corners, and a shadow, and the recorded camera in a corner. Preview, export, and stills share one compositor, so they produce the same pixels.
- **osrec** is a command-line harness that drives these modules from a terminal.
- **Studio** is the app: a take library, recording of the entire screen, an area, or a window, a zoom editor with a live preview, and export. The Xcode project in `App/` wraps it in a bundle.

## Requirements

- macOS 15 or later. Tested on Apple Silicon only.
- Swift 6.2 toolchain (Xcode 26 or later).
- Screen Recording and Input Monitoring permission for the app that runs `osrec`, usually your terminal.

## Build and test

```sh
swift build -c release
swift test
```

## Run the app

```sh
open App/OpenStudio.xcodeproj        # then Product > Run
```

Or from a terminal:

```sh
xcodebuild -project App/OpenStudio.xcodeproj -scheme OpenStudio -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/OpenStudio.app
```

Takes go to `~/Movies/open-studio`. The app asks for Screen Recording and Input Monitoring, and for the microphone or the camera if you pick one. macOS applies the first two only after a relaunch, so the app offers one.

The project signs to run locally by default. macOS ties a privacy grant to the app's signature, and an ad hoc signature changes on every build, so each rebuild asks again. To keep grants across rebuilds, copy `App/Config/Local.xcconfig.example` to `App/Config/Local.xcconfig` and set your team (a free personal team works). A grant made for an ad hoc build stays pinned to that build. After you set a team, System Settings still shows Open Studio switched on, but macOS refuses the new build. Clear the old grants, then relaunch and grant again:

```sh
tccutil reset ScreenCapture dev.openstudio.OpenStudio
tccutil reset ListenEvent dev.openstudio.OpenStudio
```

## Record a take

```sh
.build/release/osrec permissions        # exits 1 and names what's missing
.build/release/osrec displays           # lists displays and microphones
.build/release/osrec cameras            # lists cameras; never opens one
.build/release/osrec record --display <id> --duration 5 --mic default --out .
.build/release/osrec inspect <dir>.osrec --timeline
```

Export a take to MP4, or a single frame to PNG:

```sh
.build/release/osrec export <dir>.osrec --out demo.mp4                 # 1080p60 HEVC with automatic zooms
.build/release/osrec export <dir>.osrec --out demo-4k.mp4 --size uhd2160
.build/release/osrec export <dir>.osrec --still 4200                   # the frame at 4.2 s
```

`export` uses `<dir>.osrec/project.json` when it exists, so it renders the app's edits. `--auto-zooms` ignores it.

Without `--display`, `osrec` records the main display. Auto-zoom only reacts to clicks on the recorded display.

### Record the camera

```sh
.build/release/osrec record --duration 5 --camera default        # the system's preferred camera
.build/release/osrec record --duration 5 --camera <id> --mic default
.build/release/osrec export <dir>.osrec --out demo.mp4 --no-camera
```

The camera goes to its own `camera.mov`, at most 1920 x 1080 and 30 fps, on the same clock as the screen. Built-in, USB, and Continuity cameras are listed; Desk View is not. If the camera is unplugged mid-take, its track ends there with a warning and the screen keeps recording. The export draws the camera in a corner, a circle by default and mirrored. In the app, choose the camera on Home, and set its corner, size, shape, and mirroring in the editor's Camera section.

### Record system audio

```sh
.build/release/osrec record --duration 5 --system-audio                 # what the Mac plays
.build/release/osrec record --duration 5 --system-audio --mic default   # with your voice
.build/release/osrec export <dir>.osrec --out demo.mp4 --mute-mic       # or --mute-system
```

System audio goes to its own `system-audio.mov`, 48 kHz stereo AAC, on the same clock as the screen. The recorder's own sound is left out. It needs no permission beyond Screen Recording. The export mixes the microphone and system audio into one AAC track at the levels in `project.json`, both at full volume by default. In the app, turn on System audio on Home, and set each source's level and mute in the editor's Audio section.

### Record an area or a window

```sh
.build/release/osrec record --area 100,80,1280,720 --duration 5           # x,y,width,height in points from the display's top-left
.build/release/osrec record --area 0,0,800,600 --display <id> --duration 5
.build/release/osrec windows                                               # window ids, frontmost first
.build/release/osrec record --window <id> --duration 5
```

An area is clipped to its display. Each side must be at least 64 pixels after clipping. A window target records the window's own display, with windows of other apps hidden. The window's menus, sheets, and other windows still show, because they belong to the same app. The crop is the window's frame when recording starts, so it does not follow the window if it moves.

The recorder still captures the whole display. The area is stored in `recording.json`, and the export crops to it. So clicks outside the area do not zoom, the camera stays inside the area, and the exported canvas takes the area's shape. `osrec inspect` prints the area.

In the app, choose Entire Screen, Area, or Window on Home. For Area, drag a rectangle on the overlay, then press Return or Record. Press Escape to cancel. The app remembers the last area for each display.

To stop a recording early, press Ctrl-C. If the recorder was killed instead, run `osrec recover <dir>.osrec` to finish the take. It's safe to run it more than once.

`osrec inspect --check-determinism` reads every frame forward, in reverse, shuffled, and from several threads at once. It exits non-zero if any answer differs.

## Recording format

A take is a `.osrec` directory:

```
recording.json     manifest, replaced atomically; the commit point; holds the area for area and window takes
screen.mov         fragmented QuickTime, 1 s fragments
microphone.mov     fragmented QuickTime, only when recorded with --mic
system-audio.mov   fragmented QuickTime, only when recorded with --system-audio
camera.mov         fragmented QuickTime, only when recorded with --camera
events.ndjson      append-only input and cursor events
cursors/<id>.png   cursor images, named by content hash
.lock              held while recording
project.json       edits (zooms, style, audio levels, output format), written by the editor; the recorder never touches it
```

Every timestamp is in integer microseconds from the first complete video frame. Positions are in screen-video pixels, including the area. A manifest with system audio is format version 4, one with a camera but no system audio is version 3, and one with only an area is version 2. One with none of them is still written as version 1, so older builds can read it. [`recording-directory-example.md`](docs/design/accepted/recording-directory-example.md) shows a full example.

## Layout

```
Sources/RecordingFormat   the on-disk contract, shared by both modules
Sources/Recording         capture, crash recovery, permissions
Sources/Timeline          auto-zoom, springs, camera and cursor tracks
Sources/Render            compositor, export, stills, project.json
Sources/osrec             command-line harness
Experiments/              measurements the design relies on
docs/design/              brief, accepted design and rationale, rejected candidates
```

## Design

[`docs/design/accepted/rationale.md`](docs/design/accepted/rationale.md) explains the main decisions. [`docs/design/capture-targets/rationale.md`](docs/design/capture-targets/rationale.md) explains areas and windows, [`docs/design/camera/rationale.md`](docs/design/camera/rationale.md) explains the camera, and [`docs/design/system-audio/rationale.md`](docs/design/system-audio/rationale.md) explains system audio and the mix. These include running capture in-process instead of in a helper, using fragmented `.mov` for crash safety, and solving springs exactly instead of replaying them. The same document records what the experiments measured.

## Licence

MIT. See [LICENSE](LICENSE).
