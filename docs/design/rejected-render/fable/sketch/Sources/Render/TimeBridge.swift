import CoreMedia
import Timeline

// The only place CMTime meets RecordingTime. Timeline's docs promise the bridge lives in the
// renderer; this file is it.

extension RecordingTime {
    /// Rounded to the nearest microsecond. Output frame k at f fps is CMTime(k, f), so the
    /// microsecond value is round(k * 1e6 / f).
    init(_ time: CMTime) { fatalError("not implemented") }

    var cmTime: CMTime { CMTime(value: microseconds, timescale: 1_000_000) }
}

extension FrameRate {
    var frameDuration: CMTime { CMTime(value: 1, timescale: CMTimeScale(rawValue)) }
}
