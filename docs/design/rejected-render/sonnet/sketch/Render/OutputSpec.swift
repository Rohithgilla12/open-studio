public import Timeline

/// What file comes out, and the canvas the preview draws. A value, so a preset is data and the
/// exporter has no preset-specific code.
public struct OutputSpec: Sendable, Hashable, Codable {
    /// Even width and height, enforced by the initialiser (4:2:0 needs them).
    public let canvas: PixelSize
    public let frameRate: FrameRate
    public let codec: OutputCodec
    public let bitsPerSecond: Int

    public enum FrameRate: Int, Sendable, Codable, CaseIterable { case fps30 = 30, fps60 = 60 }
    public enum OutputCodec: String, Sendable, Codable, CaseIterable { case hevc, h264 }

    public init(canvas: PixelSize, frameRate: FrameRate, codec: OutputCodec, bitsPerSecond: Int) {
        fatalError("not implemented")
    }

    public static func p1080(_ fps: FrameRate, codec: OutputCodec = .hevc) -> OutputSpec { fatalError("not implemented") }
    public static func uhd4k(_ fps: FrameRate = .fps60, codec: OutputCodec = .hevc) -> OutputSpec { fatalError("not implemented") }

    /// The canvas at which an unzoomed screen is 1:1 with the recorded pixels: frame / (1 - 2 * padding),
    /// rounded to even. Text stays pixel exact at camera scale 1. It depends on the style, so it is a function.
    public static func native(for source: SourceRecording, style: Style, _ fps: FrameRate = .fps60) -> OutputSpec {
        fatalError("not implemented")
    }

    /// Preview canvas: same aspect as `self`, long side `longSide`. The single place that picks preview size.
    public func previewCanvas(longSide: Int = 1920) -> PixelSize { fatalError("not implemented") }
}

public struct PixelSize: Sendable, Hashable, Codable {
    public let width: Int
    public let height: Int
}
