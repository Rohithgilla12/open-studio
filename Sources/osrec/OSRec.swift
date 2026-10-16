import ArgumentParser
import AVFoundation
import Darwin
import Foundation
import Recording
internal import RecordingFormat
import Synchronization

@main
struct OSRec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "osrec",
        abstract: "Record a display, an area, or a window with input events into an .osrec directory, and inspect recordings.",
        subcommands: [
            PermissionsCommand.self, Displays.self, Windows.self, Record.self, Recover.self, Inspect.self, ExportCommand.self,
        ])
}

struct PermissionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "permissions", abstract: "Print each permission's status. Exit 1 if a recording would fail.")

    @Flag(help: "Show the system prompts for permissions that are not granted.") var request = false
    @Flag(help: "Also require microphone access.") var mic = false

    func run() async throws {
        var report = Permissions.check()
        if request {
            for permission in Permission.allCases where report.status(of: permission) != .granted {
                let status = await Permissions.request(permission)
                print("requested \(permission): \(status). Screen Recording and Input Monitoring apply after relaunch.")
            }
            report = Permissions.check()
        }
        for permission in Permission.allCases {
            print("\(permission.description): \(report.status(of: permission))")
        }
        print("grants belong to \(Permissions.responsibleProcess)")
        let probe = RecordingConfiguration(outputDirectory: URL(filePath: "."), microphone: mic ? .systemDefault : .none)
        let missing = report.missing(for: probe)
        guard missing.isEmpty else {
            print(RecordingError.missingPermissions(missing))
            throw ExitCode(1)
        }
    }
}

struct Displays: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List displays and microphones.")

    func run() async throws {
        for display in try await CaptureSources.displays() {
            print(
                "display \(display.id)\(display.isMain ? " (main)" : ""): \(display.name), "
                    + "\(Int(display.pixelSize.width))x\(Int(display.pixelSize.height)) px, "
                    + "\(Int(display.pointSize.width))x\(Int(display.pointSize.height)) pt at "
                    + "(\(Int(display.pointFrame.minX)), \(Int(display.pointFrame.minY))), \(Int(display.refreshRate)) Hz")
        }
        for microphone in CaptureSources.microphones() {
            print("microphone \(microphone.id)\(microphone.isDefault ? " (default)" : ""): \(microphone.name)")
        }
    }
}

struct Windows: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the windows `record --window` accepts, frontmost first.")

    func run() async throws {
        for window in CaptureSources.windows() {
            let name = window.title.map { "\(window.appName): \($0)" } ?? window.appName
            print(
                "window \(window.id): \(name), \(Int(window.frame.width))x\(Int(window.frame.height)) pt at "
                    + "(\(Int(window.frame.minX)), \(Int(window.frame.minY))) on display \(window.displayID)")
        }
    }
}

struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record a display, an area of it, or a window. Ctrl-C stops cleanly.",
        discussion: """
            The whole display is always captured; an area or a window is recorded as the part of it the take \
            shows, and export crops to it.
            """)

    @Option(help: "Display ID from `osrec displays`. Default: the main display.") var display: UInt32?
    @Option(help: "Record only x,y,width,height of the display, in points from its top-left corner.") var area: AreaArgument?
    @Option(help: "Window ID from `osrec windows`. Other apps' windows are hidden; the crop is the window's frame at start.")
    var window: UInt32?
    @Option(help: "\"default\" for the system microphone, or a device ID from `osrec displays`.") var mic: String?
    @Option(help: "Stop after this many seconds of media time.") var duration: Double?
    @Option var fps: Int = 60
    @Option var codec: VideoCodec = .hevc
    @Option(help: "Parent directory for the .osrec directory.") var out: String = "."
    @Option(
        name: .customLong("abort-after"),
        help: "Call abort() after this many seconds without finalizing, to exercise `osrec recover`.")
    var abortAfter: Double?

    func validate() throws {
        if window != nil, display != nil || area != nil {
            throw ValidationError("--window records the window's own display; it cannot be combined with --display or --area")
        }
    }

    var target: CaptureTarget {
        let selection: DisplaySelection = display.map { .id($0) } ?? .main
        if let window { return .window(window) }
        if let area { return .area(selection, area.rect) }
        return .display(selection)
    }

    func run() async throws {
        let configuration = RecordingConfiguration(
            outputDirectory: URL(filePath: out),
            target: target,
            microphone: mic.map { $0 == "default" ? .systemDefault : .device(uniqueID: $0) } ?? .none,
            maxFrameRate: fps,
            codec: codec,
            maxDuration: duration.map { .seconds($0) })
        let missing = Permissions.check().missing(for: configuration)
        guard missing.isEmpty else {
            print(RecordingError.missingPermissions(missing))
            throw ExitCode(1)
        }

        let session = try await RecordingSession.start(configuration)
        print(session.directory.path)
        fflush(stdout)

        let interrupts = InterruptHandler {
            Task { _ = await session.stop() }
        }
        interrupts.install()
        if let abortAfter {
            Task {
                try? await Task.sleep(for: .seconds(abortAfter))
                print("aborting without finalizing")
                fflush(stdout)
                abort()
            }
        }

        var lastPrinted: Duration = .zero
        for await update in session.updates {
            switch update {
            case .progress(let progress):
                if progress.mediaTime - lastPrinted >= .seconds(1) {
                    lastPrinted = progress.mediaTime
                    print(String(
                        format: "%.1fs  %d frames  %d events", progress.mediaTime.seconds, progress.framesWritten,
                        progress.eventsWritten))
                }
            case .warning(let warning):
                print("warning: \(warning)")
            case .ended(let finished):
                print(String(format: "ended after %.3fs: %@", finished.duration.seconds, String(describing: finished.termination)))
                if case .finalizationFailed = finished.termination {
                    print("run `osrec recover \(finished.directory.path)` to finalize")
                    throw ExitCode(2)
                }
            }
            fflush(stdout)
        }
    }
}

final class InterruptHandler: Sendable {
    private let onFirst: @Sendable () -> Void
    private let source: DispatchSourceSignal
    private let count = Atomic(0)

    init(onFirst: @escaping @Sendable () -> Void) {
        self.onFirst = onFirst
        source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    }

    func install() {
        signal(SIGINT, SIG_IGN)
        source.setEventHandler { [self] in
            if count.add(1, ordering: .relaxed).oldValue == 0 {
                print("\nstopping")
                onFirst()
            } else {
                _exit(130)
            }
        }
        source.resume()
    }
}

struct Recover: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Finalize a directory whose recorder died. Safe to repeat.")

    @Argument var directory: String

    func run() async throws {
        let finished = try await RecordingSession.recover(at: URL(filePath: directory))
        print(String(format: "finalized %.3fs: %@", finished.duration.seconds, String(describing: finished.termination)))
    }
}

struct Inspect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Summarize a recording directory through the format reader.")

    @Argument var directory: String
    @Option(
        name: .customLong("clock-log"),
        help: "Sidecar log of posted moves (`<host-ns> <x> <y>` per line, global points) to compare against recorded times.")
    var clockLog: String?
    @Flag(help: "Load the recording through Timeline and print its buttons and auto-zoom segments.") var timeline = false
    @Flag(
        name: .customLong("check-determinism"),
        help: "Evaluate every frame at the recording's frame rate in four orders. Exit 1 unless all are bit-identical. Implies --timeline.")
    var checkDeterminism = false
    @Option(
        help: "Print camera and cursor per sample over <start-ms>:<end-ms>:<step-ms>. Implies --timeline.")
    var frames: FrameGrid?

    func run() async throws {
        let url = URL(filePath: directory)
        let health = try RecordingReader.health(at: url)
        print("health: \(health)")
        let metadata = try RecordingReader.read(at: url)
        let manifest = metadata.manifest
        print("id: \(manifest.id.uuid.uuidString)  createdAt: \(manifest.createdAt.ISO8601Format())")
        print("recorder: \(manifest.recorder.name) \(manifest.recorder.version) on macOS \(manifest.recorder.osVersion)")
        print("display: \(manifest.display.name) (\(manifest.display.displayID)), \(Int(manifest.display.refreshRate)) Hz")
        print("screen: \(manifest.screen.pixelWidth)x\(manifest.screen.pixelHeight) \(manifest.screen.codec) up to \(manifest.screen.maxFrameRate) fps")
        if let area = manifest.area {
            print("area: \(Int(area.x)),\(Int(area.y)) \(Int(area.width))x\(Int(area.height)) px")
        }
        if let microphone = manifest.microphone {
            print("microphone: \(microphone.deviceName), \(Int(microphone.sampleRate)) Hz, \(microphone.channelCount) ch")
        }
        switch manifest.status {
        case .recording:
            print("status: recording")
        case .finalized(let duration, let termination):
            print(String(format: "status: finalized, duration %.3fs, termination %@", Double(duration.microseconds) / 1e6, String(describing: termination)))
        }
        for warning in manifest.warnings { print("warning: \(warning)") }

        let events = metadata.events
        var counts: [String: Int] = [:]
        for event in events.events { counts[event.kindName, default: 0] += 1 }
        print("events: \(events.events.count) lines" + (events.tornTailByteCount > 0 ? ", torn tail \(events.tornTailByteCount) bytes" : ""))
        for (kind, count) in counts.sorted(by: { $0.key < $1.key }) { print("  \(kind): \(count)") }
        let cursorFiles = (try? FileManager.default.contentsOfDirectory(atPath: metadata.layout.cursors.path))?
            .filter { $0.hasSuffix(".png") }.count ?? 0
        print("cursor images: \(cursorFiles) files")

        let screen = await MovieSummary.probe(metadata.layout.screen)
        print("screen.mov: \(screen)")
        if manifest.microphone != nil {
            print("microphone.mov: \(await MovieSummary.probe(metadata.layout.microphone))")
        }

        if let clockLog {
            try ClockCheck.report(logPath: clockLog, manifest: manifest, events: events.events)
        }

        if timeline || checkDeterminism || frames != nil {
            let options = TimelineInspection.Options(
                checkDeterminism: checkDeterminism, frames: frames, frameRate: manifest.screen.maxFrameRate)
            guard try await TimelineInspection.run(directory: url, options: options) else { throw ExitCode(1) }
        }
    }
}

enum MovieSummary {
    static func probe(_ url: URL) async -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "missing" }
        do {
            let asset = AVURLAsset(url: url)
            let (duration, playable) = try await asset.load(.duration, .isPlayable)
            var parts = [String(format: "duration %.3fs", duration.seconds), "playable \(playable)"]
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                parts.append("frames \(try sampleCount(asset, track))")
            }
            if let track = try await asset.loadTracks(withMediaType: .audio).first {
                let range = try await track.load(.timeRange)
                parts.append(String(format: "audio track %.3fs", range.duration.seconds))
            }
            return parts.joined(separator: ", ")
        } catch {
            return "unreadable: \(error.localizedDescription)"
        }
    }

    private static func sampleCount(_ asset: AVAsset, _ track: AVAssetTrack) throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            count += CMSampleBufferGetNumSamples(sample)
        }
        return count
    }
}

enum ClockCheck {
    struct Posted {
        var hostNanos: UInt64
        var point: CGPoint
    }

    static func report(logPath: String, manifest: WireManifest, events: [WireEvent]) throws {
        let posted = try String(contentsOfFile: logPath, encoding: .utf8).split(separator: "\n").compactMap { line -> Posted? in
            let fields = line.split(separator: " ")
            guard fields.count == 3, let nanos = UInt64(fields[0]), let x = Double(fields[1]), let y = Double(fields[2]) else { return nil }
            return Posted(hostNanos: nanos, point: CGPoint(x: x, y: y))
        }
        let frame = manifest.display.pointFrame
        let scale = CGSize(
            width: Double(manifest.screen.pixelWidth) / frame.width, height: Double(manifest.screen.pixelHeight) / frame.height)
        var movesByPosition: [WirePoint: [MediaTime]] = [:]
        for case .move(let t, let position) in events { movesByPosition[position, default: []].append(t) }

        let origin = manifest.clock.originHostTimeNanos
        var offsetsMs: [Double] = []
        var unmatched = 0
        for move in posted {
            // The HID system stores an event's location as Float32 points, so a fractional post only
            // matches the recorded pixel after the same rounding.
            let x = Double(Float(move.point.x))
            let y = Double(Float(move.point.y))
            let pixel = WirePoint(x: (x - frame.x) * scale.width, y: (y - frame.y) * scale.height)
            guard let candidates = movesByPosition[pixel], !candidates.isEmpty else {
                unmatched += 1
                continue
            }
            let recorded = candidates.map { Double(origin) + Double($0.microseconds) * 1000 }
            let postedNs = Double(move.hostNanos)
            let nearest = recorded.min { abs($0 - postedNs) < abs($1 - postedNs) }!
            offsetsMs.append((nearest - postedNs) / 1e6)
        }
        guard !offsetsMs.isEmpty else {
            print("clock check: \(posted.count) posted moves, none matched a recorded move")
            return
        }
        let sorted = offsetsMs.sorted()
        func percentile(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))] }
        print(String(
            format: "clock check: %d posted, %d matched, %d unmatched; recorded minus posted: min %.3f ms, p50 %.3f ms, p95 %.3f ms, max %.3f ms",
            posted.count, offsetsMs.count, unmatched, sorted.first!, percentile(0.5), percentile(0.95), sorted.last!))
    }
}

extension WireEvent {
    var kindName: String {
        switch self {
        case .cursorImage: "cursorImage"
        case .state: "state"
        case .move: "move"
        case .down: "down"
        case .up: "up"
        case .scroll: "scroll"
        case .key: "key"
        case .cursor: "cursor"
        }
    }
}

extension VideoCodec: ExpressibleByArgument {}

struct AreaArgument: ExpressibleByArgument {
    let rect: CGRect

    init?(argument: String) {
        let parts = argument.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, let x = parts[0], let y = parts[1], let width = parts[2], let height = parts[3],
            width > 0, height > 0
        else { return nil }
        rect = CGRect(x: x, y: y, width: width, height: height)
    }
}

extension Duration {
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
