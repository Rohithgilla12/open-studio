# Step 0 experiments

Throwaway programs that settle two design risks before any Recording code exists (grafts 3 and 6 in `docs/design/accepted/rationale.md`). They are not part of the package. Each is one file, built with `swiftc`.

Measured on 2026-10-13 on an Apple M2 Max, macOS 27.0.1 (26A434), Swift 6.4, run from Ghostty with Screen Recording and Input Monitoring granted.

## Fragmented movie after SIGKILL

```
swiftc -O Experiments/fragmented-mov/main.swift -o /tmp/fragmented-mov
/tmp/fragmented-mov run /tmp/movs 5.5
```

`run` spawns a writer child that writes 1920 × 1080 synthetic BGRA frames at 30 fps in real time to a QuickTime `.mov` (planned length 10 s). It sends the child `SIGKILL` after the given wall time, then opens the file in a separate process with `AVURLAsset` and decodes every frame with `AVAssetReader`.

Killed after 5.5 s:

| Case | Playable | Duration | Video tracks | Decoded frames | Last PTS |
|------|----------|----------|--------------|----------------|----------|
| HEVC, 1 s fragments, run 1 | yes | 5.033 s | 1 | 150 | 5.000 s |
| HEVC, 1 s fragments, run 2 | yes | 5.033 s | 1 | 150 | 5.000 s |
| HEVC, 1 s fragments, run 3 | yes | 5.033 s | 1 | 150 | 5.000 s |
| H.264, 1 s fragments | yes | 5.000 s | 1 | 150 | 4.967 s |
| HEVC, no fragment interval, runs 1 to 3 | no | `AVFoundationErrorDomain -11829 "Cannot Open"` (underlying `-12848`, "This media may be damaged") | | | |

Killed after 3.3 s: the same pattern. HEVC with fragments reads as 3.033 s and 90 frames in all three runs, H.264 as 3.000 s, and every unfragmented control fails with -11829.

The readable duration lands on the last whole-second fragment boundary in every run, at both kill times. So the loss is bounded by the fragment interval, not by luck. Without a fragment interval the file has no movie header and nothing is recoverable.

## CGEvent timestamp clock

```
swiftc -O Experiments/event-clock/main.swift -o /tmp/event-clock
/tmp/event-clock 300
```

A listen-only `cgSessionEventTap` for `mouseMoved` reads `mach_absolute_time()` and `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` in the callback. A timer posts synthetic moves at `cghidEventTap` every 10 ms, tagged through `eventSourceUserData`. Untagged events are real mouse movement during the run.

The timebase is 125/3. Example event: `timestamp = 439341441833166`, `mach_absolute_time() = 10544194610450`, `CLOCK_UPTIME_RAW = 439341442102208` ns.

| Run | Events | `CLOCK_UPTIME_RAW` minus timestamp, read as ns | Read as mach ticks instead |
|-----|--------|-----------------------------------------------|----------------------------|
| 1 | 300 posted | min 176 µs, p50 285 µs, p95 1636 µs, max 3882 µs | about -17.9 million s (nonsense) |
| 1 | 18 real | min 218 µs, p50 267 µs, p95 663 µs, max 760 µs | about -17.9 million s |
| 2 | 300 posted | min 168 µs, p50 220 µs, p95 342 µs, max 1459 µs | |
| 3 | 300 posted | min 99 µs, p50 258 µs, p95 1390 µs, max 2563 µs | |
| 3 | 9 real | min 135 µs, p50 283 µs, p95 363 µs, max 2676 µs | |

`CGEvent.timestamp` is nanoseconds on `CLOCK_UPTIME_RAW`, for both posted and real events. It is not mach ticks. Callback latency is typically 0.2 to 0.3 ms, with a p95 up to 1.6 ms.

## SCStream PTS clock

```
swiftc -O Experiments/sck-clock/main.swift -o /tmp/sck-clock
/tmp/sck-clock
```

Twelve screen buffers from a 640 × 400, 30 fps stream of the main display. Every PTS has timescale 1 000 000 000. The PTS equals the `SCStreamFrameInfo.displayTime` attachment (mach ticks) converted to nanoseconds, with a difference of 0.0 µs on all 12. It matches `CMClockGetHostTimeClock()` and `CLOCK_UPTIME_RAW` read on arrival to within a few milliseconds. Arrival minus PTS ranged from -3.6 ms to +4.0 ms, except the first buffer, which arrived 229 ms after its PTS. The PTS is the display time, so it can be slightly ahead of the moment the buffer arrives.

## Deprecations seen while building

On the macOS 27 SDK, `AVAssetWriterInput.expectsMediaDataInRealTime` and `AVAssetWriterInputPixelBufferAdaptor` are deprecated in favour of `appendImmediately(...)` and `AVAssetWriter.inputPixelBufferReceiver(for:pixelBufferAttributes:)`. The deployment target is macOS 15, so the recorder still needs the older API or an availability branch.
