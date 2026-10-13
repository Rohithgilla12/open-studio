import Foundation
import RecordingFormat

/// Owns manifest.json and the lock for the lifetime of a take. Only this type writes the manifest.
struct RecordingDirectoryWriter: ~Copyable {
    let layout: RecordingLayout
    private let lockDescriptor: Int32

    /// mkdir, open and flock the lock file, write manifest (status .recording, origin nil).
    static func create(in parent: URL, config: RecordingConfig, display: RecordingManifest.Display)
        throws(RecordingError) -> RecordingDirectoryWriter { fatalError("not implemented") }

    /// Atomic: write manifest.json.tmp, fsync, rename. A reader sees the old or the new file, never half.
    func update(_ change: (inout RecordingManifest) -> Void) throws(RecordingError) { fatalError("not implemented") }

    /// Finalise and release the lock. Consuming makes "write after finalise" a compile error.
    consuming func finalise(duration: RecordingTime, stats: RecordingManifest.Stats) throws(RecordingError) {
        fatalError("not implemented")
    }
}
