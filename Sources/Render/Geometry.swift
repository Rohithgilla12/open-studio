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
    /// Oldest first, so the newest ring draws on top.
    let clicks: [ClickRing]

    init(frame: FrameState, layout: CanvasLayout, cursorImage: CursorImageInfo?, look: CursorLook) {
        let viewport = frame.camera.viewport
        let scale = layout.content.size.width / viewport.size.width
        let contentOrigin = layout.content.origin
        self.viewport = viewport
        self.scale = scale
        self.contentOrigin = contentOrigin
        func canvasPoint(_ p: Point) -> Point {
            Self.canvasPoint(p, viewport: viewport, contentOrigin: contentOrigin, scale: scale)
        }
        clicks = frame.clicks.map { ClickRing($0, center: canvasPoint($0.position), largest: look.ringRadius * look.size * scale) }
        let cursor = frame.cursor
        guard cursor.isVisible else {
            self.cursor = nil
            return
        }
        let hotspot = cursorImage?.hotspot ?? FallbackArrow.hotspot
        let size = cursorImage?.size ?? FallbackArrow.size
        let drawScale = scale * look.size * (1 - (1 - look.pressedScale) * cursor.pressAmount)
        let q = canvasPoint(cursor.position)
        self.cursor = CursorPlacement(
            image: cursorImage == nil ? nil : cursor.image,
            rect: Rect(
                origin: Point(x: q.x - hotspot.x * drawScale, y: q.y - hotspot.y * drawScale),
                size: Size(width: size.width * drawScale, height: size.height * drawScale)),
            opacity: cursor.opacity)
    }

    /// Source pixel to canvas pixel: q = contentOrigin + (p - viewport.origin) * scale.
    func canvasPoint(_ p: Point) -> Point {
        Self.canvasPoint(p, viewport: viewport, contentOrigin: contentOrigin, scale: scale)
    }

    private static func canvasPoint(_ p: Point, viewport: Rect, contentOrigin: Point, scale: Double) -> Point {
        Point(x: contentOrigin.x + (p.x - viewport.origin.x) * scale,
              y: contentOrigin.y + (p.y - viewport.origin.y) * scale)
    }
}

/// What a scene knows about drawing the cursor and its click rings, from the cursor settings and
/// the take.
struct CursorLook: Sendable, Hashable {
    let pressedScale: Double
    let size: Double
    /// The ring's largest radius at size 1, in source pixels. A fraction of the frame's height, so
    /// it is about the same number of points on a 1x and a 2x display, where the cursor's
    /// declared size would change with whichever image is showing.
    let ringRadius: Double

    init(settings: CursorSettings, frame: Size) {
        pressedScale = settings.pressedScale
        size = settings.size
        ringRadius = 0.025 * frame.height
    }
}

/// One click ring in canvas pixels. It grows quickly from a third of its size and fades as it
/// grows, so it reads as a pulse from the click rather than a target drawn around it.
struct ClickRing: Sendable, Hashable {
    let center: Point
    let radius: Double
    let lineWidth: Double
    let opacity: Double

    init(_ pulse: ClickPulse, center: Point, largest: Double) {
        let p = min(max(pulse.progress, 0), 1)
        let eased = 1 - (1 - p) * (1 - p) * (1 - p)
        self.center = center
        radius = largest * (0.3 + 0.7 * eased)
        lineWidth = largest * 0.16 * (1 - 0.5 * p)
        opacity = 0.9 * (1 - p) * (1 - p)
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
        let widthInsideInsets = Double(canvas.width) - 2 * inset
        if size.width > widthInsideInsets {
            size = Size(
                width: widthInsideInsets.rounded(.down),
                height: (size.height * widthInsideInsets / size.width).rounded(.down))
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
