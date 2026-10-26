// Does a display stream whose filter excludes this app leave out a borderless panel the app opens
// after the stream started? A control stream that excludes nothing must show the panel, or the
// check proves nothing. A second panel tests `sharingType = .none` on its own.
// Shows two 200 x 200 panels for about one second. Exits with 2, before touching ScreenCaptureKit,
// when this process lacks Screen Recording, so it never raises the permission prompt.
//
//   swiftc -O main.swift -o /tmp/capture-exclusion && /tmp/capture-exclusion
import AppKit
import CoreMedia
import ScreenCaptureKit

guard CGPreflightScreenCaptureAccess() else {
    print("Screen Recording is not granted to this process's responsible app; nothing measured")
    exit(2)
}

final class LatestFrame: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    var frame: CVPixelBuffer? { lock.withLock { latest } }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixels = buffer.imageBuffer else { return }
        lock.withLock { latest = pixels }
    }
}

func count(_ color: (r: UInt8, g: UInt8, b: UInt8), in pixels: CVPixelBuffer, rect: CGRect, scale: CGFloat) -> Int {
    CVPixelBufferLockBaseAddress(pixels, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
    let row = CVPixelBufferGetBytesPerRow(pixels)
    let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
    var hits = 0
    for y in Int(rect.minY * scale)..<min(height, Int(rect.maxY * scale)) {
        for x in Int(rect.minX * scale)..<min(width, Int(rect.maxX * scale)) {
            let p = base + y * row + x * 4
            if abs(Int(p[2]) - Int(color.r)) < 24, abs(Int(p[1]) - Int(color.g)) < 24, abs(Int(p[0]) - Int(color.b)) < 24 { hits += 1 }
        }
    }
    return hits
}

@MainActor
func panel(_ frame: CGRect, _ color: NSColor, sharing: NSWindow.SharingType) -> NSPanel {
    let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .floating
    panel.backgroundColor = color
    panel.isOpaque = true
    panel.hasShadow = false
    panel.sharingType = sharing
    panel.orderFrontRegardless()
    return panel
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

Task { @MainActor in
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let ownBeforeWindows = content.applications.first { $0.processID == getpid() }
    print("own app listed before it has a window: \(ownBeforeWindows != nil)")
    let display = content.displays.first { $0.displayID == CGMainDisplayID() }!
    let scale = CGFloat(CGDisplayPixelsWide(display.displayID)) / CGFloat(display.width)

    func start(_ filter: SCContentFilter) async throws -> (SCStream, LatestFrame) {
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        let output = LatestFrame()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global())
        try await stream.startCapture()
        return (stream, output)
    }

    let control = try await start(SCContentFilter(display: display, excludingWindows: []))
    var excluding: (SCStream, LatestFrame)?
    if let app = ownBeforeWindows {
        excluding = try await start(SCContentFilter(display: display, excludingApplications: [app], exceptingWindows: []))
    }

    let size = CGSize(width: 200, height: 200)
    let screen = NSScreen.main!.frame
    let left = CGRect(origin: CGPoint(x: screen.midX - 220, y: screen.midY - 100), size: size)
    let right = CGRect(origin: CGPoint(x: screen.midX + 20, y: screen.midY - 100), size: size)
    let magenta = panel(left, NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1), sharing: .readOnly)
    let cyan = panel(right, NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 1), sharing: .none)
    try await Task.sleep(for: .milliseconds(700))

    let later = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let ownAfter = later.applications.first { $0.processID == getpid() }
    print("own app listed once a panel is up: \(ownAfter != nil)")
    var lateExcluding: (SCStream, LatestFrame)?
    if let app = ownAfter {
        lateExcluding = try await start(SCContentFilter(display: display, excludingApplications: [app], exceptingWindows: []))
    }
    try await Task.sleep(for: .milliseconds(300))

    func flipped(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX - screen.minX, y: screen.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
    let area = Int(size.width * scale * size.height * scale)
    func report(_ label: String, _ output: LatestFrame?) {
        guard let output, let frame = output.frame else { return print("\(label): no frame") }
        let m = count((255, 0, 255), in: frame, rect: flipped(left), scale: scale)
        let c = count((0, 255, 255), in: frame, rect: flipped(right), scale: scale)
        print("\(label): magenta panel \(m) of \(area) px, sharingType-none panel \(c) of \(area) px")
    }
    report("control, excludes nothing", control.1)
    report("excludes own app, filter built before any window", excluding?.1)
    report("excludes own app, filter built with a panel up", lateExcluding?.1)

    magenta.orderOut(nil)
    cyan.orderOut(nil)
    for stream in [control.0, excluding?.0, lateExcluding?.0].compactMap(\.self) { try? await stream.stopCapture() }
    exit(0)
}
app.run()
