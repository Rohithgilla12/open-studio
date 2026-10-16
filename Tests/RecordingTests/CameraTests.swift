import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import Recording
@testable import RecordingFormat

struct CameraFormatTests {
    typealias Candidate = CameraFormat.Candidate

    @Test func theLargestFormatInsideTheCapThatReaches30FpsWins() throws {
        let plan = try #require(CameraFormat.plan(for: [
            Candidate(width: 640, height: 480, maxFrameRate: 30),
            Candidate(width: 1280, height: 720, maxFrameRate: 60),
            Candidate(width: 1920, height: 1080, maxFrameRate: 15),
            Candidate(width: 3840, height: 2160, maxFrameRate: 30),
        ]))
        #expect(plan == CameraFormat.Plan(formatIndex: 1, width: 1280, height: 720, frameRate: 30))
    }

    @Test func a1080pFormatAt30FpsIsTakenAsItIs() throws {
        let plan = try #require(CameraFormat.plan(for: [
            Candidate(width: 1280, height: 720, maxFrameRate: 30),
            Candidate(width: 1920, height: 1080, maxFrameRate: 30),
        ]))
        #expect(plan == CameraFormat.Plan(formatIndex: 1, width: 1920, height: 1080, frameRate: 30))
    }

    @Test func aSlowCameraKeepsItsOwnRate() throws {
        let plan = try #require(CameraFormat.plan(for: [
            Candidate(width: 1280, height: 720, maxFrameRate: 24),
            Candidate(width: 640, height: 480, maxFrameRate: 29.97),
        ]))
        #expect(plan == CameraFormat.Plan(formatIndex: 0, width: 1280, height: 720, frameRate: 24))
    }

    @Test func onlyFormatsOverTheCapScaleTheSmallestIntoIt() throws {
        let plan = try #require(CameraFormat.plan(for: [
            Candidate(width: 4096, height: 2160, maxFrameRate: 30),
            Candidate(width: 3840, height: 2160, maxFrameRate: 30),
        ]))
        #expect(plan == CameraFormat.Plan(formatIndex: 1, width: 1920, height: 1080, frameRate: 30))
    }

    @Test func aPortraitCameraGetsTheSameAllowance() throws {
        let plan = try #require(CameraFormat.plan(for: [Candidate(width: 1080, height: 1920, maxFrameRate: 30)]))
        #expect(plan.width == 1080 && plan.height == 1920)
    }

    @Test func noFormatsMeansNoPlan() {
        #expect(CameraFormat.plan(for: []) == nil)
        #expect(CameraFormat.plan(for: [Candidate(width: 0, height: 0, maxFrameRate: 30)]) == nil)
    }

    @Test func deskViewIsNeverListed() {
        #expect(!CaptureSources.cameraDeviceTypes.contains(.deskViewCamera))
        #expect(CaptureSources.cameraDeviceTypes.contains(.continuityCamera))
        #expect(CaptureSources.cameraDeviceTypes.contains(.external))
    }
}

struct CameraTrackTests {
    let origin = HostTime(nanoseconds: 100_000_000_000)
    let frame = Duration.milliseconds(33)

    @Test func buffersBeforeTheOriginAreDropped() {
        var track = CameraTrack.waitingForOrigin
        #expect(!track.accepts(origin + .milliseconds(10)))
        track.start(at: origin)
        #expect(!track.accepts(HostTime(nanoseconds: origin.nanoseconds - 1)))
        #expect(track.accepts(origin))
    }

    @Test func buffersMustMoveForward() {
        var track = CameraTrack.waitingForOrigin
        track.start(at: origin)
        track.appended(origin + .milliseconds(100))
        #expect(!track.accepts(origin + .milliseconds(100)))
        #expect(!track.accepts(origin + .milliseconds(50)))
        #expect(track.accepts(origin + .milliseconds(133)))
    }

    @Test func aLostTrackKeepsNothingMoreAndEndsOneFrameAfterItsLastSample() {
        var track = CameraTrack.waitingForOrigin
        track.start(at: origin)
        track.appended(origin + .seconds(1))
        #expect(!track.isLost)
        track.lose()
        #expect(track.isLost)
        #expect(!track.accepts(origin + .seconds(2)))
        #expect(track.end(stoppingAt: origin + .seconds(5), frameInterval: frame) == origin + .seconds(1) + frame)
    }

    @Test func aLiveTrackRunsToTheTakesEnd() {
        var track = CameraTrack.waitingForOrigin
        track.start(at: origin)
        track.appended(origin + .seconds(1))
        #expect(track.end(stoppingAt: origin + .seconds(5), frameInterval: frame) == origin + .seconds(5))
    }

    @Test func aTrackLostBeforeTheOriginStaysEmpty() {
        var track = CameraTrack.waitingForOrigin
        track.lose()
        #expect(track.isLost)
        track.start(at: origin)
        #expect(track.isLost)
        #expect(!track.accepts(origin + .seconds(1)))
        #expect(track.end(stoppingAt: origin + .seconds(5), frameInterval: frame) == origin)
    }
}

struct CameraClockTests {
    @Test func aBufferOnTheHostClockIsKeptAsItIs() throws {
        let buffer = try CameraSamples.buffer(at: HostTime(nanoseconds: 5_000_000_000))
        let moved = try #require(CameraClock.onHostClock(buffer, from: CMClockGetHostTimeClock()))
        #expect(moved.pts == HostTime(nanoseconds: 5_000_000_000))
        #expect(moved.buffer === buffer)
        #expect(try #require(CameraClock.onHostClock(buffer, from: nil)).buffer === buffer)
    }

    @Test func aBufferOnAnotherClockIsMovedOntoTheHostClock() throws {
        let host = CMClockGetHostTimeClock()
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: nil, sourceClock: host, timebaseOut: &timebase)
        let shifted = try #require(timebase)
        let now = CMClockGetTime(host)
        CMTimebaseSetRateAndAnchorTime(shifted, rate: 1, anchorTime: .zero, immediateSourceTime: now)

        let buffer = try CameraSamples.buffer(at: HostTime(nanoseconds: 2_000_000_000))
        let moved = try #require(CameraClock.onHostClock(buffer, from: shifted))
        let expected = HostTime(now).nanoseconds + 2_000_000_000
        #expect(abs(Int64(moved.pts.nanoseconds) - Int64(expected)) < 1_000)
        #expect(HostTime(CMSampleBufferGetPresentationTimeStamp(moved.buffer)) == moved.pts)
    }
}

struct CameraTrackWriterTests {
    let origin = HostTime(nanoseconds: 100_000_000_000)
    let plan = CameraFormat.Plan(formatIndex: 0, width: 64, height: 48, frameRate: 30)

    @Test func mediaTimeZeroIsTheOriginAndALateCameraKeepsItsOffset() async throws {
        let url = try CameraSamples.temporaryMovieURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try CameraTrackWriter(url: url, codec: .h264, plan: plan)
        try writer.start(at: origin)
        #expect(try writer.append(CameraSamples.sample(at: origin + .milliseconds(-100))) == false)
        for index in 0..<30 {
            let pts = origin + .milliseconds(500) + .nanoseconds(Int64(index) * 33_333_333)
            try await CameraSamples.appendWhenWriterReady(at: pts, to: writer)
        }
        #expect(try await writer.finish(at: origin + .seconds(2)) == .recorded)

        let read = try await CameraSamples.read(url)
        #expect(read.samples == 30)
        #expect(abs(read.firstSampleMovieTime - 0.5) < 0.001, "first camera frame at \(read.firstSampleMovieTime) s")
        #expect(abs(read.duration - 2) < 0.001, "a live track runs to the stop time, \(read.duration) s")
    }

    @Test func aLostCameraEndsItsMovieOneFrameAfterItsLastSample() async throws {
        let url = try CameraSamples.temporaryMovieURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try CameraTrackWriter(url: url, codec: .h264, plan: plan)
        try writer.start(at: origin)
        for index in 0..<30 {
            try await CameraSamples.appendWhenWriterReady(at: origin + .nanoseconds(Int64(index) * 33_333_333), to: writer)
        }
        writer.lose()
        #expect(try writer.append(CameraSamples.sample(at: origin + .seconds(1))) == false)
        #expect(try await writer.finish(at: origin + .seconds(4)) == .recorded)

        let read = try await CameraSamples.read(url)
        #expect(read.samples == 30)
        #expect(abs(read.firstSampleMovieTime) < 0.001)
        let lastSample = 29 * 0.033333333
        #expect(abs(read.duration - (lastSample + 0.033333333)) < 0.002, "ends at \(read.duration) s, not at the take's 4 s")
    }

    @Test func aCameraThatNeverDeliveredLeavesNoMovie() async throws {
        let url = try CameraSamples.temporaryMovieURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try CameraTrackWriter(url: url, codec: .h264, plan: plan)
        writer.lose()
        try writer.start(at: origin)

        #expect(try await writer.finish(at: origin + .seconds(3)) == .removedEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path), "a movie with no samples does not open, so none is left")
    }
}

struct CameraPermissionTests {
    let report = PermissionReport(screenRecording: .granted, inputMonitoring: .granted, microphone: .granted, camera: .denied)

    @Test func theCameraIsNeededOnlyWhenOneIsSelected() {
        let directory = URL(filePath: "/tmp")
        #expect(report.missing(for: RecordingConfiguration(outputDirectory: directory)) == [])
        #expect(report.missing(for: RecordingConfiguration(outputDirectory: directory, camera: .systemDefault)) == [.camera])
        #expect(report.missing(for: RecordingConfiguration(outputDirectory: directory, camera: .device(uniqueID: "x"))) == [.camera])
    }
}

struct CameraRecoveryTests {
    @Test func recoveryFinalisesACameraTakeWhoseMoviesRead() async throws {
        let take = try await CameraSamples.crashedTake(withCameraMovie: true)
        defer { try? FileManager.default.removeItem(at: take) }

        let finished = try await RecordingSession.recover(at: take)

        guard case .recovered(let message) = finished.termination else {
            Issue.record("expected recovered, got \(finished.termination)")
            return
        }
        #expect(message?.contains("camera.mov") == false, "\(message ?? "")")
        let manifest = try WireManifest.decode(Data(contentsOf: RecordingLayout(directory: take).manifest))
        #expect(manifest.camera != nil)
    }

    @Test func recoveryNotesACameraMovieItCannotRead() async throws {
        let take = try await CameraSamples.crashedTake(withCameraMovie: false)
        defer { try? FileManager.default.removeItem(at: take) }

        let finished = try await RecordingSession.recover(at: take)

        guard case .recovered(let message) = finished.termination else {
            Issue.record("expected recovered, got \(finished.termination)")
            return
        }
        #expect(message?.contains("camera.mov unreadable: missing") == true, "\(message ?? "")")
    }
}

enum CameraSamples {
    static func temporaryMovieURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "CameraTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "camera.mov", directoryHint: .notDirectory)
    }

    static func buffer(at pts: HostTime, width: Int = 64, height: Int = 48) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        let image = try #require(pixelBuffer)
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image), 0x80, CVPixelBufferGetDataSize(image))
        CVPixelBufferUnlockBaseAddress(image, [])
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &description)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts.cmTime, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: image, formatDescription: try #require(description), sampleTiming: &timing,
            sampleBufferOut: &sample)
        return try #require(sample)
    }

    static func sample(at pts: HostTime) throws -> HostClockSample {
        try #require(CameraClock.onHostClock(try buffer(at: pts), from: nil))
    }

    static func appendWhenWriterReady(at pts: HostTime, to writer: CameraTrackWriter) async throws {
        let sample = try sample(at: pts)
        for _ in 0..<500 {
            if try writer.append(sample) { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("the writer never accepted the buffer at \(pts)")
    }

    struct Read {
        var duration: Double
        var samples: Int
        var firstSampleMovieTime: Double
    }

    static func read(_ url: URL) async throws -> Read {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var samples = 0
        while let sample = output.copyNextSampleBuffer() { samples += CMSampleBufferGetNumSamples(sample) }
        let media = try #require(try await track.load(.segments).first { !$0.isEmpty })
        return Read(duration: duration, samples: samples, firstSampleMovieTime: media.timeMapping.target.start.seconds)
    }

    static func crashedTake(withCameraMovie: Bool) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "CameraTests-\(UUID().uuidString).osrec", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let layout = RecordingLayout(directory: directory)
        let origin = HostTime(nanoseconds: 50_000_000_000)
        let plan = CameraFormat.Plan(formatIndex: 0, width: 64, height: 48, frameRate: 30)
        for url in [layout.screen] + (withCameraMovie ? [layout.camera] : []) {
            let writer = try CameraTrackWriter(url: url, codec: .h264, plan: plan)
            try writer.start(at: origin)
            for index in 0..<30 { try await appendWhenWriterReady(at: origin + .nanoseconds(Int64(index) * 33_333_333), to: writer) }
            _ = try await writer.finish(at: origin + .seconds(1))
        }
        let manifest = WireManifest(
            id: RecordingID(UUID()), createdAt: Date(),
            recorder: WireRecorderInfo(name: "test", version: "0", osVersion: "27.0"),
            clock: WireClock(originHostTimeNanos: origin.nanoseconds),
            display: WireDisplay(displayID: 1, name: "Test", pointFrame: WireRect(x: 0, y: 0, width: 64, height: 48), refreshRate: 60),
            screen: WireScreen(pixelWidth: 64, pixelHeight: 48, codec: .h264, maxFrameRate: 30),
            microphone: nil,
            camera: WireCamera(deviceName: "Synthetic Camera", pixelWidth: 64, pixelHeight: 48, frameRate: 30))
        try manifest.write(to: layout)
        return directory
    }
}
