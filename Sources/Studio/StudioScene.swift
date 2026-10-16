import AppKit
import Recording
import SwiftUI
import Timeline

/// Launch arguments: `-OpenTake <path>` opens that take in the editor once the library is listed,
/// and `-Playhead <seconds>` then moves the playhead there. `-CaptureTarget screen|area|window`
/// chooses the target on Home and saves it, as a click would. `-SelectArea x,y,w,h` opens the area
/// overlay on the chosen display with that rectangle, in display points from its top-left, once the
/// window appears. Confirming only saves the area as the target: this mode never records, so a
/// keystroke that lands in the overlay while it is being checked cannot start a take.
public struct StudioScene: Scene {
    @State private var model = StudioModel()

    public init() {}

    public var body: some Scene {
        Window("Open Studio", id: "main") {
            RootView(model: model)
                .frame(minWidth: 960, minHeight: 640)
                .task {
                    if let kind = UserDefaults.standard.string(forKey: "CaptureTarget").flatMap(CaptureKind.init(rawValue:)) {
                        model.preferences.captureKind = kind
                    }
                    await model.launch()
                    if let path = UserDefaults.standard.string(forKey: "OpenTake") {
                        await model.open(URL(filePath: path, directoryHint: .isDirectory))
                        if let seconds = UserDefaults.standard.string(forKey: "Playhead").flatMap(Double.init) {
                            model.openEditor?.scrub(to: .seconds(seconds))
                        }
                    }
                    if let area = UserDefaults.standard.string(forKey: "SelectArea").flatMap(CGRect.init(launchArgument:)) {
                        await model.chooseArea(preset: area)
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

extension CGRect {
    init?(launchArgument: String) {
        let numbers = launchArgument.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.allSatisfy({ $0 != nil }) else { return nil }
        self.init(components: numbers.compactMap(\.self))
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
