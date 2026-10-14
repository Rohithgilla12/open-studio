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
        // TODO:
        //   canvas = format.canvasSize(for: project.source.frameSize)
        //   layout = CanvasLayout(style: project.edits.style, canvas: canvas, source: project.source.frameSize)
        //   key = SceneAssets.Key(style, canvas, source.id)
        //   assets = previous?.assets.key == key ? previous!.assets : try SceneAssets.build(key, layout, project)
        //   return RenderScene(timeline: project.timeline, layout, project.edits.settings.cursor.pressedScale, assets)
        fatalError("not implemented")
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
    /// Background plus shadow, pre-rendered to a bitmap so each frame reads one texture instead of
    /// re-running a gradient and a Gaussian blur. Measured in the spike: with this, a 4K frame
    /// renders in 10.5 ms of serial compositor latency including a Lanczos resample.
    let backdrop: CIImage
    /// White rounded rectangle at `layout.content`, the clip for screen and cursor together.
    let contentMask: CIImage
    let cursors: [CursorImageID: CIImage]
    let fallbackCursor: CIImage

    static func build(_ key: Key, layout: CanvasLayout, project: Project) throws(RenderError) -> SceneAssets {
        // TODO:
        //   backdrop: Background -> CIImage (CILinearGradient / constant colour / aspect-fill image),
        //             shadow = CIRoundedRectangleGenerator(shadow.rect, black, opacity) blurred by sigma,
        //             composited, rendered once with RenderDevice.context into a CGImage, wrapped back.
        //   contentMask: CIRoundedRectangleGenerator(layout.content flipped to CI space, radius, white)
        //   cursors: for (id, info) in source.cursorImages: CIImage(contentsOf: directory + info.relativePath)
        //            A missing PNG maps to the fallback, logged once, never a failed scene.
        //   fallbackCursor: FallbackArrow.image (vector path drawn at 10x, clean-room shape)
        fatalError("not implemented")
    }

    private init(key: Key, backdrop: CIImage, contentMask: CIImage, cursors: [CursorImageID: CIImage], fallbackCursor: CIImage) {
        self.key = key
        self.backdrop = backdrop
        self.contentMask = contentMask
        self.cursors = cursors
        self.fallbackCursor = fallbackCursor
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
}

public enum RenderError: Error, Sendable, Equatable {
    case screenMovieUnreadable(String)
    case backgroundImageUnreadable(String)
    case missingSourceFrame(RecordingTime)
}
