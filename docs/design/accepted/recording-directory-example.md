# Example recording directory (format version 1)

A 5-second take of the built-in display of a 14-inch MacBook Pro (1512 × 982 points, 3024 × 1964 pixels, 120 Hz) with the default microphone. Two clicks, a short burst of typing, one Command-S, and one scroll.

```
20261013-142233.osrec/
├── recording.json            1.1 KB   manifest
├── events.ndjson             ~40 KB   ~600 lines for 5 s of pointer movement
├── screen.mov                ~6 MB    HEVC, fragmented, 1 s fragments, no cursor
├── microphone.mov            ~80 KB   AAC 48 kHz mono, fragmented
├── cursors/
│   ├── 9f2c4e1a7b3d5c60.png  arrow, 34 × 46 px
│   └── 41d07be8c2a9f315.png  I-beam, 18 × 36 px
└── .lock                     0 bytes, flock target
```

The two invariants to read everything else by:

- **One clock.** Every `t` is integer microseconds of screen media time. 0 is the first complete screen frame. `microphone.mov` starts its session at the same host time, so its media time is the same clock.
- **One space.** Every coordinate and size is in `screen.mov` pixels, origin top-left of the captured display. A point outside `0..<3024 × 0..<1964` means the pointer was on another display.

## recording.json

### While recording

The recorder writes this when the first complete frame arrives, not at launch. A directory with no manifest means the recorder died before any frame, and recovery reports `nothingRecorded`.

```json
{
  "clock" : {
    "origin" : "first-screen-frame",
    "originHostTimeNanos" : 734918273645120,
    "unit" : "microseconds"
  },
  "createdAt" : "2026-10-13T06:22:33.412Z",
  "display" : {
    "displayID" : 1,
    "name" : "Built-in Retina Display",
    "pointFrame" : [0, 0, 1512, 982],
    "refreshRate" : 120
  },
  "format" : "open-studio.recording",
  "formatVersion" : 1,
  "id" : "8E0C2B9A-6F1D-4C55-9C3E-2D7A9B4F1E10",
  "microphone" : {
    "channelCount" : 1,
    "deviceName" : "MacBook Pro Microphone",
    "sampleRate" : 48000
  },
  "recorder" : {
    "name" : "osrec",
    "osVersion" : "27.0",
    "version" : "0.1.0"
  },
  "screen" : {
    "codec" : "hevc",
    "maxFrameRate" : 60,
    "pixelHeight" : 1964,
    "pixelWidth" : 3024
  },
  "status" : "recording"
}
```

### After a clean stop

The recorder rewrites the manifest last, with temp file plus rename. This write is the commit point. Only these keys change:

```json
  "durationMicros" : 5016667,
  "status" : "finalized",
  "termination" : {
    "reason" : "durationReached"
  }
```

### After crash recovery

If the process was killed at about 3.4 s, `osrec recover` probes `screen.mov` (readable up to the last 1 s fragment), truncates the torn last event line, and commits:

```json
  "durationMicros" : 3000000,
  "status" : "finalized",
  "termination" : {
    "message" : "recorder exited without finalizing; truncated a partial event line (61 bytes)",
    "reason" : "recovered"
  }
```

Events after `durationMicros` stay in the file. Timeline clamps query times to the duration, so they are harmless, and keeping them means recovery never deletes data.

## events.ndjson

There is one JSON object per line, and each line has a `type`. Points are flattened to `x`/`y` so `grep` and `jq` work on them directly. An excerpt follows, with `…` marking omitted lines:

```
{"type":"cursorImage","id":"9f2c4e1a7b3d5c60","hotspotX":8,"hotspotY":6,"width":34,"height":46}
{"t":0,"type":"state","x":1624.5,"y":866,"buttons":[],"cursor":"9f2c4e1a7b3d5c60"}
{"t":8215,"type":"move","x":1626,"y":865}
{"t":16541,"type":"move","x":1631.5,"y":862}
…
{"t":1203110,"type":"down","button":"left","x":2210,"y":402.5,"clickCount":1}
{"t":1291870,"type":"up","button":"left","x":2210,"y":402.5}
…
{"type":"cursorImage","id":"41d07be8c2a9f315","hotspotX":9,"hotspotY":18,"width":18,"height":36}
{"t":2004332,"type":"cursor","id":"41d07be8c2a9f315"}
{"t":2301005,"type":"key","modifiers":[]}
{"t":2448760,"type":"key","modifiers":[]}
{"t":2597118,"type":"key","modifiers":["shift"]}
{"t":2790440,"type":"key","modifiers":[]}
{"t":3102236,"type":"key","modifiers":["command"],"keyCode":1}
…
{"t":3605902,"type":"down","button":"left","x":980,"y":1410,"clickCount":1}
{"t":3688020,"type":"up","button":"left","x":980,"y":1410}
{"t":4120775,"type":"scroll","x":1012,"y":1388,"dx":0,"dy":-6.5}
…
{"t":5009121,"type":"move","x":1040.5,"y":1366}
```

Points to notice:

- A `cursorImage` declaration has no `t`. It is always written after its PNG is on disk and before any line that references it.
- `state` at `t = 0` makes the stream self-contained. The pointer position, held buttons, and cursor are known at the first frame without looking back.
- Plain typing records only times and modifiers. `keyCode` appears only while Command or Control is held, which here is Command-S (`keyCode` 1). Typed text, including passwords, never reaches disk.
- Drags are written as `move`. Whether a button is held can be derived from the `down` and `up` events.
- Lines are flushed every 100 ms. A crash can tear only the last line.

Fed through `AutoZoom.segments`, the clicks at 1.20 s and 3.61 s (four button edges) give windows that overlap, so there is one segment, `[0.903 s, 4.217 s)` at 2×. The end is clamped to `duration - 0.8 s`.

## cursors/*.png

Each file is a premultiplied RGBA PNG of the system cursor at the display's backing scale, as returned by `NSCursor.currentSystem`. The file name is the first 16 hex digits of SHA-256 over the PNG bytes and the hotspot. The same cursor seen twice maps to the same file, so the write is skipped. The renderer draws the image at `width × height` source pixels (scaled with the camera), with `hotspot` on the smoothed pointer position.

## screen.mov and microphone.mov

- `screen.mov`: an HEVC (or H.264) QuickTime movie written by `AVAssetWriter` with `movieFragmentInterval = 1 s`. It is variable frame rate because ScreenCaptureKit delivers frames only when content changes. The keyframe interval is 2 × the frame rate, and quality is 0.85. The writer session starts at the first frame's PTS, so media time 0 is that frame. At stop, the session ends at the stop time, so a static final screen still lasts to the end.
- `microphone.mov`: AAC, written by a second `AVAssetWriter` whose session starts at the same host time. If the microphone fails mid-take, the track ends early, and the screen and events carry on.

## .lock

The file is empty. The live recorder holds `flock(LOCK_EX)` on it. Recovery tries a non-blocking lock first. If the lock is held, the recorder is alive and recovery refuses. The kernel releases the lock when the process dies, so unlike a PID file, it cannot go stale.
