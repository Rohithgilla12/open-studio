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
    let pressedScale: Double
    let assets: SceneAssets

    /// Reuses `previous.assets` when style, canvas, and source are unchanged, which is the common
    /// case while dragging a zoom: only the Timeline is rebuilt (about 10 ms for 30 minutes of
    /// input, measured in D2), the backdrop is not re-rendered.
    static func make(project: Project, format: OutputFormat, reusing previous: RenderScene?) throws(RenderError) -> RenderScene {
        let style = project.edits.style
        let canvas = format.canvasSize(for: project.source.frameSize, padding: style.padding)
        let layout = CanvasLayout(style: style, canvas: canvas, source: project.source.frameSize)
        let key = SceneAssets.Key(style: style, canvas: canvas, source: project.source.id)
        let assets: SceneAssets
        if let previous, previous.assets.key == key {
            assets = previous.assets
        } else {
            assets = try SceneAssets.build(key, layout: layout, project: project)
        }
        return RenderScene(
            timeline: project.timeline, layout: layout, pressedScale: project.edits.settings.cursor.pressedScale,
            assets: assets)
    }

    private init(timeline: Timeline, layout: CanvasLayout, pressedScale: Double, assets: SceneAssets) {
        self.timeline = timeline
        self.layout = layout
        self.pressedScale = pressedScale
        self.assets = assets
    }

    /// The whole per-frame drawing step. Pure: the CIImage is a recipe, and rendering it is the
    /// caller's job (the compositor renders into AVFoundation's pooled buffer).
    func image(source: CIImage, at t: RecordingTime) -> CIImage {
        let frame = timeline.frame(at: t)
        let cursorInfo = frame.cursor.image.flatMap { timeline.source.cursorImages[$0] }
        let geometry = FrameGeometry(frame: frame, layout: layout, cursorImage: cursorInfo, pressedScale: pressedScale)
        return FrameRecipe.image(source: source, geometry: geometry, layout: layout, assets: assets)
    }
}

/// GPU-side resources that depend on (style, canvas, source) but not on time. Built once per key.
final class SceneAssets: Sendable {
    struct Key: Sendable, Hashable {
        let style: Style
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
        var backdrop = try Backdrop.background(key.style.background, canvas: canvas, directory: project.source.directory)
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
    case missingSourceFrame(RecordingTime)
}
