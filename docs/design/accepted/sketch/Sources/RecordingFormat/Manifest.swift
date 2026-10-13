import Foundation

/// `recording.json`, format version 1.
///
/// Clock: every timestamp in the directory is integer microseconds of screen media time, where
/// 0 is the presentation time of the first complete screen frame. The microphone writer starts its
/// session at the same host time, so microphone media time is the same clock. Events are converted
/// from host time to this clock by the recorder before they are written; readers never see host time.
///
/// Space: every coordinate is in screen video pixels, origin top-left of the captured display,
/// y down. Cursor sizes and hotspots use the same space. Points outside
/// `[0, pixelWidth) x [0, pixelHeight)` mean the pointer was on another display.
public struct WireManifest: Codable, Sendable, Equatable {
    public var format: String
    public var formatVersion: Int
    public var id: UUID
    public var createdAt: Date
    public var recorder: WireRecorderInfo
    public var status: WireStatus
    public var clock: WireClock
    public var display: WireDisplay
    public var screen: WireScreen
    /// nil when the recording has no microphone track.
    public var microphone: WireMicrophone?
    /// Screen media duration. nil while `status == .recording`.
    public var durationMicros: Int64?
    /// nil while `status == .recording`.
    public var termination: WireTermination?

    public init(
        id: UUID, createdAt: Date, recorder: WireRecorderInfo, clock: WireClock,
        display: WireDisplay, screen: WireScreen, microphone: WireMicrophone?
    ) {
        fatalError("not implemented")
    }
}

/// Two states are enough: the only question a reader asks is "is this safe to read as a whole?".
/// How it ended lives in `termination`.
public enum WireStatus: String, Codable, Sendable {
    case recording
    case finalized
}

public struct WireRecorderInfo: Codable, Sendable, Equatable {
    public var name: String
    public var version: String
    public var osVersion: String
}

public struct WireClock: Codable, Sendable, Equatable {
    /// Always "microseconds" in version 1. Present so a human reading the file needs no spec.
    public var unit: String
    /// Always "first-screen-frame" in version 1.
    public var origin: String
    /// mach host time, in nanoseconds, of media time 0. Diagnostics only; no reader needs it.
    public var originHostTimeNanos: UInt64
}

public struct WireDisplay: Codable, Sendable, Equatable {
    public var displayID: UInt32
    public var name: String
    /// Display frame in global points at record time: [x, y, width, height].
    public var pointFrame: [Double]
    public var refreshRate: Double
}

public struct WireScreen: Codable, Sendable, Equatable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// "hevc" or "h264".
    public var codec: String
    /// Upper bound. ScreenCaptureKit only delivers frames when content changes, so the movie is
    /// variable frame rate.
    public var maxFrameRate: Int
}

public struct WireMicrophone: Codable, Sendable, Equatable {
    public var deviceName: String
    public var sampleRate: Double
    public var channelCount: Int
}

public struct WireTermination: Codable, Sendable, Equatable {
    public var reason: Reason
    /// Human-readable detail for `streamFailed` and `recovered`.
    public var message: String?

    public enum Reason: String, Codable, Sendable {
        case userStopped
        case durationReached
        case streamFailed
        case recovered
    }
}

extension WireManifest {
    /// Encodes with sorted keys and ISO 8601 dates, writes to a temporary file in the same directory,
    /// then renames over `recording.json`. rename(2) is atomic within a volume, so a crash leaves
    /// either the old manifest or the new one, never a torn file.
    public func writeAtomically(into directory: URL) throws {
        fatalError("not implemented")
    }
}
