import AVFoundation
import CoreMedia
import Foundation
internal import RecordingFormat
import ScreenCaptureKit

/// Owns the SCStream and both movie writers.
///
/// The actor's executor is the serial queue ScreenCaptureKit delivers sample buffers on, so the
/// per-frame path enters isolation with `assumeIsolated` and never hops. At 60 to 120 frames per
/// second an `await` per frame would add scheduling jitter for nothing.
actor CaptureSink {
    nonisolated let queue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    struct Plan: Sendable {
        var display: ResolvedDisplay
        var configuration: RecordingConfiguration
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
    private var firstFrameWaiter: CheckedContinuation<HostTime?, Never>?
    private var droppedSinceReport = 0
    private var lastDropReport: HostTime?
    private var lastProgress: HostTime?
    private var stopping = false

    init(plan: Plan, eventsWritten: @escaping @Sendable () -> Int, report: @escaping @Sendable (SessionInput) -> Void) {
        queue = DispatchSerialQueue(label: "open-studio.capture")
        self.plan = plan
        self.eventsWritten = eventsWritten
        self.report = report
    }

    func startCapture() async throws(RecordingError) {
        let info = plan.display.info
        screen = try MovieWriter(
            url: plan.layout.screen, kind: .screen(codec: plan.configuration.codec, pixelSize: info.pixelSize, frameRate: plan.frameRate))
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
            filter: SCContentFilter(display: plan.display.display, excludingWindows: []),
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
    }

    /// The PTS of the first complete frame, which both writers' sessions start at. Nil on timeout.
    func firstFrame(timeout: Duration) async -> HostTime? {
        if let origin { return origin }
        return await withCheckedContinuation { continuation in
            firstFrameWaiter = continuation
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(timeout.nanoseconds))) { [self] in
                assumeIsolated { $0.resolveFirstFrame(nil) }
            }
        }
    }

    /// Stops the stream and ends both writer sessions at `end`. Returns the screen duration.
    func finish(at end: HostTime) async throws(RecordingError) -> Duration {
        stopping = true
        if let stream {
            // A stream that already stopped on its own throws here; the writers still hold the frames.
            try? await stream.stopCapture()
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

    /// Stops the stream without finishing the writers. For a failed start, whose directory is
    /// about to be removed.
    func abandon() async {
        stopping = true
        resolveFirstFrame(nil)
        if let stream { try? await stream.stopCapture() }
    }

    func streamStopped(_ message: String) {
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

/// The ScreenCaptureKit callbacks. Sample buffers arrive on `sink.queue`, so they enter the actor
/// without a hop; the stop notification arrives on an arbitrary queue and hops.
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
