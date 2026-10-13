public import Foundation

enum AtomicFile {
    static func replace(_ url: URL, with data: Data) throws {
        let temporary = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        try data.write(to: temporary, options: .withoutOverwriting)
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}

extension RecordingLayout {
    /// Stores a cursor PNG under its content address and returns the declaration to append to the
    /// event log. The file is complete before this returns, so a line written afterwards never
    /// references a missing image. Storing the same cursor again is a no-op.
    public func storeCursorImage(png: Data, hotspot: WirePoint, size: WireSize) throws -> CursorImageDeclaration {
        let id = CursorImageID(png: png, hotspot: hotspot)
        let url = cursorImage(id)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: cursors, withIntermediateDirectories: true)
            try AtomicFile.replace(url, with: png)
        }
        return CursorImageDeclaration(id: id, hotspot: hotspot, size: size)
    }
}
