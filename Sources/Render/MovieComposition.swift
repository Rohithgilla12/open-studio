import AVFoundation
import Foundation
import Timeline

/// The AVFoundation view of a project: the source tracks plus the styled video composition.
/// The single builder that preview, export, and stills all use. If two consumers built their own,
/// "same pixels for the same time" would depend on keeping them in step by hand.
///
/// `@unchecked` because AVComposition is immutable once built but not marked Sendable.
struct MovieComposition: @unchecked Sendable {
    /// Screen video track and, when recorded, the microphone track, both inserted at time 0, since
    /// media time 0 in both files is recording time 0.
    let asset: AVComposition
    let screenTrackID: CMPersistentTrackID
    /// nil when the take has no microphone, or its movie could not be read (see `warnings`).
    let audioTrackID: CMPersistentTrackID?
    let duration: CMTime
    let warnings: [String]

    /// Loads the movies once. The asset never changes after an edit; only the video composition
    /// does, which is why an edit can reach a playing item without rebuilding it.
    static func load(_ source: SourceRecording) async throws(RenderError) -> MovieComposition {
        let composition = AVMutableComposition()
        let screenTrack: AVMutableCompositionTrack
        let duration: CMTime
        do {
            let screen = AVURLAsset(url: source.screenMovie)
            guard let video = try await screen.loadTracks(withMediaType: .video).first else {
                throw RenderError.screenMovieUnreadable("no video track")
            }
            // They agree on the real takes (10.000 s against 10 000 000 µs); min guards a recovered take.
            duration = min(try await screen.load(.duration), source.duration.cmTime)
            guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw RenderError.screenMovieUnreadable("could not add a video track")
            }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: video, at: .zero)
            screenTrack = track
        } catch let error as RenderError {
            throw error
        } catch {
            throw .screenMovieUnreadable(error.localizedDescription)
        }

        var audioTrackID: CMPersistentTrackID?
        var warnings: [String] = []
        if let url = source.microphoneMovie {
            do {
                let microphone = AVURLAsset(url: url)
                guard let audio = try await microphone.loadTracks(withMediaType: .audio).first,
                    let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                else {
                    throw RenderError.screenMovieUnreadable("no audio track")
                }
                let available = min(try await microphone.load(.duration), duration)
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: available), of: audio, at: .zero)
                audioTrackID = track.trackID
            } catch {
                warnings.append("microphone.mov is unreadable (\(error.localizedDescription)); exporting without audio")
            }
        }
        return MovieComposition(
            asset: composition.copy() as! AVComposition, screenTrackID: screenTrack.trackID, audioTrackID: audioTrackID,
            duration: duration, warnings: warnings)
    }

    /// The styled video composition for one scene. Cheap: no I/O, no GPU work. Called on every
    /// coalesced edit.
    ///
    /// `frameDuration` is what turns the variable-rate source into constant-rate output. The
    /// compositor is asked for a frame at every multiple of 1/fps and receives whichever source
    /// sample covers that time. Measured: a 10 s take with 200 source frames produced 600 output
    /// frames at exactly 1/60 s spacing. `sourceTrackIDForFrameTiming` stays unset for that reason.
    func videoComposition(scene: RenderScene, frameRate: FrameRate) -> AVVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = StyledCompositor.self
        composition.renderSize = CGSize(width: scene.layout.canvas.width, height: scene.layout.canvas.height)
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate.rawValue))
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        composition.instructions = [
            SceneInstruction(timeRange: CMTimeRange(start: .zero, duration: duration), screenTrackID: screenTrackID, scene: scene)
        ]
        return composition
    }
}
