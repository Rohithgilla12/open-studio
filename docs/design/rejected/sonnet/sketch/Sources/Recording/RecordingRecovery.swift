import Foundation
import RecordingFormat

public struct RecoveryReport: Sendable, Equatable {
    public var directory: URL
    public var wasAlreadyFinal: Bool
    public var duration: RecordingTime
    public var discardedLines: Int
    public var notes: [String]
}

public enum RecordingRecovery {
    public static func health(of directory: URL) -> RecordingHealth {
        RecordingHealth.probe(RecordingLayout(root: directory))
    }

    /// Turns a crashed directory into a finalised one. Idempotent: on a finalised directory
    /// it returns wasAlreadyFinal and touches nothing; run twice on a crashed one, the second
    /// run reproduces the first run's manifest exactly because every input it reads is
    /// frozen once the writer is dead.
    ///
    /// Refuses (throws) while another process holds the lock.
    public static func recover(_ directory: URL) async throws(RecordingError) -> RecoveryReport {
        // TODO:
        //  1. probe; .finalized -> early return; .beingRecorded -> throw; .unrecoverable -> throw
        //  2. read manifest (status .recording). origin must be set, else unrecoverable
        //  3. truncate each ndjson file after its last "\n" (drops the torn line); count discards
        //  4. open video/display.mp4 with AVAsset; videoEnd = last sample PTS + its duration
        //     (fragmented MP4: the readable range ends at the last complete fragment)
        //  5. micEnd likewise; duration = videoEnd. Mic past videoEnd is ignored, never extends.
        //  6. drop catalog entries whose PNG is missing; keep change lines (reader maps to fallback)
        //  7. rewrite manifest atomically: status .finalized, finalisation.kind .recovered,
        //     duration, stats recomputed from the files
        fatalError("not implemented")
    }
}
