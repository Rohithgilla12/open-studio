import Foundation
import Timeline

/// What the export writes. The preview renders with the same format so pixels match.
public struct OutputFormat: Sendable, Hashable, Codable {
    public var size: SizePreset = .p1080
    public var frameRate: FrameRate = .fps60
    public var codec: OutputCodec = .h264

    public init() {}
    public static let `default` = OutputFormat()

    /// Pixel size for a given source. `.native` is the source frame size; the padded canvas keeps
    /// that size and the screen content shrinks inside it.
    public func pixelSize(for source: SourceRecording) -> PixelSize {
        // TODO: .native -> source.frameSize; .p1080 -> 1920x1080 (or 1080x1920 if the source is portrait)
        fatalError("not implemented")
    }
}

public enum SizePreset: String, Sendable, Hashable, Codable, CaseIterable {
    case p1080
    case native
}

public enum FrameRate: Int, Sendable, Hashable, Codable, CaseIterable {
    case fps30 = 30
    case fps60 = 60
}

public enum OutputCodec: String, Sendable, Hashable, Codable, CaseIterable {
    case h264
    case hevc
}

/// Whole pixels, even on both axes so every codec accepts it.
public struct PixelSize: Sendable, Hashable, Codable {
    public let width: Int
    public let height: Int

    /// Rounds each side down to an even number and refuses zero.
    public init?(width: Int, height: Int) {
        guard width >= 2, height >= 2 else { return nil }
        self.width = width & ~1
        self.height = height & ~1
    }
}
