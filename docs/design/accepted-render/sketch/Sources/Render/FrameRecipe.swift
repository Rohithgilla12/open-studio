import CoreImage
import Foundation
import Timeline

/// Builds the Core Image recipe for one frame. The only file that knows Core Image's bottom-left
/// origin; everything it receives is in top-left canvas pixels.
enum FrameRecipe {
    static func image(source: CIImage, geometry: FrameGeometry, layout: CanvasLayout, assets: SceneAssets) -> CIImage {
        // TODO, measured shape from the spike (spike/main.swift, Scene.image):
        //   v = geometry.viewport flipped into the source CIImage's space (y' = frameHeight - maxY)
        //   content = source.cropped(to: v)
        //               .translated(-v.origin)
        //               .lanczos(scale: geometry.scale)        // CILanczosScaleTransform: text stays sharp
        //                                                     // when 3456 px shrinks to a 1600 px inset
        //               .translated(to: layout.content flipped)
        //   if let c = geometry.cursor:
        //       img = assets.cursors[c.image] ?? assets.fallbackCursor
        //       cursor = img.scaled(to: c.rect.size)  // from the image's own extent, never assumed size
        //                   .translated(to: c.rect flipped)
        //                   .multiplyingAlpha(c.opacity)      // CIColorMatrix on alpha
        //       content = cursor.composited(over: content)
        //   return content.blendWithMask(background: assets.backdrop, mask: assets.contentMask)
        //                 .cropped(to: canvas rect)
        //
        // One mask clips screen and cursor together, so the cursor leaves through the rounded edge.
        fatalError("not implemented")
    }

    /// Top-left canvas rect to Core Image's bottom-left space.
    static func flipped(_ rect: Rect, canvasHeight: Int) -> CGRect {
        CGRect(x: rect.minX, y: Double(canvasHeight) - rect.maxY, width: rect.size.width, height: rect.size.height)
    }
}

/// The cursor drawn when the recording references an image it never declared. Drawn from a path
/// written for this project, not copied from any system or third-party asset.
enum FallbackArrow {
    /// Screen pixels at a 2x display, matching the recorded arrow's declaration (hotspot 10, 10,
    /// size 56 x 80, from D3's take).
    static let hotspot = Point(x: 10, y: 10)
    static let size = Size(width: 56, height: 80)
}
