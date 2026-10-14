import Foundation
import Observation
import Project
import Recording
import Render

/// The app's whole lifecycle as one enum. Each case owns exactly the data that phase needs, so
/// "recording while exporting" or "an editor with no take" cannot be written down.
enum AppPhase {
    /// No take open: pickers, the library, and the permission report.
    case home(HomeModel)
    case recording(RecordingFlow)
    case editing(EditorModel)
    /// The editor is parked, read-only, behind a frozen plan. Edits cannot race the export because the
    /// phase that owns the editing controls is not the current one.
    case exporting(ExportFlow)
}

enum RecordingFlow {
    /// `RecordingSession.start` is in flight. Cancelling is not offered: `start` returns in about a second.
    case starting(RecordingConfiguration)
    case live(LiveRecording)
    /// `stop()` was called and is memoised by the session; waiting for `.ended`.
    case finishing(LiveRecording)
}

/// Owns the one `AppPhase`. Transitions are the only methods that assign `phase`, and each begins with a
/// `guard case` on the phase it is legal from. A wrong-phase call is a no-op, never a crash.
@MainActor @Observable
final class AppModel {
    private(set) var phase: AppPhase
    let permissions: PermissionsModel

    init() { fatalError("not implemented") }

    /// home -> recording. Checks `Permissions.check().missing(for:)` first; on missing, stays in home
    /// with the report shown. The app records through `RecordingSession` exactly as `osrec` does.
    func startRecording(_ configuration: RecordingConfiguration) { fatalError("not implemented") }

    /// recording(live) -> recording(finishing) -> editing, or home with an error if the take is unusable.
    /// A `.crashed` take is recovered with `RecordingSession.recover` before opening.
    func stopRecording() { fatalError("not implemented") }

    /// home -> editing. Loads with `Project.open`; `.needsRecovery` offers recovery, `.stillRecording` waits.
    func open(_ takeDirectory: URL) { fatalError("not implemented") }

    /// editing -> exporting. Flushes edits to disk first, so what is exported is what a restart would show.
    func beginExport(to destination: URL) { fatalError("not implemented") }

    /// exporting -> editing (cancel, failure acknowledged, or "done").
    func endExport() { fatalError("not implemented") }

    func closeEditor() { fatalError("not implemented") }
}

@MainActor @Observable
final class HomeModel {
    var displays: [DisplayInfo] = []
    var microphones: [MicrophoneInfo] = []
    var selectedDisplay: DisplaySelection = .main
    var selectedMicrophone: MicrophoneSelection = .none
    /// Newest first. Found by scanning the library directory for `.osrec` and reading only
    /// `RecordingReader.health`, so launch stays cheap.
    var takes: [TakeSummary] = []

    func refresh() async { fatalError("not implemented") }
}

struct TakeSummary: Identifiable, Sendable {
    var id: URL { directory }
    let directory: URL
    let created: Date
    let state: State
    enum State: Sendable { case ready(duration: Duration), needsRecovery, stillRecording }
}

/// What the recorder is doing, for the HUD. Fed by `RecordingSession.updates`.
@MainActor @Observable
final class LiveRecording {
    let session: RecordingSession
    private(set) var elapsed: Duration = .zero
    private(set) var warnings: [String] = []
    init(session: RecordingSession) { fatalError("not implemented") }
}
