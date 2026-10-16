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
            .appending(path: ".\(destination.lastPathComponent).partial.mp4", directoryHint: .notDirectory)
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

        let videoTracks = movie.videoTracks(for: scene)
        guard videoTracks.contains(where: { $0.trackID == movie.screenTrackID }) else {
            throw .readerFailed("the composition lost its screen track")
        }
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: nil)
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

        let audioTracks = movie.audibleTracks(project.edits.audio)
        if !audioTracks.isEmpty {
            // Decoded to LPCM and re-encoded, which trims the audio exactly at the video's end without
            // AAC priming or packet-boundary errors.
            let channels = mixedChannelCount(of: audioTracks)
            let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            audioOutput.audioMix = movie.audioMix(project.edits.audio)
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

        // A callback still running on a pump's queue may be inside the reader; cancelling the
        // reader under it traps. Draining the queues first lets it finish, and any later callback
        // sees the stop flag and returns before touching the reader.
        for pump in pumps { pump.drain() }

        // A failed append stops the pumps too, so the writer's own error is checked first.
        if writer.status == .failed {
            reader.cancelReading()
            try? FileManager.default.removeItem(at: partial)
            throw .writerFailed(writer.error?.localizedDescription ?? "writer failed")
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: partial)
            throw .readerFailed(reader.error?.localizedDescription ?? "reader failed")
        }
        if stop.isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: partial)
            throw .cancelled
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

    /// Stereo as soon as one source is, so a take without system audio keeps its microphone's channels.
    private static func mixedChannelCount(of tracks: [AVAssetTrack]) -> Int {
        let channels = tracks.flatMap(\.formatDescriptions)
            .compactMap { ($0 as! CMFormatDescription).audioStreamBasicDescription?.mChannelsPerFrame }
        return channels.max().map { min(Int($0), 2) } ?? 1
    }

    /// Shared stop signal between the task that owns the export and the pumps on their dispatch
    /// queues, which cannot see `Task.isCancelled`. Stopping also releases every pump that is
    /// waiting for its input to become ready again, which a failed writer never does.
    private final class Stop: Sendable {
        private let state = Mutex<(stopped: Bool, release: [@Sendable () -> Void])>((false, []))

        var isCancelled: Bool { state.withLock { $0.stopped } }

        func onStop(_ release: @escaping @Sendable () -> Void) {
            let stopped = state.withLock { state in
                if !state.stopped { state.release.append(release) }
                return state.stopped
            }
            if stopped { release() }
        }

        func cancel() {
            let release = state.withLock { state in
                state.stopped = true
                defer { state.release = [] }
                return state.release
            }
            for pump in release { pump() }
        }
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

        /// Returns once no callback is executing on this pump's queue.
        func drain() { queue.sync {} }

        func run(until stop: Stop) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumed = Mutex(false)
                let resume: @Sendable () -> Void = {
                    guard resumed.withLock({ let was = $0; $0 = true; return !was }) else { return }
                    continuation.resume()
                }
                // A stop resumes without marking the input finished; the owner cancels the writer.
                stop.onStop(resume)
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    while input.isReadyForMoreMediaData {
                        if stop.isCancelled { return resume() }
                        guard let sample = output.copyNextSampleBuffer() else {
                            input.markAsFinished()
                            return resume()
                        }
                        guard input.append(sample) else {
                            // The writer holds the error; the owner reports it after the pumps stop.
                            stop.cancel()
                            return resume()
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
