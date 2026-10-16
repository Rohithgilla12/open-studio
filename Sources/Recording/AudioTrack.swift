import AVFoundation
import CoreMedia
import Foundation

/// How far an audio movie has got on the host clock, and the silence a buffer needs in front of it.
///
/// `AVAssetWriter` packs audio samples back to back and ignores a gap between their timestamps
/// (measured: a second with no buffers vanished, and the audio after it played a second early). So
/// a source that skips time has to be given that time as silence, or everything after the gap
/// drifts out of sync with the screen.
struct AudioContinuity: Sendable, Equatable {
    /// Just after the last sample written. nil before the first, which the writer places at its own
    /// time with an empty edit.
    private(set) var writtenThrough: HostTime?

    /// About one 1024-frame buffer at 48 kHz. Timestamp jitter below it is not a gap.
    static let tolerance: Duration = .milliseconds(20)

    func silence(before pts: HostTime) -> Duration {
        guard let writtenThrough, pts > writtenThrough else { return .zero }
        let gap = pts.duration(since: writtenThrough)
        return gap > Self.tolerance ? gap : .zero
    }

    /// Records samples written at the end of the movie. `pts` places only the first of them.
    mutating func wrote(_ duration: Duration, at pts: HostTime) {
        writtenThrough = (writtenThrough ?? pts) + duration
    }
}

/// An audio movie whose media time 0 is the origin, kept in step with the host clock, and removed
/// at the end if no sample ever arrived.
final class AudioTrackWriter {
    private let writer: MovieWriter
    private var origin: HostTime?
    private(set) var continuity = AudioContinuity()

    init(url: URL, channels: Int) throws(RecordingError) {
        writer = try MovieWriter(url: url, kind: .audio(channels: channels))
    }

    func start(at origin: HostTime) throws(RecordingError) {
        try writer.startSession(at: origin)
        self.origin = origin
    }

    /// Whether the buffer was written. False for a buffer before the origin, or while the encoder is
    /// busy; the next buffer then gets the time it missed as silence.
    func append(_ buffer: CMSampleBuffer) throws(RecordingError) -> Bool {
        let pts = HostTime(CMSampleBufferGetPresentationTimeStamp(buffer))
        guard let origin, pts >= origin, let format = AudioFormat(buffer) else { return false }
        var gap = continuity.silence(before: pts)
        while gap > .zero {
            let frames = min(format.frames(in: gap), Int(format.sampleRate))
            guard frames > 0, let silence = format.silence(frames: frames, at: continuity.writtenThrough ?? pts),
                try writer.append(silence)
            else { break }
            let written = format.duration(of: frames)
            continuity.wrote(written, at: pts)
            gap -= written
        }
        guard try writer.append(buffer) else { return false }
        continuity.wrote(format.duration(of: CMSampleBufferGetNumSamples(buffer)), at: pts)
        return true
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
    /// No sample ever arrived, so the movie was removed: a movie with no samples does not open, and
    /// the take should not name a source it does not have.
    case removedEmpty
}

/// The linear PCM layout of a buffer, enough to make silence in the same layout.
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

    /// Zero samples, which is silence for both integer and float PCM.
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
