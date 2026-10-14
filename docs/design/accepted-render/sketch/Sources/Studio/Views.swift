import AppKit
import AVFoundation
import Recording
import Render
import SwiftUI
import Timeline

/// The whole app as a Scene, so the Xcode target's `@main` is one line and every view builds and
/// type-checks under `swift build`.
public struct StudioScene: Scene {
    @State private var model = StudioModel()

    public init() {}

    public var body: some Scene {
        WindowGroup("Open Studio") {
            RootView(model: model)
                .task { await model.launch() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.refreshPermissions()
                }
        }
        MenuBarExtra("Recording", systemImage: "record.circle", isInserted: .constant(model.isRecording)) {
            RecordingMenu(model: model)
        }
    }
}

extension StudioModel {
    var isRecording: Bool {
        if case .recording = phase { true } else { false }
    }
}

struct RootView: View {
    let model: StudioModel

    var body: some View {
        switch model.phase {
        case .home: HomeView(model: model)
        case .recording(let live): RecordingView(model: model, live: live)
        case .editing(let editor): EditorView(model: model, editor: editor)
        case .exporting(let job):
            EditorView(model: model, editor: job.editor)
                .disabled(true)
                .sheet(isPresented: .constant(true)) { ExportSheet(model: model, job: job) }
        }
    }
}

// MARK: Home

/// Permissions banner, display and microphone pickers, Record, and recent takes.
struct HomeView: View {
    let model: StudioModel
    var body: some View { EmptyView() }
}

/// Lists each missing permission with "Open System Settings". Screen Recording and Input
/// Monitoring take effect after relaunch, so a granted-but-not-live state offers "Relaunch".
struct PermissionBanner: View {
    let report: PermissionReport
    let openSettings: (Permission) -> Void
    var body: some View { EmptyView() }
}

struct SourcePickers: View {
    @Binding var preferences: RecordingPreferences
    let displays: [DisplayInfo]
    let microphones: [MicrophoneInfo]
    var body: some View { EmptyView() }
}

struct TakeList: View {
    let takes: [TakeSummary]
    let open: (URL) -> Void
    var body: some View { EmptyView() }
}

// MARK: Recording

/// What the window shows if the user unhides it mid-take: elapsed time, warnings, Stop.
struct RecordingView: View {
    let model: StudioModel
    let live: LiveRecording
    var body: some View { EmptyView() }
}

struct RecordingMenu: View {
    let model: StudioModel
    var body: some View { EmptyView() }
}

// MARK: Editor

/// Preview on top, transport, the zoom strip, and a style inspector on the side.
struct EditorView: View {
    let model: StudioModel
    let editor: Editor
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        // TODO: VStack { PlayerSurface(player: editor.preview.player); TransportBar; ZoomStrip }
        //       .inspector { StyleInspector }
        //       .toolbar { FormatPicker; Export button -> NSSavePanel -> model.export(to:) }
        //       .onAppear { editor.undoManager = undoManager }
        EmptyView()
    }
}

/// An `AVPlayerLayer` in an NSView. The layer scales the rendered canvas to the view; the
/// compositor always renders at the export canvas, so the preview is the export, downscaled.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> NSView { fatalError("not implemented") }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct TransportBar: View {
    let editor: Editor
    var body: some View { EmptyView() }
}

/// The recording's duration as a horizontal strip with one block per zoom segment.
///
/// - Drag a block body: `editor.moveZoom`, an edge: `editor.resizeZoom`, both on each change;
///   `editor.endDrag` on gesture end, so one drag is one undo step.
/// - Click selects; Delete removes the selection; double-click on empty strip adds a zoom.
/// - The playhead follows `editor.playhead`; clicking empty strip scrubs.
/// Pixel-to-time mapping is a pure function of strip width and duration (`StripScale`), tested.
struct ZoomStrip: View {
    let editor: Editor
    var body: some View { EmptyView() }
}

struct StripScale: Equatable {
    let width: Double
    let duration: RecordingTime
    func time(atX x: Double) -> RecordingTime { fatalError("not implemented") }
    func x(at t: RecordingTime) -> Double { fatalError("not implemented") }
}

/// Background presets (generated gradients, solid colour, pick an image), padding, corner
/// radius, shadow. Each change is `editor.apply`; slider drags use `editor.drag` and `endDrag`.
struct StyleInspector: View {
    let editor: Editor
    var body: some View { EmptyView() }
}

// MARK: Export

/// Progress bar and Cancel while running; Reveal in Finder and Done when finished; the error
/// and Done when failed. Done and Cancel both call `model.dismissExport()`.
struct ExportSheet: View {
    let model: StudioModel
    let job: ExportJob
    var body: some View { EmptyView() }
}
