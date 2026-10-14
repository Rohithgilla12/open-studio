import AVFoundation
import CoreGraphics
import Timeline

/// Writes an MP4 from a project, through the same compositor the preview uses.
///
/// Reader side: `AVAssetReaderVideoCompositionOutput` on the project's composition with the plan's
/// `AVVideoComposition`. The output's `frameDuration` makes the reader deliver one composed BGRA
/// frame per tick (sample-and-hold of the VFR source), so the loop below never steps frames itself.
/// Audio is a second reader output with nil settings (compressed AAC passthrough).
///
/// Writer side: `AVAssetWriter` with explicit codec, size, bitrate, and BT.709 colour properties;
/// VideoToolbox does the BGRA to 4:2:0 conversion in hardware. Audio input with nil settings
/// (passthrough). Both tracks start at 0 on the recording clock, so sync is by construction.
public enum Exporter {
    /// Starts immediately. Writes to `<out>.partial` and renames on success, so a cancelled or
    /// failed export leaves no half file and rerunning gives the same bytes modulo encoder
    /// nondeterminism.
    public static func export(_ project: Project, to url: URL) -> ExportJob { fatalError("not implemented") }

    /// One composed frame at `t`, for `osrec frame` and the pixel tests. Goes through the reader
    /// path over the range `[t, t + 1/fps)`, so it is the export's pixels, not a second drawing.
    public static func frame(_ project: Project, at t: RecordingTime) async throws(ExportError) -> CGImage {
        fatalError("not implemented")
    }
}

/// A running export. `progress` ends when `result` is ready. `cancel` is idempotent.
public final class ExportJob: Sendable {
    public let progress: AsyncStream<Double>
    public let result: Task<ExportResult, any Error>

    init(progress: AsyncStream<Double>, result: Task<ExportResult, any Error>) { fatalError("not implemented") }

    public func cancel() { result.cancel() }

    // TODO (inside the Task):
    //   plan = RenderPlan(project, edit); box = PlanBox(plan)   // frozen: nobody else holds the box
    //   reader = AVAssetReader(asset: composition)
    //   video = AVAssetReaderVideoCompositionOutput(videoTracks: [screen], videoSettings: BGRA)
    //   video.videoComposition = RenderComposition.make(plan: box, asset:, frameRate:)
    //   audio = microphone.map { AVAssetReaderTrackOutput(track: $0, outputSettings: nil) }
    //   writer = AVAssetWriter(outputURL: partial, fileType: .mp4)
    //   videoIn = AVAssetWriterInput(.video, settings: OutputSettings.video(edit.output, size))
    //   audioIn = audio.map { AVAssetWriterInput(.audio, outputSettings: nil) }
    //   startWriting; startSession(atSourceTime: .zero)
    //   pump: each input requestMediaDataWhenReady on its own serial queue; copyNextSampleBuffer ->
    //         append; video PTS / duration -> progress; Task.isCancelled -> reader.cancelReading,
    //         writer.cancelWriting, remove partial, throw CancellationError
    //   both finished -> finishWriting -> rename partial to url -> ExportResult
}

public struct ExportResult: Sendable, Hashable {
    public let url: URL
    public let duration: RecordingTime
    public let frameCount: Int
    public let wallClock: Duration
    /// `duration / wallClock`. The README's "at or faster than real time" is this number >= 1.
    public var realTimeFactor: Double { fatalError("not implemented") }
}

public enum ExportError: Error, Sendable {
    case invalidZooms(ZoomTrackError)
    case readerFailed(String)
    case writerFailed(String)
    case cancelled
    case destinationUnwritable(URL, String)
}

/// Encoder settings per codec and size. Bitrate scales with pixel rate (bits per pixel per frame)
/// so 1080p30 and native 60 both look right without a table of magic numbers.
enum OutputSettings {
    static func video(_ format: OutputFormat, size: PixelSize) -> [String: Any] { fatalError("not implemented") }
}
