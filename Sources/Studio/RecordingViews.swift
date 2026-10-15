import AppKit
import Recording
import SwiftUI

struct RecordingView: View {
    let model: StudioModel
    let live: LiveRecording

    var body: some View {
        VStack(spacing: 16) {
            switch live.stage {
            case .starting:
                ProgressView()
                Text("Starting…").font(.title2)
                Text("Waiting for the first frame of the display.").foregroundStyle(.secondary)
            case .live:
                Image(systemName: "record.circle.fill").font(.system(size: 48)).foregroundStyle(.red)
                Text(Elapsed.text(live.elapsed)).font(.system(size: 40, weight: .medium, design: .monospaced))
                Button("Stop Recording") {
                    Task { await model.stopRecording() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.escape, modifiers: [])
            case .finishing:
                ProgressView()
                Text("Finishing the take…").font(.title2)
            }
            ForEach(Array(live.warnings.enumerated()), id: \.offset) { _, warning in
                Label(String(describing: warning), systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RecordingMenu: View {
    let model: StudioModel

    var body: some View {
        if let live = model.liveRecording {
            Text("Recording \(Elapsed.text(live.elapsed))")
            Button("Stop Recording") {
                Task { await model.stopRecording() }
            }
            .disabled(!live.isLive)
            Divider()
            Button("Show Open Studio") {
                NSApplication.shared.unhide(nil)
                NSApplication.shared.activate()
            }
        }
    }
}

struct RecordingMenuLabel: View {
    let model: StudioModel

    var body: some View {
        let elapsed = model.liveRecording?.elapsed ?? .zero
        Label(Elapsed.text(elapsed), systemImage: "record.circle.fill")
            .labelStyle(.titleAndIcon)
            .monospacedDigit()
    }
}

enum Elapsed {
    static func text(_ duration: Duration) -> String {
        let total = Int(duration.components.seconds)
        let (hours, minutes, seconds) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
