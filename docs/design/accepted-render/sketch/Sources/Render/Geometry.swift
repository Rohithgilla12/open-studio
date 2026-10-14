import Foundation
import Timeline

// All geometry here is in canvas pixels, origin top-left, y down: the same orientation as
// Timeline's source pixels. Core Image's bottom-left origin appears only inside FrameRecipe.

/// Where the screen content sits on the canvas. Depends only on (style, canvas, source size), so a
/// scene computes it once and every frame shares it.
struct CanvasLayout: Sendable, Hashable {
    let canvas: PixelSize
    /// Aspect-fit of the source inside the padded canvas, centred, snapped to whole pixels so the
    /// rounded edge does not shimmer between frames. Its aspect equals the source's (to within
    /// the snap), which is what lets one scale factor map both axes.
    let content: Rect
    let cornerRadius: Double
    let shadow: ShadowGeometry?

    init(style: Style, canvas: PixelSize, source: Size) {
        // TODO:
        //   unit = min(canvas.width, canvas.height)
        //   avail = canvas rect inset by style.padding * unit on all sides
        //   k = min(avail.w / source.w, avail.h / source.h)
        //   content = centred (source * k), origin floored, size rounded
        //   cornerRadius = style.cornerRadius * unit, clamped to min(content.w, content.h) / 2
        //   shadow = style.shadow.opacity > 0 ? ShadowGeometry(rect: content offset by offsetY*unit,
        //            sigma: blur*unit, opacity) : nil
        fatalError("not implemented")
    }
}

struct ShadowGeometry: Sendable, Hashable {
    let rect: Rect
    let cornerRadius: Double
    let sigma: Double
    let opacity: Double
}

/// The per-frame mapping, derived from one `FrameState`. Pure, so tests pin it without a GPU.
struct FrameGeometry: Sendable, Hashable {
    /// The source rectangle shown, which is `camera.viewport`.
    let viewport: Rect
    /// Canvas pixels per source pixel. Equal on both axes because viewport and content share the
    /// source's aspect.
    let scale: Double
    /// Canvas position of the viewport's origin, which is `layout.content.origin`.
    let contentOrigin: Point
    let cursor: CursorPlacement?

    init(frame: FrameState, layout: CanvasLayout, cursorImage: CursorImageInfo?, pressedScale: Double) {
        // TODO:
        //   viewport = frame.camera.viewport
        //   scale = layout.content.size.width / viewport.size.width
        //   contentOrigin = layout.content.origin
        //   cursor = frame.cursor.isVisible ? CursorPlacement(...) : nil
        fatalError("not implemented")
    }

    /// Source pixel to canvas pixel: q = contentOrigin + (p - viewport.origin) * scale.
    func canvasPoint(_ p: Point) -> Point {
        Point(x: contentOrigin.x + (p.x - viewport.origin.x) * scale,
              y: contentOrigin.y + (p.y - viewport.origin.y) * scale)
    }
}

/// Where and how to draw the cursor image on the canvas.
///
/// The recorded hotspot and size are in screen pixels at 1x camera zoom, and screen pixels are
/// source pixels. So the cursor scales with the camera like everything else on screen, and the
/// press shrink pivots on the hotspot, which keeps the tip on the click.
struct CursorPlacement: Sendable, Hashable {
    /// Image key in `SceneAssets.cursors`. nil selects the built-in fallback arrow.
    let image: CursorImageID?
    /// Canvas rect the image is drawn into. The image's own pixel size never matters: a 280 x 400
    /// PNG declared as 56 x 80 screen pixels is drawn into 56 x 80 x drawScale canvas pixels,
    /// which is what makes higher-resolution cursor captures crisp without a format change.
    let rect: Rect
    let opacity: Double

    // TODO (cursor transform):
    //   q          = geometry.canvasPoint(cursor.position)           // hotspot on the canvas
    //   press      = 1 - (1 - pressedScale) * cursor.pressAmount
    //   drawScale  = geometry.scale * press
    //   info       = cursorImage ?? (FallbackArrow.hotspot, FallbackArrow.size)
    //   rect.origin = q - info.hotspot * drawScale
    //   rect.size   = info.size * drawScale
    //   opacity    = cursor.opacity
    // Not clamped to the content rect here. FrameRecipe clips the cursor with the same rounded
    // mask as the screen, so the cursor is part of the screen and leaves through its edge.
}
