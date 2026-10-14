import Foundation
import Observation
import Render
import Timeline

/// The editing phase. Owns the project, the preview, and the edit/export mode.
///
/// `mode` is the state machine the brief asks for: while exporting, the editable document is not
/// reachable, so the strip and style controls cannot mutate anything, and the frozen document is
/// the one being written.
@Observable @MainActor
final class Editor {
    enum Mode {
        case editing(EditDocument)
        case exporting(frozen: EditDocument, job: ExportJob, progress: Double)
        case exported(EditDocument, ExportResult)
        case exportFailed(EditDocument, ExportError)
    }

    private(set) var project: Project
    private(set) var preview: Preview
    private(set) var mode: Mode
    private(set) var playhead: RecordingTime = .zero
    private let undo = UndoManager()
    private var saveDebounce: Task<Void, Never>?

    init(project: Project) throws(PreviewError) { fatalError("not implemented") }

    /// The one path for every edit. Pure reducer, then: preview.apply (box swap, or a new Preview
    /// when the output format changed), undo registration with the previous value, debounced save.
    /// A thrown `EditError` is a bug surfacing; it is logged and the document is unchanged.
    func apply(_ action: EditAction) {
        // TODO:
        //   guard case .editing(let doc) = mode else { return }   // unreachable from the UI while exporting
        //   next = try doc.applying(action, source: project.source)
        //   undo.registerUndo(withTarget: self) { $0.restore(doc) }
        //   mode = .editing(next); project.replaceEdit(next)
        //   if !preview.apply(edit: next) { preview = try Preview(project: project) }
        //   scheduleSave()
        fatalError("not implemented")
    }

    /// editing -> exporting. Saves first so the file matches what is rendered.
    func export(to url: URL) { fatalError("not implemented") }

    /// exporting -> editing (cancel) or exported / exportFailed (result). Driven by the job's streams.
    func cancelExport() { fatalError("not implemented") }

    /// exported | exportFailed -> editing.
    func dismissExportResult() { fatalError("not implemented") }

    func seek(to t: RecordingTime) { preview.seek(to: t) }

    /// 300 ms after the last edit. The Timeline rebuild inside `preview.apply` is ~10 ms for a
    /// 30-minute take (measured in D2), so it stays synchronous per drag tick.
    private func scheduleSave() { fatalError("not implemented") }
}
