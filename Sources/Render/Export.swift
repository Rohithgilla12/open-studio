import Foundation
import Timeline

public struct ExportProgress: Sendable, Hashable {
    public let framesWritten: Int
    public let framesTotal: Int
    public var fraction: Double { framesTotal > 0 ? Double(framesWritten) / Double(framesTotal) : 0 }
}

public struct ExportReport: Sendable, Hashable {
    public let destination: URL
    public let frames: Int
    public let duration: RecordingTime
    public let wallSeconds: Double
    public let bytes: Int64
    /// Media seconds per wall second. The brief requires at least 1 for 4K60.
    public var realTimeFactor: Double { duration.seconds / wallSeconds }
}

public enum ExportError: Error, Sendable, Equatable {
    case render(RenderError)
    case readerFailed(String)
    case writerFailed(String)
    case destinationUnwritable(String)
    case cancelled
}
