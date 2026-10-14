import AppKit
import AVFoundation
import SwiftUI
import Timeline

/// Switches on `AppModel.phase`. No view reads two phases.
struct RootView: View {
    @Bindable var app: AppModel
    var body: some View { fatalError("not implemented") }
}

struct HomeView: View {
    @Bindable var model: HomeModel
    let onRecord: () -> Void
    let onOpen: (URL) -> Void
    var body: some View { fatalError("not implemented") }
}

/// Lists each missing permission with a button that opens the matching System Settings pane
/// (`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` and `Privacy_ListenEvent`).
/// Shows `Permissions.responsibleProcess`, which is this app's bundle, not the terminal.
struct PermissionsBanner: View {
    let model: PermissionsModel
    var body: some View { fatalError("not implemented") }
}

@MainActor @Observable
final class PermissionsModel {
    private(set) var report = Permissions.check()
    /// Rechecked on app activation, because the user grants in System Settings and switches back.
    func refresh() { fatalError("not implemented") }
    func openSettings(for permission: Permission) { fatalError("not implemented") }
}

struct RecorderHUD: View {
    let recording: LiveRecording
    let onStop: () -> Void
    var body: some View { fatalError("not implemented") }
}

struct EditorView: View {
    @Bindable var editor: EditorModel
    let onExport: () -> Void
    var body: some View {
        // VStack { PlayerView, ZoomStrip, StylePanel }; toolbar: preset picker, Export
        fatalError("not implemented")
    }
}

/// An `AVPlayerLayer` host. `videoGravity = .resizeAspect`; the layer scales the 1920 px preview.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> NSView { fatalError("not implemented") }
    func updateNSView(_ view: NSView, context: Context) { fatalError("not implemented") }
}

/// One lane, time on the x axis. Each segment is a rounded block with drag handles on both edges; the
/// body drags to move; Delete removes the selection; double-click on empty lane adds one. It emits
/// `EditAction`s with times already converted from x, and decides nothing about validity (ZoomEditing clamps).
struct ZoomStrip: View {
    let zooms: ZoomTrack
    let duration: RecordingTime
    let playhead: RecordingTime
    let selection: ZoomSegment.ID?
    let send: (EditAction) -> Void
    let seek: (RecordingTime) -> Void
    var body: some View { fatalError("not implemented") }
}

struct StylePanel: View {
    let style: Style
    let output: OutputChoice
    let send: (EditAction) -> Void
    var body: some View { fatalError("not implemented") }
}

struct ExportSheet: View {
    @Bindable var flow: ExportFlow
    var body: some View { fatalError("not implemented") }
}
