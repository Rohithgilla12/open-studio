import AVFoundation
import Darwin
import Foundation
import Synchronization
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
        progress: @escaping @Sendable (ExportProgress) -> Void = { _ in }
    ) async throws(ExportError) -> ExportReport {
        let movie: MovieComposition
        let scene: RenderScene
        do {
            movie = try await MovieComposition.load(project.source)
            scene = try RenderScene.make(project: project, format: project.edits.format, reusing: nil)
        } catch {
            throw .render(error)
        }
        let format = project.edits.format
        let canvas = scene.layout.canvas
        let partial = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).partial", directoryHint: .notDirectory)
        try? FileManager.default.removeItem(at: partial)

        let reader: AVAssetReader
        let writer: AVAssetWriter
        let video: Pump
        var audio: Pump?
        do {
            reader = try AVAssetReader(asset: movie.asset)
            writer = try AVAssetWriter(outputURL: partial, fileType: .mp4)
        } catch {
            throw .destinationUnwritable(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true
        // The writer's own scratch files go to the system temp directory, never beside the
        // destination, which may be inside a take.
        writer.directoryForTemporaryFiles = FileManager.default.temporaryDirectory

        let tracks = movie.asset.tracks
        guard let screenTrack = tracks.first(where: { $0.trackID == movie.screenTrackID }) else {
            throw .readerFailed("the composition lost its screen track")
        }
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [screenTrack], videoSettings: nil)
        videoOutput.videoComposition = movie.videoComposition(scene: scene, frameRate: format.frameRate)
        videoOutput.alwaysCopiesSampleData = false
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: format.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: canvas.width,
            AVVideoHeightKey: canvas.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: format.bitRate(for: canvas)],
        ])
        guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else {
            throw .writerFailed("the writer rejected \(canvas.width)x\(canvas.height) \(format.codec)")
        }
        reader.add(videoOutput)
        writer.add(videoInput)
        let framesTotal = Int((Double(movie.duration.seconds) * Double(format.frameRate.rawValue)).rounded(.up))
        video = Pump(output: videoOutput, input: videoInput, label: "video") { frames in
            progress(ExportProgress(framesWritten: frames, framesTotal: framesTotal))
        }

        if let audioTrack = tracks.first(where: { $0.trackID == movie.audioTrackID }) {
            // Decoded to LPCM and re-encoded, which trims the microphone exactly at the video's end
            // without AAC priming or packet-boundary errors.
            let channels = audioTrack.formatDescriptions
                .compactMap { ($0 as! CMFormatDescription).audioStreamBasicDescription?.mChannelsPerFrame }
                .first.map(Int.init) ?? 1
            let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 128_000,
            ])
            if reader.canAdd(audioOutput), writer.canAdd(audioInput) {
                reader.add(audioOutput)
                writer.add(audioInput)
                audio = Pump(output: audioOutput, input: audioInput, label: "audio") { _ in }
            }
        }

        let started = DispatchTime.now().uptimeNanoseconds
        guard reader.startReading() else {
            throw .readerFailed(reader.error?.localizedDescription ?? "could not start reading")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw .writerFailed(writer.error?.localizedDescription ?? "could not start writing")
        }
        writer.startSession(atSourceTime: .zero)

        let stop = Stop()
        let pumps = [video] + (audio.map { [$0] } ?? [])
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                for pump in pumps {
                    group.addTask { await pump.run(until: stop) }
                }
            }
        } onCancel: {
            stop.cancel()
        }

        if stop.isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: partial)
            throw .cancelled
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: partial)
            throw .readerFailed(reader.error?.localizedDescription ?? "reader failed")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: partial)
            throw .writerFailed(writer.error?.localizedDescription ?? "writer failed with status \(writer.status.rawValue)")
        }
        let wall = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9

        // rename(2) replaces an existing destination atomically, so a reader never sees a torn file.
        guard rename(partial.path, destination.path) == 0 else {
            let message = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: partial)
            throw .destinationUnwritable("\(destination.path): \(message)")
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        return ExportReport(
            destination: destination, frames: video.count, duration: RecordingTime(movie.duration), wallSeconds: wall,
            bytes: bytes, warnings: movie.warnings + scene.assets.warnings)
    }

    /// Shared cancellation flag between the task that owns the export and the pumps on their
    /// dispatch queues, which cannot see `Task.isCancelled`.
    private final class Stop: Sendable {
        private let flag = Mutex(false)
        var isCancelled: Bool { flag.withLock { $0 } }
        func cancel() { flag.withLock { $0 = true } }
    }

    /// Moves every sample from one reader output into one writer input. The composition yields
    /// exactly one video sample per frame duration (measured: 600 for 10 s at 60), so there is no
    /// drop or duplicate logic here: the variable-to-constant conversion already happened.
    ///
    /// `@unchecked` because the reader output and writer input are not marked Sendable; each pump
    /// is the only user of its pair, on its own queue.
    private final class Pump: @unchecked Sendable {
        private let output: AVAssetReaderOutput
        private let input: AVAssetWriterInput
        private let queue: DispatchQueue
        private let onSample: @Sendable (Int) -> Void
        private let written = Mutex(0)

        init(output: AVAssetReaderOutput, input: AVAssetWriterInput, label: String, onSample: @escaping @Sendable (Int) -> Void) {
            self.output = output
            self.input = input
            self.onSample = onSample
            queue = DispatchQueue(label: "open-studio.export.\(label)")
        }

        var count: Int { written.withLock { $0 } }

        func run(until stop: Stop) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let finished = Mutex(false)
                let finish = { [input] in
                    guard finished.withLock({ let was = $0; $0 = true; return !was }) else { return }
                    input.markAsFinished()
                    continuation.resume()
                }
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    while input.isReadyForMoreMediaData {
                        if stop.isCancelled { return finish() }
                        guard let sample = output.copyNextSampleBuffer() else { return finish() }
                        guard input.append(sample) else {
                            // The writer records its error; the outer check reports it.
                            stop.cancel()
                            return finish()
                        }
                        onSample(written.withLock { $0 += 1; return $0 })
                    }
                }
            }
        }
    }
}

extension OutputFormat {
    /// About 0.08 bits per pixel per frame for HEVC and 0.12 for H.264: 10 and 15 Mbps at 1080p60,
    /// 40 and 60 Mbps at 4K60. Screen content is mostly static, so the encoder rarely needs it all.
    func bitRate(for canvas: PixelSize) -> Int {
        let bitsPerPixel = codec == .hevc ? 0.08 : 0.12
        return Int(Double(canvas.width * canvas.height * frameRate.rawValue) * bitsPerPixel)
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
    /// Things that degraded the output without failing it: a microphone that would not load, a
    /// cursor PNG that fell back to the arrow.
    public let warnings: [String]
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
