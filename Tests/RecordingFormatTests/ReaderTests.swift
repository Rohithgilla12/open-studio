import Foundation
import Testing
@testable import RecordingFormat

/// Holds `.lock` with flock(2) from a separate process, through the system's lockf(1).
private final class LockHolder {
    let process = Process()

    init(_ layout: RecordingLayout) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        process.arguments = ["-k", layout.lock.path, "/bin/sleep", "10"]
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while try !DirectoryLock.isHeld(in: layout) {
            guard Date() < deadline else { throw POSIXError(.ETIMEDOUT) }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    func killHard() {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }
}

final class ReaderTests {
    let directory: URL
    let layout: RecordingLayout

    init() throws {
        directory = try Fixtures.temporaryDirectory()
        layout = RecordingLayout(directory: directory)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    @Test func healthFollowsAnotherProcessHoldingAndDyingWithTheLock() throws {
        let holder = try LockHolder(layout)
        defer { holder.killHard() }

        #expect(try RecordingReader.health(at: directory) == .live)
        try Fixtures.manifest().write(to: layout)
        #expect(try RecordingReader.health(at: directory) == .live)
        #expect(try DirectoryLock.acquire(in: layout) == nil)

        holder.killHard()

        #expect(try RecordingReader.health(at: directory) == .crashed)
        #expect(try DirectoryLock.acquire(in: layout) != nil)
    }

    @Test func healthSeesALockHeldThroughAnotherDescriptorInThisProcess() throws {
        try Fixtures.manifest().write(to: layout)
        let lock = try #require(try DirectoryLock.acquire(in: layout))

        #expect(try RecordingReader.health(at: directory) == .live)
        #expect(try RecordingReader.read(at: directory).health == .live)

        lock.release()

        #expect(try RecordingReader.health(at: directory) == .crashed)
        #expect(try RecordingReader.read(at: directory).health == .crashed)
    }

    @Test func probingDoesNotBlockTheRecorderFromLockingLater() throws {
        try Fixtures.manifest().write(to: layout)
        FileManager.default.createFile(atPath: layout.lock.path, contents: nil)

        _ = try RecordingReader.health(at: directory)
        _ = try RecordingReader.health(at: directory)

        #expect(try DirectoryLock.acquire(in: layout) != nil)
    }

    @Test func aProbeInFlightIsNotMistakenForARecorder() throws {
        try Fixtures.manifest().write(to: layout)
        let otherProbe = open(layout.lock.path, O_RDWR | O_CREAT, 0o644)
        defer { close(otherProbe) }
        try #require(flock(otherProbe, LOCK_SH | LOCK_NB) == 0)

        #expect(try RecordingReader.health(at: directory) == .crashed)
    }

    @Test func noManifestAndNoRecorderIsUnrecoverable() throws {
        FileManager.default.createFile(atPath: layout.lock.path, contents: nil)

        #expect(try RecordingReader.health(at: directory) == .unrecoverable)
        #expect(throws: FormatError.noManifest(directory)) { try RecordingReader.read(at: directory) }
    }

    @Test func finalizedManifestIsFinalized() throws {
        try Fixtures.manifest(status: .finalized(duration: MediaTime(microseconds: 5_000_000), termination: .userStopped))
            .write(to: layout)
        try Fixtures.log(Fixtures.everyKind).write(to: layout.events)

        #expect(try RecordingReader.health(at: directory) == .finalized)
        let metadata = try RecordingReader.read(at: directory)
        #expect(metadata.health == .finalized)
        #expect(metadata.events.events == Fixtures.everyKind)
    }

    @Test func crashedRecordingReadsUpToItsTornTail() throws {
        try Fixtures.manifest().write(to: layout)
        let complete = try Fixtures.log(Fixtures.everyKind)
        try (complete + Data(#"{"t":5009121,"ty"#.utf8)).write(to: layout.events)

        let metadata = try RecordingReader.read(at: directory)

        #expect(metadata.health == .crashed)
        #expect(metadata.events.events == Fixtures.everyKind)
        #expect(metadata.events.validByteCount == complete.count)
        #expect(metadata.events.tornTailByteCount == 16)
    }

    @Test func finalizedRecordingWithATornTailIsRefused() throws {
        try Fixtures.manifest(status: .finalized(duration: MediaTime(microseconds: 1), termination: .userStopped))
            .write(to: layout)
        try (Fixtures.log(Fixtures.everyKind) + Data(#"{"t":5"#.utf8)).write(to: layout.events)

        #expect(throws: FormatError.tornTailInFinalizedRecording(byteCount: 6)) { try RecordingReader.read(at: directory) }
    }

    @Test func recordingWithoutAnEventLogYetReadsAsEmpty() throws {
        try Fixtures.manifest().write(to: layout)

        #expect(try RecordingReader.read(at: directory).events.events == [])
    }

    @Test func finalizedRecordingWithoutAnEventLogIsUnreadable() throws {
        try Fixtures.manifest(status: .finalized(duration: MediaTime(microseconds: 1), termination: .userStopped))
            .write(to: layout)

        let error = #expect(throws: FormatError.self) { try RecordingReader.read(at: directory) }

        guard case .eventsUnreadable = error else {
            Issue.record("expected eventsUnreadable, got \(String(describing: error))")
            return
        }
    }

    @Test func newerVersionDirectoryIsRejected() throws {
        let newer = try Fixtures.editJSON(Fixtures.manifest().encoded()) { $0["formatVersion"] = 2 }
        try newer.write(to: layout.manifest)

        #expect(throws: FormatError.unsupportedVersion(found: 2, supported: 1)) { try RecordingReader.read(at: directory) }
        #expect(throws: FormatError.unsupportedVersion(found: 2, supported: 1)) { try RecordingReader.health(at: directory) }
    }

    @Test func aFileIsNotARecordingDirectory() throws {
        try Fixtures.manifest().write(to: layout)

        #expect(throws: FormatError.notARecordingDirectory(layout.manifest)) { try RecordingReader.read(at: layout.manifest) }
        #expect(throws: FormatError.notARecordingDirectory(layout.manifest)) { try RecordingReader.health(at: layout.manifest) }
    }

    @Test func releasingTwiceIsHarmlessAndFreesTheLock() throws {
        let lock = try #require(try DirectoryLock.acquire(in: layout))
        #expect(try DirectoryLock.acquire(in: layout) == nil)

        lock.release()
        lock.release()

        #expect(try DirectoryLock.acquire(in: layout) != nil)
    }
}
