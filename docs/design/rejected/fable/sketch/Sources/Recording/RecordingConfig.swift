import CoreGraphics
import Foundation
import RecordingFormat

public struct RecordingConfig: Sendable, Equatable {
    public enum DisplaySelection: Sendable, Equatable {
        case main
        case id(CGDirectDisplayID)
    }

    public enum MicrophoneSelection: Sendable, Equatable {
        case none
        case systemDefault
        case device(uniqueID: String)
    }

    /// Created by `RecordingSession.start`. Must not exist, or must be an empty directory.
    /// Conventionally named `<yyyyMMdd-HHmmss>.osrec`.
    public var outputDirectory: URL
    public var display: DisplaySelection = .main
    public var frameRate: Int = 60
    public var codec: VideoDescriptor.Codec = .hevc
    public var microphone: MicrophoneSelection = .none
    public var recordsKeyCodes = false
    public var cursorSamplingHz = 30
    /// Shorter loses less on a crash and costs a little bitrate for the extra `moof` boxes.
    public var fragmentInterval: Duration = .seconds(1)
    /// How long `start` waits for the first video frame before failing with `.noFrames`.
    public var firstFrameTimeout: Duration = .seconds(3)

    public init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
    }
}

public struct RecordingResult: Sendable, Equatable {
    public var directory: URL
    public var duration: Duration
    public var videoFrames: Int
    public var droppedFrames: Int
    public var eventCount: Int
}

public enum RecordingError: Error, Sendable, Equatable {
    case permissionsMissing([Permission])
    case displayNotFound
    case outputDirectoryNotEmpty(URL)
    case cannotCreateDirectory(URL, reason: String)
    /// SCStream delivered no frame within `firstFrameTimeout`. Typical cause: Screen
    /// Recording was granted but the process has not relaunched since.
    case noFrames
    case captureFailed(reason: String)
    case writerFailed(reason: String)
    case invalidTransition(from: String, action: String)
}
