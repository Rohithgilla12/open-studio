import CoreGraphics
import CoreImage
import Foundation
import Timeline

/// Everything one frame needs besides the source pixels and the time. Immutable and Sendable, so
/// AVFoundation's compositor threads share it without locks, and a frame is a pure function of
/// (source frame, t, scene).
///
/// A scene is built per (project edits, output format). An edit builds a new scene; nothing ever
/// mutates one. That is what makes preview and export agree: both read a scene value, never a
/// shared mutable box.
final class RenderScene: Sendable {
    let timeline: Timeline
    let layout: CanvasLayout
    let cursorLook: CursorLook
    let assets: SceneAssets
    /// nil when the take has no camera or the overlay is hidden, so the compositor never asks
    /// for camera frames.
    let cameraOverlay: CameraOverlay?

    /// Reuses `previous.assets` when style, canvas, and source are unchanged, which is the common
    /// case while dragging a zoom: only the Timeline is rebuilt (about 10 ms for 30 minutes of
    /// input, measured in D2), the backdrop is not re-rendered.
    static func make(project: Project, format: OutputFormat, reusing previous: RenderScene?) throws(RenderError) -> RenderScene {
        let style = project.edits.style
        let canvas = project.canvasSize(for: format)
        let layout = CanvasLayout(style: style, canvas: canvas, source: project.source.visibleRect.size)
        let key = SceneAssets.Key(
            background: style.background, padding: style.padding, cornerRadius: style.cornerRadius, shadow: style.shadow,
            canvas: canvas, source: project.source.id)
        let assets: SceneAssets
        if let previous, previous.assets.key == key {
            assets = previous.assets
        } else {
            assets = try SceneAssets.build(key, layout: layout, project: project)
        }
        return RenderScene(
            timeline: project.timeline, layout: layout,
            cursorLook: CursorLook(settings: project.edits.settings.cursor, frame: project.source.frameSize),
            assets: assets, cameraOverlay: project.source.hasCamera && style.camera.isVisible ? style.camera : nil)
    }

    private init(timeline: Timeline, layout: CanvasLayout, cursorLook: CursorLook, assets: SceneAssets, cameraOverlay: CameraOverlay?) {
        self.timeline = timeline
        self.layout = layout
        self.cursorLook = cursorLook
        self.assets = assets
        self.cameraOverlay = cameraOverlay
    }

    /// The whole per-frame drawing step. Pure: the CIImage is a recipe, and rendering it is the
    /// caller's job (the compositor renders into AVFoundation's pooled buffer).
    ///
    /// `camera` is the camera frame covering `t`, or nil when there is none at `t` (before the
    /// camera's first frame, or after it was lost), in which case no overlay is drawn.
    func image(source: CIImage, camera: CIImage? = nil, at t: OutputTime) -> CIImage {
        let frame = timeline.frame(at: t)
        let cursorInfo = frame.cursor.image.flatMap { timeline.source.cursorImages[$0] }
        let geometry = FrameGeometry(frame: frame, layout: layout, cursorImage: cursorInfo, look: cursorLook)
        var overlay: (image: CIImage, geometry: CameraOverlayGeometry)?
        if let camera, let cameraOverlay {
            let size = Size(width: camera.extent.width, height: camera.extent.height)
            overlay = (camera, CameraOverlayGeometry(overlay: cameraOverlay, canvas: layout.canvas, camera: size))
        }
        return FrameRecipe.image(source: source, geometry: geometry, layout: layout, assets: assets, camera: overlay)
    }
}

/// GPU-side resources that depend on (style, canvas, source) but not on time. Built once per key.
final class SceneAssets: Sendable {
    /// The parts of the style the backdrop draws. The camera overlay is not among them, so moving
    /// it never re-renders the backdrop.
    struct Key: Sendable, Hashable {
        let background: Background
        let padding: Double
        let cornerRadius: Double
        let shadow: Shadow
        let canvas: PixelSize
        let source: UUID
    }

    let key: Key
    /// Background plus shadow, pre-rendered and dithered to an 8-bit bitmap so each frame reads one
    /// texture instead of re-running a gradient and a Gaussian blur. Measured in the spike: with
    /// this, a 4K frame renders in 10.5 ms of serial compositor latency including a Lanczos resample.
    let backdrop: CIImage
    /// White rounded rectangle at `layout.content`, the clip for screen and cursor together.
    let contentMask: CIImage
    let cursors: [CursorImageID: CIImage]
    let fallbackCursor: CIImage
    /// Cursor PNGs that could not be read. They draw as the fallback arrow instead of failing the scene.
    let warnings: [String]

    static func build(_ key: Key, layout: CanvasLayout, project: Project) throws(RenderError) -> SceneAssets {
        let canvas = layout.canvas
        let full = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        var backdrop = try Backdrop.background(key.background, canvas: canvas, directory: project.source.directory)
        if let shadow = layout.shadow {
            let shape = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                kCIInputExtentKey: CIVector(cgRect: FrameRecipe.flipped(shadow.rect, canvasHeight: canvas.height)),
                kCIInputRadiusKey: shadow.cornerRadius,
                kCIInputColorKey: CIColor(red: 0, green: 0, blue: 0, alpha: shadow.opacity),
            ])!.outputImage!
            backdrop = shape.applyingGaussianBlur(sigma: shadow.sigma).cropped(to: full).composited(over: backdrop)
        }
        let contentMask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            kCIInputExtentKey: CIVector(cgRect: FrameRecipe.flipped(layout.content, canvasHeight: canvas.height)),
            kCIInputRadiusKey: layout.cornerRadius,
            kCIInputColorKey: CIColor.white,
        ])!.outputImage!

        var cursors: [CursorImageID: CIImage] = [:]
        var warnings: [String] = []
        for (id, info) in project.source.cursorImages {
            let url = project.source.directory.appending(path: info.relativePath, directoryHint: .notDirectory)
            if let image = CIImage(contentsOf: url) {
                cursors[id] = image
            } else {
                warnings.append("cursor image \(info.relativePath) is unreadable; drawing the fallback arrow")
            }
        }
        return SceneAssets(
            key: key, backdrop: Backdrop.dithered(backdrop, canvas: canvas), contentMask: contentMask,
            cursors: cursors, fallbackCursor: FallbackArrow.image(), warnings: warnings.sorted())
    }

    private init(
        key: Key, backdrop: CIImage, contentMask: CIImage, cursors: [CursorImageID: CIImage], fallbackCursor: CIImage,
        warnings: [String]
    ) {
        self.key = key
        self.backdrop = backdrop
        self.contentMask = contentMask
        self.cursors = cursors
        self.fallbackCursor = fallbackCursor
        self.warnings = warnings
    }
}

/// Process-wide GPU objects. One CIContext for preview, export, and stills, so all three use the
/// same working space, the same filters, and the same output colour conversion.
enum RenderDevice {
    /// Working space extended linear sRGB; caching intermediates off, because every frame's
    /// intermediates are unique and caching them only costs memory.
    static let context: CIContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .cacheIntermediates: false,
    ])
    /// The output buffers are tagged BT.709 primaries, transfer, and matrix, matching the source
    /// that ScreenCaptureKit writes (measured: bt709 / bt709 / bt709, video range).
    static let outputColorSpace = CGColorSpace(name: CGColorSpace.itur_709)!
    /// Style colours are sRGB values.
    static let styleColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
}

public enum RenderError: Error, Sendable, Equatable {
    case screenMovieUnreadable(String)
    case backgroundImageUnreadable(String)
    case missingSourceFrame(OutputTime)
}
