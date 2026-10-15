import AppKit
import Foundation
import Recording
internal import RecordingFormat

public struct TakeSummary: Sendable, Hashable, Identifiable {
    public let url: URL
    public let createdAt: Date?
    public let health: TakeHealth
    public let hasEdits: Bool

    public var id: URL { url }
    public var name: String { url.deletingPathExtension().lastPathComponent }
}

public enum TakeHealth: Sendable, Hashable {
    case ready
    case recording
    case needsRecovery
    case nothingRecorded
    case unreadable(String)

    var canOpen: Bool {
        switch self {
        case .ready, .needsRecovery: true
        case .recording, .nothingRecorded, .unreadable: false
        }
    }
}

enum TakeLibrary {
    @concurrent
    static func recoverAndScan(_ library: URL) async -> [TakeSummary] {
        let urls = takeURLs(in: library)
        for url in urls where health(of: url) == .needsRecovery {
            _ = try? await RecordingSession.recover(at: url)
        }
        return urls.map(summary).sorted { ($0.createdAt ?? .distantPast, $0.name) > ($1.createdAt ?? .distantPast, $1.name) }
    }

    static func takeURLs(in library: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: library, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return entries.filter {
            $0.pathExtension == "osrec" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    static func summary(_ url: URL) -> TakeSummary {
        TakeSummary(
            url: url,
            createdAt: createdAt(fromName: url.deletingPathExtension().lastPathComponent),
            health: health(of: url),
            hasEdits: FileManager.default.fileExists(atPath: url.appending(path: "project.json").path))
    }

    static func health(of take: URL) -> TakeHealth {
        do {
            return switch try RecordingReader.health(at: take) {
            case .finalized: .ready
            case .live: .recording
            case .crashed: .needsRecovery
            case .unrecoverable: .nothingRecorded
            }
        } catch {
            return .unreadable(String(describing: error))
        }
    }

    static func createdAt(fromName name: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.date(from: name)
    }
}

public struct RecordingPreferences: Sendable, Equatable {
    public var display: DisplaySelection
    public var microphone: MicrophoneSelection

    public init(display: DisplaySelection, microphone: MicrophoneSelection) {
        self.display = display
        self.microphone = microphone
    }

    private static let displayKey = "recording.display"
    private static let microphoneKey = "recording.microphone"

    static func load(from defaults: UserDefaults = .standard) -> RecordingPreferences {
        let display: DisplaySelection =
            (defaults.object(forKey: displayKey) as? NSNumber).map { .id(CGDirectDisplayID($0.uint32Value)) } ?? .main
        let microphone: MicrophoneSelection = switch defaults.string(forKey: microphoneKey) {
        case "default": .systemDefault
        case let stored? where stored.hasPrefix("device:"): .device(uniqueID: String(stored.dropFirst("device:".count)))
        default: .none
        }
        return RecordingPreferences(display: display, microphone: microphone)
    }

    func save(to defaults: UserDefaults = .standard) {
        switch display {
        case .main: defaults.removeObject(forKey: Self.displayKey)
        case .id(let id): defaults.set(NSNumber(value: id), forKey: Self.displayKey)
        }
        switch microphone {
        case .none: defaults.set("none", forKey: Self.microphoneKey)
        case .systemDefault: defaults.set("default", forKey: Self.microphoneKey)
        case .device(let uniqueID): defaults.set("device:\(uniqueID)", forKey: Self.microphoneKey)
        }
    }
}

/// A display the picker offers. Listed from `NSScreen`, not ScreenCaptureKit, because asking
/// ScreenCaptureKit for shareable content shows the Screen Recording prompt before the user has
/// chosen to record.
struct DisplayChoice: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let isMain: Bool

    @MainActor
    static func current() -> [DisplayChoice] {
        let main = CGMainDisplayID()
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            return DisplayChoice(id: id, name: screen.localizedName, isMain: id == main)
        }
    }
}
