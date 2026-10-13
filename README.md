# open-studio

A native macOS screen recorder that zooms in on your clicks. Written in Swift, with no Electron.

This repository has the recording and timeline core. It doesn't have the editor app, renderer, or export yet.

- **Recording** captures one display with ScreenCaptureKit and hides the cursor from the video. It also records input events, cursor images, and optionally the microphone. A crash or force-quit keeps everything written up to the last second.
- **Timeline** reads a recording and works out the automatic zooms from your clicks. It then gives the camera position, zoom, and cursor state for any frame. Its answers are pure functions of time, so a renderer can ask from any thread in any order and get identical results.
- **osrec** is a command-line harness that drives both modules from a terminal.

## Requirements

- macOS 15 or later. Tested on Apple Silicon only.
- Swift 6.2 toolchain (Xcode 26 or later).
- Screen Recording and Input Monitoring permission for the app that runs `osrec`, usually your terminal.

## Build and test

```sh
swift build -c release
swift test
```

## Record a take

```sh
.build/release/osrec permissions        # exits 1 and names what's missing
.build/release/osrec displays           # lists displays and microphones
.build/release/osrec record --display <id> --duration 5 --mic default --out .
.build/release/osrec inspect <dir>.osrec --timeline
```

Without `--display`, `osrec` records the main display. Auto-zoom only reacts to clicks on the recorded display.

To stop a recording early, press Ctrl-C. If the recorder was killed instead, run `osrec recover <dir>.osrec` to finish the take. It's safe to run it more than once.

`osrec inspect --check-determinism` reads every frame forward, in reverse, shuffled, and from several threads at once. It exits non-zero if any answer differs.

## Recording format

A take is a `.osrec` directory:

```
recording.json     manifest, replaced atomically; the commit point
screen.mov         fragmented QuickTime, 1 s fragments
microphone.mov     fragmented QuickTime, only when recorded with --mic
events.ndjson      append-only input and cursor events
cursors/<id>.png   cursor images, named by content hash
.lock              held while recording
```

Every timestamp is in integer microseconds from the first complete video frame. Positions are in screen-video pixels. [`recording-directory-example.md`](docs/design/accepted/recording-directory-example.md) shows a full example.

## Layout

```
Sources/RecordingFormat   the on-disk contract, shared by both modules
Sources/Recording         capture, crash recovery, permissions
Sources/Timeline          auto-zoom, springs, camera and cursor tracks
Sources/osrec             command-line harness
Experiments/              measurements the design relies on
docs/design/              brief, accepted design and rationale, rejected candidates
```

## Design

[`docs/design/accepted/rationale.md`](docs/design/accepted/rationale.md) explains the main decisions. These include running capture in-process instead of in a helper, using fragmented `.mov` for crash safety, and solving springs exactly instead of replaying them. The same document records what the experiments measured.

## Licence

MIT. See [LICENSE](LICENSE).
