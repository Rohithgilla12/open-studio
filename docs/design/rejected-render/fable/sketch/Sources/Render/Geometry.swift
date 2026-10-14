import CoreGraphics
import Timeline

// Pure geometry, no Core Image. Unit-tested with exact numbers. Every function here is a function
// of (output size, source size, style, frame state) and nothing else.

/// Where the screen content sits on the canvas. Output pixels, origin top-left, y down, the same
/// convention as Timeline, so a reader never flips until `CoreImageSpace`.
public struct CanvasLayout: Sendable, Hashable {
    public let output: PixelSize
    /// The source aspect fitted inside the padded canvas and centred.
    public let contentRect: Rect
    public let cornerRadius: Double
    public let shadowBlur: Double
    public let shadowOffsetY: Double

    public init(output: PixelSize, sourceSize: Size, style: Style) {
        // TODO: padding = style.padding.pixels(in: output); fit = min((w - 2p)/sw, (h - 2p)/sh);
        // contentRect = sw*fit x sh*fit centred. Radii and shadow via Fraction.pixels.
        fatalError("not implemented")
    }
}

/// Maps source pixels to output pixels for one frame: the camera viewport fills `contentRect`.
///
/// Uniform scale, because `CameraState.viewport` always has the source aspect (Timeline divides
/// both sides by the same scale), so `contentRect.width / viewport.width` equals the height ratio.
public struct ViewportTransform: Sendable, Hashable {
    public let scale: Double
    public let translation: Point

    public init(viewport: Rect, contentRect: Rect) { fatalError("not implemented") }

    public func apply(_ p: Point) -> Point { fatalError("not implemented") }
    public func apply(_ r: Rect) -> Rect { fatalError("not implemented") }
    public var affine: CGAffineTransform { fatalError("not implemented") }
}

/// The cursor's rectangle in source pixels for one frame. The image is drawn at `info.size`
/// (screen pixels at 1x) shrunk about the hotspot by the press amount; the camera zoom then applies
/// through `ViewportTransform`, so the cursor grows with the zoom like the content under it, and
/// the PNG is resampled exactly once on the way to the output.
public enum CursorPlacement {
    public static func rect(cursor: CursorState, image: CursorImageInfo, pressedScale: Double) -> Rect {
        // TODO: k = 1 - (1 - pressedScale) * cursor.pressAmount
        //       origin = position - hotspot * k; size = image.size * k
        fatalError("not implemented")
    }
}

/// The single y flip between Timeline's y-down pixel space and Core Image's y-up space.
public enum CoreImageSpace {
    /// `(x, y) -> (x, height - y)`, applied to rects by flipping maxY to minY.
    public static func flip(height: Double) -> CGAffineTransform { fatalError("not implemented") }
    public static func rect(_ r: Rect, height: Double) -> CGRect { fatalError("not implemented") }
}
