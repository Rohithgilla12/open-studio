import AppKit
import Render
import SwiftUI
import UniformTypeIdentifiers

struct ExportSheet: View {
    let model: StudioModel
    let editor: Editor
    @Binding var isPresented: Bool
    @State private var destination: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(.title2.weight(.semibold))
            if let job = model.exportJob {
                ExportProgressView(model: model, job: job, close: close)
            } else {
                options
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private var chosenDestination: URL { destination ?? model.defaultExportDestination(for: editor) }

    private var options: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                FormatPicker(editor: editor)
                LabeledContent("Save to") {
                    HStack {
                        Text(chosenDestination.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(chosenDestination.path(percentEncoded: false))
                        Button("Choose…") { chooseDestination() }
                    }
                }
            }
            if FileManager.default.fileExists(atPath: chosenDestination.path) {
                Label("A file with this name exists and will be replaced.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Export") { model.export(to: chosenDestination) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.directoryURL = chosenDestination.deletingLastPathComponent()
        panel.nameFieldStringValue = chosenDestination.lastPathComponent
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }

    private func close() {
        isPresented = false
        Task { await model.dismissExport() }
    }
}

struct ExportProgressView: View {
    let model: StudioModel
    let job: ExportJob
    let close: () -> Void

    var body: some View {
        switch job.status {
        case .running(let progress):
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: progress?.fraction ?? 0)
                Text(job.isCancelling ? "Cancelling…" : progress.map { "Frame \($0.framesWritten) of \($0.framesTotal)" } ?? "Preparing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(job.destination.lastPathComponent).font(.callout)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { close() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(job.isCancelling)
                }
            }
        case .finished(let report):
            VStack(alignment: .leading, spacing: 10) {
                Label("Exported \(report.destination.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(summary(report)).font(.callout).foregroundStyle(.secondary)
                ForEach(report.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button("Reveal in Finder") { job.revealInFinder() }
                    Button("Done") { close() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        case .failed(let error):
            VStack(alignment: .leading, spacing: 10) {
                Label("Export failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Text(StudioAlert.describe(error)).font(.callout).textSelection(.enabled)
                HStack {
                    Spacer()
                    Button("Done") { close() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func summary(_ report: ExportReport) -> String {
        let size = ByteCountFormatter.string(fromByteCount: report.bytes, countStyle: .file)
        return String(format: "%d frames, %@, %.1fx real time", report.frames, size, report.realTimeFactor)
    }
}
