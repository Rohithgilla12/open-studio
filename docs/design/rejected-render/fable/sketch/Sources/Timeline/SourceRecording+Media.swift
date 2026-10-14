import Foundation
internal import RecordingFormat

// Proposed addition to Sources/Timeline/SourceRecording.swift. Timeline already tells callers where
// the take lives (`directory`) and where each cursor PNG is (`relativePath`), so the movie URLs
// belong beside them: one place describes what files make up a take, and Render never imports
// RecordingFormat. Timeline still never opens media.

extension SourceRecording {
    /// The media files of the take. Resolved from the manifest, never probed.
    public struct Media: Sendable, Hashable {
        /// Fragmented QuickTime, HEVC or H.264, `frameSize` pixels, variable frame rate, cursor hidden.
        public let screen: URL
        /// Present only when the take was recorded with a microphone. AAC, same clock as `screen`.
        public let microphone: URL?
    }

    /// Built in `init(_ metadata:)` from `RecordingLayout`; `microphone` is nil when `!hasMicrophone`.
    public var media: Media { fatalError("not implemented") }

    /// Absolute URL of a declared cursor image.
    public func cursorImageURL(_ id: CursorImageID) -> URL? {
        // TODO: cursorImages[id].map { directory.appending(path: $0.relativePath) }
        fatalError("not implemented")
    }
}
