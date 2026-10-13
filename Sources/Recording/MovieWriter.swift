import AVFoundation
import CoreMedia
import Foundation

/// One `AVAssetWriter` writing a fragmented QuickTime movie.
///
/// `movieFragmentInterval` = 1 s is the whole media crash-safety story: an interrupted fragmented
/// movie opens and plays up to its last complete fragment (measured in `Experiments/README.md`).
///
/// Uses the classic `AVAssetWriterInput` path on purpose. The macOS 27 SDK deprecates
/// `expectsMediaDataInRealTime`, `isReadyForMoreMediaData`, and `append(_:)` for Swift in favour of
/// an input receiver that exists only on macOS 27. With a macOS 15 deployment target the classic
/// path is the only one available on every supported OS, the deprecation does not fire, and an
/// availability branch would double the writer for no behavioural gain. Revisit when the target
/// moves to 27. ScreenCaptureKit hands over timed `CMSampleBuffer`s, so no pixel buffer adaptor
/// is involved either way.
///
/// Not Sendable on purpose: it lives inside `CaptureSink` and is touched only on its queue.
final class MovieWriter {
    enum Kind {
        /// Keyframe interval 2 × frame rate, constant quality 0.85.
        case screen(codec: VideoCodec, pixelSize: CGSize, frameRate: Int)
        /// AAC at 48 kHz.
        case microphone(channels: Int)
    }

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private(set) var samplesWritten = 0

    init(url: URL, kind: Kind) throws(RecordingError) {
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw .captureFailedToStart("cannot create \(url.lastPathComponent): \(error.localizedDescription)")
        }
        writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)
        let (mediaType, settings) = kind.outputSettings
        guard writer.canApply(outputSettings: settings, forMediaType: mediaType) else {
            throw .captureFailedToStart("\(url.lastPathComponent): unsupported output settings \(settings)")
        }
        input = AVAssetWriterInput(mediaType: mediaType, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)
    }

    func startSession(at origin: HostTime) throws(RecordingError) {
        guard writer.startWriting() else { throw .captureFailedToStart(failureDescription) }
        writer.startSession(atSourceTime: origin.cmTime)
    }

    /// False when the input is busy: a real-time source drops the sample rather than queueing.
    func append(_ buffer: CMSampleBuffer) throws(RecordingError) -> Bool {
        guard input.isReadyForMoreMediaData else { return false }
        guard input.append(buffer) else { throw .captureFailedToStart(failureDescription) }
        samplesWritten += 1
        return true
    }

    /// Ends the session at `end`, so a static final screen still lasts to the end of the take.
    func finish(at end: HostTime) async throws(RecordingError) {
        guard writer.status == .writing else { throw .captureFailedToStart(failureDescription) }
        writer.endSession(atSourceTime: end.cmTime)
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw .captureFailedToStart(failureDescription) }
    }

    private var failureDescription: String {
        "\(writer.outputURL.lastPathComponent): \(writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)")"
    }
}

extension MovieWriter.Kind {
    var outputSettings: (AVMediaType, [String: Any]) {
        switch self {
        case .screen(let codec, let pixelSize, let frameRate):
            let codecType: AVVideoCodecType = switch codec {
            case .hevc: .hevc
            case .h264: .h264
            }
            return (.video, [
                AVVideoCodecKey: codecType,
                AVVideoWidthKey: Int(pixelSize.width),
                AVVideoHeightKey: Int(pixelSize.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
                    AVVideoQualityKey: 0.85,
                ],
            ])
        case .microphone(let channels):
            return (.audio, [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 96_000 * channels,
            ])
        }
    }
}
