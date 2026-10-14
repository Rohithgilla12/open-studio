import Foundation
import Observation
import Recording
import Render
import Timeline

/// The app is in exactly one phase, and each phase carries only the data that exists in it.
/// A `RecordingSession` exists only inside `.recording`; a `Preview` only inside `.editing`.
/// There is no "recording while editing" or "exporting with no project" to represent.
enum Phase {
    case setup(RecordSetup)
    case recording(ActiveRecording)
    case editing(Editor)
}

@Observable @MainActor
final class AppModel {
    private(set) var phase: Phase
    let library: Library

    init(library: Library) { fatalError("not implemented") }

    /// setup -> recording. `RecordingSession.start` is the only entry; failure stays in setup with
    /// the error shown. On success the main window hides and `RecordingPanel` shows.
    func startRecording() async { fatalError("not implemented") }

    /// recording -> editing. Awaits `session.stop()` (idempotent, never throws), then opens the
    /// finished directory as a project. A `finalizationFailed` termination offers recovery first.
    func stopRecording() async { fatalError("not implemented") }

    /// setup -> editing, from the library list.
    func open(_ take: LibraryTake) async { fatalError("not implemented") }

    /// editing -> setup. Refused while an export runs (the editor's mode makes that a type check,
    /// not a flag).
    func closeEditor() { fatalError("not implemented") }
}

/// The record screen: pickers and the permission report. Refreshed when the window becomes key
/// (grants change in System Settings behind the app's back).
struct RecordSetup {
    var displays: [DisplayInfo] = []
    var microphones: [MicrophoneInfo] = []
    var selectedDisplay: DisplaySelection = .main
    var selectedMicrophone: MicrophoneSelection = .none
    var permissions: PermissionReport
    var lastError: RecordingError?

    var configuration: RecordingConfiguration { fatalError("not implemented") }
    var missingPermissions: [Permission] { permissions.missing(for: configuration) }
}

/// Live take: the session, its last progress, and warnings for the panel.
struct ActiveRecording {
    let session: RecordingSession
    var progress: RecordingProgress
    var warnings: [RecordingWarning] = []
}

/// Takes in `~/Movies/open-studio/`. Scanned, never watched; the list refreshes on return to setup.
/// Crashed takes are listed with a Recover button that calls `RecordingSession.recover`.
struct Library: Sendable {
    let directory: URL
    func takes() -> [LibraryTake] { fatalError("not implemented") }
}

struct LibraryTake: Identifiable, Sendable {
    let id: URL
    let name: String
    let health: TakeHealth
}

enum TakeHealth: Sendable {
    case ready(duration: RecordingTime)
    case live
    case crashed
    case unreadable(String)
}
