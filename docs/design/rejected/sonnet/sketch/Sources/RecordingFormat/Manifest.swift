import Foundation

/// manifest.json. Written atomically (write temp, fsync, rename) at start, again when the
/// origin is known, and a last time at finalisation. Never appended to.
public struct RecordingManifest: Codable, Sendable, Equatable {
    /// Major version only. The reader accepts equal majors and ignores unknown keys,
    /// so additive changes never bump it.
    public var formatVersion: Int
    public var id: UUID
    /// Wall clock, for humans and file browsers. Never used for alignment.
    public var createdAt: Date
    public var producer: Producer
    public var status: Status
    public var clock: Clock
    public var display: Display
    public var streams: Streams
    /// Nil until finalisation or recovery. The reader never guesses a duration.
    public var finalisation: Finalisation?
    public var warnings: [Warning]

    public static let currentFormatVersion = 1

    public enum Status: String, Codable, Sendable {
        case recording
        case finalized
    }

    public struct Producer: Codable, Sendable, Equatable {
        public var name: String
        public var version: String
        public var osVersion: String
    }

    public struct Clock: Codable, Sendable, Equatable {
        /// Fixed to "host-time-ns" in v1. A field rather than an assumption, so a reader
        /// can refuse a recording made on a clock it does not understand.
        public var kind: String
        /// Host time of the first video frame. Nil until that frame arrives.
        public var origin: HostTime?
    }

    public struct Display: Codable, Sendable, Equatable {
        public var displayID: UInt32
        /// Size in points. Input coordinates are in this space, top-left origin, display-local.
        public var pointSize: Size
        public var backingScale: Double
        public var pixelSize: Size
        public var refreshRate: Double
    }

    public struct Size: Codable, Sendable, Equatable {
        public var width: Double
        public var height: Double
    }

    public struct Streams: Codable, Sendable, Equatable {
        public var video: VideoStream
        public var microphone: AudioStream?
        public var input: LogStream
        public var cursor: CursorStreams
    }

    public struct VideoStream: Codable, Sendable, Equatable {
        /// Path relative to the recording directory.
        public var file: String
        public var codec: String
        public var pixelSize: Size
        public var nominalFrameRate: Double
        /// True when frames arrive only on screen change (ScreenCaptureKit behaviour).
        public var isVariableFrameRate: Bool
    }

    public struct AudioStream: Codable, Sendable, Equatable {
        public var file: String
        public var codec: String
        public var sampleRate: Double
        public var channels: Int
        public var deviceName: String
    }

    public struct LogStream: Codable, Sendable, Equatable {
        public var file: String
        /// Schema version of the line format in this file. Lines carry a "k" discriminator.
        public var schema: Int
    }

    public struct CursorStreams: Codable, Sendable, Equatable {
        public var changes: LogStream
        public var catalog: LogStream
        public var imageDirectory: String
    }

    public struct Finalisation: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case clean, recovered }
        public var kind: Kind
        public var duration: RecordingTime
        public var finalisedAt: Date
        public var stats: Stats
    }

    public struct Stats: Codable, Sendable, Equatable {
        public var videoFrames: Int
        public var droppedVideoFrames: Int
        public var inputEvents: Int
        public var cursorImages: Int
        /// Event-log lines discarded because they were torn or malformed.
        public var discardedLines: Int
    }

    public struct Warning: Codable, Sendable, Equatable {
        public var code: String
        public var message: String
        public var at: RecordingTime?
    }
}
