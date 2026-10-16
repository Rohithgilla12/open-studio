public import Foundation

///     20261013-142233.osrec/
///       recording.json      manifest, written at the first screen frame and again at finalization
///       events.ndjson       append-only input and cursor events, one JSON object per line
///       screen.mov          fragmented QuickTime movie, cursor not drawn
///       microphone.mov      fragmented QuickTime movie, present only when the manifest lists one
///       system-audio.mov    fragmented QuickTime movie, present only when the manifest lists it
///       camera.mov          fragmented QuickTime movie, present only when the manifest lists one
///       cursors/<id>.png    content-addressed cursor images
///       .lock               held with flock(2) by the live recorder, never read for content
///
/// The recorder is the only writer until the manifest is finalized, by the recorder or by
/// recovery. After that the recording files are immutable.
public struct RecordingLayout: Sendable, Hashable {
    public static let packageExtension = "osrec"

    private static let manifestName = "recording.json"
    private static let eventsName = "events.ndjson"
    private static let screenName = "screen.mov"
    private static let microphoneName = "microphone.mov"
    private static let systemAudioName = "system-audio.mov"
    private static let cameraName = "camera.mov"
    private static let cursorsName = "cursors"
    private static let lockName = ".lock"

    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public var manifest: URL { directory.appending(path: Self.manifestName, directoryHint: .notDirectory) }
    public var events: URL { directory.appending(path: Self.eventsName, directoryHint: .notDirectory) }
    public var screen: URL { directory.appending(path: Self.screenName, directoryHint: .notDirectory) }
    public var microphone: URL { directory.appending(path: Self.microphoneName, directoryHint: .notDirectory) }
    public var systemAudio: URL { directory.appending(path: Self.systemAudioName, directoryHint: .notDirectory) }
    public var camera: URL { directory.appending(path: Self.cameraName, directoryHint: .notDirectory) }
    public var cursors: URL { directory.appending(path: Self.cursorsName, directoryHint: .isDirectory) }
    public var lock: URL { directory.appending(path: Self.lockName, directoryHint: .notDirectory) }

    /// Relative to the recording directory.
    public static func cursorImagePath(_ id: CursorImageID) -> String { "\(cursorsName)/\(id.rawValue).png" }

    public func cursorImage(_ id: CursorImageID) -> URL {
        directory.appending(path: Self.cursorImagePath(id), directoryHint: .notDirectory)
    }

    /// `YYYYMMDD-HHMMSS.osrec` in the given time zone.
    public static func directoryName(for start: Date, in timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        let stamp = String(
            format: "%04d%02d%02d-%02d%02d%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        return "\(stamp).\(packageExtension)"
    }
}

/// Additive changes (a new event type, a new optional manifest key) keep the version, because
/// readers ignore event types and keys they do not know. A change to the meaning of an existing
/// field bumps the version, and readers refuse versions newer than `current`.
///
/// A manifest is written with the lowest version that can express it, so a take that uses nothing
/// newer stays readable by older builds.
public enum FormatVersion {
    public static let current = 4
    /// Added `area`. An older reader would ignore the key and show the whole display, including what
    /// the person cropped out, so the key needs a version an older reader refuses.
    static let area = 2
    /// Added `camera`. An older reader would export the take without the person in it, and an older
    /// recovery would rewrite the manifest without the key, losing the camera for good.
    static let camera = 3
    /// Added `systemAudio`. An older reader would export the take without its sound, and an older
    /// recovery would rewrite the manifest without the key, losing the sound for good.
    static let systemAudio = 4
    public static let identifier = "open-studio.recording"
}
