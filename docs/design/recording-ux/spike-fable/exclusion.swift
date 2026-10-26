// Throwaway. Does ScreenCaptureKit keep our own borderless floating panel out of a display capture?
//
//   swiftc -O -swift-version 5 docs/design/recording-ux/candidate/spike/exclusion.swift -o $SCRATCH/exclusion
//   $SCRATCH/exclusion
//
// Shows a 240 x 240 red, borderless, non-activating panel at floating level for about three
// seconds, and captures one complete frame of the main display under three filters: no exclusion,
// `excludingApplications: [this process]`, and `excludingWindows: [the panel's SCWindow]`. For each
// it reports the fraction of red pixels inside the panel's rectangle. Needs Screen Recording for
// the responsible process (the terminal).

import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit

final class OneFrame: NSObject, SCStreamOutput {
    var continuation: CheckedContinuation<CVPixelBuffer, Never>?
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let status = (attachments.first?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:)), status == .complete,
            let pixels = CMSampleBufferGetImageBuffer(buffer)
        else { return }
        continuation?.resume(returning: pixels)
        continuation = nil
    }
}

func redFraction(in pixels: CVPixelBuffer, rect: CGRect) -> Double {
    CVPixelBufferLockBaseAddress(pixels, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pixels)
    var red = 0, total = 0
    for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
            let p = base + y * stride + x * 4
            let (b, g, r) = (p[0], p[1], p[2])
            if r > 180 && g < 80 && b < 80 { red += 1 }
            total += 1
        }
    }
    return Double(red) / Double(max(total, 1))
}

func capture(_ filter: SCContentFilter, width: Int, height: Int) async throws -> CVPixelBuffer {
    let configuration = SCStreamConfiguration()
    configuration.width = width
    configuration.height = height
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.showsCursor = false
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    let output = OneFrame()
    let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
    try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "spike.capture"))
    let frame: CVPixelBuffer = await withCheckedContinuation { continuation in
        output.continuation = continuation
        Task { try await stream.startCapture() }
    }
    try await stream.stopCapture()
    return frame
}

guard CGPreflightScreenCaptureAccess() else {
    print("Screen Recording is not granted to this process's responsible app; run from a terminal that has it. Not prompting.")
    exit(3)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let screen = NSScreen.main!
let pointFrame = NSRect(x: screen.frame.minX + 300, y: screen.frame.minY + 300, width: 240, height: 240)
let panel = NSPanel(contentRect: pointFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
panel.level = .floating
panel.backgroundColor = .red
panel.isOpaque = true
panel.hidesOnDeactivate = false
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
panel.orderFrontRegardless()

Task {
    do {
        try await Task.sleep(for: .milliseconds(500))
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
        let display = content.displays.first { $0.displayID == displayID }!
        let mode = CGDisplayCopyDisplayMode(displayID)!
        let scale = CGFloat(mode.pixelWidth) / screen.frame.width
        // Panel points are bottom-left; the capture is top-left.
        let pixelRect = CGRect(
            x: (pointFrame.minX - screen.frame.minX) * scale,
            y: (screen.frame.maxY - pointFrame.maxY) * scale,
            width: pointFrame.width * scale, height: pointFrame.height * scale).insetBy(dx: 8, dy: 8)
        let me = getpid()
        let ownApp = content.applications.first { $0.processID == me }
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == me }
        print("display \(mode.pixelWidth)x\(mode.pixelHeight) scale \(scale)  panel pixel rect \(pixelRect)")
        print("own SCRunningApplication listed: \(ownApp != nil)  own SCWindows listed: \(ownWindows.count) \(ownWindows.map { "\($0.windowID)@\($0.frame)" })")

        var filters: [(String, SCContentFilter)] = [
            ("no exclusion", SCContentFilter(display: display, excludingWindows: [])),
        ]
        if let ownApp {
            filters.append(("excludingApplications [self]", SCContentFilter(display: display, excludingApplications: [ownApp], exceptingWindows: [])))
        }
        filters.append(("excludingWindows [own windows]", SCContentFilter(display: display, excludingWindows: ownWindows)))
        for (name, filter) in filters {
            let started = DispatchTime.now().uptimeNanoseconds
            let frame = try await capture(filter, width: mode.pixelWidth, height: mode.pixelHeight)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            print(String(format: "%-34@ red fraction in panel rect %.3f   (first complete frame after %.0f ms)", name as NSString, redFraction(in: frame, rect: pixelRect), ms))
        }
        // A window created after the filter was built: does an application exclusion cover it?
        if let ownApp {
            let late = NSPanel(contentRect: pointFrame.offsetBy(dx: 300, dy: 0), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            late.level = .floating
            late.backgroundColor = .red
            late.isOpaque = true
            late.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(300))
            let lateRect = pixelRect.offsetBy(dx: 300 * scale, dy: 0)
            let frame = try await capture(SCContentFilter(display: display, excludingApplications: [ownApp], exceptingWindows: []), width: mode.pixelWidth, height: mode.pixelHeight)
            print(String(format: "%-34@ red fraction in late panel rect %.3f", "excludingApplications, panel made after filter" as NSString, redFraction(in: frame, rect: lateRect)))
            late.orderOut(nil)
        }
    } catch {
        print("error: \(error)")
    }
    panel.orderOut(nil)
    exit(0)
}
app.run()
