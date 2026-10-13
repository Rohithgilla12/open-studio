# Example recording directory

A 5.2 s take on a 14-inch MacBook Pro built-in display (1512×982 points at 2×), with the microphone on, two clicks, and a short burst of typing. Format version 1.

## File tree

```
20261013-143012.osrec/
├── manifest.json        written first, immutable
├── events.ndjson        append-only; three producers; unsorted
├── cursors/
│   ├── 3f9c1a7e0b2d4c61.png     arrow, 32×32 px (16×16 pt @2x)
│   └── a81d0e55c7f2b390.png     I-beam
├── display.mov          fragmented QuickTime: hevc video + aac microphone track
├── timebase.json        written when the first video frame was appended
└── finish.json          written on clean stop; absent after a crash
```

## manifest.json

```json
{
  "formatVersion": 1,
  "recordingID": "6B5D7E2A-9C3F-4E1B-8A7D-2F0C4B9E1D33",
  "createdAt": "2026-10-13T06:30:12Z",
  "clock": {
    "kind": "machHostTime",
    "startHostNanos": 734215889120450
  },
  "display": {
    "displayID": 1,
    "pixelWidth": 3024,
    "pixelHeight": 1964,
    "pointWidth": 1512,
    "pointHeight": 982,
    "scaleFactor": 2,
    "originX": 0,
    "originY": 0,
    "refreshRate": 120
  },
  "video": {
    "fileName": "display.mov",
    "codec": "hevc",
    "frameRate": 60,
    "pixelWidth": 3024,
    "pixelHeight": 1964,
    "fragmentIntervalNanos": 1000000000,
    "showsCursor": false
  },
  "audio": {
    "microphoneDeviceID": "BuiltInMicrophoneDevice",
    "sampleRate": 48000,
    "channels": 1
  },
  "input": {
    "recordsKeyCodes": false,
    "cursorSamplingHz": 30
  }
}
```

`createdAt` is wall clock and informational. Nothing is aligned with it.

## timebase.json

```json
{
  "firstVideoFrameOffsetNanos": 212487333,
  "firstVideoFramePTS": { "value": 734216101607783, "timescale": 1000000000 }
}
```

The first complete frame arrived 212 ms after the session clock started. Recording time zero is that frame; the loader subtracts `212487333` from every event `t`. `firstVideoFramePTS` is the PTS passed to `startSession(atSourceTime:)`, so movie time zero is also that frame. Note `pts − startHostNanos == firstVideoFrameOffsetNanos`, which `osrec inspect` checks.

## events.ndjson

Every `t` is nanoseconds after `clock.startHostNanos`. Lines from the tap, the cursor watcher, and the session interleave in arrival order. Positions are CoreGraphics global points. Truncated here to the interesting part; a real 5 s take has around 300 `mouseMoved` lines.

```
{"t":1203411,"type":"mark","mark":"recordingStarted"}
{"t":33940210,"type":"cursorImageDefined","cursor":{"id":"3f9c1a7e0b2d4c61","fileName":"cursors/3f9c1a7e0b2d4c61.png","hotspotX":4,"hotspotY":2,"pointWidth":16,"pointHeight":16,"scaleFactor":2,"systemName":"arrow"}}
{"t":33940210,"type":"cursorChanged","cursorID":"3f9c1a7e0b2d4c61"}
{"t":398112044,"type":"mouseMoved","x":612.5,"y":433}
{"t":406445981,"type":"mouseMoved","x":618,"y":436.5}
{"t":414779918,"type":"mouseMoved","x":627.5,"y":441}
{"t":1101223570,"type":"mouseDown","x":640,"y":452,"button":"left","modifiers":0}
{"t":1187890421,"type":"mouseUp","x":640,"y":452,"button":"left","modifiers":0}
{"t":1533338102,"type":"cursorImageDefined","cursor":{"id":"a81d0e55c7f2b390","fileName":"cursors/a81d0e55c7f2b390.png","hotspotX":4.5,"hotspotY":9,"pointWidth":9,"pointHeight":18,"scaleFactor":2,"systemName":"iBeam"}}
{"t":1533338102,"type":"cursorChanged","cursorID":"a81d0e55c7f2b390"}
{"t":1812004912,"type":"keyDown","modifiers":0}
{"t":1934117203,"type":"keyUp","modifiers":0}
{"t":1988551010,"type":"keyDown","modifiers":0}
{"t":2102386774,"type":"keyUp","modifiers":0}
{"t":2140010334,"type":"keyDown","modifiers":0}
{"t":2251337401,"type":"keyUp","modifiers":0}
{"t":2533338102,"type":"cursorChanged","cursorID":"3f9c1a7e0b2d4c61"}
{"t":3310887120,"type":"scrolled","x":702,"y":510,"deltaX":0,"deltaY":-12}
{"t":4010662357,"type":"mouseMoved","x":1010,"y":300.5}
{"t":4021996294,"type":"mouseMoved","x":1004,"y":299}
{"t":4120994512,"type":"mouseDown","x":1004,"y":299,"button":"left","modifiers":8}
{"t":4198771003,"type":"mouseUp","x":1004,"y":299,"button":"left","modifiers":8}
{"t":5398002117,"type":"mark","mark":"stopRequested"}
```

Points of note:

- `modifiers` is the `Modifiers` option-set raw value; `8` is Command.
- `keyDown` carries no `keyCode` because `recordsKeyCodes` is false.
- `cursorImageDefined` always precedes the first `cursorChanged` that references it.
- The three `keyDown` lines inside 1800 ms make the typing-fade rule fire from about 2.14 s (recording time 1.93 s).

## cursors/3f9c1a7e0b2d4c61.png

A 32×32 PNG with alpha, the arrow cursor rendered at 2×. The file name is the first 16 hex characters of SHA-256 over the PNG bytes, so identical bitmaps collapse to one file across takes.

## display.mov

QuickTime movie written by `AVAssetWriter` with `movieFragmentInterval = 1 s`:

```
ftyp
moov        (header; sample tables empty, fragments carry samples)
moof+mdat   fragment 1, video 0.000–1.000 s, audio
moof+mdat   fragment 2, …
…
moof+mdat   fragment 6 (partial last second)
```

Video track: HEVC, 3024×1964, 60 fps nominal (SCStream delivers fewer frames when the screen is static). Audio track: AAC, 48 kHz, mono. If the process dies, the file is playable up to the last complete `moof`.

## finish.json

```json
{
  "stoppedAt": "2026-10-13T06:30:17Z",
  "stopOffsetNanos": 5398002117,
  "durationNanos": 5185514784,
  "videoFrames": 187,
  "droppedFrames": 0,
  "eventCount": 312,
  "outcome": "completed"
}
```

`durationNanos` is `stopOffsetNanos − firstVideoFrameOffsetNanos`. `videoFrames` is 187 rather than 311 because SCStream only delivers changed frames.

## The same directory after a force-quit at 4 s

```
20261013-143012.osrec/
├── manifest.json
├── events.ndjson        last line may lack its newline
├── cursors/…
├── display.mov          fragments 1–4 complete; fragment 5 partial
└── timebase.json
```

No `finish.json`. `Take.load` returns `integrity: .recovered(truncatedEventTail: true)` with `duration` estimated from the last event (about 4.0 s). The renderer reads the real duration from the movie. If even `timebase.json` is missing, the recorder died before its first frame and `Take.load` throws `.neverStarted`.
