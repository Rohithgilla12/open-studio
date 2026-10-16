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

/// What Record captures. The raw values are what `UserDefaults` stores and what the
/// `-CaptureTarget` launch argument names.
public enum CaptureKind: String, Sendable, CaseIterable, Identifiable {
    case screen
    case area
    case window

    public var id: Self { self }

    var title: String {
        switch self {
        case .screen: "Entire Screen"
        case .area: "Area"
        case .window: "Window"
        }
    }
}

public struct RecordingPreferences: Sendable, Equatable {
    public var display: DisplaySelection
    public var microphone: MicrophoneSelection
    public var captureKind: CaptureKind
    /// The last area chosen on each display, in display points, origin top-left. A window is not
    /// remembered, because its id dies with the window.
    public var areas: [CGDirectDisplayID: CGRect]

    public init(
        display: DisplaySelection, microphone: MicrophoneSelection, captureKind: CaptureKind = .screen,
        areas: [CGDirectDisplayID: CGRect] = [:]
    ) {
        self.display = display
        self.microphone = microphone
        self.captureKind = captureKind
        self.areas = areas
    }

    public func area(on display: DisplaySelection) -> CGRect? {
        areas[display.resolvedID]
    }

    public mutating func setArea(_ area: CGRect, on display: DisplaySelection) {
        areas[display.resolvedID] = area
    }

    private static let displayKey = "recording.display"
    private static let microphoneKey = "recording.microphone"
    private static let captureKindKey = "recording.captureKind"
    private static let areasKey = "recording.areas"

    static func load(from defaults: UserDefaults = .standard) -> RecordingPreferences {
        let display: DisplaySelection =
            (defaults.object(forKey: displayKey) as? NSNumber).map { .id(CGDirectDisplayID($0.uint32Value)) } ?? .main
        let microphone: MicrophoneSelection = switch defaults.string(forKey: microphoneKey) {
        case "default": .systemDefault
        case let stored? where stored.hasPrefix("device:"): .device(uniqueID: String(stored.dropFirst("device:".count)))
        default: .none
        }
        let captureKind = defaults.string(forKey: captureKindKey).flatMap(CaptureKind.init(rawValue:)) ?? .screen
        let stored = defaults.dictionary(forKey: areasKey) as? [String: [Double]] ?? [:]
        let areas = stored.reduce(into: [CGDirectDisplayID: CGRect]()) { areas, entry in
            guard let id = CGDirectDisplayID(entry.key), let area = CGRect(components: entry.value) else { return }
            areas[id] = area
        }
        return RecordingPreferences(display: display, microphone: microphone, captureKind: captureKind, areas: areas)
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
        defaults.set(captureKind.rawValue, forKey: Self.captureKindKey)
        defaults.set(
            Dictionary(uniqueKeysWithValues: areas.map { (String($0.key), [$0.value.minX, $0.value.minY, $0.value.width, $0.value.height]) }),
            forKey: Self.areasKey)
    }
}

extension DisplaySelection {
    /// `.main` is the display with the menu bar now, as `RecordingSession.start` resolves it.
    var resolvedID: CGDirectDisplayID {
        switch self {
        case .main: CGMainDisplayID()
        case .id(let id): id
        }
    }
}

extension CGRect {
    /// `[x, y, width, height]`, as preferences store an area and `-SelectArea` spells one. Refuses
    /// anything that is not four finite numbers with a positive size.
    init?(components: [Double]) {
        guard components.count == 4, components.allSatisfy(\.isFinite), components[2] > 0, components[3] > 0 else { return nil }
        self.init(x: components[0], y: components[1], width: components[2], height: components[3])
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    static func showing(_ display: DisplaySelection) -> NSScreen? {
        let id = display.resolvedID
        return screens.first { $0.displayID == id }
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
            guard let id = screen.displayID else { return nil }
            return DisplayChoice(id: id, name: screen.localizedName, isMain: id == main)
        }
    }
}
