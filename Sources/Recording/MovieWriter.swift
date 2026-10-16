import AVFoundation
import CoreMedia
import Foundation

/// `movieFragmentInterval` = 1 s is the whole media crash-safety story: an interrupted fragmented
/// movie opens and plays up to its last complete fragment (measured in `Experiments/README.md`).
/// Uses the `AVAssetWriterInput` path that the macOS 27 SDK deprecates for Swift, because its
/// replacement (input receivers) exists only on macOS 27 and the deployment target is 15. See
/// the D3 section of docs/design/accepted/rationale.md.
final class MovieWriter {
    enum Kind {
        case video(codec: VideoCodec, pixelSize: CGSize, frameRate: Int)
        case audio(channels: Int)
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

    func append(_ buffer: CMSampleBuffer) throws(RecordingError) -> Bool {
        guard input.isReadyForMoreMediaData else { return false }
        guard input.append(buffer) else { throw .captureFailedToStart(failureDescription) }
        samplesWritten += 1
        return true
    }

    func finish(at end: HostTime) async throws(RecordingError) {
        guard writer.status == .writing else { throw .captureFailedToStart(failureDescription) }
        writer.endSession(atSourceTime: end.cmTime)
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw .captureFailedToStart(failureDescription) }
    }

    /// Abandons the movie and removes its file.
    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: writer.outputURL)
    }

    private var failureDescription: String {
        "\(writer.outputURL.lastPathComponent): \(writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)")"
    }
}

extension MovieWriter.Kind {
    var outputSettings: (AVMediaType, [String: Any]) {
        switch self {
        case .video(let codec, let pixelSize, let frameRate):
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
        case .audio(let channels):
            return (.audio, [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 96_000 * channels,
            ])
        }
    }
}
