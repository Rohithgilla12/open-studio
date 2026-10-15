import AppKit
import AVFoundation
public import CoreGraphics
public import Foundation
import ScreenCaptureKit

/// What to record. Everything has a default except where the recording goes.
public struct RecordingConfiguration: Sendable, Equatable {
    public var display: DisplaySelection
    public var microphone: MicrophoneSelection
    /// Parent directory. The session creates `YYYYMMDD-HHMMSS.osrec` inside it.
    public var outputDirectory: URL
    /// Capped at the display's refresh rate.
    public var maxFrameRate: Int
    public var codec: VideoCodec
    /// The session stops itself with `.durationReached` after this much media time.
    public var maxDuration: Duration?

    public init(
        outputDirectory: URL,
        display: DisplaySelection = .main,
        microphone: MicrophoneSelection = .none,
        maxFrameRate: Int = 60,
        codec: VideoCodec = .hevc,
        maxDuration: Duration? = nil
    ) {
        self.outputDirectory = outputDirectory
        self.display = display
        self.microphone = microphone
        self.maxFrameRate = maxFrameRate
        self.codec = codec
        self.maxDuration = maxDuration
    }
}

public enum DisplaySelection: Sendable, Hashable {
    /// The display with the menu bar when `start` is called.
    case main
    case id(CGDirectDisplayID)
}

public enum MicrophoneSelection: Sendable, Hashable {
    case none
    case systemDefault
    /// `AVCaptureDevice.uniqueID`.
    case device(uniqueID: String)
}

public enum VideoCodec: String, Sendable, Equatable, CaseIterable {
    case hevc
    case h264
}

public struct DisplayInfo: Sendable, Equatable, Identifiable {
    public let id: CGDirectDisplayID
    public let name: String
    /// `CGDisplayBounds`: global points, origin top-left of the main display.
    public let pointFrame: CGRect
    public let pixelSize: CGSize
    public let refreshRate: Double
    public let isMain: Bool

    public var pointSize: CGSize { pointFrame.size }
}

public struct MicrophoneInfo: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let isDefault: Bool
}

public enum CaptureSources {
    public static func displays() async throws(RecordingError) -> [DisplayInfo] {
        try await shareableDisplays().map(\.info)
    }

    public static func microphones() -> [MicrophoneInfo] {
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        return audioDevices().map { MicrophoneInfo(id: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == defaultID) }
    }

    static func resolve(_ selection: DisplaySelection) async throws(RecordingError) -> ResolvedDisplay {
        let wanted: CGDirectDisplayID = switch selection {
        case .main: CGMainDisplayID()
        case .id(let id): id
        }
        guard let display = try await shareableDisplays().first(where: { $0.info.id == wanted }) else {
            throw .displayNotFound(selection)
        }
        return display
    }

    static func resolve(_ selection: MicrophoneSelection) throws(RecordingError) -> AVCaptureDevice? {
        switch selection {
        case .none:
            return nil
        case .systemDefault:
            guard let device = AVCaptureDevice.default(for: .audio) else { throw .microphoneNotFound(selection) }
            return device
        case .device(let uniqueID):
            guard let device = audioDevices().first(where: { $0.uniqueID == uniqueID }) else {
                throw .microphoneNotFound(selection)
            }
            return device
        }
    }

    private static func audioDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices
    }

    private static func shareableDisplays() async throws(RecordingError) -> [ResolvedDisplay] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw .captureFailedToStart("shareable content unavailable: \(error.localizedDescription)")
        }
        let main = CGMainDisplayID()
        let names = await MainActor.run { screenNames() }
        return content.displays.map { display in
            let id = display.displayID
            let mode = CGDisplayCopyDisplayMode(id)
            let bounds = CGDisplayBounds(id)
            let pixelSize = mode.map { CGSize(width: $0.pixelWidth, height: $0.pixelHeight) } ?? bounds.size
            let info = DisplayInfo(
                id: id,
                name: names[id] ?? "Display \(id)",
                pointFrame: bounds,
                pixelSize: pixelSize,
                refreshRate: mode?.refreshRate ?? 0,
                isMain: id == main)
            return ResolvedDisplay(display: display, info: info)
        }
    }

    @MainActor
    private static func screenNames() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            names[CGDirectDisplayID(number.uint32Value)] = screen.localizedName
        }
        return names
    }
}

/// `SCDisplay` is a class without a Sendable annotation, and ScreenCaptureKit hands it out only to
/// be passed back into `SCContentFilter`. It is never mutated here.
struct ResolvedDisplay: @unchecked Sendable {
    let display: SCDisplay
    let info: DisplayInfo
}
