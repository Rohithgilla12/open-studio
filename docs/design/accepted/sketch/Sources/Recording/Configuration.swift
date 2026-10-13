import CoreGraphics
import Foundation

/// What to record. Everything has a default except where the recording goes.
public struct RecordingConfiguration: Sendable, Equatable {
    public var display: DisplaySelection
    public var microphone: MicrophoneSelection
    /// Parent directory. The session creates `YYYYMMDD-HHMMSS.osrec` inside it.
    public var outputDirectory: URL
    /// Capped at the display's refresh rate.
    public var maxFrameRate: Int
    public var codec: VideoCodec
    /// The session stops itself with `.durationReached` after this much media time.
    public var maxDuration: Duration?

    public init(
        outputDirectory: URL,
        display: DisplaySelection = .main,
        microphone: MicrophoneSelection = .none,
        maxFrameRate: Int = 60,
        codec: VideoCodec = .hevc,
        maxDuration: Duration? = nil
    ) {
        fatalError("not implemented")
    }
}

public enum DisplaySelection: Sendable, Equatable {
    /// The display with the menu bar at the time `start` is called.
    case main
    case id(CGDirectDisplayID)
}

public enum MicrophoneSelection: Sendable, Equatable {
    case none
    case systemDefault
    /// `AVCaptureDevice.uniqueID`.
    case device(uniqueID: String)
}

public enum VideoCodec: String, Sendable, Equatable, CaseIterable {
    case hevc
    case h264
}

/// Read-only discovery for pickers and `osrec displays`.
public enum CaptureSources {
    public static func displays() async throws(RecordingError) -> [DisplayInfo] {
        fatalError("not implemented")
    }

    public static func microphones() -> [MicrophoneInfo] {
        fatalError("not implemented")
    }
}

public struct DisplayInfo: Sendable, Equatable, Identifiable {
    public let id: CGDirectDisplayID
    public let name: String
    public let pointSize: CGSize
    public let pixelSize: CGSize
    public let refreshRate: Double
    public let isMain: Bool
}

public struct MicrophoneInfo: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let isDefault: Bool
}
