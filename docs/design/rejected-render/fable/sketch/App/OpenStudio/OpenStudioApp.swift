import SwiftUI

/// Thin Xcode project in App/, depending on the root package by path. It owns the bundle id
/// (`co.openstudio.app`), usage strings (NSScreenCaptureUsageDescription is not a key; Screen
/// Recording and Input Monitoring are granted per bundle in System Settings; NSMicrophoneUsageDescription
/// is required), the entitlements, and signing.
///
/// Project layout uses an Xcode 16+ file-system-synchronized root group, so adding a Swift file
/// under App/OpenStudio needs no .pbxproj edit. That removes the main case for xcodegen; the
/// accepted "checked-in project" decision stands.
///
/// TCC note for developers: a grant is bound to the code signature's designated requirement. An
/// ad hoc signed rebuild gets a new cdhash and loses the grant. Sign with a stable Apple
/// Development identity and a fixed bundle id (set in the project, not per machine) and grants
/// persist across rebuilds. `tccutil reset ScreenCapture co.openstudio.app` clears a stale one.
@main
struct OpenStudioApp: App {
    @State private var model = AppModel(library: Library(directory: URL.moviesDirectory.appending(path: "open-studio")))

    var body: some Scene {
        WindowGroup("Open Studio") {
            RootView(model: model)
        }
        .commands { EditorCommands(model: model) }

        // A small non-activating panel with the elapsed time and a Stop button, shown only in the
        // recording phase. The main window is hidden so it is not in the take.
        Window("Recording", id: "recording") {
            RecordingPanel(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowLevel(.floating)
    }
}

/// Switches on `model.phase`. Each case gets a view that takes only that phase's data.
struct RootView: View {
    let model: AppModel
    var body: some View { fatalError("not implemented") }
}

/// Undo/redo, Export (Cmd-E), Delete zoom (Backspace), Play/Pause (Space).
struct EditorCommands: Commands {
    let model: AppModel
    var body: some Commands { fatalError("not implemented") }
}
