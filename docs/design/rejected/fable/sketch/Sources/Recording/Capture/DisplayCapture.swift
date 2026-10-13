@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import RecordingFormat
@preconcurrency import ScreenCaptureKit

/// SCStream for one display (cursor hidden, optional microphone output) feeding a
/// fragmented QuickTime writer. Screen and microphone come from the same stream so they
/// share the host clock without any resampling on our side.
final class DisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct FirstFrame: Sendable, Equatable {
        var offset: Int64
        var pts: RationalTime
    }

    private let stream: SCStream
    private let writer: MovieWriter
    private let clock: HostClock
    private let onFirstFrame: @Sendable (FirstFrame) -> Void
    private let onFailure: @Sendable (RecordingError) -> Void
    private let onDroppedFrames: @Sendable (Int) -> Void

    /// `SCStreamConfiguration`: showsCursor = false, width/height = display pixels,
    /// minimumFrameInterval = 1/frameRate, pixelFormat = 420v (BGRA costs 2x bandwidth
    /// for no gain since we encode immediately), capturesAudio = false,
    /// captureMicrophone = (microphone != .none), microphoneCaptureDeviceID.
    init(
        display: SCDisplay,
        config: RecordingConfig,
        clock: HostClock,
        writer: MovieWriter,
        onFirstFrame: @escaping @Sendable (FirstFrame) -> Void,
        onDroppedFrames: @escaping @Sendable (Int) -> Void,
        onFailure: @escaping @Sendable (RecordingError) -> Void
    ) {
        fatalError("not implemented")
    }

    func start() async throws {
        fatalError("not implemented")
    }

    /// Stops the stream then finishes the writer. Returns frame counts for `finish.json`.
    func stop() async throws -> (videoFrames: Int, droppedFrames: Int) {
        fatalError("not implemented")
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // TODO:
        // .screen: skip if SCStreamFrameInfo.status != .complete (idle/blank frames carry no pixels)
        //          on first complete frame: writer.startSession(at: pts); onFirstFrame(offset, pts)
        //          writer.appendVideo(sampleBuffer)
        // .microphone: writer.appendAudio(sampleBuffer)   (ignored until session started)
        fatalError("not implemented")
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        fatalError("not implemented")
    }
}

/// AVAssetWriter wrapper. One file, `display.mov`, video track plus optional audio track,
/// `movieFragmentInterval` set so the file is playable up to the last fragment if the
/// process dies before `finishWriting`.
final class MovieWriter: @unchecked Sendable {
    init(url: URL, video: VideoDescriptor, audio: AudioDescriptor?, fragmentInterval: Duration) throws {
        // TODO: AVAssetWriter(outputURL:, fileType: .mov)
        //       movieFragmentInterval = CMTime(fragmentInterval)
        //       video input: codec hevc|h264, expectsMediaDataInRealTime = true
        //       audio input: AAC 48 kHz, expectsMediaDataInRealTime = true
        fatalError("not implemented")
    }

    func startSession(at pts: CMTime) {
        fatalError("not implemented")
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        // TODO: if !input.isReadyForMoreMediaData { droppedFrames += 1; return }
        fatalError("not implemented")
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        fatalError("not implemented")
    }

    func finish() async throws -> (videoFrames: Int, droppedFrames: Int) {
        fatalError("not implemented")
    }
}
