import AVFoundation
import Timeline

// The compositor's only change. Composition time is output time, and `Timeline.frame(at:)` takes
// output time, so the compositor converts nothing and holds no map:
//
//     let t = OutputTime(compositionTime: request.compositionTime)
//     ...
//     let image = scene.image(source: ..., camera: ..., at: t)
//
// `RenderScene.image(source:camera:at:)` takes `OutputTime`, and `RenderError.missingSourceFrame`
// carries `OutputTime`.

/// The two CMTime bridges, named by clock. `RecordingTime(_: CMTime)` is deleted: it is the one
/// conversion that would read a composition time as a recording time and compile.
extension OutputTime {
    /// Rounds to the nearest microsecond, the Timeline's resolution.
    init(compositionTime time: CMTime) {
        self = .seconds(time.seconds)
    }

    var compositionTime: CMTime { CMTime(value: microseconds, timescale: 1_000_000) }
}

extension RecordingTime {
    /// A time in one of the take's source movies. Only the composition builder uses it, to name the
    /// ranges it inserts.
    var mediaTime: CMTime { CMTime(value: microseconds, timescale: 1_000_000) }
}
