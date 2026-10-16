import AVFoundation
import CoreMedia
public import Foundation
internal import RecordingFormat
import Synchronization

/// A recording in progress. The only way to get one is `start`, so there is no idle or
/// half-configured session to misuse: holding a `RecordingSession` means frames are being written.
///
/// Runs in the caller's process. Crash safety comes from the directory format, not from process
/// isolation: if this process dies, everything written up to the last movie fragment (1 s) and the
/// last event flush (100 ms) stays on disk, and `recover(at:)` finalizes it.
public actor RecordingSession {
    public nonisolated let directory: URL
    /// Progress, warnings, and exactly one `.ended`, after which the stream finishes.
    public nonisolated let updates: AsyncStream<RecordingUpdate>

    private let continuation: AsyncStream<RecordingUpdate>.Continuation
    private var phase: SessionPhase
    private var finalization: Task<FinishedRecording, Never>?
    private let capture: CaptureSink
    private let input: InputCapture
    private let eventLog: EventLogWriter
    private let lock: DirectoryLock
    private let layout: RecordingLayout
    private let origin: HostTime
    private let maxDuration: Duration?
    private var manifest: WireManifest
    private var durationTimer: Task<Void, Never>?

    static let firstFrameTimeout: Duration = .seconds(5)

    /// Checks permissions, creates the directory, starts capture, and returns once the first
    /// complete screen frame is on disk and `recording.json` exists.
    ///
    /// Either returns a live session or throws and leaves nothing behind: on any failure the
    /// half-created directory is removed.
    public static func start(_ configuration: RecordingConfiguration) async throws(RecordingError) -> RecordingSession {
        let missing = Permissions.check().missing(for: configuration)
        guard missing.isEmpty else { throw .missingPermissions(missing) }
        let target = try await CaptureSources.resolve(configuration.target)
        let display = target.display
        let microphone = try CaptureSources.resolve(configuration.microphone)
        let layout = try createDirectory(under: configuration.outputDirectory)
        guard let lock = try acquireLock(in: layout) else {
            try? FileManager.default.removeItem(at: layout.directory)
            throw .captureFailedToStart("another recorder holds \(layout.lock.path)")
        }

        let refresh = display.info.refreshRate
        let frameRate = max(1, refresh > 0 ? min(configuration.maxFrameRate, Int(refresh.rounded())) : configuration.maxFrameRate)
        let mapping = DisplayMapping(displayPointFrame: display.info.pointFrame, pixelSize: display.info.pixelSize)
        let inlet = SessionInlet()
        let input = InputCapture(displayScale: mapping.scale.width, onTapReenabled: inlet.tapReenabled)
        let capture = CaptureSink(
            plan: CaptureSink.Plan(
                target: target, codec: configuration.codec, frameRate: frameRate,
                microphone: microphone.map { ($0.uniqueID, $0.channelCount) }, layout: layout),
            eventsWritten: { inlet.eventsWritten }, report: inlet.send)

        do {
            try await input.start()
            try await capture.startCapture()
            guard let origin = await capture.firstFrame(timeout: firstFrameTimeout) else { throw RecordingError.noFramesDelivered }
            let eventLog = EventLogWriter(
                layout: layout, tapBuffer: input.tapBuffer, cursorBuffer: input.cursorBuffer,
                conversion: EventConversion(origin: origin, mapping: mapping))
            try await eventLog.begin(snapshot: await input.snapshot())
            let manifest = WireManifest(
                id: RecordingID(UUID()),
                createdAt: Date(),
                recorder: WireRecorderInfo(
                    name: ProcessInfo.processInfo.processName, version: "0.1.0",
                    osVersion: ProcessInfo.processInfo.operatingSystemVersionString),
                clock: WireClock(originHostTimeNanos: origin.nanoseconds),
                display: WireDisplay(
                    displayID: display.info.id, name: display.info.name,
                    pointFrame: WireRect(display.info.pointFrame), refreshRate: refresh),
                screen: WireScreen(
                    pixelWidth: Int(display.info.pixelSize.width), pixelHeight: Int(display.info.pixelSize.height),
                    codec: WireCodec(configuration.codec), maxFrameRate: frameRate),
                area: target.area.map(WireRect.init),
                microphone: microphone.map {
                    WireMicrophone(deviceName: $0.localizedName, sampleRate: 48_000, channelCount: $0.channelCount)
                })
            try manifest.write(to: layout)
            let session = RecordingSession(
                layout: layout, capture: capture, input: input, eventLog: eventLog, lock: lock,
                origin: origin, maxDuration: configuration.maxDuration, manifest: manifest)
            await session.scheduleDurationLimit()
            inlet.attach(session: session, eventLog: eventLog, origin: origin)
            return session
        } catch {
            await input.stop()
            await capture.abandon()
            lock.release()
            try? FileManager.default.removeItem(at: layout.directory)
            throw (error as? RecordingError) ?? .captureFailedToStart(String(describing: error))
        }
    }

    /// Stops capture and finalizes the directory. Idempotent: every call, including calls made
    /// after the session ended on its own, returns the same `FinishedRecording`.
    ///
    /// Never throws. A finalization problem still leaves a readable directory; it is reported
    /// through `termination`, and the manifest stays `.recording` so `recover(at:)` can finish.
    public func stop() async -> FinishedRecording {
        handle(.stopRequested)
        return await finalization!.value
    }

    private init(
        layout: RecordingLayout, capture: CaptureSink, input: InputCapture, eventLog: EventLogWriter,
        lock: DirectoryLock, origin: HostTime, maxDuration: Duration?, manifest: WireManifest
    ) {
        directory = layout.directory
        self.layout = layout
        self.capture = capture
        self.input = input
        self.eventLog = eventLog
        self.lock = lock
        self.origin = origin
        self.maxDuration = maxDuration
        self.manifest = manifest
        phase = .recording(RecordingProgress(mediaTime: .zero, framesWritten: 1, eventsWritten: eventLog.eventsWritten))
        (updates, continuation) = AsyncStream.makeStream(of: RecordingUpdate.self)
    }

    func handle(_ input: SessionInput) {
        let transition = SessionPhase.next(phase, input)
        phase = transition.phase
        for effect in transition.effects {
            switch effect {
            case .emit(let update):
                continuation.yield(update)
                if case .warning(let warning) = update { record(warning) }
                if case .ended = update { continuation.finish() }
            case .finalize(let reason):
                finalization = Task { await self.finalize(reason) }
            }
        }
    }

    private func scheduleDurationLimit() {
        guard let maxDuration else { return }
        let deadline = origin + maxDuration
        durationTimer = Task {
            let remaining = deadline.duration(since: .now())
            if remaining > .zero { try? await Task.sleep(for: remaining) }
            guard !Task.isCancelled else { return }
            handle(.durationReached)
        }
    }

    private func record(_ warning: RecordingWarning) {
        let wire: ManifestWarning? = switch warning {
        case .microphoneLost(let at, let message): .microphoneLost(at: MediaTime(at), message: message)
        case .inputTapReenabled(let at): .inputTapReenabled(at: MediaTime(at))
        case .framesDropped, .manifestWriteFailed: nil
        }
        guard let wire else { return }
        manifest.warnings.append(wire)
        do {
            try manifest.write(to: layout)
        } catch {
            continuation.yield(.warning(.manifestWriteFailed("\(error)")))
        }
    }

    private func finalize(_ reason: StopReason) async -> FinishedRecording {
        durationTimer?.cancel()
        let end: HostTime = if reason == .durationReached, let maxDuration { origin + maxDuration } else { .now() }
        await input.stop()
        var problems: [String] = []
        do {
            _ = try await eventLog.finish()
        } catch {
            problems.append("event log: \(error)")
        }
        var duration: Duration = .zero
        do {
            duration = try await capture.finish(at: end)
        } catch {
            problems.append(error.description)
        }
        if problems.isEmpty {
            manifest.status = .finalized(duration: MediaTime(duration), termination: reason.wire)
            do {
                try manifest.write(to: layout)
            } catch {
                problems.append("manifest: \(error)")
            }
        }
        lock.release()
        let finished = FinishedRecording(
            directory: directory, duration: duration, hasMicrophone: manifest.microphone != nil,
            termination: problems.isEmpty ? reason.termination : .finalizationFailed(problems.joined(separator: "; ")))
        handle(.finalized(finished))
        return finished
    }

    private static func acquireLock(in layout: RecordingLayout) throws(RecordingError) -> DirectoryLock? {
        do {
            return try DirectoryLock.acquire(in: layout)
        } catch {
            try? FileManager.default.removeItem(at: layout.directory)
            throw .outputDirectoryUnwritable(layout.directory, error.localizedDescription)
        }
    }

    private static func createDirectory(under parent: URL) throws(RecordingError) -> RecordingLayout {
        let base = RecordingLayout.directoryName(for: Date())
        let stem = String(base.dropLast(RecordingLayout.packageExtension.count + 1))
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            for attempt in 1... {
                let name = attempt == 1 ? base : "\(stem)-\(attempt).\(RecordingLayout.packageExtension)"
                let directory = parent.appending(path: name, directoryHint: .isDirectory)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                    return RecordingLayout(directory: directory)
                } catch CocoaError.fileWriteFileExists {
                    continue
                }
            }
            fatalError("unreachable")
        } catch {
            throw .outputDirectoryUnwritable(parent, error.localizedDescription)
        }
    }
}

private final class SessionInlet: Sendable {
    private struct Target {
        var session: RecordingSession?
        var eventLog: EventLogWriter?
        var origin: HostTime?
        var pending: [SessionInput] = []
    }

    private let target = Mutex(Target())

    func send(_ input: SessionInput) {
        let session = target.withLock { target -> RecordingSession? in
            guard let session = target.session else {
                target.pending.append(input)
                return nil
            }
            return session
        }
        if let session { Task { await session.handle(input) } }
    }

    func tapReenabled(at time: HostTime) {
        let origin = target.withLock(\.origin)
        send(.warning(.inputTapReenabled(at: origin.map { max(.zero, time.duration(since: $0)) } ?? .zero)))
    }

    var eventsWritten: Int { target.withLock { $0.eventLog?.eventsWritten ?? 0 } }

    func attach(session: RecordingSession, eventLog: EventLogWriter, origin: HostTime) {
        let pending = target.withLock { target in
            target.session = session
            target.eventLog = eventLog
            target.origin = origin
            defer { target.pending = [] }
            return target.pending
        }
        Task {
            for input in pending { await session.handle(input) }
        }
    }
}

extension StopReason {
    var wire: WireTermination {
        switch self {
        case .userStopped: .userStopped
        case .durationReached: .durationReached
        case .streamFailed(let message): .streamFailed(message: message)
        }
    }
}

extension MediaTime {
    init(_ duration: Duration) { self.init(microseconds: duration.nanoseconds / 1000) }
}

extension WireRect {
    init(_ rect: CGRect) { self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height) }
}

extension WireCodec {
    init(_ codec: VideoCodec) {
        switch codec {
        case .hevc: self = .hevc
        case .h264: self = .h264
        }
    }
}

extension AVCaptureDevice {
    var channelCount: Int {
        let description = activeFormat.formatDescription
        let channels = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee.mChannelsPerFrame ?? 1
        return min(max(1, Int(channels)), 2)
    }
}
