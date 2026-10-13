import Foundation

/// `manifest.json`. Written before capture starts and never modified, so a crash at any
/// later point leaves it intact.
public struct Manifest: Codable, Sendable, Equatable {
    public var formatVersion: Int
    public var recordingID: UUID
    /// Wall-clock time, informational only. Never used for alignment.
    public var createdAt: Date
    public var clock: ClockDescriptor
    public var display: DisplayDescriptor
    public var video: VideoDescriptor
    public var audio: AudioDescriptor?
    public var input: InputDescriptor

    public init(
        formatVersion: Int = RecordingFormatVersion.current,
        recordingID: UUID,
        createdAt: Date,
        clock: ClockDescriptor,
        display: DisplayDescriptor,
        video: VideoDescriptor,
        audio: AudioDescriptor?,
        input: InputDescriptor
    ) {
        fatalError("not implemented")
    }
}

/// The one clock. Every `t` in `events.ndjson`, and `firstVideoFrameOffsetNanos` in
/// `timebase.json`, is nanoseconds after `startHostNanos` on this clock.
///
/// `startHostNanos` is sampled once, before any producer starts, so producers never
/// coordinate on time: each stamps its own events from the host clock and the reader
/// re-bases everything on the first video frame.
public struct ClockDescriptor: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// `mach_absolute_time` scaled to nanoseconds (`CMClockGetHostTimeClock`).
        /// ScreenCaptureKit sample-buffer PTS and `CGEvent.timestamp` both derive from it.
        case machHostTime
    }
    public var kind: Kind
    public var startHostNanos: UInt64
}

public struct DisplayDescriptor: Codable, Sendable, Equatable {
    public var displayID: UInt32
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var pointWidth: Double
    public var pointHeight: Double
    public var scaleFactor: Double
    /// Top-left of this display in CoreGraphics global points (origin at the main
    /// display's top-left, y down). Event coordinates are recorded in that space.
    public var originX: Double
    public var originY: Double
    public var refreshRate: Double?
}

public struct VideoDescriptor: Codable, Sendable, Equatable {
    public enum Codec: String, Codable, Sendable { case hevc, h264 }
    public var fileName: String
    public var codec: Codec
    public var frameRate: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Fragment cadence of `display.mov`. Bounds how much video a crash can lose.
    public var fragmentIntervalNanos: Int64
    public var showsCursor: Bool
}

/// Microphone audio is a second track inside `display.mov`, captured by the same
/// SCStream so it shares the host clock. No separate audio file exists.
public struct AudioDescriptor: Codable, Sendable, Equatable {
    public var microphoneDeviceID: String?
    public var sampleRate: Int
    public var channels: Int
}

public struct InputDescriptor: Codable, Sendable, Equatable {
    /// Off by default. Typing detection only needs key timing; key codes are a privacy
    /// decision the user opts into.
    public var recordsKeyCodes: Bool
    public var cursorSamplingHz: Int
}

/// `timebase.json`. Written exactly once, when the first video frame is appended.
/// Recording time zero is this frame. Until it exists the directory is not loadable.
public struct Timebase: Codable, Sendable, Equatable {
    public var firstVideoFrameOffsetNanos: Int64
    /// The PTS handed to `AVAssetWriter.startSession(atSourceTime:)`, kept for
    /// cross-checking against the movie file.
    public var firstVideoFramePTS: RationalTime
}

public struct RationalTime: Codable, Sendable, Equatable {
    public var value: Int64
    public var timescale: Int32
}

/// `finish.json`. Written on a clean stop. Missing means the recorder died; the reader
/// then takes duration from the movie and marks the take as recovered.
public struct Finish: Codable, Sendable, Equatable {
    public enum Outcome: Codable, Sendable, Equatable {
        case completed
        case failed(message: String)
    }
    public var stoppedAt: Date
    public var stopOffsetNanos: Int64
    public var durationNanos: Int64
    public var videoFrames: Int
    public var droppedFrames: Int
    public var eventCount: Int
    public var outcome: Outcome
}
