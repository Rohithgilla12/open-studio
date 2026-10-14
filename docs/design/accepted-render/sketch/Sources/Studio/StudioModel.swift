import AppKit
import Foundation
import Observation
import Recording
import Render
import Timeline

/// The app's one source of state. Views read it and call its intents; nothing else mutates it.
///
/// `phase` makes the illegal combinations unrepresentable: there is no "recording while an editor
/// is open" or "exporting with no project", because each case carries only its own data.
@MainActor
@Observable
public final class StudioModel {
    public enum Phase {
        /// Pickers, permissions, recent takes. Its data is model-wide (permissions, preferences,
        /// takes), because the editor's "record again" uses it too.
        case home
        case recording(LiveRecording)
        case editing(Editor)
        /// Holds the editor it returns to. The job exports a `Project` value copied at start,
        /// so the editor's later state cannot leak into the file.
        case exporting(ExportJob)
    }

    public private(set) var phase: Phase = .home
    public private(set) var permissions: PermissionReport
    public private(set) var takes: [TakeSummary] = []
    public var preferences: RecordingPreferences
    /// The one place a failed intent reports to the user.
    public var alert: StudioAlert?
    public let library: URL

    public init(library: URL = StudioModel.defaultLibrary) {
        self.library = library
        permissions = Permissions.check()
        preferences = RecordingPreferences.load()
    }

    /// `~/Movies/Open Studio`.
    public static var defaultLibrary: URL {
        URL.moviesDirectory.appending(path: "Open Studio", directoryHint: .isDirectory)
    }

    // MARK: Intents

    /// On launch: finalise takes a crash left behind, then list the library. Recovery is
    /// idempotent and a no-op for finalised takes, so running it every launch is safe.
    public func launch() async {
        // TODO: for dir in osrec dirs in library: _ = try? await RecordingSession.recover(at: dir)
        //       takes = scan(library) sorted newest first
        fatalError("not implemented")
    }

    /// Re-reads TCC state. Called on `NSApplication.didBecomeActiveNotification`, which is when a
    /// user comes back from System Settings.
    public func refreshPermissions() {
        permissions = Permissions.check()
    }

    public func openSettings(for permission: Permission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }

    /// From `.home` or `.editing`. An open editor saves first. Ignored in other phases (their
    /// views do not offer it).
    public func startRecording() async {
        // TODO:
        //   switch phase { case .home: break; case .editing(let e): e.flush(); case .recording, .exporting: return }
        //   config = RecordingConfiguration(outputDirectory: library, display: preferences.display,
        //                                   microphone: preferences.microphone)
        //   do { session = try await RecordingSession.start(config) } catch { alert = .recording(error); return }
        //   live = LiveRecording(session); phase = .recording(live)
        //   live.observe { ended in await self.recordingEnded(ended) }    // handles a self-stopped stream
        //   NSApp.hide(nil)   // the menu bar extra carries Stop while the window is out of the shot
        fatalError("not implemented")
    }

    /// From `.recording` only. Stop is idempotent in `RecordingSession`, so a double click and a
    /// self-ended stream racing each other converge on one `FinishedRecording`.
    public func stopRecording() async {
        guard case .recording(let live) = phase else { return }
        await recordingEnded(await live.stop())
    }

    public func open(_ take: URL) async {
        // TODO:
        //   guard phase is .home or .editing (flush the old editor) else return
        //   project = try Project.open(take)
        //     on .source(.needsRecovery): try await RecordingSession.recover(at: take), then retry once
        //   editor = try await Editor(project: project); phase = .editing(editor)
        fatalError("not implemented")
    }

    public func closeEditor() {
        guard case .editing(let editor) = phase else { return }
        editor.flush()
        phase = .home
    }

    /// From `.editing` only.
    public func export(to destination: URL) {
        guard case .editing(let editor) = phase else { return }
        phase = .exporting(ExportJob(editor: editor, destination: destination))
    }

    /// Back to the same editor after a finished, failed, or cancelled export.
    public func dismissExport() {
        guard case .exporting(let job) = phase else { return }
        job.cancel()
        phase = .editing(job.editor)
    }

    private func recordingEnded(_ finished: FinishedRecording) async {
        // TODO: guard still .recording (a second call is a no-op); NSApp.unhide(nil);
        //       takes.insert(...); await open(finished.directory) (the open path handles recovery)
        fatalError("not implemented")
    }
}

/// One take in progress. A class because progress arrives many times a second.
@MainActor
@Observable
public final class LiveRecording {
    public let session: RecordingSession
    public private(set) var progress: RecordingProgress?
    public private(set) var warnings: [RecordingWarning] = []
    public private(set) var isStopping = false

    init(session: RecordingSession) {
        self.session = session
    }

    func stop() async -> FinishedRecording {
        isStopping = true
        return await session.stop()
    }
}

/// An export in flight or just finished.
@MainActor
@Observable
public final class ExportJob {
    public enum Status {
        case running(ExportProgress?)
        case finished(ExportReport)
        case failed(ExportError)
    }

    public let editor: Editor
    public let destination: URL
    public private(set) var status: Status = .running(nil)
    private var task: Task<Void, Never>?

    init(editor: Editor, destination: URL) {
        self.editor = editor
        self.destination = destination
        // TODO: snapshot = editor.project (a value); task = Task { status = result of Export.run(snapshot,
        //       to: destination) { p in Task { @MainActor in status = .running(p) } } }
    }

    func cancel() { task?.cancel() }

    public func revealInFinder() {
        guard case .finished(let report) = status else { return }
        NSWorkspace.shared.activateFileViewerSelecting([report.destination])
    }
}

public struct TakeSummary: Sendable, Hashable, Identifiable {
    public let url: URL
    /// Parsed from the `YYYYMMDD-HHMMSS.osrec` name, so listing never reads the takes.
    public let createdAt: Date?
    public var id: URL { url }
}

/// Display and microphone choices, kept in UserDefaults between launches.
public struct RecordingPreferences: Sendable, Equatable {
    public var display: DisplaySelection
    public var microphone: MicrophoneSelection

    static func load() -> RecordingPreferences {
        RecordingPreferences(display: .main, microphone: .systemDefault)
    }
}

public enum StudioAlert: Sendable, Equatable {
    case recording(RecordingError)
    case project(ProjectError)
    case render(RenderError)
}
