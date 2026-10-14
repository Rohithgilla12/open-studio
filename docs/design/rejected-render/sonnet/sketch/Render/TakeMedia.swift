public import AVFoundation
public import Timeline

/// The media half of a take, built once when the take opens: an `AVMutableComposition` holding the
/// screen video track and, if present, the microphone track, both inserted at zero because recording
/// time 0 is media time 0 in both files. Edits never touch it. An edit builds a new `RenderPlan` and
/// swaps the video composition only.
///
/// This is the public face of Render: preview and export are two methods on one value.
public final class TakeMedia: @unchecked Sendable {
    let composition: AVMutableComposition
    let screenTrackID: CMPersistentTrackID
    let microphoneTrackID: CMPersistentTrackID?
    public let duration: RecordingTime

    /// Loads track metadata (async, no decoding). The composition's duration is the screen track's;
    /// the microphone range is clipped to it, so a microphone that ran a few ms long cannot extend the file.
    public init(source: SourceRecording) async throws(RenderError) { fatalError("not implemented") }

    /// A player item whose video composition draws `plan`. Build it once per take window.
    @MainActor public func makePlayerItem(plan: RenderPlan) -> AVPlayerItem { fatalError("not implemented") }

    /// Swaps in a video composition for `plan` on the live item: an edit reaches the preview without
    /// rebuilding the player or the item. While paused AVFoundation re-requests the current frame;
    /// while playing it re-primes, which costs a frame or two (unmeasured, see open questions).
    @MainActor public func apply(_ plan: RenderPlan, to item: AVPlayerItem) { fatalError("not implemented") }

    /// Writes an MP4. Cancelling the calling task cancels the export and removes the partial file.
    /// The result file appears only on success (written as `<name>.partial`, then renamed), so a crash
    /// or a second run cannot leave a plausible-looking truncated MP4.
    public func export(
        plan: RenderPlan, to destination: URL, progress: @Sendable (ExportProgress) -> Void
    ) async throws(RenderError) -> ExportResult {
        // TODO
        //  vc = videoComposition(for: plan, canvas: plan.output.canvas)   // frameDuration = 1 / fps, renderSize = canvas
        //  reader = AVAssetReader(asset: composition)
        //  video = AVAssetReaderVideoCompositionOutput(videoTracks: [screenTrack], videoSettings: [BGRA, IOSurface])
        //  video.videoComposition = vc; video.alwaysCopiesSampleData = false
        //  audio = microphoneTrack.map { AVAssetReaderAudioMixOutput(audioTracks: [$0], audioSettings: LPCM 48 kHz) }
        //  writer = AVAssetWriter(url: partial, fileType: .mp4)
        //  vIn: codec, canvas, AVVideoAverageBitRateKey, MaxKeyFrameInterval = 2 s, expectedFrameRate,
        //       AVVideoColorPropertiesKey = BT.709 primaries, transfer, matrix; mediaTimeScale = 600 * fps
        //  aIn: AAC, 48 kHz, mono or stereo as the source, 128 kbps
        //  pump each input on its own queue with requestMediaDataWhenReady (classic path, as the recorder)
        //  progress = pts / duration, reported at most every 250 ms; check Task.isCancelled between buffers
        //  finish: writer.finishWriting, rename partial to destination (replace), return ExportResult
        //  on error or cancel: reader.cancelReading, writer.cancelWriting, delete partial
        fatalError("not implemented")
    }

    /// One frame at `t`, through the same compositor path as preview and export (a one-frame
    /// AVAssetReader over the composition at `t`), at the plan's canvas size. For `osrec still` and tests.
    public func still(plan: RenderPlan, at t: RecordingTime) async throws(RenderError) -> CGImage {
        fatalError("not implemented")
    }

    func videoComposition(for plan: RenderPlan, canvas: PixelSize) -> AVVideoComposition { fatalError("not implemented") }
}

public struct ExportProgress: Sendable {
    public let fraction: Double
    /// Seconds of video produced per wall-clock second so far. 1 = real time.
    public let speed: Double
}

public struct ExportResult: Sendable {
    public let url: URL
    public let frames: Int
    public let wallSeconds: Double
    public let bytes: Int
}
