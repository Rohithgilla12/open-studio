import AVFoundation
import CoreMedia
import Foundation

/// `AVAssetWriter` packs audio samples back to back and ignores a gap between their timestamps
/// (measured: a second with no buffers vanished, and the audio after it played a second early). So
/// a source that skips time has to be given that time as silence, or everything after the gap
/// drifts out of sync with the screen.
struct AudioContinuity: Sendable, Equatable {
    /// nil before the first sample, which `AVAssetWriter` places at its own time with an empty edit.
    private(set) var writtenThrough: HostTime?

    static let tolerance: Duration = .nanoseconds(1024 * 1_000_000_000 / 48_000)

    func silence(before pts: HostTime) -> Duration {
        guard let writtenThrough, pts > writtenThrough else { return .zero }
        let gap = pts.duration(since: writtenThrough)
        return gap > Self.tolerance ? gap : .zero
    }

    mutating func wrote(_ duration: Duration, at pts: HostTime) {
        writtenThrough = (writtenThrough ?? pts) + duration
    }
}

final class AudioTrackWriter {
    private let writer: MovieWriter
    private var origin: HostTime?
    private(set) var continuity = AudioContinuity()
    private static let longestSilence: Duration = .seconds(1)

    init(url: URL, channels: Int) throws(RecordingError) {
        writer = try MovieWriter(url: url, kind: .audio(channels: channels))
    }

    func start(at origin: HostTime) throws(RecordingError) {
        try writer.startSession(at: origin)
        self.origin = origin
    }

    func append(_ buffer: CMSampleBuffer) throws(RecordingError) -> Bool {
        let pts = HostTime(CMSampleBufferGetPresentationTimeStamp(buffer))
        guard let origin, pts >= origin else { return false }
        let format = AudioFormat(buffer)
        if let format { try fill(continuity.silence(before: pts), like: format, at: pts) }
        guard try writer.append(buffer) else { return false }
        continuity.wrote(format?.duration(of: CMSampleBufferGetNumSamples(buffer)) ?? .zero, at: pts)
        return true
    }

    private func fill(_ gap: Duration, like format: AudioFormat, at pts: HostTime) throws(RecordingError) {
        var remaining = gap
        while remaining > .zero {
            let frames = format.frames(in: min(remaining, Self.longestSilence))
            guard frames > 0, let silence = format.silence(frames: frames, at: continuity.writtenThrough ?? pts),
                try writer.append(silence)
            else { return }
            let written = format.duration(of: frames)
            continuity.wrote(written, at: pts)
            remaining -= written
        }
    }

    func finish(at end: HostTime) async throws(RecordingError) -> TrackOutcome {
        guard continuity.writtenThrough != nil else {
            writer.cancel()
            return .removedEmpty
        }
        try await writer.finish(at: end)
        return .recorded
    }
}

enum TrackOutcome: Sendable, Equatable {
    case recorded
    /// A movie with no samples does not open.
    case removedEmpty
}

struct AudioFormat {
    let description: CMAudioFormatDescription
    let sampleRate: Double
    let bytesPerFrame: Int
    let planes: Int

    init?(_ buffer: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(buffer),
            let asbd = description.audioStreamBasicDescription, asbd.mSampleRate > 0
        else { return nil }
        self.description = description
        sampleRate = asbd.mSampleRate
        bytesPerFrame = Int(asbd.mBytesPerFrame)
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        planes = nonInterleaved ? Int(asbd.mChannelsPerFrame) : 1
        guard asbd.mFormatID == kAudioFormatLinearPCM, bytesPerFrame > 0 else { return nil }
    }

    func frames(in duration: Duration) -> Int { Int((duration.seconds * sampleRate).rounded()) }

    func duration(of frames: Int) -> Duration { .nanoseconds(Int64((Double(frames) / sampleRate * 1e9).rounded())) }

    func silence(frames: Int, at pts: HostTime) -> CMSampleBuffer? {
        let length = frames * bytesPerFrame * planes
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
            let block, CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) == noErr
        else { return nil }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: description, sampleCount: frames,
            presentationTimeStamp: pts.cmTime, packetDescriptions: nil, sampleBufferOut: &sample) == noErr
        else { return nil }
        return sample
    }
}
