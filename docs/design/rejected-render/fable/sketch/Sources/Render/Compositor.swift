import AVFoundation
import CoreVideo
import Timeline

/// The single instruction spanning the whole asset. AVFoundation hands it back on every request,
/// which is how the plan (and the live box) reaches the compositor that AVFoundation instantiated.
final class RenderInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    /// False: every output frame is drawn, even when the source frame has not changed, because the
    /// cursor and camera move between source frames. With true AVFoundation would reuse frames.
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let plan: PlanBox
    let screenTrackID: CMPersistentTrackID

    init(plan: PlanBox, screenTrackID: CMPersistentTrackID, duration: CMTime) { fatalError("not implemented") }
}

/// Created by AVFoundation (`customVideoCompositorClass`), once per player item or reader output.
/// It owns nothing per take: the renderer is process-wide and the plan rides on the instruction.
///
/// `startRequest` is called on AVFoundation's threads, ahead of playback, out of order while
/// scrubbing, possibly concurrently. Every input it reads is immutable or read once (the box), and
/// `FrameRenderer.draw` is pure, so order and concurrency cannot change a pixel.
final class FrameCompositor: NSObject, AVVideoCompositing {
    private let renderer = FrameRenderer.shared
    private let renderContext = Mutex<AVVideoCompositionRenderContext?>(nil)

    var sourcePixelBufferAttributes: [String: any Sendable]? { FrameRenderer.sourcePixelBufferAttributes }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { FrameRenderer.outputPixelBufferAttributes }
    let supportsWideColorSourceFrames = false
    let supportsHDRSourceFrames = false

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        // Store it: its pixel buffer pool is the only source of output buffers.
        fatalError("not implemented")
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        // TODO (synchronous; AVFoundation pipelines around us):
        //   guard instruction = request.videoCompositionInstruction as? RenderInstruction
        //     else { request.finish(with: CompositorError.unexpectedInstruction); return }
        //   plan = instruction.plan.current                       // read once
        //   t = RecordingTime(request.compositionTime)             // TimeBridge
        //   frame = plan.timeline.frame(at: t)
        //   source = request.sourceFrame(byTrackID: instruction.screenTrackID)   // nil in a gap
        //   guard output = renderContext.newPixelBuffer() else { finish(with: .noOutputBuffer) }
        //   renderer.draw(source: source, frame: frame, plan: plan, into: output)
        //   request.finish(withComposedVideoFrame: output)
        fatalError("not implemented")
    }

    /// Nothing is pending: each request completes inside `startRequest`.
    func cancelAllPendingVideoCompositionRequests() {}
}

enum CompositorError: Error {
    case unexpectedInstruction
    case noOutputBuffer
}

/// `AVVideoComposition` for one plan: render size and frame rate from the plan, one instruction.
///
/// `frameDuration` is what turns the variable-rate source into constant-rate output. AVFoundation
/// asks for a frame at every tick and supplies the source sample in effect at that time, for both
/// AVPlayer and AVAssetReaderVideoCompositionOutput. No frame-stepping loop exists in Render.
enum RenderComposition {
    static func make(plan: PlanBox, asset: SourceAsset, frameRate: FrameRate) -> AVVideoComposition {
        // TODO: AVMutableVideoComposition(); customVideoCompositorClass = FrameCompositor.self;
        // renderSize = plan.current.output; frameDuration = CMTime(1, frameRate); instructions = [one]
        fatalError("not implemented")
    }
}
