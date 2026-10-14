import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Synchronization
import Timeline

/// Carries one immutable `RenderScene` into the compositor. AVFoundation hands the same object
/// back on every request (`request.videoCompositionInstruction`), which is the only data channel
/// into a compositor it instantiates itself. Verified in the spike: the instruction's stored
/// scene reached all 600 requests.
///
/// `@unchecked` only because NSObject is not Sendable; every stored property is immutable.
final class SceneInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
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
final class StyledCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    /// Requests rendered concurrently. CIContext is thread-safe. Measured on a 4K60 export: 1 in
    /// flight 92 fps, 2 in flight 101 fps, 4 in flight 97 fps with the writer attached (the writer
    /// side caps it); 4 in flight without a writer 142 fps.
    static let maxInFlight = 2

    private struct State {
        var renderContext: AVVideoCompositionRenderContext?
        var generation = 0
    }

    private let state = Mutex(State())
    /// Requests wait for a slot here, one at a time, so a seek storm never parks a thread per
    /// queued request on the concurrent queue.
    private let gate = DispatchQueue(label: "open-studio.render.gate", qos: .userInitiated)
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
        let (context, generation) = state.withLock { ($0.renderContext, $0.generation) }
        let pending = Pending(request: request, context: context, generation: generation)
        gate.async { [self] in
            slots.wait()
            work.async { [self] in
                defer { slots.signal() }
                render(pending)
            }
        }
    }

    /// Called on seeks. Requests already queued see a newer generation and finish as cancelled,
    /// so scrubbing never waits behind frames nobody will show.
    func cancelAllPendingVideoCompositionRequests() {
        state.withLock { $0.generation += 1 }
    }

    private func render(_ pending: Pending) {
        let request = pending.request
        // Checked just before rendering, not only when dequeued, so a request already in flight
        // when a seek lands finishes as cancelled instead of rendering a frame nobody will see.
        guard state.withLock({ $0.generation }) == pending.generation else {
            request.finishCancelledRequest()
            return
        }
        // Composition time equals recording time in v1; a trim would add its map here and only here.
        let t = RecordingTime(request.compositionTime)
        guard let instruction = request.videoCompositionInstruction as? SceneInstruction,
            let source = request.sourceFrame(byTrackID: instruction.screenTrackID),
            let context = pending.context, let output = context.newPixelBuffer()
        else {
            request.finish(with: RenderError.missingSourceFrame(t))
            return
        }
        let scene = instruction.scene
        let image = scene.image(source: CIImage(cvPixelBuffer: source), at: t)
        let bounds = CGRect(x: 0, y: 0, width: scene.layout.canvas.width, height: scene.layout.canvas.height)
        RenderDevice.context.render(image, to: output, bounds: bounds, colorSpace: RenderDevice.outputColorSpace)
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        request.finish(withComposedVideoFrame: output)
    }

    /// `@unchecked` because AVFoundation's request and render context are not marked Sendable; each
    /// request is handed to exactly one render closure.
    private struct Pending: @unchecked Sendable {
        let request: AVAsynchronousVideoCompositionRequest
        let context: AVVideoCompositionRenderContext?
        let generation: Int
    }
}

extension RecordingTime {
    /// The one CMTime bridge. Rounds to the nearest microsecond, the Timeline's resolution.
    init(_ time: CMTime) {
        self = .seconds(time.seconds)
    }

    var cmTime: CMTime { CMTime(value: microseconds, timescale: 1_000_000) }
}
