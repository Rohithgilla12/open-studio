import AVFoundation
import Foundation
import Timeline

public enum Export {
    /// Writes `project` as an MP4 at `destination`. The app and `osrec export` both call this.
    ///
    /// - Takes a `Project` value, so edits made while exporting cannot reach this export.
    /// - Writes to a hidden sibling and renames on success, so `destination` is either the previous
    ///   file or the complete new one, never a torn MP4. Rerunning overwrites; cancelling (task
    ///   cancellation) removes the partial file.
    /// - Calls `progress` from a background thread, at most once per output frame.
    public static func run(
        _ project: Project,
        to destination: URL,
        progress: @Sendable (ExportProgress) -> Void = { _ in }
    ) async throws(ExportError) -> ExportReport {
        // TODO (VFR to CFR export loop):
        //   movie = try await MovieComposition.load(project.source)
        //   scene = try RenderScene.make(project: project, format: project.edits.format, reusing: nil)
        //   reader = AVAssetReader(asset: movie.asset)
        //   video = AVAssetReaderVideoCompositionOutput(videoTracks: [screen track], videoSettings: nil)
        //   video.videoComposition = movie.videoComposition(scene: scene, frameRate: format.frameRate)
        //   video.alwaysCopiesSampleData = false
        //   audio = movie.audioTrackID.map { AVAssetReaderTrackOutput(track, outputSettings: LPCM 48 kHz) }
        //
        //   partial = destination.deletingLastPathComponent()/".<name>.partial.mp4"
        //   writer = AVAssetWriter(partial, .mp4); writer.shouldOptimizeForNetworkUse = true
        //   videoIn = AVAssetWriterInput(.video, settings: codec, canvas size, bitrate for canvas,
        //             AVVideoColorPropertiesKey = 709/709/709, expectsMediaDataInRealTime = false)
        //   audioIn = AAC 48 kHz, 128 kbps, channels from the source
        //
        //   reader.startReading(); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        //   Pump each (output, input) pair with requestMediaDataWhenReady on its own queue:
        //     while input.isReadyForMoreMediaData:
        //       if Task.isCancelled: reader.cancelReading(); writer.cancelWriting(); remove partial; throw .cancelled
        //       guard let sample = output.copyNextSampleBuffer() else { input.markAsFinished(); signal; return }
        //       input.append(sample)            // false -> writer.error, stop both pumps
        //       video only: progress(ExportProgress(frame: n, of: expectedFrames))
        //   expectedFrames = ceil(duration * fps). The composition yields exactly one sample per
        //   frameDuration (measured 600 for 10 s at 60), so no frame-dropping or duplicating
        //   logic exists here: the VFR to CFR conversion happened in the composition.
        //   await both pumps; await writer.finishWriting()
        //   FileManager.replaceItemAt(destination, withItemAt: partial)
        //   return ExportReport(frames, wall time, file size)
        fatalError("not implemented")
    }
}

public struct ExportProgress: Sendable, Hashable {
    public let framesWritten: Int
    public let framesTotal: Int
    public var fraction: Double { framesTotal > 0 ? Double(framesWritten) / Double(framesTotal) : 0 }
}

public struct ExportReport: Sendable, Hashable {
    public let destination: URL
    public let frames: Int
    public let duration: RecordingTime
    public let wallSeconds: Double
    public let bytes: Int64
    /// Media seconds per wall second. The brief requires at least 1 for 4K60.
    public var realTimeFactor: Double { duration.seconds / wallSeconds }
}

public enum ExportError: Error, Sendable, Equatable {
    case render(RenderError)
    case readerFailed(String)
    case writerFailed(String)
    case destinationUnwritable(String)
    case cancelled
}

/// Single frames through the same composition, for `osrec export --still`, the pixel test, and
/// later the zoom strip's thumbnails.
public enum Still {
    /// PNG bytes of the frame at `t`. Uses `AVAssetImageGenerator` with the project's video
    /// composition and zero tolerances, so the compositor and scene are exactly the export's.
    public static func png(_ project: Project, at t: RecordingTime) async throws(ExportError) -> Data {
        fatalError("not implemented")
    }
}
