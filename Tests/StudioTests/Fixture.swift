import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Recording
import Render
@testable import Studio
import Synchronization
import Testing

struct Library {
    let url: URL
    let take: URL

    static func make(file: StaticString = #filePath) async throws -> Library {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "StudioTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let committed = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/recordings/20261013-five-clicks.osrec", directoryHint: .isDirectory)
        let take = url.appending(path: "20261013-120000.osrec", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: committed, to: take)
        try await writeMovie(to: take.appending(path: "screen.mov", directoryHint: .notDirectory), seconds: 2)
        return Library(url: url, take: take)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    var projectFile: URL { take.appending(path: "project.json", directoryHint: .notDirectory) }

    private static func writeMovie(to url: URL, seconds: Int) async throws {
        let (width, height, fps) = (1920, 1080, 10)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        writer.add(input)
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        let buffer = try #require(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0x80, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &description)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for index in 0..<(seconds * fps) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
                presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: nil, imageBuffer: buffer, formatDescription: description!, sampleTiming: &timing, sampleBufferOut: &sample)
            input.append(sample!)
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }
}

actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

final class FakeRecording: RecordingHandle {
    let directory: URL
    let updates: AsyncStream<RecordingUpdate>
    private let continuation: AsyncStream<RecordingUpdate>.Continuation
    private let stops = Atomic(0)

    private let endsOnStop: Bool

    init(directory: URL, endsOnStop: Bool = true) {
        self.directory = directory
        self.endsOnStop = endsOnStop
        (updates, continuation) = AsyncStream.makeStream()
    }

    var stopCount: Int { stops.load(ordering: .relaxed) }

    var finished: FinishedRecording {
        FinishedRecording(directory: directory, duration: .seconds(2), hasMicrophone: false, termination: .userStopped)
    }

    func stop() async -> FinishedRecording {
        stops.add(1, ordering: .relaxed)
        if endsOnStop { end() }
        return finished
    }

    func progress(_ seconds: Int) {
        continuation.yield(.progress(RecordingProgress(mediaTime: .seconds(seconds), framesWritten: seconds * 60, eventsWritten: 0)))
    }

    func end() {
        continuation.yield(.ended(finished))
        continuation.finish()
    }
}

@MainActor
final class Calls {
    var starts = 0
    var configurations: [RecordingConfiguration] = []
    var areaRequests: [(display: DisplaySelection, preset: CGRect?)] = []
    var hidden: [Bool] = []
}

extension StudioServices {
    @MainActor
    static func fake(
        calls: Calls,
        start: @escaping @Sendable () async throws(RecordingError) -> any RecordingHandle = { throw .noFramesDelivered },
        selectArea: AreaSelection = .cancelled,
        windows: [WindowInfo] = [],
        export: @escaping Exporter = { _, _, _ throws(ExportError) in throw .cancelled }
    ) -> StudioServices {
        StudioServices(
            startRecording: { configuration throws(RecordingError) in
                await MainActor.run {
                    calls.starts += 1
                    calls.configurations.append(configuration)
                }
                return try await start()
            },
            selectArea: { display, preset in
                calls.areaRequests.append((display, preset))
                return selectArea
            },
            listWindows: { windows },
            export: export,
            setAppHidden: { calls.hidden.append($0) },
            openURL: { _ in })
    }
}

extension StudioModel {
    var phaseName: String {
        switch phase {
        case .home: "home"
        case .recording(let live):
            switch live.stage {
            case .starting: "recording.starting"
            case .live: "recording.live"
            case .finishing: "recording.finishing"
            }
        case .editing: "editing"
        case .exporting: "exporting"
        }
    }
}

@MainActor
func eventually(_ timeout: Duration = .seconds(10), _ predicate: () -> Bool) async -> Bool {
    let start = ContinuousClock.now
    while ContinuousClock.now - start < timeout {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return predicate()
}
