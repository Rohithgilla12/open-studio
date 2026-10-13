import Foundation
import RecordingFormat

public enum RecordingError: Error, Sendable, Equatable, Codable {
    case permissionsMissing([Permission])
    case displayNotFound(UInt32)
    case outputDirectoryUnusable(String)
    case captureFailed(String)
    case writerFailed(stream: String, message: String)
    case alreadyStopped
}

/// A part of the recording that failed while the rest carried on. Recorded in the manifest.
public enum Degradation: Sendable, Equatable, Codable {
    case inputTapLost(at: RecordingTime)
    case microphoneLost(at: RecordingTime)
    case cursorWatcherLost(at: RecordingTime)
}
