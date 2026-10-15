import AppKit
import Recording
import SwiftUI

struct HomeView: View {
    @Bindable var model: StudioModel
    @State private var displays: [DisplayChoice] = []
    @State private var microphones: [MicrophoneInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            if !model.missingPermissions.isEmpty || model.relaunchSuggested {
                PermissionBanner(model: model)
            }
            SourcePickers(preferences: $model.preferences, displays: displays, microphones: microphones)
            Divider()
            HStack {
                Text("Takes").font(.title3.weight(.semibold))
                Spacer()
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.open(model.library)
                }
                .buttonStyle(.borderless)
                Button("Open Take…", systemImage: "arrow.up.forward.app") {
                    if let take = TakePanel.choose(in: model.library) {
                        Task { await model.open(take) }
                    }
                }
                .buttonStyle(.borderless)
            }
            TakeList(takes: model.takes) { take in
                Task { await model.open(take) }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            displays = DisplayChoice.current()
            microphones = CaptureSources.microphones()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            displays = DisplayChoice.current()
            microphones = CaptureSources.microphones()
            Task { await model.refreshTakes() }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Open Studio").font(.largeTitle.weight(.semibold))
                Text(model.library.path(percentEncoded: false))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                Task { await model.startRecording() }
            } label: {
                Label("Record", systemImage: "record.circle.fill")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(!model.canStartRecording)
            .help(model.missingPermissions.isEmpty ? "Start recording the chosen display" : "Grant the permissions above first")
        }
    }
}

struct PermissionBanner: View {
    let model: StudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Open Studio needs permission to record", systemImage: "lock.shield")
                .font(.headline)
            ForEach(model.missingPermissions, id: \.self) { permission in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(permission.description).fontWeight(.medium)
                        Text(permission.purpose).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.permissions.status(of: permission) == .notDetermined {
                        Button("Ask macOS") {
                            Task { await model.requestAccess(to: permission) }
                        }
                    }
                    Button("Open System Settings") {
                        model.openSettings(for: permission)
                    }
                }
            }
            if model.relaunchSuggested {
                HStack {
                    Text("Screen Recording and Input Monitoring apply after Open Studio relaunches.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Relaunch") { model.relaunch() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(14)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.35)))
    }
}

extension Permission {
    var purpose: String {
        switch self {
        case .screenRecording: "To capture the display."
        case .inputMonitoring: "To record clicks and keys, which drive the automatic zooms."
        case .microphone: "To record your voice with the take."
        }
    }
}

struct SourcePickers: View {
    @Binding var preferences: RecordingPreferences
    let displays: [DisplayChoice]
    let microphones: [MicrophoneInfo]

    var body: some View {
        HStack(spacing: 24) {
            Picker("Display", selection: $preferences.display) {
                Text("Main display").tag(DisplaySelection.main)
                ForEach(displays) { display in
                    Text(display.isMain ? "\(display.name) (main)" : display.name).tag(DisplaySelection.id(display.id))
                }
            }
            .frame(maxWidth: 320)
            Picker("Microphone", selection: $preferences.microphone) {
                Text("None").tag(MicrophoneSelection.none)
                Text("System default").tag(MicrophoneSelection.systemDefault)
                ForEach(microphones) { microphone in
                    Text(microphone.name).tag(MicrophoneSelection.device(uniqueID: microphone.id))
                }
            }
            .frame(maxWidth: 320)
        }
    }
}

struct TakeList: View {
    let takes: [TakeSummary]
    let open: (URL) -> Void

    var body: some View {
        if takes.isEmpty {
            ContentUnavailableView(
                "No takes yet", systemImage: "film.stack",
                description: Text("Press Record, or open an .osrec folder from anywhere."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(takes) { take in
                TakeRow(take: take, open: open)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }
}

struct TakeRow: View {
    let take: TakeSummary
    let open: (URL) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "film")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(take.name).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HealthBadge(health: take.health, hasEdits: take.hasEdits)
            Button("Open") { open(take.url) }
                .disabled(!take.health.canOpen)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if take.health.canOpen { open(take.url) }
        }
    }

    private var title: String {
        take.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? take.name
    }
}

struct HealthBadge: View {
    let health: TakeHealth
    let hasEdits: Bool

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .help(help)
    }

    private var text: String {
        switch health {
        case .ready: hasEdits ? "Edited" : "Ready"
        case .recording: "Recording"
        case .needsRecovery: "Needs recovery"
        case .nothingRecorded: "Empty"
        case .unreadable: "Unreadable"
        }
    }

    private var symbol: String {
        switch health {
        case .ready: hasEdits ? "pencil.circle" : "checkmark.circle"
        case .recording: "record.circle"
        case .needsRecovery: "bandage"
        case .nothingRecorded: "circle.dashed"
        case .unreadable: "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch health {
        case .ready: .green
        case .recording: .red
        case .needsRecovery: .orange
        case .nothingRecorded, .unreadable: .secondary
        }
    }

    private var help: String {
        switch health {
        case .ready: hasEdits ? "Finalised, with saved edits" : "Finalised"
        case .recording: "A recorder is writing this take"
        case .needsRecovery: "The recorder died before finishing; opening recovers it"
        case .nothingRecorded: "The recorder died before the first frame"
        case .unreadable(let detail): detail
        }
    }
}
