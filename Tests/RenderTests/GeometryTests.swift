import CoreGraphics
import Foundation
import Testing
@testable import Render
import Timeline

// Each test names the defect it catches. Everything here is pure: no GPU, no files.

let source = Size(width: 3456, height: 2234)

func layout(padding: Double = 0.08, cornerRadius: Double = 0.012, shadow: Shadow = .soft, canvas: PixelSize = PixelSize(width: 1920, height: 1080))
    -> CanvasLayout
{
    CanvasLayout(
        style: Style(background: .solid(RGBColor(red: 0, green: 0, blue: 1)), padding: padding, cornerRadius: cornerRadius, shadow: shadow),
        canvas: canvas, source: source)
}

func frame(viewport: Rect, cursor: Point = Point(x: 0, y: 0), image: CursorImageID? = nil, pressAmount: Double = 0, opacity: Double = 1, visible: Bool = true)
    -> FrameState
{
    FrameState(
        camera: CameraState(
            viewport: viewport, scale: source.width / viewport.size.width,
            center: Point(x: viewport.minX + viewport.size.width / 2, y: viewport.minY + viewport.size.height / 2),
            centerVelocity: .zero, scaleVelocity: 0),
        cursor: CursorState(
            position: cursor, velocity: .zero, image: image, isPressed: pressAmount > 0, pressAmount: pressAmount,
            opacity: opacity, isVisible: visible))
}

let fullFrame = Rect(origin: Point(x: 0, y: 0), size: source)

struct CanvasLayoutSpec {
    @Test func contentAspectFitsInsidePaddingAndIsCentred() throws {
        // 3456 x 2234 into 1920 x 1080 with padding 0.08: unit 1080, inset 86.4 px each side.
        // Available 1747.2 x 907.2; k = min(0.5056, 0.4061) = 0.4061; content 1403 x 907, centred.
        // Catches: padding applied in source pixels, or fit by width only (content taller than canvas).
        let l = layout()
        #expect(l.content == Rect(origin: Point(x: 258, y: 86), size: Size(width: 1403, height: 907)))
        #expect(l.cornerRadius == 0.012 * 1080)
        let shadow = try #require(l.shadow)
        #expect(shadow.rect.origin == Point(x: 258, y: 86 + 0.012 * 1080))
        #expect(shadow.sigma == 0.02 * 1080)
        #expect(shadow.opacity == 0.45)
    }

    @Test func zeroPaddingFillsTheShorterAxisExactly() {
        let l = layout(padding: 0)
        #expect(l.content.size.height == 1080)
        #expect(l.content.origin.y == 0)
        #expect(l.content.size.width == (3456 * 1080 / 2234.0).rounded())
    }

    @Test func layoutIsIdenticalAcrossCanvasSizesUpToScale() {
        // Catches: any style length expressed in pixels.
        let small = layout(canvas: PixelSize(width: 1920, height: 1080))
        let large = layout(canvas: PixelSize(width: 3840, height: 2160))
        #expect(abs(large.content.size.width - 2 * small.content.size.width) <= 1)
        #expect(abs(large.content.size.height - 2 * small.content.size.height) <= 1)
        #expect(abs(large.content.origin.x - 2 * small.content.origin.x) <= 1)
        #expect(large.cornerRadius == 2 * small.cornerRadius)
        #expect(large.shadow!.sigma == 2 * small.shadow!.sigma)
    }

    @Test func cornerRadiusNeverExceedsHalfTheContentSide() {
        #expect(layout(cornerRadius: 10).cornerRadius == 453.5)
    }

    @Test func noShadowWhenOpacityIsZero() {
        #expect(layout(shadow: .none).shadow == nil)
    }

    @Test func nativeCanvasMakesUnzoomedPixelsOneToOne() {
        // Catches: native meaning "the source's own size", which would shrink the content by the padding.
        let style = Style.default
        let canvas = OutputFormat.native.canvasSize(for: source, padding: style.padding)
        #expect(canvas.width % 2 == 0 && canvas.height % 2 == 0)
        let l = CanvasLayout(style: style, canvas: canvas, source: source)
        #expect(l.content.size == source)
    }
}

struct FrameGeometrySpec {
    @Test func unzoomedViewportMapsSourceCornersToContentCorners() {
        let l = layout()
        let g = FrameGeometry(frame: frame(viewport: fullFrame), layout: l, cursorImage: nil, pressedScale: 0.9)
        #expect(g.canvasPoint(Point(x: 0, y: 0)) == l.content.origin)
        let max = g.canvasPoint(Point(x: source.width, y: source.height))
        #expect(max.x == l.content.maxX)
        #expect(abs(max.y - l.content.maxY) < 0.2)
    }

    @Test func twoTimesZoomDoublesScaleAndKeepsTheCentreFixed() {
        // Catches: scale computed from camera.scale instead of the viewport width (they differ
        // once the viewport is clamped at an edge).
        let l = layout()
        let whole = FrameGeometry(frame: frame(viewport: fullFrame), layout: l, cursorImage: nil, pressedScale: 0.9)
        let half = Rect(origin: Point(x: 864, y: 558.5), size: Size(width: 1728, height: 1117))
        let zoomed = FrameGeometry(frame: frame(viewport: half), layout: l, cursorImage: nil, pressedScale: 0.9)
        #expect(zoomed.scale == 2 * whole.scale)
        let centre = Point(x: 1728, y: 1117)
        #expect(zoomed.canvasPoint(centre) == whole.canvasPoint(centre))
        #expect(zoomed.canvasPoint(half.origin) == l.content.origin)

        var state = frame(viewport: Rect(origin: Point(x: 0, y: 0), size: Size(width: 1728, height: 1117)))
        state = FrameState(
            camera: CameraState(viewport: state.camera.viewport, scale: 1.9, center: state.camera.center, centerVelocity: .zero, scaleVelocity: 0),
            cursor: state.cursor)
        #expect(FrameGeometry(frame: state, layout: l, cursorImage: nil, pressedScale: 0.9).scale == zoomed.scale)
    }

    let arrow = CursorImageInfo(relativePath: "cursors/a.png", hotspot: Point(x: 10, y: 10), size: Size(width: 56, height: 80))

    @Test func cursorHotspotLandsOnTheMappedPointerPosition() throws {
        // Catches: drawing the image's top-left at the pointer (the tip lands hotspot px off).
        let l = layout()
        let position = Point(x: 1000, y: 700)
        let g = FrameGeometry(frame: frame(viewport: fullFrame, cursor: position, image: CursorImageID(rawValue: "a")), layout: l, cursorImage: arrow, pressedScale: 0.9)
        let placement = try #require(g.cursor)
        let q = g.canvasPoint(position)
        let drawScale = placement.rect.size.width / 56
        #expect(abs(placement.rect.origin.x + 10 * drawScale - q.x) < 1e-9)
        #expect(abs(placement.rect.origin.y + 10 * drawScale - q.y) < 1e-9)
        #expect(abs(drawScale - g.scale) < 1e-12)
        #expect(placement.image == CursorImageID(rawValue: "a"))
        #expect(placement.opacity == 1)
    }

    @Test func pressShrinksAroundTheHotspot() throws {
        let l = layout()
        let position = Point(x: 1000, y: 700)
        let rest = try #require(FrameGeometry(frame: frame(viewport: fullFrame, cursor: position), layout: l, cursorImage: arrow, pressedScale: 0.9).cursor)
        let pressed = try #require(FrameGeometry(frame: frame(viewport: fullFrame, cursor: position, pressAmount: 1), layout: l, cursorImage: arrow, pressedScale: 0.9).cursor)
        #expect(abs(pressed.rect.size.width - 0.9 * rest.rect.size.width) < 1e-9)
        #expect(abs(pressed.rect.size.height - 0.9 * rest.rect.size.height) < 1e-9)
        let restTip = Point(x: rest.rect.origin.x + 10 * rest.rect.size.width / 56, y: rest.rect.origin.y + 10 * rest.rect.size.height / 80)
        let pressedTip = Point(x: pressed.rect.origin.x + 10 * pressed.rect.size.width / 56, y: pressed.rect.origin.y + 10 * pressed.rect.size.height / 80)
        #expect(abs(restTip.x - pressedTip.x) < 1e-9 && abs(restTip.y - pressedTip.y) < 1e-9)
    }

    @Test func cursorSizeComesFromTheDeclarationNotThePNG() throws {
        // The placement only knows the declared 56 x 80; a 280 x 400 PNG is the recipe's problem.
        // Catches: a renderer that sizes by image extent, which would draw hi-res captures 5x too big.
        let l = layout(padding: 0, canvas: PixelSize(width: 3456, height: 2234))
        let g = FrameGeometry(frame: frame(viewport: fullFrame, cursor: Point(x: 100, y: 100)), layout: l, cursorImage: arrow, pressedScale: 0.9)
        #expect(try #require(g.cursor).rect.size == Size(width: 56, height: 80))
    }

    @Test func undeclaredCursorUsesTheFallbackArrowDeclaration() throws {
        let l = layout()
        let g = FrameGeometry(frame: frame(viewport: fullFrame, cursor: Point(x: 100, y: 100), image: nil), layout: l, cursorImage: nil, pressedScale: 0.9)
        let placement = try #require(g.cursor)
        #expect(placement.image == nil)
        #expect(abs(placement.rect.size.width - FallbackArrow.size.width * g.scale) < 1e-9)
    }

    @Test func invisibleCursorHasNoPlacement() {
        let l = layout()
        let hidden = frame(viewport: fullFrame, cursor: Point(x: 100, y: 100), opacity: 0, visible: false)
        #expect(FrameGeometry(frame: hidden, layout: l, cursorImage: arrow, pressedScale: 0.9).cursor == nil)
    }

    @Test func flipMovesTheOriginToTheBottomLeft() {
        let rect = Rect(origin: Point(x: 10, y: 20), size: Size(width: 100, height: 50))
        let flipped = FrameRecipe.flipped(rect, canvasHeight: 1080)
        #expect(flipped == CGRect(x: 10, y: 1080 - 70, width: 100, height: 50))
    }
}

struct BackdropSpec {
    @Test func ditherIsDeterministicAndWithinOneCodeValue() {
        for (x, y) in [(0, 0), (17, 3), (1919, 1079), (3839, 2159)] {
            let n = Backdrop.noise(x: x, y: y)
            #expect(n >= 0 && n < 1)
            #expect(n == Backdrop.noise(x: x, y: y))
        }
        #expect(Backdrop.noise(x: 1, y: 0) != Backdrop.noise(x: 0, y: 1))
    }
}
