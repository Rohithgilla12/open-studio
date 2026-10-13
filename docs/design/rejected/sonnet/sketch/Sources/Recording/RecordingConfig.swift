import Foundation

/// Everything is Codable and Sendable so the same value can cross an XPC boundary later
/// without changing the public API. The CLI builds it from flags, the app from settings.
public struct RecordingConfig: Codable, Sendable, Equatable {
    /// Parent directory. The session creates `<yyyymmdd-hhmmss>-<4 hex>.osrec` inside it.
    public var outputDirectory: URL
    public var display: DisplaySelection = .main
    public var framesPerSecond: Int = 60
    public var video: VideoEncoding = .init()
    public var microphone: MicrophoneSelection = .off
    /// Stops itself after this long. Nil records until stop() is called.
    public var maximumDuration: Duration?
    public var durability: Durability = .init()

    public init(outputDirectory: URL) { self.outputDirectory = outputDirectory }

    public enum DisplaySelection: Codable, Sendable, Equatable {
        case main
        case id(UInt32)
    }

    public enum MicrophoneSelection: Codable, Sendable, Equatable {
        case off
        case systemDefault
        case device(uniqueID: String)
    }

    public struct VideoEncoding: Codable, Sendable, Equatable {
        public enum Codec: String, Codable, Sendable { case hevc, h264 }
        public var codec: Codec = .hevc
        /// Nil lets VideoToolbox choose from resolution and frame rate.
        public var megabitsPerSecond: Int?
        /// Short GOPs keep scrubbing in the editor cheap. SS uses 2 x refresh rate; one second is our default.
        public var keyframeInterval: Duration = .seconds(1)
        public init() {}
    }

    /// How much a crash can cost. Both knobs trade write amplification for lost tail.
    public struct Durability: Codable, Sendable, Equatable {
        /// AVAssetWriter.movieFragmentInterval. At most this much video is lost on a crash.
        public var videoFragmentInterval: Duration = .seconds(1)
        /// Event logs are buffered in memory and appended at this cadence.
        public var eventFlushInterval: Duration = .milliseconds(200)
        public init() {}
    }
}

public struct DisplayDescriptor: Sendable, Equatable, Identifiable {
    public var id: UInt32
    public var name: String
    public var pointSize: CGSize
    public var backingScale: Double
    public var isMain: Bool
}
