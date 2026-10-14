import AVFoundation
import CoreImage
import Foundation
import Synchronization
import Timeline

/// Carries one immutable `RenderScene` into the compositor. AVFoundation hands the same object
/// back on every request (`request.videoCompositionInstruction`), which is the only data channel
/// into a compositor it instantiates itself. Verified in the spike: the instruction's stored
/// scene reached all 600 requests.
final class SceneInstruction: NSObject, AVVideoCompositionInstructionProtocol, Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    /// Every frame changes (camera, cursor), so AVFoundation must never reuse a previous output.
    let containsTweening = true
    var requiredSourceTrackIDs: [NSValue]? { [NSNumber(value: screenTrackID)] }
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let screenTrackID: CMPersistentTrackID
    let scene: RenderScene

    init(timeRange: CMTimeRange, screenTrackID: CMPersistentTrackID, scene: RenderScene) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.scene = scene
    }
}

/// The one compositor. AVPlayer, AVAssetReader, and AVAssetImageGenerator all instantiate it from
/// the same `AVVideoComposition`, so preview, export, and stills run the same drawing code.
///
/// Holds no per-frame state. Its only mutable state is the render context AVFoundation assigns and
/// a cancellation generation, both behind one Mutex.
final class StyledCompositor: NSObject, AVVideoCompositing, Sendable {
    /// Requests rendered concurrently. CIContext is thread-safe. Measured on a 4K60 export: 1 in
    /// flight 92 fps, 2 in flight 101 fps, 4 in flight 97 fps with the writer attached (the writer
    /// side caps it); 4 in flight without a writer 142 fps.
    static let maxInFlight = 2

    private struct State {
        var renderContext: AVVideoCompositionRenderContext?
        var generation = 0
    }

    private let state = Mutex(State())
    private let work = DispatchQueue(label: "open-studio.render", qos: .userInitiated, attributes: .concurrent)
    private let slots = DispatchSemaphore(value: StyledCompositor.maxInFlight)

    /// Decoder-native 4:2:0, so the decode side never converts; Core Image reads the YCbCr matrix
    /// from the buffer's attachments.
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        state.withLock { $0.renderContext = newRenderContext }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        // TODO (request handling):
        //   (context, generation) = state.withLock { ($0.renderContext, $0.generation) }
        //   work.async {
        //     slots.wait(); defer { slots.signal() }
        //     if state.withLock({ $0.generation }) != generation { request.finishCancelledRequest(); return }
        //     guard let instruction = request.videoCompositionInstruction as? SceneInstruction,
        //           let source = request.sourceFrame(byTrackID: instruction.screenTrackID),
        //           let context, let output = context.newPixelBuffer()
        //     else { request.finish(with: RenderError.missingSourceFrame(t)); return }
        //     t = RecordingTime(request.compositionTime)   // composition time == recording time in v1;
        //                                                  // trims add their map here and only here
        //     image = instruction.scene.image(source: CIImage(cvPixelBuffer: source), at: t)
        //     RenderDevice.context.render(image, to: output, bounds: canvas rect,
        //                                 colorSpace: RenderDevice.outputColorSpace)
        //     request.finish(withComposedVideoFrame: output)
        //   }
        // The semaphore waits on the work queue, never on AVFoundation's calling thread, so a seek
        // storm queues work instead of blocking the player.
        fatalError("not implemented")
    }

    /// Called on seeks. Requests already queued see a newer generation and finish as cancelled,
    /// so scrubbing never waits behind frames nobody will show.
    func cancelAllPendingVideoCompositionRequests() {
        state.withLock { $0.generation += 1 }
    }
}

extension RecordingTime {
    /// The one CMTime bridge. Rounds to the nearest microsecond, the Timeline's resolution.
    init(_ time: CMTime) {
        self = .seconds(time.seconds)
    }
}
