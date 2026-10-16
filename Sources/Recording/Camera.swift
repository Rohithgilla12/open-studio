import AVFoundation
import CoreMedia
import Foundation

enum CameraFormat {
    struct Candidate: Sendable, Equatable {
        var width: Int
        var height: Int
        var maxFrameRate: Double
    }

    struct Plan: Sendable, Equatable {
        var formatIndex: Int
        /// The movie's size: the format's own size, or that size scaled into the cap.
        var width: Int
        var height: Int
        var frameRate: Double
    }

    static let cap = (long: 1920, short: 1080)
    static let frameRate = 30.0

    /// The largest format inside the cap that reaches 30 fps; failing that, the largest inside the
    /// cap; failing that, the smallest format, scaled into the cap. nil only when there are none.
    static func plan(for candidates: [Candidate]) -> Plan? {
        let indexed = candidates.enumerated().filter { $0.element.width > 0 && $0.element.height > 0 }
        let fitting = indexed.filter { fits($0.element) }
        let area = { (entry: (offset: Int, element: Candidate)) in entry.element.width * entry.element.height }
        let chosen = fitting.filter { $0.element.maxFrameRate >= frameRate }.max { area($0) < area($1) }
            ?? fitting.max { area($0) < area($1) }
            ?? indexed.min { area($0) < area($1) }
        guard let chosen else { return nil }
        let (width, height) = scaledIntoCap(chosen.element)
        return Plan(
            formatIndex: chosen.offset, width: width, height: height,
            frameRate: min(frameRate, chosen.element.maxFrameRate))
    }

    private static func fits(_ candidate: Candidate) -> Bool {
        max(candidate.width, candidate.height) <= cap.long && min(candidate.width, candidate.height) <= cap.short
    }

    private static func scaledIntoCap(_ candidate: Candidate) -> (Int, Int) {
        guard !fits(candidate) else { return (candidate.width, candidate.height) }
        let long = Double(max(candidate.width, candidate.height)), short = Double(min(candidate.width, candidate.height))
        let scale = min(Double(cap.long) / long, Double(cap.short) / short)
        func even(_ v: Double) -> Int { max(2, Int((v * scale / 2).rounded(.down)) * 2) }
        return (even(Double(candidate.width)), even(Double(candidate.height)))
    }
}

enum CameraClock {
    /// `AVCaptureSession` stamps buffers on its `synchronizationClock`, which is usually the host
    /// clock but is not promised to be. Every other source is on the host clock, so a buffer from
    /// any other clock is moved onto it and retimed.
    static func onHostClock(_ buffer: CMSampleBuffer, from clock: CMClockOrTimebase?) -> HostClockSample? {
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard pts.isValid else { return nil }
        let host = CMClockGetHostTimeClock()
        guard let clock, !CFEqual(clock, host) else { return HostClockSample(buffer: buffer, pts: HostTime(pts)) }
        let converted = CMSyncConvertTime(pts, from: clock, to: host)
        guard converted.isValid else { return nil }
        let timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(buffer), presentationTimeStamp: converted, decodeTimeStamp: .invalid)
        guard let retimed = try? CMSampleBuffer(copying: buffer, withNewTiming: [timing]) else { return nil }
        return HostClockSample(buffer: retimed, pts: HostTime(converted))
    }
}

/// A camera buffer whose timing is on the host clock. Only `CameraClock` makes one.
struct HostClockSample {
    let buffer: CMSampleBuffer
    let pts: HostTime

    fileprivate init(buffer: CMSampleBuffer, pts: HostTime) {
        self.buffer = buffer
        self.pts = pts
    }
}

/// The camera track's life: which buffers it keeps and where the movie ends.
enum CameraTrack: Sendable, Equatable {
    case waitingForOrigin
    case recording(origin: HostTime, lastSample: HostTime?)
    case lost(origin: HostTime, lastSample: HostTime?)
    /// Lost before the screen's first frame. The movie starts its session at the origin and stays
    /// empty.
    case lostBeforeOrigin

    mutating func start(at origin: HostTime) {
        switch self {
        case .waitingForOrigin: self = .recording(origin: origin, lastSample: nil)
        case .lostBeforeOrigin: self = .lost(origin: origin, lastSample: nil)
        case .recording, .lost: break
        }
    }

    func accepts(_ pts: HostTime) -> Bool {
        guard case .recording(let origin, let last) = self else { return false }
        return pts >= origin && last.map { pts > $0 } ?? true
    }

    var hasSamples: Bool {
        switch self {
        case .recording(_, let last), .lost(_, let last): last != nil
        case .waitingForOrigin, .lostBeforeOrigin: false
        }
    }

    mutating func appended(_ pts: HostTime) {
        if case .recording(let origin, _) = self { self = .recording(origin: origin, lastSample: pts) }
    }

    var isLost: Bool {
        switch self {
        case .waitingForOrigin, .recording: false
        case .lost, .lostBeforeOrigin: true
        }
    }

    mutating func lose() {
        switch self {
        case .waitingForOrigin: self = .lostBeforeOrigin
        case .recording(let origin, let last): self = .lost(origin: origin, lastSample: last)
        case .lost, .lostBeforeOrigin: break
        }
    }

    /// A live track runs to the take's end, like the screen. A lost one ends one frame after its last
    /// sample, so the last picture is not held as a frozen frame until the take ends.
    func end(stoppingAt stop: HostTime, frameInterval: Duration) -> HostTime {
        switch self {
        case .waitingForOrigin, .lostBeforeOrigin, .recording: stop
        case .lost(let origin, let last): min(stop, last.map { $0 + frameInterval } ?? origin)
        }
    }
}

final class CameraTrackWriter {
    private let writer: MovieWriter
    private let frameInterval: Duration
    private(set) var track = CameraTrack.waitingForOrigin

    init(url: URL, codec: VideoCodec, plan: CameraFormat.Plan) throws(RecordingError) {
        let frameRate = max(1, Int(plan.frameRate.rounded()))
        writer = try MovieWriter(
            url: url, kind: .video(codec: codec, pixelSize: CGSize(width: plan.width, height: plan.height), frameRate: frameRate))
        frameInterval = .nanoseconds(Int64(1e9 / max(plan.frameRate, 1)))
    }

    func start(at origin: HostTime) throws(RecordingError) {
        try writer.startSession(at: origin)
        track.start(at: origin)
    }

    /// Whether the buffer was written. False for a buffer before the origin, out of order, after
    /// the track was lost, or while the encoder is busy.
    func append(_ sample: HostClockSample) throws(RecordingError) -> Bool {
        guard track.accepts(sample.pts), try writer.append(sample.buffer) else { return false }
        track.appended(sample.pts)
        return true
    }

    func lose() { track.lose() }

    enum Outcome: Sendable, Equatable {
        case recorded
        /// No frame ever arrived, so the movie was removed: a movie with no samples does not open,
        /// and the take should not name a camera it does not have.
        case removedEmpty
    }

    func finish(at stop: HostTime) async throws(RecordingError) -> Outcome {
        guard track.hasSamples else {
            writer.cancel()
            return .removedEmpty
        }
        try await writer.finish(at: track.end(stoppingAt: stop, frameInterval: frameInterval))
        return .recorded
    }
}

/// `@unchecked` because the AVFoundation objects carry no Sendable annotation; each is configured
/// in `init` and then only started and stopped.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let control = DispatchQueue(label: "open-studio.camera")
    private let onFrame: (CMSampleBuffer, CMClock?) -> Void
    private var observers: [any NSObjectProtocol] = []

    /// `onLost` runs once per notification, on an arbitrary thread.
    init(
        _ camera: ResolvedCamera, queue: DispatchSerialQueue,
        onFrame: @escaping (CMSampleBuffer, CMClock?) -> Void, onLost: @escaping @Sendable (String) -> Void
    ) throws(RecordingError) {
        self.onFrame = onFrame
        super.init()
        let device = camera.device
        let name = device.localizedName
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw .captureFailedToStart("\(name): \(error.localizedDescription)")
        }
        guard session.canAddInput(input) else { throw .captureFailedToStart("\(name) cannot be added to a capture session") }
        session.addInput(input)
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: camera.plan.width,
            kCVPixelBufferHeightKey as String: camera.plan.height,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw .captureFailedToStart("\(name) cannot deliver video frames") }
        session.addOutput(output)
        // Set after the input joins the session, which would otherwise apply its preset over it.
        do {
            try device.lockForConfiguration()
        } catch {
            throw .captureFailedToStart("\(name) is in use: \(error.localizedDescription)")
        }
        device.activeFormat = camera.format
        let interval = Self.frameInterval(for: camera.format, frameRate: camera.plan.frameRate)
        device.activeVideoMinFrameDuration = interval
        device.activeVideoMaxFrameDuration = interval
        device.unlockForConfiguration()

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
                onLost("capture error: \(error?.localizedDescription ?? "unknown")")
            },
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { _ in
                onLost("capture was interrupted")
            },
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { _ in
                onLost("\(name) was disconnected")
            },
        ]
    }

    /// Blocks until the camera runs, which can take a few hundred milliseconds.
    func start() { control.sync { session.startRunning() } }

    /// Returns at once. `stopRunning` blocks until the session has stopped, and the caller is the
    /// queue that frames are delivered on, so waiting there could wait on its own frames.
    func stop() {
        control.async { [self] in
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            if session.isRunning { session.stopRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onFrame(sampleBuffer, session.synchronizationClock)
    }

    /// AVFoundation raises an exception for a frame duration outside the format's ranges, so the
    /// planned rate is clamped into one of them.
    private static func frameInterval(for format: AVCaptureDevice.Format, frameRate: Double) -> CMTime {
        let ranges = format.videoSupportedFrameRateRanges
        if let range = ranges.first(where: { $0.minFrameRate <= frameRate && frameRate <= $0.maxFrameRate }) {
            return max(range.minFrameDuration, CMTime(seconds: 1 / frameRate, preferredTimescale: 30_000))
        }
        return ranges.max { $0.maxFrameRate < $1.maxFrameRate }?.minFrameDuration ?? CMTime(value: 1, timescale: 30)
    }
}
