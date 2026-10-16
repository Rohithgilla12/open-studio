import AVFoundation
import Foundation
import Timeline

/// The AVFoundation view of a project: the source tracks plus the styled video composition.
/// The single builder that preview, export, and stills all use. If two consumers built their own,
/// "same pixels for the same time" would depend on keeping them in step by hand.
///
/// `@unchecked` because AVComposition is immutable once built but not marked Sendable.
struct MovieComposition: @unchecked Sendable {
    let asset: AVComposition
    let screenTrackID: CMPersistentTrackID
    let audioTracks: [AudioSource: CMPersistentTrackID]
    /// nil when the take has no camera, or its movie could not be read (see `warnings`).
    let camera: CameraFootage?
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

        var audioTracks: [AudioSource: CMPersistentTrackID] = [:]
        var warnings: [String] = []
        for audioSource in AudioSource.allCases {
            guard let url = audioSource.movie(in: source) else { continue }
            do {
                let movie = AVURLAsset(url: url)
                guard let audio = try await movie.loadTracks(withMediaType: .audio).first,
                    let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                else {
                    throw RenderError.screenMovieUnreadable("no audio track")
                }
                let available = min(try await movie.load(.duration), duration)
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: available), of: audio, at: .zero)
                audioTracks[audioSource] = track.trackID
            } catch {
                warnings.append("\(url.lastPathComponent) is unreadable (\(error.localizedDescription)); exporting without it")
            }
        }

        var camera: CameraFootage?
        if let url = source.cameraMovie {
            do {
                let movie = AVURLAsset(url: url)
                if let video = try await movie.loadTracks(withMediaType: .video).first,
                    let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                {
                    // The camera's own edit list carries a late start, so inserting from 0 keeps it aligned.
                    let available = min(try await movie.load(.duration), duration)
                    try track.insertTimeRange(CMTimeRange(start: .zero, duration: available), of: video, at: .zero)
                    camera = CameraFootage(trackID: track.trackID, end: available)
                } else {
                    warnings.append("camera.mov has no video track; exporting without the camera")
                }
            } catch {
                warnings.append("camera.mov is unreadable (\(error.localizedDescription)); exporting without the camera")
            }
        }
        return MovieComposition(
            asset: composition.copy() as! AVComposition, screenTrackID: screenTrack.trackID, audioTracks: audioTracks,
            camera: camera, duration: duration, warnings: warnings)
    }

    struct CameraFootage: Sendable {
        let trackID: CMPersistentTrackID
        /// Where the camera's media ends, which is earlier than the take's for a lost camera.
        let end: CMTime
    }

    /// The camera, when the scene draws it. A hidden overlay leaves it out of the request, so
    /// AVFoundation never decodes it.
    func camera(for scene: RenderScene) -> CameraFootage? {
        scene.cameraOverlay == nil ? nil : camera
    }

    func videoTracks(for scene: RenderScene) -> [AVAssetTrack] {
        let wanted = [screenTrackID] + (camera(for: scene).map { [$0.trackID] } ?? [])
        return wanted.compactMap { id in asset.tracks.first { $0.trackID == id } }
    }

    /// The export passes `audibleOnly`, because a reader output refuses a mix that names a track it
    /// does not read.
    func audioMix(_ levels: AudioLevels, audibleOnly: Bool = false) -> AVAudioMix? {
        let sources = audioSources(levels, audibleOnly: audibleOnly)
        guard !sources.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = sources.map { source, id in
            let parameters = AVMutableAudioMixInputParameters()
            parameters.trackID = id
            parameters.setVolume(Float(levels[source].gain), at: .zero)
            return parameters
        }
        return mix
    }

    func audibleTracks(_ levels: AudioLevels) -> [AVAssetTrack] {
        audioSources(levels, audibleOnly: true).compactMap { _, id in asset.tracks.first { $0.trackID == id } }
    }

    private func audioSources(_ levels: AudioLevels, audibleOnly: Bool) -> [(AudioSource, CMPersistentTrackID)] {
        AudioSource.allCases.compactMap { source in
            guard let id = audioTracks[source], !audibleOnly || levels[source].gain > 0 else { return nil }
            return (source, id)
        }
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
        composition.instructions = instructionRanges(for: scene).map { range, cameraTrackID in
            SceneInstruction(timeRange: range, screenTrackID: screenTrackID, cameraTrackID: cameraTrackID, scene: scene)
        }
        return composition
    }

    /// The camera track is required only while it has media. Past its end the export's reader
    /// keeps handing over the last camera frame (measured by the D9 review), where a still gets
    /// none, so the camera's range and the rest get separate instructions.
    private func instructionRanges(for scene: RenderScene) -> [(CMTimeRange, CMPersistentTrackID?)] {
        let whole = CMTimeRange(start: .zero, duration: duration)
        guard let camera = camera(for: scene), camera.end > .zero else { return [(whole, nil)] }
        guard camera.end < duration else { return [(whole, camera.trackID)] }
        return [
            (CMTimeRange(start: .zero, end: camera.end), camera.trackID),
            (CMTimeRange(start: camera.end, end: duration), nil),
        ]
    }
}
