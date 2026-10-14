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
    public static let native = OutputFormat(size: .native, frameRate: .fps60, codec: .hevc)

    /// Even width and height, because 4:2:0 encoders reject odd sizes.
    public func canvasSize(for source: Size) -> PixelSize {
        switch size {
        case .hd1080: PixelSize(width: 1920, height: 1080)
        case .uhd2160: PixelSize(width: 3840, height: 2160)
        case .native: PixelSize(width: Int(source.width) & ~1, height: Int(source.height) & ~1)
        }
    }
}

public enum CanvasPreset: String, Sendable, Hashable, Codable, CaseIterable {
    /// 1920 x 1080.
    case hd1080
    /// 3840 x 2160.
    case uhd2160
    /// The source's pixel size, so a 3456 x 2234 take exports at 3456 x 2234 with the source's aspect.
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
}
