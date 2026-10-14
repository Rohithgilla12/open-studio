import AVFoundation
import Foundation
import Timeline

/// The AVFoundation view of a project: the source tracks plus the styled video composition.
/// The single builder that preview, export, and stills all use. If two consumers built their own,
/// "same pixels for the same time" would depend on keeping them in step by hand.
struct MovieComposition: @unchecked Sendable {
    /// Screen video track and, when recorded, the microphone track, both inserted at time 0, since
    /// media time 0 in both files is recording time 0.
    let asset: AVComposition
    let screenTrackID: CMPersistentTrackID
    /// nil when the take has no microphone.
    let audioTrackID: CMPersistentTrackID?
    let duration: CMTime

    /// Loads the movies once. The asset never changes after an edit; only the video composition
    /// does, which is why an edit can reach a playing item without rebuilding it.
    static func load(_ source: SourceRecording) async throws(RenderError) -> MovieComposition {
        // TODO:
        //   screen = AVURLAsset(url: source.screenMovie); videoTrack = first video track
        //   duration = min(screen duration, source.duration as CMTime)
        //     (they agree today: 10.000 s vs 10 000 000 µs on the D4 take; min guards a recovered take)
        //   composition.addMutableTrack(.video).insertTimeRange([0, duration], of: videoTrack, at: .zero)
        //   if let mic = source.microphoneMovie:
        //       insert [0, min(mic duration, duration)] of its audio track at .zero
        //   A microphone track that fails to load drops audio with a warning, never the export.
        fatalError("not implemented")
    }

    /// The styled video composition for one scene. Cheap: no I/O, no GPU work. Called on every
    /// coalesced edit.
    ///
    /// `frameDuration` is what turns the variable-rate source into constant-rate output. The
    /// compositor is asked for a frame at every multiple of 1/fps and receives whichever source
    /// sample covers that time. Measured: a 10 s take with 200 source frames produced 600 output
    /// frames at exactly 1/60 s spacing. `sourceTrackIDForFrameTiming` stays unset for that reason.
    func videoComposition(scene: RenderScene, frameRate: FrameRate) -> AVVideoComposition {
        // TODO:
        //   let c = AVMutableVideoComposition()
        //   c.customVideoCompositorClass = StyledCompositor.self
        //   c.renderSize = CGSize(scene.layout.canvas)
        //   c.frameDuration = CMTime(value: 1, timescale: frameRate.rawValue)
        //   c.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2   (and transfer, matrix)
        //   c.instructions = [SceneInstruction(timeRange: [0, duration), screenTrackID, scene)]
        //   return c
        fatalError("not implemented")
    }
}
