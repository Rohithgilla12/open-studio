import Timeline

/// Where everything goes on the canvas for one frame, in output pixels. Pure CPU geometry. The Metal
/// shader is deliberately dumb: it draws exactly this and decides nothing. So the viewport mapping,
/// the cursor transform and the style maths are covered by plain `swift test` with no GPU.
struct FrameLayout: Equatable {
    /// Source pixels to show (Timeline's viewport, already inside the frame).
    var viewport: Rect
    /// The rounded screen rect on the canvas: aspect-fit of the source into the padded canvas.
    var content: Rect
    var cornerRadius: Double
    var shadow: ShadowLayout
    var background: Background
    var cursor: CursorQuad?

    struct ShadowLayout: Equatable { var opacity: Double; var sigma: Double; var offsetY: Double }

    /// The cursor as a quad, premultiplied-alpha sprite drawn with `opacity`.
    struct CursorQuad: Equatable {
        var sprite: CursorImageID?   // nil = built-in arrow
        var rect: Rect               // output pixels
        var opacity: Double
    }

    static func make(
        frame: FrameState, source: SourceRecording, settings: TimelineSettings, sprites: CursorSprites,
        style: Style, canvas: PixelSize
    ) -> FrameLayout {
        // TODO content rect:
        //   pad = style.padding * canvas.width
        //   inset = Rect(pad, pad, canvas.w - 2 pad, canvas.h - 2 pad)
        //   k = min(inset.w / source.frameSize.w, inset.h / source.frameSize.h)   // aspect fit
        //   content = Rect centred in inset, size source.frameSize * k
        //   (viewport has the source aspect, so no further letterboxing inside content)
        //
        // TODO viewport to canvas:
        //   s = content.w / frame.camera.viewport.w          // output px per source px, includes zoom
        //   map(p) = content.origin + (p - viewport.origin) * s
        //
        // TODO cursor (only when frame.cursor.isVisible and opacity > 0 and the hotspot maps near the content):
        //   info = source.cursorImages[id]  (size and hotspot in source px, drawn at 1x)
        //   press = 1 - (1 - pressedScale) * frame.cursor.pressAmount    // pressedScale = settings.cursor.pressedScale
        //   d = s * style.cursor.sizeMultiplier * press                  // output px per sprite px
        //   rect.size = info.size * d
        //   rect.origin = map(frame.cursor.position) - info.hotspot * d  // scale about the hotspot, so the click lands
        //   opacity = frame.cursor.opacity
        //   clip: the cursor is clipped by the content rounded rect in the shader (it must not draw on the padding)
        //
        // TODO shadow: sigma = style.shadow.blur * canvas.w, offsetY = style.shadow.offsetY * canvas.w
        fatalError("not implemented")
    }
}
