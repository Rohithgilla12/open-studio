// Can one AVCaptureSession drive an AVCaptureVideoPreviewLayer in a window and an
// AVCaptureVideoDataOutput at once, with the recorder's format and frame duration locked, and does
// attaching or removing the layer change the data output's frame rate? Shows a 160 x 160 panel for
// about two seconds. Exits with 2 when Camera is not authorized, so it never raises the prompt.
//
//   swiftc -O main.swift -o /tmp/camera-preview && /tmp/camera-preview
import AppKit
import AVFoundation

guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
    print("Camera is not authorized for this process's responsible app; nothing measured")
    exit(2)
}

final class Counter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.withLock { frames += 1 }
    }
    func take() -> Int { lock.withLock { defer { frames = 0 }; return frames } }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

Task { @MainActor in
    guard let device = AVCaptureDevice.systemPreferredCamera ?? AVCaptureDevice.default(for: .video) else {
        print("no camera")
        exit(1)
    }
    let session = AVCaptureSession()
    session.beginConfiguration()
    let input = try AVCaptureDeviceInput(device: device)
    session.addInput(input)
    let output = AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = true
    let counter = Counter()
    output.setSampleBufferDelegate(counter, queue: DispatchQueue(label: "frames"))
    session.addOutput(output)
    try device.lockForConfiguration()
    device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
    device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
    device.unlockForConfiguration()
    session.commitConfiguration()

    let control = DispatchQueue(label: "control")
    await withCheckedContinuation { done in control.async { session.startRunning(); done.resume() } }
    _ = counter.take()
    try await Task.sleep(for: .seconds(1))
    print("data output alone: \(counter.take()) frames in 1 s")

    let panel = NSPanel(contentRect: CGRect(x: 80, y: 80, width: 160, height: 160), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .floating
    let view = NSView(frame: panel.contentLayoutRect)
    view.wantsLayer = true
    let preview = AVCaptureVideoPreviewLayer(session: session)
    preview.videoGravity = .resizeAspectFill
    preview.frame = view.bounds
    view.layer = preview
    preview.cornerRadius = 80
    panel.contentView = view
    panel.orderFrontRegardless()
    _ = counter.take()
    try await Task.sleep(for: .seconds(1))
    print("data output with preview layer: \(counter.take()) frames in 1 s; preview connection active \(preview.connection?.isActive ?? false), enabled \(preview.connection?.isEnabled ?? false)")
    print("device frame duration after the layer joined: \(device.activeVideoMinFrameDuration.seconds) s")

    preview.session = nil
    _ = counter.take()
    try await Task.sleep(for: .milliseconds(500))
    print("data output after removing the layer: \(counter.take()) frames in 0.5 s, session running \(session.isRunning)")
    panel.orderOut(nil)
    control.sync { session.stopRunning() }
    exit(0)
}
app.run()
