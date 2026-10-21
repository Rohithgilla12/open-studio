import AVFoundation
import Foundation
import Timeline

/// The take's movies, opened once. The I/O half of building a composition.
///
/// Holds the `AVURLAsset`s themselves, not only their tracks: a track does not keep its asset
/// alive, and inserting from a track whose asset is gone fails with -11800 / -12780 (measured in
/// the cuts spike). The preview keeps one of these for the editor's life and rebuilds
/// compositions from it on every cut.
///
/// `@unchecked` because AVURLAsset and AVAssetTrack are immutable once loaded but not Sendable.
struct SourceMedia: @unchecked Sendable {
    private let assets: [AVURLAsset]
    let screen: AVAssetTrack
    /// Recording time where each track's media ends: the take's duration for the screen (one
    /// frame less on a recovered take), earlier for a lost microphone or camera.
    let screenEnd: RecordingTime
    let audio: [AudioSource: (track: AVAssetTrack, end: RecordingTime)]
    let camera: (track: AVAssetTrack, end: RecordingTime)?
    let recordingDuration: RecordingTime
    let warnings: [String]

    static func load(_ source: SourceRecording) async throws(RenderError) -> SourceMedia {
        var assets: [AVURLAsset] = []
        let screen: AVAssetTrack
        let screenEnd: RecordingTime
        do {
            let asset = AVURLAsset(url: source.screenMovie)
            assets.append(asset)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw RenderError.screenMovieUnreadable("no video track")
            }
            // They agree on the real takes (10.000 s against 10 000 000 µs); min guards a recovered take.
            screenEnd = min(RecordingTime(mediaTime: try await asset.load(.duration)), source.duration)
            screen = video
        } catch let error as RenderError {
            throw error
        } catch {
            throw .screenMovieUnreadable(error.localizedDescription)
        }

        var audio: [AudioSource: (track: AVAssetTrack, end: RecordingTime)] = [:]
        var warnings: [String] = []
        for audioSource in AudioSource.allCases {
            guard let url = audioSource.movie(in: source) else { continue }
            do {
                let movie = AVURLAsset(url: url)
                guard let track = try await movie.loadTracks(withMediaType: .audio).first else {
                    throw RenderError.screenMovieUnreadable("no audio track")
                }
                assets.append(movie)
                audio[audioSource] = (track, min(RecordingTime(mediaTime: try await movie.load(.duration)), screenEnd))
            } catch {
                warnings.append("\(url.lastPathComponent) is unreadable (\(error.localizedDescription)); exporting without it")
            }
        }

        var camera: (track: AVAssetTrack, end: RecordingTime)?
        if let url = source.cameraMovie {
            do {
                let movie = AVURLAsset(url: url)
                if let track = try await movie.loadTracks(withMediaType: .video).first {
                    assets.append(movie)
                    camera = (track, min(RecordingTime(mediaTime: try await movie.load(.duration)), screenEnd))
                } else {
                    warnings.append("camera.mov has no video track; exporting without the camera")
                }
            } catch {
                warnings.append("camera.mov is unreadable (\(error.localizedDescription)); exporting without the camera")
            }
        }
        return SourceMedia(
            assets: assets, screen: screen, screenEnd: screenEnd, audio: audio, camera: camera,
            recordingDuration: source.duration, warnings: warnings)
    }
}

/// The AVFoundation view of one edit state: the kept spans of every track laid end to end, so
/// composition time is output time. The single builder preview, export, and stills all use. If
/// two consumers built their own, "same pixels for the same output time" would depend on keeping
/// them in step by hand.
///
/// Cheap and synchronous, no I/O. Measured on the 5 s D4 take with its microphone: 0.06 ms for
/// 10 cuts, 0.43 ms for 100, 2.3 ms for 500.
///
/// `@unchecked` because AVComposition is immutable once built but not marked Sendable.
struct MovieComposition: @unchecked Sendable {
    let media: SourceMedia
    /// The map this asset was built for. A scene built from another edit state must not be drawn
    /// over it; `videoComposition(scene:frameRate:)` checks.
    let map: TimeMap
    let asset: AVComposition
    let screenTrackID: CMPersistentTrackID
    let audioTracks: [AudioSource: CMPersistentTrackID]
    /// nil when the take has no camera, or its movie could not be read (see `warnings`).
    let camera: CameraFootage?
    /// The asset's length in output time: `map.duration`, less only what a recovered screen movie
    /// is short.
    let duration: CMTime
    var warnings: [String] { media.warnings }

    /// How long the audio fades out before a join and in after it. Measured on a 440 Hz sine read
    /// through `AVAssetReaderAudioMixOutput`: with no ramp the largest sample step at a join was
    /// 0.42 (the sine's own is 0.029, so a click); 5, 10, and 20 ms ramps are smoothed by the
    /// mixer and still leave 0.80, 0.60, and 0.16 gain at the join; 30 ms reaches 0.02 and a
    /// largest step of 0.009. `Cuts.minimumKept` keeps neighbouring ramps from overlapping.
    static let joinFade = OutputTime.milliseconds(30)

    /// Every track is inserted whole at 0, exactly as the uncut composition was, then each cut is
    /// removed from the whole composition, last cut first. One call moves every track, so a lost,
    /// late, or short track needs no per-track clipping, and screen, microphone, system audio, and
    /// camera stay in sync across every cut (measured: 441 of 441 frames carried the source frame
    /// the map predicts; the audio sample count was within 2 samples of the kept duration).
    init(media: SourceMedia, map: TimeMap) {
        let composition = AVMutableComposition()
        func insert(_ track: AVAssetTrack, until end: RecordingTime, as mediaType: AVMediaType) -> CMPersistentTrackID? {
            guard let target = composition.addMutableTrack(withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { return nil }
            do {
                try target.insertTimeRange(CMTimeRange(start: .zero, end: end.mediaTime), of: track, at: .zero)
            } catch {
                return nil
            }
            return target.trackID
        }
        // The screen movie loaded and inserted whole before, so this cannot fail in practice.
        let screenTrackID = insert(media.screen, until: media.screenEnd, as: .video) ?? kCMPersistentTrackID_Invalid
        var audioTracks: [AudioSource: CMPersistentTrackID] = [:]
        // In a fixed order, so track ids are the same on every build from one SourceMedia.
        for source in AudioSource.allCases {
            guard let audio = media.audio[source] else { continue }
            audioTracks[source] = insert(audio.track, until: audio.end, as: .audio)
        }
        var camera: CameraFootage?
        if let footage = media.camera, let trackID = insert(footage.track, until: footage.end, as: .video) {
            camera = CameraFootage(trackID: trackID, end: map.output(collapsing: footage.end).compositionTime)
        }
        var removedEnd = media.recordingDuration
        for segment in map.segments.reversed() {
            if segment.source.end < removedEnd {
                composition.removeTimeRange(CMTimeRange(start: segment.source.end.mediaTime, end: removedEnd.mediaTime))
            }
            removedEnd = segment.source.start
        }
        if removedEnd > .zero {
            composition.removeTimeRange(CMTimeRange(start: .zero, end: removedEnd.mediaTime))
        }

        self.media = media
        self.map = map
        asset = composition.copy() as! AVComposition
        self.screenTrackID = screenTrackID
        self.audioTracks = audioTracks
        self.camera = camera
        duration = min(composition.duration, map.duration.compositionTime)
    }

    struct CameraFootage: Sendable {
        let trackID: CMPersistentTrackID
        /// Output time where the camera's kept media ends: `map.output(collapsing: camera end)`.
        /// The kept camera media is contiguous in output time from 0 to here, whether the loss
        /// falls before, inside, or after a cut, so the two-range instruction split is unchanged.
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

    /// Levels, plus a dip at every join and a fade at a trimmed start or end, on every track.
    /// Volume ramps hold their end value (measured: one ramp to 0 silenced the rest of the take),
    /// so each dip is a pair: gain to 0 over [join - joinFade, join), 0 to gain over
    /// [join, join + joinFade).
    ///
    /// The export passes `audibleOnly`, because a reader output refuses a mix that names a track
    /// it does not read.
    func audioMix(_ levels: AudioLevels, audibleOnly: Bool = false) -> AVAudioMix? {
        let sources = audioSources(levels, audibleOnly: audibleOnly)
        guard !sources.isEmpty else { return nil }
        let fade = Self.joinFade
        let trims = map.trims(within: media.recordingDuration)
        let mix = AVMutableAudioMix()
        mix.inputParameters = sources.map { source, id in
            let parameters = AVMutableAudioMixInputParameters()
            parameters.trackID = id
            let gain = Float(levels[source].gain)
            parameters.setVolume(gain, at: .zero)
            if trims.start {
                parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: gain, timeRange: CMTimeRange(start: .zero, end: fade.compositionTime))
            }
            for join in map.joins {
                parameters.setVolumeRamp(
                    fromStartVolume: gain, toEndVolume: 0, timeRange: CMTimeRange(start: (join - fade).compositionTime, end: join.compositionTime))
                parameters.setVolumeRamp(
                    fromStartVolume: 0, toEndVolume: gain, timeRange: CMTimeRange(start: join.compositionTime, end: (join + fade).compositionTime))
            }
            if trims.end {
                parameters.setVolumeRamp(
                    fromStartVolume: gain, toEndVolume: 0,
                    timeRange: CMTimeRange(start: (map.duration - fade).compositionTime, end: map.duration.compositionTime))
            }
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
    /// coalesced edit. Instruction ranges are in output time because the composition is.
    ///
    /// `frameDuration` is what turns the variable-rate source into constant-rate output. The
    /// compositor is asked for a frame at every multiple of 1/fps and receives whichever source
    /// sample covers that time. Measured: a 10 s take with 200 source frames produced 600 output
    /// frames at exactly 1/60 s spacing. `sourceTrackIDForFrameTiming` stays unset for that reason.
    func videoComposition(scene: RenderScene, frameRate: FrameRate) -> AVVideoComposition {
        // A runtime check rather than a type: the scene and the movie come from the same Project
        // value at every call site, and this catches the one way they could differ (a preview that
        // swapped the scene but not the item).
        precondition(scene.timeline.map == map, "scene and composition were built for different cuts")
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
