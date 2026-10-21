import AVFoundation
import Foundation
import Timeline

/// The take's movies, opened once. The I/O half of what `MovieComposition.load` does today.
///
/// Holds the `AVURLAsset`s themselves, not only their tracks: a track does not keep its asset
/// alive, and inserting from a track whose asset is gone fails with -11800 / -12780 (measured in
/// the cuts spike). Preview rebuilds compositions from this for the life of the editor.
///
/// `@unchecked` because AVURLAsset and AVAssetTrack are immutable once loaded but not Sendable.
struct SourceMedia: @unchecked Sendable {
    private let assets: [AVURLAsset]
    let screen: AVAssetTrack
    /// Recording time where each track's media ends: the take's duration for the screen, earlier
    /// for a lost microphone or camera.
    let audio: [AudioSource: (track: AVAssetTrack, end: RecordingTime)]
    let camera: (track: AVAssetTrack, end: RecordingTime)?
    let recordingDuration: RecordingTime
    let warnings: [String]

    static func load(_ source: SourceRecording) async throws(RenderError) -> SourceMedia {
        // TODO: today's loading and warning logic from MovieComposition.load, keeping every asset.
        fatalError("not implemented")
    }
}

/// The AVFoundation view of one edit state: the kept spans of every track laid end to end, so
/// composition time is output time. Still the single builder preview, export, and stills use.
///
/// Cheap and synchronous: no I/O. Measured on the 5 s D4 take with its microphone: 0.06 ms for
/// 10 cuts, 0.43 ms for 100, 2.3 ms for 500.
struct MovieComposition: @unchecked Sendable {
    let media: SourceMedia
    /// The map this asset was built for. A scene built from another edit state must not be drawn
    /// over it; `videoComposition(scene:frameRate:)` checks.
    let map: TimeMap
    let asset: AVComposition
    let screenTrackID: CMPersistentTrackID
    let audioTracks: [AudioSource: CMPersistentTrackID]
    let camera: CameraFootage?
    var duration: CMTime { map.duration.compositionTime }
    var warnings: [String] { media.warnings }

    /// How long the audio takes to fade out before a join and in after it. Measured on a 440 Hz
    /// sine read through `AVAssetReaderAudioMixOutput`: with no ramp the largest sample step at a
    /// join was 0.42 (the sine's own is 0.029, so a click); 5, 10, and 20 ms ramps are smoothed by
    /// the mixer and still leave 0.80, 0.60, and 0.16 gain at the join; 30 ms reaches 0.02 and a
    /// largest step of 0.009.
    static let joinFade = OutputTime.milliseconds(30)

    init(media: SourceMedia, map: TimeMap) {
        // TODO: one composition track per source track. For each map segment, insert
        // segment.source clipped to that track's media end at segment.outputStart; a range past a
        // track's end inserts nothing, leaving that output span empty for that track (a lost
        // microphone is silent there, a lost camera draws no overlay). Every track gets the same
        // segments, so screen, microphone, system audio, and camera stay in sync across every cut
        // (measured: 441 of 441 frames carried the source frame the map predicts; the audio
        // sample count was within 2 samples of the kept duration).
        fatalError("not implemented")
    }

    struct CameraFootage: Sendable {
        let trackID: CMPersistentTrackID
        /// Output time where the camera's kept media ends: `map.output(collapsing: camera end)`.
        /// The kept camera media is contiguous in output time from 0 to here, whether the loss
        /// falls before, inside, or after a cut, so the two-range instruction split is unchanged.
        let end: CMTime
    }

    func camera(for scene: RenderScene) -> CameraFootage? {
        scene.cameraOverlay == nil ? nil : camera
    }

    /// Levels, plus a dip at every join and a fade at a trimmed start or end, on every track.
    /// Volume ramps hold their end value (measured: one ramp to 0 silenced the rest of the take),
    /// so each dip is a pair: gain to 0 over [join - joinFade, join), 0 to gain over
    /// [join, join + joinFade). Cuts.minimumKept keeps neighbouring ramps from overlapping.
    func audioMix(_ levels: AudioLevels, audibleOnly: Bool = false) -> AVAudioMix? {
        fatalError("not implemented")
    }

    func audibleTracks(_ levels: AudioLevels) -> [AVAssetTrack] {
        fatalError("not implemented")
    }

    func videoTracks(for scene: RenderScene) -> [AVAssetTrack] {
        fatalError("not implemented")
    }

    /// Today's body. Instruction ranges are in output time because the composition is.
    func videoComposition(scene: RenderScene, frameRate: FrameRate) -> AVVideoComposition {
        // A runtime check rather than a type: the scene and the movie come from the same Project
        // value at every call site, and this catches the one way they could differ (a preview that
        // swapped the scene but not the item).
        precondition(scene.timeline.map == map, "scene and composition were built for different cuts")
        fatalError("not implemented")
    }
}
