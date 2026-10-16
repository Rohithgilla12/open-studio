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
        self.canvas = canvas
        let unit = Double(min(canvas.width, canvas.height))
        let inset = style.padding * unit
        let available = Size(width: Double(canvas.width) - 2 * inset, height: Double(canvas.height) - 2 * inset)
        let fit = min(available.width / source.width, available.height / source.height)
        // The native canvas is rounded to even pixels, which pushes the fit off 1 by less than a
        // pixel across the content. Snapping keeps native exactly 1:1, which is what it is for.
        let k = abs(fit - 1) * max(source.width, source.height) < 1 ? 1 : fit
        let size = Size(width: (source.width * k).rounded(), height: (source.height * k).rounded())
        let origin = Point(
            x: ((Double(canvas.width) - size.width) / 2).rounded(.down),
            y: ((Double(canvas.height) - size.height) / 2).rounded(.down))
        content = Rect(origin: origin, size: size)
        cornerRadius = min(style.cornerRadius * unit, min(size.width, size.height) / 2)
        shadow = style.shadow.opacity > 0
            ? ShadowGeometry(
                rect: Rect(origin: Point(x: origin.x, y: origin.y + style.shadow.offsetY * unit), size: size),
                cornerRadius: cornerRadius, sigma: style.shadow.blur * unit, opacity: style.shadow.opacity)
            : nil
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
        viewport = frame.camera.viewport
        scale = layout.content.size.width / frame.camera.viewport.size.width
        contentOrigin = layout.content.origin
        let cursor = frame.cursor
        guard cursor.isVisible else {
            self.cursor = nil
            return
        }
        let hotspot = cursorImage?.hotspot ?? FallbackArrow.hotspot
        let size = cursorImage?.size ?? FallbackArrow.size
        let drawScale = scale * (1 - (1 - pressedScale) * cursor.pressAmount)
        let q = Point(
            x: contentOrigin.x + (cursor.position.x - viewport.origin.x) * scale,
            y: contentOrigin.y + (cursor.position.y - viewport.origin.y) * scale)
        self.cursor = CursorPlacement(
            image: cursorImage == nil ? nil : cursor.image,
            rect: Rect(
                origin: Point(x: q.x - hotspot.x * drawScale, y: q.y - hotspot.y * drawScale),
                size: Size(width: size.width * drawScale, height: size.height * drawScale)),
            opacity: cursor.opacity)
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
///
/// Not clamped to the content rect. FrameRecipe clips the cursor with the same rounded mask as the
/// screen, so the cursor is part of the screen and leaves through its edge.
struct CursorPlacement: Sendable, Hashable {
    /// Image key in `SceneAssets.cursors`. nil selects the built-in fallback arrow.
    let image: CursorImageID?
    /// Canvas rect the image is drawn into. The image's own pixel size never matters: a 280 x 400
    /// PNG declared as 56 x 80 screen pixels is drawn into 56 x 80 x drawScale canvas pixels,
    /// which is what makes higher-resolution cursor captures crisp without a format change.
    let rect: Rect
    let opacity: Double
}

/// Where the camera footage is drawn on the canvas for one frame. Depends on the camera frame's
/// size, which the compositor knows only once it holds the frame, so it is built per frame; it is a
/// few multiplications.
struct CameraOverlayGeometry: Sendable, Hashable {
    /// Canvas pixels, top-left, snapped to whole pixels.
    let rect: Rect
    let cornerRadius: Double
    /// Canvas pixels per camera pixel. The camera is scaled to fill the rect and centred, so a
    /// circle shows the middle of a wide picture.
    let scale: Double
    let mirrored: Bool

    init(overlay: CameraOverlay, canvas: PixelSize, camera: Size) {
        let unit = Double(min(canvas.width, canvas.height))
        let inset = (overlay.inset * unit).rounded()
        let height = (overlay.size * unit).rounded()
        var size = switch overlay.shape {
        case .circle: Size(width: height, height: height)
        case .roundedRectangle: Size(width: (height * camera.width / camera.height).rounded(), height: height)
        }
        // A very wide camera in a narrow canvas would run off the far edge, so it shrinks to fit.
        let room = Double(canvas.width) - 2 * inset
        if size.width > room {
            size = Size(width: room.rounded(.down), height: (size.height * room / size.width).rounded(.down))
        }
        let left = overlay.corner == .topLeft || overlay.corner == .bottomLeft
        let top = overlay.corner == .topLeft || overlay.corner == .topRight
        rect = Rect(
            origin: Point(
                x: left ? inset : Double(canvas.width) - inset - size.width,
                y: top ? inset : Double(canvas.height) - inset - size.height),
            size: size)
        cornerRadius = switch overlay.shape {
        case .circle: size.width / 2
        case .roundedRectangle: 0.12 * min(size.width, size.height)
        }
        scale = max(size.width / camera.width, size.height / camera.height)
        mirrored = overlay.mirrored
    }
}
