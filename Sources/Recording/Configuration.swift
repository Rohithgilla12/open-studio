import AppKit
import AVFoundation
public import CoreGraphics
public import Foundation
import ScreenCaptureKit

/// What to record. Everything has a default except where the recording goes.
public struct RecordingConfiguration: Sendable, Equatable {
    public var target: CaptureTarget
    public var microphone: MicrophoneSelection
    /// Recorded to its own movie beside the screen, at most 1920 x 1080 and 30 fps.
    public var camera: CameraSelection
    /// Parent directory. The session creates `YYYYMMDD-HHMMSS.osrec` inside it.
    public var outputDirectory: URL
    /// Capped at the display's refresh rate.
    public var maxFrameRate: Int
    public var codec: VideoCodec
    /// The session stops itself with `.durationReached` after this much media time.
    public var maxDuration: Duration?

    public init(
        outputDirectory: URL,
        target: CaptureTarget = .display(.main),
        microphone: MicrophoneSelection = .none,
        camera: CameraSelection = .none,
        maxFrameRate: Int = 60,
        codec: VideoCodec = .hevc,
        maxDuration: Duration? = nil
    ) {
        self.outputDirectory = outputDirectory
        self.target = target
        self.microphone = microphone
        self.camera = camera
        self.maxFrameRate = maxFrameRate
        self.codec = codec
        self.maxDuration = maxDuration
    }
}

/// What a take shows. Every target captures the whole display it is on, so the video and the input
/// events share one coordinate space; an area or a window is recorded as the part of that display
/// the take shows, and the renderer crops to it.
public enum CaptureTarget: Sendable, Hashable {
    case display(DisplaySelection)
    /// `rect` is in points, origin top-left of the display. `start` clips it to the display.
    case area(DisplaySelection, CGRect)
    /// The window's frame when recording starts becomes the area, and the crop does not follow a
    /// later move or resize. Windows of other apps are hidden; the owning app's other windows,
    /// such as its menus and sheets, are not.
    case window(CGWindowID)

    /// The shortest side, in screen pixels after clipping, that `start` accepts for an area or a
    /// window.
    public static let minimumAreaPixels = 64
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

public enum CameraSelection: Sendable, Hashable {
    case none
    /// `AVCaptureDevice.systemPreferredCamera`, which follows the person's choice in Control Centre
    /// and Continuity Camera's automatic switching, when it is one `CaptureSources.cameras()` lists.
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

public struct CameraInfo: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// The camera `CameraSelection.systemDefault` resolves to now.
    public let isDefault: Bool
}

public struct WindowInfo: Sendable, Equatable, Identifiable {
    public let id: CGWindowID
    public let appName: String
    /// nil when the window has none, or when macOS withholds it: window titles are shared only with
    /// processes that have Screen Recording permission.
    public let title: String?
    public let processID: pid_t
    /// Global points, origin top-left of the main display.
    public let frame: CGRect
    /// The display holding most of the window. The window records on this display.
    public let displayID: CGDirectDisplayID

    public init(id: CGWindowID, appName: String, title: String?, processID: pid_t, frame: CGRect, displayID: CGDirectDisplayID) {
        self.id = id
        self.appName = appName
        self.title = title
        self.processID = processID
        self.frame = frame
        self.displayID = displayID
    }
}

public enum CaptureSources {
    public static func displays() async throws(RecordingError) -> [DisplayInfo] {
        await shareableDisplays(in: try shareableContent()).map(\.info)
    }

    /// On-screen, normal-level windows of other processes, frontmost first.
    ///
    /// Reads the window server's list rather than ScreenCaptureKit's, so listing windows never shows
    /// the Screen Recording prompt.
    public static func windows() -> [WindowInfo] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let displays = activeDisplays()
        return list.compactMap { windowInfo(from: $0, displays: displays, ownProcess: getpid()) }
    }

    static func windowInfo(
        from entry: [String: Any], displays: [(id: CGDirectDisplayID, frame: CGRect)], ownProcess: pid_t
    ) -> WindowInfo? {
        guard let number = entry[kCGWindowNumber as String] as? NSNumber,
            let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownProcess,
            (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
            let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
            let frame = CGRect(dictionaryRepresentation: bounds)
        else { return nil }
        let appName = (entry[kCGWindowOwnerName as String] as? String) ?? ""
        let title = (entry[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard !appName.isEmpty || title != nil, let display = display(holdingMostOf: frame, among: displays) else { return nil }
        return WindowInfo(id: number.uint32Value, appName: appName, title: title, processID: pid, frame: frame, displayID: display)
    }

    static func display(holdingMostOf frame: CGRect, among displays: [(id: CGDirectDisplayID, frame: CGRect)]) -> CGDirectDisplayID? {
        let overlaps = displays.map { display -> (id: CGDirectDisplayID, area: CGFloat) in
            let shared = display.frame.intersection(frame)
            return (display.id, shared.isNull ? 0 : shared.width * shared.height)
        }
        guard let best = overlaps.max(by: { $0.area < $1.area }), best.area > 0 else { return nil }
        return best.id
    }

    private static func activeDisplays() -> [(id: CGDirectDisplayID, frame: CGRect)] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { ($0, CGDisplayBounds($0)) }
    }

    public static func microphones() -> [MicrophoneInfo] {
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        return audioDevices().map { MicrophoneInfo(id: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == defaultID) }
    }

    /// Built-in, USB, and Continuity cameras. Desk View is never listed: it is a cut-out of another
    /// camera pointed at the desk, not a picture of the person.
    ///
    /// Lists devices without opening one, so it needs no Camera permission and lights no camera.
    public static func cameras() -> [CameraInfo] {
        let devices = videoDevices()
        let preferred = preferredCamera(among: devices)?.uniqueID
        return devices.map { CameraInfo(id: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == preferred) }
    }

    /// Without `NSCameraUseContinuityCameraDeviceType` in the bundle, as for `osrec`, a Continuity
    /// Camera reports itself as a built-in wide-angle camera (the SDK's note on
    /// `AVCaptureDeviceTypeContinuityCamera`), so both types are listed.
    static let cameraDeviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .continuityCamera, .external]

    private static func videoDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: cameraDeviceTypes, mediaType: .video, position: .unspecified).devices
    }

    private static func preferredCamera(among devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        let preferred = AVCaptureDevice.systemPreferredCamera?.uniqueID
        return devices.first { $0.uniqueID == preferred } ?? devices.first
    }

    static func resolve(_ selection: CameraSelection) throws(RecordingError) -> ResolvedCamera? {
        let device: AVCaptureDevice
        switch selection {
        case .none:
            return nil
        case .systemDefault:
            guard let preferred = preferredCamera(among: videoDevices()) else { throw .cameraNotFound(selection) }
            device = preferred
        case .device(let uniqueID):
            guard let found = videoDevices().first(where: { $0.uniqueID == uniqueID }) else { throw .cameraNotFound(selection) }
            device = found
        }
        let formats = device.formats.map { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return CameraFormat.Candidate(
                width: Int(dimensions.width), height: Int(dimensions.height),
                maxFrameRate: format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
        }
        guard let plan = CameraFormat.plan(for: formats) else {
            throw .captureFailedToStart("\(device.localizedName) offers no video format")
        }
        return ResolvedCamera(device: device, format: device.formats[plan.formatIndex], plan: plan)
    }

    static func resolve(_ target: CaptureTarget) async throws(RecordingError) -> ResolvedTarget {
        let content = try await shareableContent()
        let displays = await shareableDisplays(in: content)
        switch target {
        case .display(let selection):
            return ResolvedTarget(display: try display(selection, in: displays), content: .display, pixelArea: nil)
        case .area(let selection, let rect):
            let display = try display(selection, in: displays)
            let area = try CaptureArea.clippedPixels(ofPoints: rect, displayPointSize: display.info.pointSize, pixelSize: display.info.pixelSize)
            return ResolvedTarget(display: display, content: .display, pixelArea: area)
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw .windowNotFound(id) }
            let frames = displays.map { (id: $0.info.id, frame: $0.info.pointFrame) }
            guard let displayID = Self.display(holdingMostOf: window.frame, among: frames),
                let display = displays.first(where: { $0.info.id == displayID })
            else { throw .areaOutsideDisplay }
            let local = window.frame.offsetBy(dx: -display.info.pointFrame.minX, dy: -display.info.pointFrame.minY)
            let area = try CaptureArea.clippedPixels(ofPoints: local, displayPointSize: display.info.pointSize, pixelSize: display.info.pixelSize)
            let included: ResolvedTarget.Content = window.owningApplication.map { .application($0) } ?? .window(window)
            return ResolvedTarget(display: display, content: included, pixelArea: area)
        }
    }

    private static func display(_ selection: DisplaySelection, in displays: [ResolvedDisplay]) throws(RecordingError) -> ResolvedDisplay {
        let wanted: CGDirectDisplayID = switch selection {
        case .main: CGMainDisplayID()
        case .id(let id): id
        }
        guard let display = displays.first(where: { $0.info.id == wanted }) else { throw .displayNotFound(selection) }
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

    private static func shareableContent() async throws(RecordingError) -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw .captureFailedToStart("shareable content unavailable: \(error.localizedDescription)")
        }
    }

    private static func shareableDisplays(in content: SCShareableContent) async -> [ResolvedDisplay] {
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

/// `AVCaptureDevice` carries no Sendable annotation. It is configured once, on the session's
/// start path, and otherwise only read.
struct ResolvedCamera: @unchecked Sendable {
    let device: AVCaptureDevice
    let format: AVCaptureDevice.Format
    let plan: CameraFormat.Plan
}

/// The ScreenCaptureKit objects are held only to build the filter, like `ResolvedDisplay`'s.
struct ResolvedTarget: @unchecked Sendable {
    enum Content {
        case display
        case application(SCRunningApplication)
        case window(SCWindow)
    }

    let display: ResolvedDisplay
    let content: Content
    let pixelArea: CGRect?

    var filter: SCContentFilter {
        switch content {
        case .display: SCContentFilter(display: display.display, excludingWindows: [])
        case .application(let app): SCContentFilter(display: display.display, including: [app], exceptingWindows: [])
        case .window(let window): SCContentFilter(display: display.display, including: [window])
        }
    }
}

enum CaptureArea {
    static func clippedPixels(ofPoints rect: CGRect, displayPointSize: CGSize, pixelSize: CGSize) throws(RecordingError) -> CGRect {
        let clipped = rect.standardized.intersection(CGRect(origin: .zero, size: displayPointSize))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { throw .areaOutsideDisplay }
        let scaleX = pixelSize.width / displayPointSize.width
        let scaleY = pixelSize.height / displayPointSize.height
        let floatingPointSlack: CGFloat = 1e-6
        func down(_ v: CGFloat) -> CGFloat { (v + floatingPointSlack).rounded(.down) }
        func up(_ v: CGFloat) -> CGFloat { (v - floatingPointSlack).rounded(.up) }
        let minX = max(0, down(clipped.minX * scaleX)), minY = max(0, down(clipped.minY * scaleY))
        let maxX = min(pixelSize.width, up(clipped.maxX * scaleX)), maxY = min(pixelSize.height, up(clipped.maxY * scaleY))
        let pixels = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let minimum = CGFloat(CaptureTarget.minimumAreaPixels)
        guard pixels.width >= minimum, pixels.height >= minimum else {
            throw .areaTooSmall(width: Int(pixels.width), height: Int(pixels.height))
        }
        return pixels
    }
}
