import CoreImage
import CoreVideo
import Metal
import Synchronization
import Timeline

/// Draws one styled frame with Core Image on a Metal-backed context.
///
/// One instance per process (`shared`): a `CIContext` is expensive to create, thread-safe, and
/// owns the Metal device. Per-plan data arrives through `RenderPlan`, never through this object.
///
/// Colour: the context works and outputs in sRGB. Source frames are BT.709 from ScreenCaptureKit
/// (same primaries as sRGB, near-identical transfer), so screen content passes through
/// untouched. Output buffers are 32BGRA tagged BT.709 primaries/transfer/matrix, in both preview
/// and export, so AVPlayer's display path and the encoder's YUV conversion see the same tags and
/// produce the same picture.
///
/// GPU path: Core Image, not raw Metal. The graph (crop, scale, rounded mask, composite, cursor) is
/// built-in filters that CI concatenates into one or two Metal passes, and the one expensive op, the
/// shadow blur, is in the cached backdrop. The spike measured the whole graph at native 4K faster
/// than real time (numbers in the rationale), so a hand-written Metal pipeline buys nothing yet.
final class FrameRenderer: Sendable {
    static let shared = FrameRenderer()

    private let context: CIContext
    private let device: any MTLDevice
    /// Backdrop (background + shadow) per (style, output size), rendered once into a pixel buffer.
    /// A cache of a pure function; holds at most two entries so an edit that changes the style
    /// keeps the previous backdrop alive only until the next one.
    private let backdrops: Mutex<[BackdropKey: CIImage]>

    private init() { fatalError("not implemented") }

    /// Pure in (source, frame, plan): draws into `output`, which must be `plan.output` sized BGRA.
    /// `source` nil (no sample at this time, which the recorder's heartbeat makes rare) draws the
    /// backdrop with an empty content rect rather than failing the frame.
    func draw(source: CVPixelBuffer?, frame: FrameState, plan: RenderPlan, into output: CVPixelBuffer) {
        // TODO:
        //   backdrop = self.backdrop(for: plan)                           // cached
        //   if let source:
        //     crop = CoreImageSpace.rect(frame.camera.viewport, height: sourceHeight)
        //     xf = ViewportTransform(viewport:contentRect:).affine ∘ flips (source y-up -> output y-up)
        //     content = CIImage(cvPixelBuffer: source).cropped(to: crop).transformed(by: xf)
        //     image = blendWithMask(content over backdrop, mask: roundedRect(plan.layout))
        //   else image = backdrop
        //   if frame.cursor.isVisible:
        //     info = plan.cursors.info(frame.cursor.image); png = plan.cursors.image(frame.cursor.image)
        //     rect = CursorPlacement.rect(cursor:image:pressedScale:) -> ViewportTransform.apply -> CI space
        //     cursor = png.transformed(to: rect, sampling: lanczos).applyingAlpha(frame.cursor.opacity)
        //     image = cursor.composited(over: image)
        //   tag(output, bt709)
        //   context.render(image.cropped(to: outputRect), to: output, bounds: outputRect, colorSpace: srgb)
        fatalError("not implemented")
    }

    /// Attributes for the compositor's output pool: 32BGRA, IOSurface-backed, Metal-compatible.
    static var outputPixelBufferAttributes: [String: Any] { fatalError("not implemented") }

    /// Pixel formats the compositor accepts from the decoder: 420v, 420f, and BGRA. Core Image
    /// reads the biplanar formats directly, so HEVC frames are never converted on the CPU.
    static var sourcePixelBufferAttributes: [String: Any] { fatalError("not implemented") }

    private func backdrop(for plan: RenderPlan) -> CIImage {
        // TODO: lookup by plan.backdropKey; miss -> render background (solid, gradient, or image)
        // plus the blurred, offset, darkened rounded rect into a pooled buffer; keep two entries.
        fatalError("not implemented")
    }

    private static func tag(_ buffer: CVPixelBuffer, bt709: Void) { fatalError("not implemented") }
}

/// Every cursor image of one take, decoded once. `CIImage` is immutable and thread-safe, hence the
/// unchecked Sendable. A `nil` id, or a PNG that failed to load, draws `defaultArrow`.
final class CursorAtlas: @unchecked Sendable {
    private let images: [CursorImageID: CIImage]
    private let infos: [CursorImageID: CursorImageInfo]
    /// A clean-room arrow drawn from a CGPath at 2x, with hotspot (0, 0) and a 1x size of 16 x 24.
    static let defaultArrow: (image: CIImage, info: CursorImageInfo) = { fatalError("not implemented") }()

    init(source: SourceRecording) { fatalError("not implemented") }

    func image(_ id: CursorImageID?) -> CIImage { fatalError("not implemented") }
    func info(_ id: CursorImageID?) -> CursorImageInfo { fatalError("not implemented") }
}
