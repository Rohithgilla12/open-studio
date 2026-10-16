import AppKit
import Recording
import SwiftUI
import Timeline

/// Launch arguments: `-OpenTake <path>` opens that take in the editor once the library is listed,
/// and `-Playhead <seconds>` then moves the playhead there.
public struct StudioScene: Scene {
    @State private var model = StudioModel()

    public init() {}

    public var body: some Scene {
        Window("Open Studio", id: "main") {
            RootView(model: model)
                .frame(minWidth: 960, minHeight: 640)
                .task {
                    await model.launch()
                    if let path = UserDefaults.standard.string(forKey: "OpenTake") {
                        await model.open(URL(filePath: path, directoryHint: .isDirectory))
                        if let seconds = UserDefaults.standard.string(forKey: "Playhead").flatMap(Double.init) {
                            model.openEditor?.scrub(to: .seconds(seconds))
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.refreshPermissions()
                }
                .alert(
                    model.alert?.title ?? "",
                    isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
                    presenting: model.alert
                ) { _ in
                    Button("OK") {}
                } message: { alert in
                    Text(alert.message)
                }
        }
        .defaultSize(width: 1280, height: 820)
        .commands { StudioCommands(model: model) }

        MenuBarExtra(isInserted: Binding(get: { model.isRecording }, set: { _ in })) {
            RecordingMenu(model: model)
        } label: {
            RecordingMenuLabel(model: model)
        }
    }
}

extension StudioModel {
    var isRecording: Bool {
        if case .recording = phase { true } else { false }
    }

    var liveRecording: LiveRecording? {
        if case .recording(let live) = phase { live } else { nil }
    }
}

struct RootView: View {
    let model: StudioModel

    var body: some View {
        if let editor = model.openEditor {
            EditorView(model: model, editor: editor)
                .id(ObjectIdentifier(editor))
        } else if let live = model.liveRecording {
            RecordingView(model: model, live: live)
        } else {
            HomeView(model: model)
        }
    }
}

struct StudioCommands: Commands {
    let model: StudioModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Recording") {
                Task { await model.record() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!model.canStartRecording)

            Button("Open Take…") {
                if let take = TakePanel.choose(in: model.library) {
                    Task { await model.open(take) }
                }
            }
            .keyboardShortcut("o")
        }
    }
}

enum TakePanel {
    @MainActor
    static func choose(in directory: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Open Take"
        panel.message = "Choose an .osrec recording folder."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = directory
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
