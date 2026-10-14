import Foundation
import Timeline

/// What an export writes, and the size the preview renders at. The preview always renders at the
/// selected format's canvas, so what plays is what exports.
public struct OutputFormat: Sendable, Hashable, Codable {
    public var size: CanvasPreset
    public var frameRate: FrameRate
    public var codec: Codec

    public init(size: CanvasPreset, frameRate: FrameRate, codec: Codec) {
        self.size = size
        self.frameRate = frameRate
        self.codec = codec
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
        case .hd1080: return PixelSize(width: 1920, height: 1080)
        case .uhd2160: return PixelSize(width: 3840, height: 2160)
        case .native:
            let grow = 1 / max(1 - 2 * padding, 0.05)
            return PixelSize(width: Self.even(source.width * grow), height: Self.even(source.height * grow))
        }
    }

    private static func even(_ value: Double) -> Int { Int(value.rounded()) & ~1 }
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
