import AVFoundation
import Timeline

/// The instruction AVFoundation hands back with every request. It carries the whole plan, so a request
/// is self-describing: no global, no lookup, no lock. One instruction spans the whole composition.
final class PlanInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let plan: RenderPlan
    let screenTrackID: CMPersistentTrackID

    // AVVideoCompositionInstructionProtocol
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    /// Every frame differs (camera and cursor move), so AVFoundation must not cache or reuse a frame.
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    init(plan: RenderPlan, screenTrackID: CMPersistentTrackID, timeRange: CMTimeRange) { fatalError("not implemented") }
}

/// Created by AVFoundation, never by us. `startRequest` is called on AVFoundation's threads, ahead of
/// playback and out of order while scrubbing, so it must be pure and fast: no stored state besides the
/// shared renderer.
final class StudioCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    /// 420v: AVFoundation hands over the decoder's native format, with no conversion pass before ours.
    let sourcePixelBufferAttributes: [String: any Sendable]? = [:]  // TODO 420v, IOSurface, Metal compatible
    /// BGRA8, IOSurface, Metal compatible.
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [:]  // TODO

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        // Nothing to do: the canvas is read from each request's render context.
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        // TODO
        //  guard let instruction = request.videoCompositionInstruction as? PlanInstruction
        //      else { request.finish(with: RenderError.sourceUnreadable("foreign instruction")); return }
        //  guard let source = request.sourceFrame(byTrackID: instruction.screenTrackID),
        //        let target = request.renderContext.newPixelBuffer() else { fail }
        //  let plan = instruction.plan
        //  let t = plan.recordingTime(for: request.compositionTime)
        //  let canvas = PixelSize(request.renderContext.size)   // preview and export differ only here
        //  let layout = plan.layout(at: t, canvas: canvas)
        //  renderer.draw(layout, sprites: plan.sprites, source: source, into: target) { result in
        //      switch result {
        //      case .success: request.finish(withComposedVideoFrame: target)
        //      case .failure(let e): request.finish(with: e)
        //      }
        //  }
        // VFR to CFR: `sourceFrame(byTrackID:)` is the source frame in effect at compositionTime, so a
        // 1/60 s frameDuration on the AVVideoComposition resamples the variable-rate screen.mov for free.
        // Gated by the first test (rationale, "Next implementation step").
        fatalError("not implemented")
    }

    func cancelAllPendingVideoCompositionRequests() {
        // Metal work already committed finishes and its completion calls request.finish, which
        // AVFoundation tolerates after cancellation. TODO verify: if not, keep a cancelled-generation flag.
    }
}
