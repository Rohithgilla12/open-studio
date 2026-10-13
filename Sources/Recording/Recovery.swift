import AVFoundation
public import Foundation
internal import RecordingFormat

extension RecordingSession {
    /// Finalizes a directory whose recorder died. Safe to call on any recording directory, any
    /// number of times:
    /// - already finalized: returns it unchanged, without touching a byte
    /// - recorder still alive (lock held): throws `.stillRecording`
    /// - no manifest (died before the first frame): throws `.nothingRecorded`
    public static func recover(at directory: URL) async throws(RecoveryError) -> FinishedRecording {
        let layout = RecordingLayout(directory: directory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw .notARecording(directory) }

        // A reader's health probe takes a shared lock for an instant, which makes an exclusive
        // acquire fail as if a recorder were alive. A few retries tell the two apart.
        var lock: DirectoryLock?
        for attempt in 1...Recovery.lockAttempts {
            do {
                lock = try DirectoryLock.acquire(in: layout)
            } catch {
                throw .unreadable("cannot open \(layout.lock.path): \(error.localizedDescription)")
            }
            if lock != nil || attempt == Recovery.lockAttempts { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let lock else { throw .stillRecording }
        defer { lock.release() }

        let metadata: RecordingMetadata
        do {
            metadata = try RecordingReader.read(at: directory)
        } catch .noManifest {
            throw .nothingRecorded
        } catch .notARecordingDirectory {
            throw .notARecording(directory)
        } catch .unsupportedVersion(let found, _) {
            throw .unsupportedVersion(found: found)
        } catch {
            throw .unreadable(String(describing: error))
        }
        var manifest = metadata.manifest
        let hasMicrophone = manifest.microphone != nil
        if case .finalized(let duration, let termination) = manifest.status {
            return FinishedRecording(
                directory: directory, duration: duration.duration, hasMicrophone: hasMicrophone,
                termination: Termination(termination))
        }

        var notes: [String] = []
        if metadata.events.tornTailByteCount > 0 {
            do {
                let handle = try FileHandle(forWritingTo: layout.events)
                try handle.truncate(atOffset: UInt64(metadata.events.validByteCount))
                try handle.close()
            } catch {
                throw .unreadable("cannot truncate \(layout.events.lastPathComponent): \(error.localizedDescription)")
            }
            notes.append("truncated a partial event line (\(metadata.events.tornTailByteCount) bytes)")
        }
        // An unreadable movie still leaves the events worth keeping, so it is a note, not a failure.
        var duration: Duration = .zero
        switch await Recovery.probeDuration(of: layout.screen) {
        case .success(let probed): duration = probed
        case .failure(let detail): notes.append("screen.mov unreadable: \(detail)")
        }
        if hasMicrophone, case .failure(let detail) = await Recovery.probeDuration(of: layout.microphone) {
            notes.append("microphone.mov unreadable: \(detail)")
        }

        let message = (["recorder exited without finalizing"] + notes).joined(separator: "; ")
        manifest.status = .finalized(duration: MediaTime(duration), termination: .recovered(message: message))
        do {
            try manifest.write(to: layout)
        } catch {
            throw .unreadable("cannot write \(layout.manifest.lastPathComponent): \(error.localizedDescription)")
        }
        return FinishedRecording(directory: directory, duration: duration, hasMicrophone: hasMicrophone, termination: .recovered(message))
    }
}

enum Recovery {
    static let lockAttempts = 5

    enum Probe {
        case success(Duration)
        case failure(String)
    }

    /// A fragmented movie reads up to its last complete fragment.
    static func probeDuration(of url: URL) async -> Probe {
        guard FileManager.default.fileExists(atPath: url.path) else { return .failure("missing") }
        do {
            let seconds = try await AVURLAsset(url: url).load(.duration).seconds
            guard seconds.isFinite else { return .failure("indefinite duration") }
            return .success(.seconds(seconds))
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

extension Termination {
    init(_ wire: WireTermination) {
        switch wire {
        case .userStopped: self = .userStopped
        case .durationReached: self = .durationReached
        case .streamFailed(let message): self = .streamFailed(message)
        case .recovered(let message): self = .recovered(message)
        }
    }
}
