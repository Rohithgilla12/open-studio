public import Foundation
internal import RecordingFormat

/// Addition to Sources/Timeline. The one public answer to "where are the media files", so Render and
/// the app never import RecordingFormat or spell a file name.
///
/// Timeline already owns `SourceRecording`, the validated domain view of the directory, and already
/// imports `RecordingLayout` internally. Putting the URLs here keeps `RecordingLayout` the only place
/// file names appear (the accepted packaging rule) without a new module or a second loader.
extension SourceRecording {
    public var media: SourceMedia { SourceMedia(layout: RecordingLayout(directory: directory), source: self) }
}

public struct SourceMedia: Sendable {
    let layout: RecordingLayout
    let source: SourceRecording

    public var screenVideo: URL { layout.screen }

    /// nil when the take has no microphone. Derived from the manifest, not from a file check, so a
    /// missing file in a take that claims one is a load-time error and not a silent drop.
    public var microphone: URL? { source.hasMicrophone ? layout.microphone : nil }

    /// nil for an id the take never declared (the renderer falls back to its built-in arrow).
    public func cursorImage(_ id: CursorImageID) -> URL? {
        source.cursorImages[id] == nil ? nil : source.directory.appending(path: source.cursorImages[id]!.relativePath)
    }
}
