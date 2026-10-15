import AppKit
import Foundation
import Observation
import Recording
import Render
import Timeline

@MainActor
@Observable
public final class StudioModel {
    public enum Phase {
        case home
        case recording(LiveRecording)
        case editing(Editor)
        case exporting(ExportJob)
    }

    public private(set) var phase: Phase = .home
    public private(set) var permissions: PermissionReport
    public private(set) var takes: [TakeSummary] = []
    public var preferences: RecordingPreferences {
        didSet { preferences.save() }
    }
    public var alert: StudioAlert?
    public let library: URL

    @ObservationIgnored private let services: StudioServices
    @ObservationIgnored private let permissionsAtLaunch: PermissionReport
    private var askedForRelaunchPermission = false
    @ObservationIgnored private var latestOpen = 0
    @ObservationIgnored private var launched = false
    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?

    public convenience init(library: URL = StudioModel.defaultLibrary) {
        self.init(library: library, services: .live)
    }

    init(library: URL, services: StudioServices) {
        self.library = library
        self.services = services
        let report = Permissions.check()
        permissions = report
        permissionsAtLaunch = report
        preferences = RecordingPreferences.load()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveEdits() }
        }
    }

    public nonisolated static var defaultLibrary: URL {
        URL.moviesDirectory.appending(path: "open-studio", directoryHint: .isDirectory)
    }

    public var configuration: RecordingConfiguration {
        RecordingConfiguration(outputDirectory: library, display: preferences.display, microphone: preferences.microphone)
    }

    public var missingPermissions: [Permission] { permissions.missing(for: configuration) }

    public var relaunchSuggested: Bool {
        askedForRelaunchPermission
            || Permission.needingRelaunch.contains {
                permissions.status(of: $0) == .granted && permissionsAtLaunch.status(of: $0) != .granted
            }
    }

    var openEditor: Editor? {
        switch phase {
        case .editing(let editor): editor
        case .exporting(let job): job.editor
        case .home, .recording: nil
        }
    }

    var exportJob: ExportJob? {
        if case .exporting(let job) = phase { job } else { nil }
    }

    public func launch() async {
        guard !launched else { return }
        launched = true
        do {
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        } catch {
            alert = StudioAlert(title: "Cannot create the library", message: "\(library.path): \(error.localizedDescription)")
            return
        }
        await refreshTakes()
    }

    public func refreshTakes() async {
        takes = await TakeLibrary.recoverAndScan(library)
    }

    public func refreshPermissions() {
        permissions = Permissions.check()
    }

    public func openSettings(for permission: Permission) {
        if Permission.needingRelaunch.contains(permission) { askedForRelaunchPermission = true }
        services.openURL(permission.settingsURL)
    }

    public func requestAccess(to permission: Permission) async {
        if Permission.needingRelaunch.contains(permission) { askedForRelaunchPermission = true }
        _ = await Permissions.request(permission)
        refreshPermissions()
    }

    public func relaunch() {
        saveEdits()
        let relaunch = Process()
        relaunch.executableURL = URL(filePath: "/bin/sh")
        relaunch.arguments = [
            "-c", Self.openOnceProcessExits,
            Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier),
        ]
        do {
            try relaunch.run()
        } catch {
            alert = StudioAlert(title: "Cannot relaunch", message: error.localizedDescription)
            return
        }
        NSApplication.shared.terminate(nil)
    }

    private static let openOnceProcessExits =
        #"while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open "$0""#

    public func saveEdits() {
        openEditor?.flush()
    }

    public func startRecording() async {
        let previous: Editor?
        switch phase {
        case .home:
            previous = nil
        case .editing(let editor):
            editor.pause()
            guard savedBeforeLeaving(editor) else { return }
            previous = editor
        case .recording, .exporting:
            return
        }
        let live = LiveRecording()
        phase = .recording(live)
        let handle: any RecordingHandle
        do {
            handle = try await services.startRecording(configuration)
        } catch {
            phase = previous.map(Phase.editing) ?? .home
            refreshPermissions()
            alert = StudioAlert(title: "Recording did not start", message: error.description)
            return
        }
        previous?.close()
        live.stage = .live(handle)
        services.setAppHidden(true)
        Task { [weak self] in
            for await update in handle.updates {
                switch update {
                case .progress(let progress): live.progress = progress
                case .warning(let warning): live.warnings.append(warning)
                case .ended(let finished): await self?.recordingEnded(finished, from: live)
                }
            }
        }
    }

    public func stopRecording() async {
        guard case .recording(let live) = phase, case .live(let handle) = live.stage else { return }
        live.stage = .finishing
        let finished = await handle.stop()
        await recordingEnded(finished, from: live)
    }

    public func open(_ take: URL) async {
        switch phase {
        case .home:
            break
        case .editing(let current):
            if current.project.source.directory.standardizedFileURL == take.standardizedFileURL { return }
            guard savedBeforeLeaving(current) else { return }
        case .recording, .exporting:
            return
        }
        latestOpen += 1
        let generation = latestOpen
        let editor: Editor
        do {
            editor = try await Editor(project: Self.loadProject(take))
        } catch {
            guard generation == latestOpen else { return }
            alert = StudioAlert(title: "Cannot open \(take.lastPathComponent)", message: StudioAlert.describe(error))
            return
        }
        guard generation == latestOpen else {
            editor.close()
            return
        }
        switch phase {
        case .home: break
        case .editing(let old): old.close()
        case .recording, .exporting:
            editor.close()
            return
        }
        phase = .editing(editor)
    }

    public func closeEditor() {
        guard case .editing(let editor) = phase, savedBeforeLeaving(editor) else { return }
        editor.close()
        phase = .home
        Task { await refreshTakes() }
    }

    public func export(to destination: URL) {
        guard case .editing(let editor) = phase else { return }
        editor.pause()
        editor.flush()
        phase = .exporting(ExportJob(editor: editor, destination: destination, export: services.export))
    }

    /// A running export is cancelled and waited for, so its cleanup cannot remove the partial
    /// file of a new export to the same destination.
    public func dismissExport() async {
        guard case .exporting(let job) = phase else { return }
        await job.cancelAndWait()
        guard case .exporting(let current) = phase, current === job else { return }
        phase = .editing(job.editor)
    }

    func defaultExportDestination(for editor: Editor) -> URL {
        library.appending(path: "\(editor.takeName).mp4", directoryHint: .notDirectory)
    }

    private func savedBeforeLeaving(_ editor: Editor) -> Bool {
        editor.flush()
        guard case .failed(let detail) = editor.saveState else { return true }
        alert = StudioAlert(title: "Your edits could not be saved", message: detail)
        return false
    }

    private func recordingEnded(_ finished: FinishedRecording, from live: LiveRecording) async {
        guard case .recording(let current) = phase, current === live else { return }
        phase = .home
        services.setAppHidden(false)
        if case .streamFailed(let detail) = finished.termination {
            alert = StudioAlert(title: "The recording ended early", message: "Everything up to the failure was kept. \(detail)")
        }
        await refreshTakes()
        await open(finished.directory)
    }

    private static func loadProject(_ take: URL) async throws(ProjectError) -> Project {
        do {
            return try Project.open(take)
        } catch .source(.needsRecovery) {
            _ = try? await RecordingSession.recover(at: take)
            return try Project.open(take)
        }
    }
}

extension Permission {
    /// TCC applies these grants only to processes launched after the grant.
    static let needingRelaunch: [Permission] = [.screenRecording, .inputMonitoring]
}

@MainActor
@Observable
public final class LiveRecording {
    enum Stage {
        case starting
        case live(any RecordingHandle)
        case finishing
    }

    var stage: Stage = .starting
    public internal(set) var progress: RecordingProgress?
    public internal(set) var warnings: [RecordingWarning] = []

    var isLive: Bool {
        if case .live = stage { true } else { false }
    }

    var elapsed: Duration { progress?.mediaTime ?? .zero }
}

@MainActor
@Observable
public final class ExportJob {
    public enum Status {
        case running(ExportProgress?)
        case finished(ExportReport)
        case failed(ExportError)
    }

    public let editor: Editor
    public let project: Project
    public let destination: URL
    public private(set) var status: Status = .running(nil)
    @ObservationIgnored private var task: Task<Void, Never>?

    init(editor: Editor, destination: URL, export: @escaping Exporter) {
        self.editor = editor
        project = editor.project
        self.destination = destination
        task = Task { [project] in
            let (updates, continuation) = AsyncStream.makeStream(of: ExportProgress.self, bufferingPolicy: .bufferingNewest(1))
            let shown = Task {
                for await progress in updates { status = .running(progress) }
            }
            let result: Result<ExportReport, ExportError>
            do throws(ExportError) {
                result = .success(try await export(project, destination) { continuation.yield($0) })
            } catch {
                result = .failure(error)
            }
            continuation.finish()
            await shown.value
            switch result {
            case .success(let report): status = .finished(report)
            case .failure(let error): status = .failed(error)
            }
        }
    }

    var isRunning: Bool {
        if case .running = status { true } else { false }
    }

    public private(set) var isCancelling = false

    func cancelAndWait() async {
        isCancelling = true
        task?.cancel()
        await task?.value
    }

    public func revealInFinder() {
        guard case .finished(let report) = status else { return }
        NSWorkspace.shared.activateFileViewerSelecting([report.destination])
    }
}

public struct StudioAlert: Sendable, Equatable, Identifiable {
    public let title: String
    public let message: String
    public var id: String { title + message }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as ProjectError:
            switch error {
            case .source(.stillRecording): "A recorder is still writing this take."
            case .source(.needsRecovery): "The recorder died before finishing this take, and recovery did not complete."
            case .source(.notARecording(let url)): "\(url.lastPathComponent) is not an open-studio recording."
            case .source(.unsupportedVersion(let found, let supported)):
                "This take was recorded in format version \(found); this build reads up to \(supported)."
            case .source(.corrupt(let detail)): "The take is damaged: \(detail)"
            case .projectFromNewerVersion(let found, let supported):
                "Its edits were saved by a newer build (version \(found); this build reads up to \(supported))."
            case .projectUnreadable(let detail), .saveFailed(let detail): detail
            case .invalidZooms(let error): "Its saved zooms are invalid: \(error)"
            }
        case let error as RenderError:
            switch error {
            case .screenMovieUnreadable(let detail): "The screen movie cannot be read: \(detail)"
            case .backgroundImageUnreadable(let detail): "The background image cannot be read: \(detail)"
            case .missingSourceFrame(let t): "No screen frame at \(t.seconds) s."
            }
        case let error as ExportError:
            switch error {
            case .render(let error): describe(error)
            case .readerFailed(let detail): "Reading the take failed: \(detail)"
            case .writerFailed(let detail): "Writing the movie failed: \(detail)"
            case .destinationUnwritable(let detail): "The destination cannot be written: \(detail)"
            case .cancelled: "The export was cancelled."
            }
        default:
            String(describing: error)
        }
    }
}

protocol RecordingHandle: Sendable {
    var directory: URL { get }
    var updates: AsyncStream<RecordingUpdate> { get }
    func stop() async -> FinishedRecording
}

extension RecordingSession: RecordingHandle {}

typealias Exporter = @Sendable (Project, URL, @escaping @Sendable (ExportProgress) -> Void) async throws(ExportError)
    -> ExportReport

struct StudioServices: Sendable {
    var startRecording: @Sendable (RecordingConfiguration) async throws(RecordingError) -> any RecordingHandle
    var export: Exporter
    var setAppHidden: @MainActor @Sendable (Bool) -> Void
    var openURL: @MainActor @Sendable (URL) -> Void

    static let live = StudioServices(
        startRecording: { configuration throws(RecordingError) in try await RecordingSession.start(configuration) },
        export: { project, destination, progress throws(ExportError) in
            try await runExport(project, to: destination, progress: progress)
        },
        setAppHidden: { hidden in
            if hidden {
                NSApplication.shared.hide(nil)
            } else {
                NSApplication.shared.unhide(nil)
                NSApplication.shared.activate()
            }
        },
        openURL: { NSWorkspace.shared.open($0) })
}

@concurrent
private func runExport(
    _ project: Project, to destination: URL, progress: @escaping @Sendable (ExportProgress) -> Void
) async throws(ExportError) -> ExportReport {
    try await Export.run(project, to: destination, progress: progress)
}
