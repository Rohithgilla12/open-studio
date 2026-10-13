public import Foundation

/// `recording.json`.
///
/// Clock: every time in the directory is a `MediaTime`, integer microseconds since the first
/// complete screen frame. The microphone writer starts its session at the same host time, so
/// microphone media time is the same clock. The recorder converts events from host time before
/// writing them, so readers never see host time.
///
/// Space: every coordinate is in screen video pixels, origin top-left of the captured display,
/// y down. A point outside `[0, pixelWidth) × [0, pixelHeight)` means the pointer was on another
/// display.
public struct WireManifest: Sendable, Equatable {
    public var id: RecordingID
    /// Encoded as ISO 8601 with milliseconds, so it round-trips at millisecond precision.
    public var createdAt: Date
    public var recorder: WireRecorderInfo
    public var clock: WireClock
    public var display: WireDisplay
    public var screen: WireScreen
    public var microphone: WireMicrophone?
    /// Degradations that did not end the take. Written when they happen, so they survive a crash.
    public var warnings: [ManifestWarning]
    public var status: ManifestStatus

    public init(
        id: RecordingID, createdAt: Date, recorder: WireRecorderInfo, clock: WireClock,
        display: WireDisplay, screen: WireScreen, microphone: WireMicrophone?,
        warnings: [ManifestWarning] = [], status: ManifestStatus = .recording
    ) {
        self.id = id
        self.createdAt = createdAt
        self.recorder = recorder
        self.clock = clock
        self.display = display
        self.screen = screen
        self.microphone = microphone
        self.warnings = warnings
        self.status = status
    }
}

/// The only question a reader asks of the status is whether the directory is complete. How the
/// take ended exists only once it is.
public enum ManifestStatus: Sendable, Equatable {
    case recording
    case finalized(duration: MediaTime, termination: WireTermination)
}

public enum WireTermination: Sendable, Equatable {
    case userStopped
    case durationReached
    /// ScreenCaptureKit stopped the stream. Everything up to the failure is kept.
    case streamFailed(message: String)
    /// The recorder died and recovery finalized the directory. The message lists anything lost.
    case recovered(message: String?)
}

public enum ManifestWarning: Sendable, Equatable {
    /// The microphone track ends at `at`. Screen and events continue.
    case microphoneLost(at: MediaTime, message: String)
    /// The system disabled the event tap and the recorder re-enabled it at `at`. Input in the gap
    /// is missing.
    case inputTapReenabled(at: MediaTime)
}

public struct WireRecorderInfo: Sendable, Equatable, Codable {
    public var name: String
    public var version: String
    public var osVersion: String

    public init(name: String, version: String, osVersion: String) {
        self.name = name
        self.version = version
        self.osVersion = osVersion
    }
}

/// Encoded with the constant `unit` and `origin` of format version 1, so a person reading the file
/// needs no spec. Decoding rejects any other unit or origin.
public struct WireClock: Sendable, Equatable {
    /// Host time of media time 0, in nanoseconds on `CLOCK_UPTIME_RAW`, the clock of SCStream PTS
    /// and `CGEvent.timestamp`. Diagnostics only: no reader needs it.
    public var originHostTimeNanos: UInt64

    public init(originHostTimeNanos: UInt64) { self.originHostTimeNanos = originHostTimeNanos }

    static let unit = "microseconds"
    static let origin = "first-screen-frame"
}

public struct WireDisplay: Sendable, Equatable, Codable {
    public var displayID: UInt32
    public var name: String
    /// The display frame in global points at record time.
    public var pointFrame: WireRect
    public var refreshRate: Double

    public init(displayID: UInt32, name: String, pointFrame: WireRect, refreshRate: Double) {
        self.displayID = displayID
        self.name = name
        self.pointFrame = pointFrame
        self.refreshRate = refreshRate
    }
}

/// Encoded as `[x, y, width, height]`.
public struct WireRect: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        guard c.count == 4 else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "a rect is [x, y, width, height]")
        }
        self.init(
            x: try c.decode(Double.self), y: try c.decode(Double.self),
            width: try c.decode(Double.self), height: try c.decode(Double.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(contentsOf: [x, y, width, height])
    }
}

public struct WireScreen: Sendable, Equatable, Codable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var codec: WireCodec
    /// Upper bound. ScreenCaptureKit delivers frames only when content changes, so the movie is
    /// variable frame rate.
    public var maxFrameRate: Int

    public init(pixelWidth: Int, pixelHeight: Int, codec: WireCodec, maxFrameRate: Int) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.codec = codec
        self.maxFrameRate = maxFrameRate
    }
}

public enum WireCodec: String, Sendable, Equatable, Codable {
    case hevc, h264
}

public struct WireMicrophone: Sendable, Equatable, Codable {
    public var deviceName: String
    public var sampleRate: Double
    public var channelCount: Int

    public init(deviceName: String, sampleRate: Double, channelCount: Int) {
        self.deviceName = deviceName
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

extension WireManifest {
    /// Decodes and applies the version gate. The gate runs before the rest of the manifest is
    /// read, so a newer manifest reports its version rather than a missing key.
    public static func decode(_ data: Data) throws(FormatError) -> WireManifest {
        do {
            return try JSONDecoder().decode(WireManifest.self, from: data)
        } catch let error as FormatError {
            throw error
        } catch {
            throw .manifestUnreadable(detail: String(describing: error))
        }
    }

    /// Sorted keys, so equal manifests give equal bytes.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Writes a temporary file beside `recording.json` and renames it into place. rename(2) is
    /// atomic within a volume, so a crash or a concurrent reader sees the old manifest or the new
    /// one, never a torn file.
    public func write(to layout: RecordingLayout) throws {
        try AtomicFile.replace(layout.manifest, with: encoded())
    }
}

private enum ManifestKey: String, CodingKey {
    case format, formatVersion, id, createdAt, recorder, clock, display, screen, microphone, warnings
    case status, durationMicros, termination
}

private enum ClockKey: String, CodingKey {
    case unit, origin, originHostTimeNanos
}

private enum TaggedKey: String, CodingKey {
    case reason, kind, message, at
}

private enum StatusTag: String, Codable {
    case recording, finalized
}

private enum ReasonTag: String, Codable {
    case userStopped, durationReached, streamFailed, recovered
}

private enum WarningTag: String, Codable {
    case microphoneLost, inputTapReenabled
}

private let createdAtStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

extension WireManifest: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: ManifestKey.self)
        let format = try c.decode(String.self, forKey: .format)
        guard format == FormatVersion.identifier else { throw FormatError.wrongFormat(found: format) }
        let version = try c.decode(Int.self, forKey: .formatVersion)
        guard (1...FormatVersion.current).contains(version) else {
            throw FormatError.unsupportedVersion(found: version, supported: FormatVersion.current)
        }

        let createdAt = try c.decode(String.self, forKey: .createdAt)
        guard let date = try? createdAtStyle.parse(createdAt) else {
            throw DecodingError.dataCorruptedError(
                forKey: .createdAt, in: c, debugDescription: "not an ISO 8601 date: \(createdAt)")
        }

        let clock = try c.nestedContainer(keyedBy: ClockKey.self, forKey: .clock)
        let unit = try clock.decode(String.self, forKey: .unit)
        let origin = try clock.decode(String.self, forKey: .origin)
        guard unit == WireClock.unit, origin == WireClock.origin else {
            throw DecodingError.dataCorruptedError(
                forKey: .clock, in: c, debugDescription: "clock must be \(WireClock.unit) since \(WireClock.origin)")
        }

        let status: ManifestStatus
        switch try c.decode(StatusTag.self, forKey: .status) {
        case .recording:
            status = .recording
        case .finalized:
            status = .finalized(
                duration: try c.decode(MediaTime.self, forKey: .durationMicros),
                termination: try c.decode(WireTermination.self, forKey: .termination))
        }

        self.init(
            id: try c.decode(RecordingID.self, forKey: .id),
            createdAt: date,
            recorder: try c.decode(WireRecorderInfo.self, forKey: .recorder),
            clock: WireClock(originHostTimeNanos: try clock.decode(UInt64.self, forKey: .originHostTimeNanos)),
            display: try c.decode(WireDisplay.self, forKey: .display),
            screen: try c.decode(WireScreen.self, forKey: .screen),
            microphone: try c.decodeIfPresent(WireMicrophone.self, forKey: .microphone),
            warnings: try c.decodeIfPresent([TolerantWarning].self, forKey: .warnings)?.compactMap(\.warning) ?? [],
            status: status)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: ManifestKey.self)
        try c.encode(FormatVersion.identifier, forKey: .format)
        try c.encode(FormatVersion.current, forKey: .formatVersion)
        try c.encode(id, forKey: .id)
        try c.encode(createdAt.formatted(createdAtStyle), forKey: .createdAt)
        try c.encode(recorder, forKey: .recorder)
        var clockContainer = c.nestedContainer(keyedBy: ClockKey.self, forKey: .clock)
        try clockContainer.encode(WireClock.unit, forKey: .unit)
        try clockContainer.encode(WireClock.origin, forKey: .origin)
        try clockContainer.encode(clock.originHostTimeNanos, forKey: .originHostTimeNanos)
        try c.encode(display, forKey: .display)
        try c.encode(screen, forKey: .screen)
        try c.encodeIfPresent(microphone, forKey: .microphone)
        try c.encode(warnings, forKey: .warnings)
        switch status {
        case .recording:
            try c.encode(StatusTag.recording, forKey: .status)
        case .finalized(let duration, let termination):
            try c.encode(StatusTag.finalized, forKey: .status)
            try c.encode(duration, forKey: .durationMicros)
            try c.encode(termination, forKey: .termination)
        }
    }
}

extension WireTermination: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: TaggedKey.self)
        switch try c.decode(ReasonTag.self, forKey: .reason) {
        case .userStopped: self = .userStopped
        case .durationReached: self = .durationReached
        case .streamFailed: self = .streamFailed(message: try c.decode(String.self, forKey: .message))
        case .recovered: self = .recovered(message: try c.decodeIfPresent(String.self, forKey: .message))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: TaggedKey.self)
        switch self {
        case .userStopped:
            try c.encode(ReasonTag.userStopped, forKey: .reason)
        case .durationReached:
            try c.encode(ReasonTag.durationReached, forKey: .reason)
        case .streamFailed(let message):
            try c.encode(ReasonTag.streamFailed, forKey: .reason)
            try c.encode(message, forKey: .message)
        case .recovered(let message):
            try c.encode(ReasonTag.recovered, forKey: .reason)
            try c.encodeIfPresent(message, forKey: .message)
        }
    }
}

extension ManifestWarning: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: TaggedKey.self)
        switch self {
        case .microphoneLost(let at, let message):
            try c.encode(WarningTag.microphoneLost, forKey: .kind)
            try c.encode(at, forKey: .at)
            try c.encode(message, forKey: .message)
        case .inputTapReenabled(let at):
            try c.encode(WarningTag.inputTapReenabled, forKey: .kind)
            try c.encode(at, forKey: .at)
        }
    }
}

/// A warning kind added by a newer recorder decodes to nil and is dropped, so an additive change
/// does not make the whole manifest unreadable.
private struct TolerantWarning: Decodable {
    let warning: ManifestWarning?

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: TaggedKey.self)
        switch WarningTag(rawValue: try c.decode(String.self, forKey: .kind)) {
        case .microphoneLost:
            warning = .microphoneLost(
                at: try c.decode(MediaTime.self, forKey: .at), message: try c.decode(String.self, forKey: .message))
        case .inputTapReenabled:
            warning = .inputTapReenabled(at: try c.decode(MediaTime.self, forKey: .at))
        case nil:
            warning = nil
        }
    }
}
