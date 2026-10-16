import AVFoundation
import CoreMedia
import Foundation
internal import RecordingFormat
import ScreenCaptureKit

actor CaptureSink {
    nonisolated let queue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    struct Plan: Sendable {
        var target: ResolvedTarget
        var codec: VideoCodec
        var frameRate: Int
        var microphone: (uniqueID: String, channels: Int)?
        var layout: RecordingLayout
    }

    private let plan: Plan
    private let report: @Sendable (SessionInput) -> Void
    private let eventsWritten: @Sendable () -> Int
    private var stream: SCStream?
    private var output: StreamOutput?
    private var screen: MovieWriter?
    private var microphone: MovieWriter?
    private var origin: HostTime?
    private var lastFrame: (buffer: CMSampleBuffer, pts: HostTime)?
    private var heartbeat: DispatchSourceTimer?
    private var firstFrameWaiter: CheckedContinuation<HostTime?, Never>?
    private var droppedSinceReport = 0
    private var lastDropReport: HostTime?
    private var lastProgress: HostTime?
    private var stopping = false
    private var streamEnded = false

    init(plan: Plan, eventsWritten: @escaping @Sendable () -> Int, report: @escaping @Sendable (SessionInput) -> Void) {
        queue = DispatchSerialQueue(label: "open-studio.capture")
        self.plan = plan
        self.eventsWritten = eventsWritten
        self.report = report
    }

    func startCapture() async throws(RecordingError) {
        let info = plan.target.display.info
        screen = try MovieWriter(
            url: plan.layout.screen, kind: .screen(codec: plan.codec, pixelSize: info.pixelSize, frameRate: plan.frameRate))
        if let microphone = plan.microphone {
            self.microphone = try MovieWriter(url: plan.layout.microphone, kind: .microphone(channels: microphone.channels))
        }

        let configuration = SCStreamConfiguration()
        configuration.width = Int(info.pixelSize.width)
        configuration.height = Int(info.pixelSize.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(plan.frameRate))
        configuration.showsCursor = false
        configuration.queueDepth = 6
        configuration.capturesAudio = false
        if let microphone = plan.microphone {
            configuration.captureMicrophone = true
            configuration.microphoneCaptureDeviceID = microphone.uniqueID
        }
        let output = StreamOutput(sink: self)
        let stream = SCStream(
            filter: plan.target.filter,
            configuration: configuration, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            if plan.microphone != nil {
                try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: queue)
            }
            try await stream.startCapture()
        } catch {
            throw .captureFailedToStart(error.localizedDescription)
        }
        self.stream = stream
        self.output = output
        startHeartbeat()
    }

    /// ScreenCaptureKit delivers a frame only when the display changes, and the cursor is hidden
    /// from the capture, so a still screen produces no frames at all. A fragmented movie is
    /// readable only up to its last fragment that holds a sample, so a crash during a still
    /// stretch would lose everything after the last change. Re-appending the last frame once per
    /// fragment interval keeps every fragment populated at the cost of one tiny P-frame per second.
    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.heartbeatInterval, repeating: Self.heartbeatInterval, leeway: .milliseconds(50))
        timer.setEventHandler { [self] in assumeIsolated { $0.beat() } }
        timer.resume()
        heartbeat = timer
    }

    private static let heartbeatInterval: DispatchTimeInterval = .seconds(1)

    private func beat() {
        guard !stopping, let screen, let last = lastFrame else { return }
        let now = HostTime.now()
        guard now.duration(since: last.pts) >= .seconds(1) else { return }
        do {
            let copy = try CMSampleBuffer(copying: last.buffer, withNewTiming: [CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: now.cmTime, decodeTimeStamp: .invalid)])
            if try screen.append(copy) { lastFrame = (copy, now) }
        } catch {
            report(.streamFailed(error.localizedDescription))
        }
    }

    func firstFrame(timeout: Duration) async -> HostTime? {
        if let origin { return origin }
        return await withCheckedContinuation { continuation in
            firstFrameWaiter = continuation
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(timeout.nanoseconds))) { [self] in
                assumeIsolated { $0.resolveFirstFrame(nil) }
            }
        }
    }

    func finish(at end: HostTime) async throws(RecordingError) -> Duration {
        stopping = true
        heartbeat?.cancel()
        if let stream, !streamEnded {
            do {
                try await stream.stopCapture()
            } catch {
                throw .captureFailedToStart("stopCapture: \(error.localizedDescription)")
            }
        }
        guard let origin, let screen else { throw .noFramesDelivered }
        let endTime = max(end, origin)
        try await screen.finish(at: endTime)
        if let microphone {
            do {
                try await microphone.finish(at: endTime)
            } catch {
                report(.warning(.microphoneLost(at: endTime.duration(since: origin), error.description)))
            }
        }
        return endTime.duration(since: origin)
    }

    func abandon() async {
        stopping = true
        heartbeat?.cancel()
        resolveFirstFrame(nil)
        if let stream { try? await stream.stopCapture() }
    }

    func streamStopped(_ message: String) {
        streamEnded = true
        guard !stopping else { return }
        report(.streamFailed(message))
    }

    private func resolveFirstFrame(_ time: HostTime?) {
        firstFrameWaiter?.resume(returning: time)
        firstFrameWaiter = nil
    }

    fileprivate func receive(_ buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopping else { return }
        switch type {
        case .screen: receiveScreen(buffer)
        case .microphone: receiveMicrophone(buffer)
        default: break
        }
    }

    private func receiveScreen(_ buffer: CMSampleBuffer) {
        guard buffer.frameStatus == .complete, let screen else { return }
        let pts = HostTime(CMSampleBufferGetPresentationTimeStamp(buffer))
        if origin == nil {
            do {
                try screen.startSession(at: pts)
                try microphone?.startSession(at: pts)
            } catch {
                report(.streamFailed(error.description))
                return
            }
            origin = pts
            lastProgress = pts
            resolveFirstFrame(pts)
        }
        guard let origin else { return }
        do {
            if try screen.append(buffer) {
                lastFrame = (buffer, pts)
                reportDrops(at: pts, since: origin)
            } else {
                droppedSinceReport += 1
            }
        } catch {
            report(.streamFailed(error.description))
            return
        }
        if let lastProgress, pts.duration(since: lastProgress) >= .milliseconds(250) {
            self.lastProgress = pts
            report(.progress(RecordingProgress(
                mediaTime: pts.duration(since: origin), framesWritten: screen.samplesWritten, eventsWritten: eventsWritten())))
        }
    }

    private func reportDrops(at now: HostTime, since origin: HostTime) {
        guard droppedSinceReport > 0 else { return }
        if let last = lastDropReport, now.duration(since: last) < .seconds(1) { return }
        report(.warning(.framesDropped(count: droppedSinceReport)))
        droppedSinceReport = 0
        lastDropReport = now
    }

    private func receiveMicrophone(_ buffer: CMSampleBuffer) {
        guard let origin, let microphone else { return }
        let pts = HostTime(CMSampleBufferGetPresentationTimeStamp(buffer))
        guard pts >= origin else { return }
        do {
            _ = try microphone.append(buffer)
        } catch {
            self.microphone = nil
            report(.warning(.microphoneLost(at: pts.duration(since: origin), error.description)))
        }
    }
}

private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let sink: CaptureSink

    init(sink: CaptureSink) { self.sink = sink }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // CMSampleBuffer carries no Sendable annotation. The closure runs synchronously on the queue
        // that delivered the buffer, which is the actor's executor, so nothing crosses an isolation
        // boundary here.
        nonisolated(unsafe) let buffer = buffer
        sink.assumeIsolated { $0.receive(buffer, of: type) }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let (sink, message) = (sink, error.localizedDescription)
        Task { await sink.streamStopped(message) }
    }
}

extension CMSampleBuffer {
    var frameStatus: SCFrameStatus? {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        return (attachments?.first?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:))
    }
}
