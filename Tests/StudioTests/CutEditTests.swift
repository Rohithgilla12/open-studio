import Foundation
import Render
import Testing
import Timeline
@testable import Studio

@MainActor
@Suite(.serialized)
struct CutEditSpec {
    private func openEditor(_ library: Library) async throws -> (Editor, UndoManager) {
        let model = StudioModel(library: library.url, services: .fake(calls: Calls()))
        await model.open(library.take)
        let editor = try #require(model.openEditor)
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        return (editor, undo)
    }

    private func grouped(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    private func range(_ start: Double, _ end: Double) -> TimeRange { TimeRange(start: .seconds(start), end: .seconds(end))! }

    /// Catches a cut drag that records a step per mouse event, or one that unions every step: the
    /// gesture is one undo step, computed from the cuts before it began.
    @Test func aCutDragIsOneUndoStepComputedFromWhereItBegan() async throws {
        let library = try await Library.make()
        defer { library.remove() }
        let (editor, undo) = try await openEditor(library)
        grouped(undo) { editor.markCut(from: .seconds(2), to: .seconds(5)) }
        grouped(undo) { editor.markCut(from: .seconds(2), to: .seconds(4)) }
        #expect(editor.cuts.map(\.range) == [range(2, 4)], "dragging back shrinks the cut")
        #expect(undo.undoActionName == "", "nothing recorded until the gesture ends")
        guard case .cut(let id)? = editor.selection else {
            Issue.record("the new cut is selected")
            return
        }
        #expect(editor.cuts[0].id == id)
        #expect(editor.outputDuration == .seconds(10))
        grouped(undo) { editor.endDrag() }
        #expect(undo.undoActionName == "Cut")
        undo.undo()
        #expect(editor.cuts.isEmpty, "one undo removes the whole gesture")
        #expect(editor.selection == nil)
        undo.redo()
        #expect(editor.cuts.map(\.range) == [range(2, 4)])
    }

    @Test func trimsRestoreAndDeleteGoThroughTheTotalEdits() async throws {
        let library = try await Library.make()
        defer { library.remove() }
        let (editor, undo) = try await openEditor(library)
        grouped(undo) { editor.trim(.start, to: .seconds(1)) }
        grouped(undo) { editor.trim(.start, to: .seconds(1.5)) }
        grouped(undo) { editor.endDrag() }
        #expect(editor.trimmed == RecordingTime.seconds(1.5)...editor.duration)
        #expect(editor.outputDuration == .seconds(10.5))
        #expect(undo.undoActionName == "Trim")

        editor.scrub(to: .seconds(11))
        grouped(undo) { editor.trimToPlayhead(.end) }
        #expect(editor.trimmed == RecordingTime.seconds(1.5)...RecordingTime.seconds(11))
        #expect(editor.cuts.count == 2)

        grouped(undo) { editor.markCut(from: .seconds(5), to: .seconds(6)) }
        grouped(undo) { editor.endDrag() }
        let middle = try #require(editor.cuts.first { $0.range.start == .seconds(5) })
        editor.selection = .cut(middle.id)
        grouped(undo) { editor.deleteSelection() }
        #expect(editor.cuts.count == 2, "Delete restores the selected cut")
        #expect(editor.selection == nil)
        #expect(undo.undoActionName == "Restore Cut")
        undo.undo()
        #expect(editor.cuts.count == 3, "undoing the restore cuts it again")

        grouped(undo) { editor.resizeCut(middle.id, edge: .end, to: .seconds(7)) }
        grouped(undo) { editor.endDrag() }
        let resized = editor.cuts.first { $0.id == middle.id }
        #expect(resized?.range.end == .seconds(7))
        editor.flush()
        #expect(try Project.open(library.take).edits.cuts == editor.project.edits.cuts)
    }

    /// Catches `[` and `]` clamping against a cut they pass instead of absorbing it, which left a
    /// 200 ms kept sliver before the old cut; a handle drag still stops short of the next cut.
    @Test func trimToPlayheadAbsorbsTheCutsItPassesWhileAHandleDragClamps() async throws {
        let library = try await Library.make()
        defer { library.remove() }
        let (editor, undo) = try await openEditor(library)
        grouped(undo) { editor.markCut(from: .seconds(2), to: .seconds(4)) }
        grouped(undo) { editor.endDrag() }
        editor.scrub(to: .seconds(4.5))
        grouped(undo) { editor.trimToPlayhead(.start) }
        #expect(editor.cuts.map(\.range) == [range(0, 4.5)], "the start trim swallows the cut at [2, 4)")
        #expect(editor.trimmed == RecordingTime.seconds(4.5)...editor.duration)
        undo.undo()
        #expect(editor.cuts.map(\.range) == [range(2, 4)])

        grouped(undo) { editor.markCut(from: .seconds(6), to: .seconds(8)) }
        grouped(undo) { editor.endDrag() }
        editor.scrub(to: .seconds(5.5))
        grouped(undo) { editor.trimToPlayhead(.end) }
        #expect(editor.cuts.map(\.range) == [range(2, 4), range(5.5, 12)], "the end trim swallows the cut at [6, 8)")
        #expect(editor.trimmed == RecordingTime.zero...RecordingTime.seconds(5.5))

        grouped(undo) { editor.trim(.start, to: .seconds(4.5)) }
        grouped(undo) { editor.endDrag() }
        #expect(editor.trimmed.lowerBound == .seconds(1.8), "a handle drag keeps the minimum span before the cut")
    }

    /// Catches the playhead stopping inside a removed region: scrubbing into a cut lands on its end
    /// in both clocks.
    @Test func scrubbingIntoACutLandsOnItsEnd() async throws {
        let library = try await Library.make()
        defer { library.remove() }
        let (editor, undo) = try await openEditor(library)
        grouped(undo) { editor.markCut(from: .seconds(3), to: .seconds(5)) }
        grouped(undo) { editor.endDrag() }
        editor.scrub(to: .seconds(4))
        #expect(editor.playhead == Playhead(output: .seconds(3), recording: .seconds(5)))
        editor.scrub(to: .seconds(7))
        #expect(editor.playhead == Playhead(output: .seconds(5), recording: .seconds(7)))
    }
}
