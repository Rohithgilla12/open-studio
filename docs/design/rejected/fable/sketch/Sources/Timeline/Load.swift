import Foundation
import RecordingFormat

/// The only file in Timeline that reads the file system. It reads four files into
/// memory and hands them to the pure `Take.init`; all validation happens there.
extension Take {
    public static func load(from directory: URL) throws(TakeLoadError) -> Take {
        // TODO:
        // manifest = decode(manifest.json) or .missingFile
        // timebase = decode(timebase.json) or .neverStarted
        // finish   = decode(finish.json) if present
        // events   = NDJSON.decode(Data(contentsOf: events.ndjson))
        // return try Take(directory:, manifest:, timebase:, finish:, events:)
        fatalError("not implemented")
    }
}
