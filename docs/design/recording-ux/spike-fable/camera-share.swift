// Throwaway. Can one AVCaptureSession feed an AVCaptureVideoPreviewLayer and a video data output
// at once, and can a second data output join while the session runs?
//
//   swiftc -O -swift-version 5 docs/design/recording-ux/candidate/spike/camera-share.swift -o $SCRATCH/camera-share
//   $SCRATCH/camera-share
//
// Phases, two seconds each, counting frames on each data output:
//   1. data output A alone
//   2. A plus a preview layer in a 320 x 240 window (the bubble)
//   3. A, the preview, plus data output B added through beginConfiguration/commitConfiguration
//      while running (the recorder joining a feed the bubble already uses)
//   4. preview removed, A and B still delivering (the bubble closing mid-take)
// Needs Camera permission for the responsible process (the terminal).

import AppKit
import AVFoundation

final class Counter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let name: String
    var frames = 0
    var firstPTS: CMTime?
    var lastPTS: CMTime?
    init(name: String) { self.name = name }
    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frames += 1
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        if firstPTS == nil { firstPTS = pts }
        lastPTS = pts
    }
    func reset() { frames = 0; firstPTS = nil; lastPTS = nil }
    var report: String {
        guard let firstPTS, let lastPTS, frames > 1 else { return "\(name): \(frames) frames" }
        let span = (lastPTS - firstPTS).seconds
        return String(format: "%@: %d frames over %.2f s = %.1f fps", name, frames, span, Double(frames - 1) / span)
    }
}

func makeOutput(_ counter: Counter, queue: DispatchQueue) -> AVCaptureVideoDataOutput {
    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(counter, queue: queue)
    return output
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

Task {
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    print("camera authorization: \(status.rawValue) (3 = authorized)")
    guard status == .authorized else {
        print("Camera is not granted to this process's responsible app; run from a terminal that has it. Not prompting.")
        exit(3)
    }
    guard let device = AVCaptureDevice.default(for: .video) else { print("no camera"); exit(1) }
    print("device: \(device.localizedName)")
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "spike.camera")
    let a = Counter(name: "output A"), b = Counter(name: "output B")
    do {
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        session.addInput(input)
        session.addOutput(makeOutput(a, queue: queue))
        session.commitConfiguration()
        let started = DispatchTime.now().uptimeNanoseconds
        session.startRunning()
        print(String(format: "startRunning took %.0f ms", Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6))

        try await Task.sleep(for: .seconds(2))
        print("phase 1  " + a.report)
        a.reset()

        let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 320, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = window.contentView!.bounds
        window.contentView!.wantsLayer = true
        window.contentView!.layer!.addSublayer(preview)
        window.orderFrontRegardless()
        try await Task.sleep(for: .seconds(2))
        print("phase 2  " + a.report + "   preview connection active: \(preview.connection?.isActive ?? false)")
        a.reset()

        session.beginConfiguration()
        session.addOutput(makeOutput(b, queue: queue))
        session.commitConfiguration()
        try await Task.sleep(for: .seconds(2))
        print("phase 3  " + a.report + " | " + b.report + "   preview active: \(preview.connection?.isActive ?? false)")
        a.reset(); b.reset()

        preview.session = nil
        window.orderOut(nil)
        try await Task.sleep(for: .seconds(2))
        print("phase 4  " + a.report + " | " + b.report)
        print("session still running: \(session.isRunning)  synchronizationClock is host clock: \(session.synchronizationClock.map { CFEqual($0, CMClockGetHostTimeClock()) } ?? false)")
        session.stopRunning()
    } catch {
        print("error: \(error)")
    }
    exit(0)
}
app.run()
