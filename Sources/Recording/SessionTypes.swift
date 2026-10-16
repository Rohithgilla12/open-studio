public import CoreGraphics
public import Foundation

public struct FinishedRecording: Sendable, Equatable {
    public let directory: URL
    public let duration: Duration
    public let hasMicrophone: Bool
    public let termination: Termination

    public init(directory: URL, duration: Duration, hasMicrophone: Bool, termination: Termination) {
        self.directory = directory
        self.duration = duration
        self.hasMicrophone = hasMicrophone
        self.termination = termination
    }
}

public enum Termination: Sendable, Equatable {
    case userStopped
    case durationReached
    /// ScreenCaptureKit stopped the stream (display unplugged, permission revoked mid-take, writer
    /// failure). Everything up to the failure is kept.
    case streamFailed(String)
    /// The recorder died and `recover(at:)` finalized the directory. The message lists anything lost.
    case recovered(String?)
    /// `stop()` could not finalize cleanly. The directory is readable and `recover(at:)` finishes it.
    case finalizationFailed(String)
}

public enum RecordingUpdate: Sendable, Equatable {
    case progress(RecordingProgress)
    case warning(RecordingWarning)
    case ended(FinishedRecording)
}

public struct RecordingProgress: Sendable, Equatable {
    public let mediaTime: Duration
    public let framesWritten: Int
    public let eventsWritten: Int

    public init(mediaTime: Duration, framesWritten: Int, eventsWritten: Int) {
        self.mediaTime = mediaTime
        self.framesWritten = framesWritten
        self.eventsWritten = eventsWritten
    }
}

public enum RecordingWarning: Sendable, Equatable {
    /// The microphone track ends early. Screen and events continue.
    case microphoneLost(at: Duration, String)
    /// The system disabled the event tap and the recorder re-enabled it. Input in the gap is missing.
    case inputTapReenabled(at: Duration)
    case framesDropped(count: Int)
    /// A mid-take warning could not be saved to the manifest. The final manifest at stop still
    /// carries it, but a crash before then loses it.
    case manifestWriteFailed(String)
}

public enum RecordingError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingPermissions([Permission])
    case displayNotFound(DisplaySelection)
    /// The area does not overlap its display.
    case areaOutsideDisplay
    /// The area, after clipping to its display, is narrower or shorter than
    /// `CaptureTarget.minimumAreaPixels`. The size is in screen pixels.
    case areaTooSmall(width: Int, height: Int)
    /// The window closed, or left the screen, before recording started.
    case windowNotFound(CGWindowID)
    case microphoneNotFound(MicrophoneSelection)
    case outputDirectoryUnwritable(URL, String)
    case captureFailedToStart(String)
    /// The stream started but no complete frame arrived within the start timeout.
    case noFramesDelivered

    public var description: String {
        switch self {
        case .missingPermissions(let permissions):
            let panes = permissions.map { "\($0.description) (\($0.settingsURL.absoluteString))" }.joined(separator: ", ")
            return "missing permissions: \(panes). Grant them to \(Permissions.responsibleProcess), which owns this process's grants."
        case .displayNotFound(let selection):
            return "display not found: \(selection)"
        case .areaOutsideDisplay:
            return "the area does not overlap its display"
        case .areaTooSmall(let width, let height):
            return "the area is \(width)x\(height) px; each side must be at least \(CaptureTarget.minimumAreaPixels) px"
        case .windowNotFound(let id):
            return "window \(id) is not on screen"
        case .microphoneNotFound(let selection):
            return "microphone not found: \(selection)"
        case .outputDirectoryUnwritable(let url, let detail):
            return "cannot write recording under \(url.path): \(detail)"
        case .captureFailedToStart(let detail):
            return "capture failed to start: \(detail)"
        case .noFramesDelivered:
            return "the stream started but delivered no complete frame"
        }
    }
}

public enum RecoveryError: Error, Sendable, Equatable, CustomStringConvertible {
    case stillRecording
    case nothingRecorded
    case notARecording(URL)
    case unsupportedVersion(found: Int)
    case unreadable(String)

    public var description: String {
        switch self {
        case .stillRecording: "a live recorder holds the directory lock"
        case .nothingRecorded: "the recorder died before its first frame; there is nothing to keep"
        case .notARecording(let url): "not a recording directory: \(url.path)"
        case .unsupportedVersion(let found): "recording format version \(found) is newer than this reader"
        case .unreadable(let detail): "recording unreadable: \(detail)"
        }
    }
}
