import CoreVideo
import Metal
import Timeline

/// Draws one frame with one Metal render pass. The only drawing function in the repo: preview,
/// export, `osrec still`, and the pixel test all call `draw`.
///
/// Holds a device, a command queue, one pipeline state, a cursor texture cache and a
/// CVMetalTextureCache. None of that is frame state: every cached item is a function of immutable
/// inputs (shader source, PNG bytes). `draw` is callable from any thread.
final class FrameRenderer: @unchecked Sendable {
    /// One per process. The device is `MTLCreateSystemDefaultDevice()`.
    static func shared() throws(RenderError) -> FrameRenderer { fatalError("not implemented") }

    /// Encodes and commits the pass, then calls `completion` from the Metal completion handler.
    /// Does not block the caller, so AVFoundation's request threads pipeline several frames.
    ///
    /// - source: 420v (video range, BT.709), IOSurface backed, as the compositor declared.
    /// - target: BGRA8, IOSurface backed. The renderer tags it BT.709 on every attachment.
    func draw(
        _ layout: FrameLayout, sprites: CursorSprites,
        source: CVPixelBuffer, into target: CVPixelBuffer,
        completion: @escaping @Sendable (Result<Void, RenderError>) -> Void
    ) {
        // TODO
        //  1. Wrap source planes as r8Unorm and rg8Unorm textures, target as bgra8Unorm, via the texture cache.
        //  2. Pack `layout` into `ShaderUniforms` (std140-style padding, as in the spike).
        //  3. One render pass, loadAction .dontCare (the shader writes every pixel), draw a fullscreen triangle.
        //  4. Fragment, per pixel (see Shaders.swift): background (gradient or image) -> analytic shadow
        //     (erf of the rounded-rect SDF) -> screen sample inside the rounded rect, coverage from the SDF
        //     -> cursor quad clipped to the rounded rect -> 1/255 ordered dither from pixel coordinates.
        //  5. commandBuffer.addCompletedHandler { flush texture cache; completion(...) }
        //  6. CVBufferSetAttachment on target: primaries, transfer, matrix = ITU_R_709_2.
        fatalError("not implemented")
    }

    /// Synchronous convenience for the still command and the tests. Same `draw`, awaited.
    func drawAndWait(
        _ layout: FrameLayout, sprites: CursorSprites, source: CVPixelBuffer, into target: CVPixelBuffer
    ) throws(RenderError) {
        fatalError("not implemented")
    }
}
