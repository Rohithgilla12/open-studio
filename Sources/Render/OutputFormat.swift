import Foundation
import Timeline

/// What an export writes, and the size the preview renders at. The preview always renders at the
/// selected format's canvas, so what plays is what exports.
public struct OutputFormat: Sendable, Hashable, Codable {
    public var size: CanvasPreset
    /// The canvas's shape. Native ignores it, because growing the native box to another shape
    /// would move the padding and break its 1:1 promise.
    public var aspect: CanvasAspect
    public var frameRate: FrameRate
    public var codec: Codec

    public init(size: CanvasPreset, aspect: CanvasAspect = .fit, frameRate: FrameRate, codec: Codec) {
        self.size = size
        self.aspect = aspect
        self.frameRate = frameRate
        self.codec = codec
    }

    private enum CodingKeys: String, CodingKey {
        case size, aspect, frameRate, codec
    }

    /// A project saved before aspects existed has no `aspect` key and keeps today's canvas.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            size: try c.decode(CanvasPreset.self, forKey: .size),
            aspect: try c.decodeIfPresent(CanvasAspect.self, forKey: .aspect) ?? .fit,
            frameRate: try c.decode(FrameRate.self, forKey: .frameRate),
            codec: try c.decode(Codec.self, forKey: .codec))
    }

    public static let hd1080 = OutputFormat(size: .hd1080, frameRate: .fps60, codec: .hevc)
    public static let uhd2160 = OutputFormat(size: .uhd2160, frameRate: .fps60, codec: .hevc)
    public static let native = OutputFormat(size: .native, frameRate: .fps60, codec: .hevc)

    /// Even width and height, because 4:2:0 encoders reject odd sizes.
    ///
    /// `native` is the canvas on which unzoomed screen pixels land 1:1: the source grown by the
    /// padding on each side, so at camera scale 1 the content rect is the source's own size.
    public func canvasSize(for source: Size, padding: Double) -> PixelSize {
        switch size {
        case .hd1080: return aspect.box(shorterSide: 1080)
        case .uhd2160: return aspect.box(shorterSide: 2160)
        case .native:
            let grow = 1 / max(1 - 2 * padding, 0.05)
            return PixelSize(width: Self.even(source.width * grow), height: Self.even(source.height * grow))
        }
    }

    /// The canvas for a take that shows only an area of its frame. With `fit`, the largest even
    /// canvas with the area's aspect inside the preset's box. With an explicit aspect, the box
    /// itself, the area fitted inside it like an entire screen. For native, the area grown by the
    /// padding.
    public func canvasSize(forArea area: Size, padding: Double) -> PixelSize {
        let box = canvasSize(for: area, padding: padding)
        guard size != .native, aspect == .fit else { return box }
        let aspect = area.width / area.height
        if aspect >= Double(box.width) / Double(box.height) {
            return PixelSize(width: box.width, height: max(2, Self.even(Double(box.width) / aspect)))
        }
        return PixelSize(width: max(2, Self.even(Double(box.height) * aspect)), height: box.height)
    }

    static func even(_ value: Double) -> Int { Int(value.rounded()) & ~1 }
}

/// The canvas's shape for the 1080p and 4K presets, which fix its shorter side.
public enum CanvasAspect: String, Sendable, Hashable, Codable, CaseIterable {
    /// Today's canvas: the 16:9 box, or for an area take the area's shape inside it.
    case fit
    case widescreen = "16:9"
    case vertical = "9:16"
    case square = "1:1"
    case standard = "4:3"
    case portrait = "4:5"

    /// Width over height in whole numbers. `fit` boxes at 16:9.
    public var ratio: (width: Int, height: Int) {
        switch self {
        case .fit, .widescreen: (16, 9)
        case .vertical: (9, 16)
        case .square: (1, 1)
        case .standard: (4, 3)
        case .portrait: (4, 5)
        }
    }

    func box(shorterSide: Int) -> PixelSize {
        let (w, h) = ratio
        if w >= h {
            return PixelSize(width: OutputFormat.even(Double(shorterSide * w) / Double(h)), height: shorterSide)
        }
        return PixelSize(width: shorterSide, height: OutputFormat.even(Double(shorterSide * h) / Double(w)))
    }
}

public enum CanvasPreset: String, Sendable, Hashable, Codable, CaseIterable {
    /// 1920 x 1080.
    case hd1080
    /// 3840 x 2160.
    case uhd2160
    /// Source pixels 1:1 when unzoomed: the source size divided by (1 - 2 * padding).
    case native
}

public enum FrameRate: Int, Sendable, Hashable, Codable, CaseIterable {
    case fps30 = 30
    case fps60 = 60
}

public enum Codec: String, Sendable, Hashable, Codable, CaseIterable {
    case hevc, h264
}

public struct PixelSize: Sendable, Hashable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}
