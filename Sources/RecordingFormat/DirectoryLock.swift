import Foundation
import Synchronization

/// The live recorder's exclusive flock(2) on `.lock`, held for the whole take.
///
/// The kernel drops a flock when its holder dies, so it cannot go stale.
/// flock belongs to the open file description, so a second open(2) of `.lock` in the same process
/// contends with it exactly as another process would.
public final class DirectoryLock: Sendable {
    private let descriptor: Mutex<Int32?>

    private init(descriptor: Int32) { self.descriptor = Mutex(descriptor) }

    /// Non-blocking. Returns nil when another holder has the lock. Creates `.lock` if needed.
    public static func acquire(in layout: RecordingLayout) throws -> DirectoryLock? {
        let fd = open(layout.lock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return DirectoryLock(descriptor: fd)
    }

    /// Idempotent.
    public func release() {
        descriptor.withLock { fd in
            if let open = fd { close(open) }
            fd = nil
        }
    }

    deinit { release() }

    /// Takes a shared lock and drops it at once. True when an exclusive holder refuses it. For that
    /// instant, an `acquire` fails as if a recorder held the lock.
    static func sharedLockRefused(in layout: RecordingLayout) throws(FormatError) -> Bool {
        let fd = open(layout.lock.path, O_RDONLY | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return false }
            throw .lockUnreadable(detail: String(cString: strerror(errno)))
        }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 { return false }
        if errno == EWOULDBLOCK { return true }
        throw .lockUnreadable(detail: String(cString: strerror(errno)))
    }
}
