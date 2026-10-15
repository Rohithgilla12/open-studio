import Foundation
import Recording
import Render
@testable import Studio
import Synchronization
import Testing
import Timeline

@MainActor
@Suite(.serialized)
struct PhaseSpec {
    @Test func openingATakeFromHomeShowsTheEditorAndClosingReturnsHome() async throws {
        let library = try await Library.make()
        defer { library.remove() }
        let model = StudioModel(library: library.url, services: .fake(calls: Calls()))
        await model.launch()
        #expect(model.takes.map(\.url.lastPathComponent) == ["20261013-120000.osrec"])
        #expect(model.takes.first?.health == .ready)

        await model.open(library.take)
        #expect(model.phaseName == "editing")
        #expect(model.openEditor?.zooms.count == 2)

        model.closeEditor()
        #expect(model.phaseName == "home")
    }

    @Test func intentsFromTheWrongPhaseChangeNothing() async throws {
        let library = try await Library.make()
        defer { library.remove() }
        let calls = Calls()
        let model = StudioModel(library: library.url, services: .fake(calls: calls))

        await model.stopRecording()
        model.closeEditor()
        model.export(to: library.url.appending(path: "x.mp4"))
        await model.dismissExport()
        #expect(model.phaseName == "home")
        #expect(!FileManager.default.fileExists(atPath: library.url.appending(path: "x.mp4").path))

        await model.open(library.take)
        let editor = try #require(model.openEditor)
        await model.stopRecording()
        await model.dismissExport()
        #expect(model.phaseName == "editing")
        #expect(model.openEditor === editor)

        model.export(to: library.url.appending(path: "x.mp4"))
        #expect(model.phaseName == "exporting")
        await model.open(library.take)
        await model.startRecording()
        model.closeEditor()
        model.export(to: library.url.appending(path: "y.mp4"))
        #expect(model.phaseName == "exporting")
        #expect(model.exportJob?.destination.lastPathComponent == "x.mp4")
        #expect(calls.starts == 0)

        await model.dismissExport()
        #expect(model.phaseName == "editing")
        #expect(model.openEditor === editor)
    }

    @Test func aSecondRecordPressWhileStartingDoesNotStartASecondTake() async throws {
        let library = try await Library.make()
        defer { library.remove() }
        let calls = Calls()
        let gate = Gate()
        let fake = FakeRecording(directory: library.take)
        let model = StudioModel(library: library.url, services: .fake(calls: calls, start: {
            await gate.wait()
            return fake
        }))

        let first = Task { await model.startRecording() }
        #expect(await eventually { model.phaseName == "recording.starting" && calls.starts == 1 })
        await model.startRecording()
        await model.stopRecording()
        #expect(calls.starts == 1)
        #expect(model.phaseName == "recording.starting")
        #expect(fake.stopCount == 0)

        await gate.open()
        await first.value
        #expect(model.phaseName == "recording.live")
        #expect(calls.hidden == [true])
        fake.progress(3)
        #expect(await eventually { model.liveRecording?.elapsed == .seconds(3) })
    }

    @Test func stopFinishesTheTakeAndOpensItInTheEditor() async throws {
        let library = try await Library.make()
        defer { library.remove() }
        let calls = Calls()
        let fake = FakeRecording(directory: library.take)
        let model = StudioModel(library: library.url, services: .fake(calls: calls, start: { fake }))

        await model.startRecording()
        #expect(model.phaseName == "recording.live")
        await model.stopRecording()
        #expect(model.phaseName == "editing")
        #expect(model.openEditor?.project.source.directory == library.take)
        #expect(calls.hidden == [true, false])
    }

    @Test func theStreamsEndedAfterStopAndASecondStopChangeNothing() async throws {
        let library = try await Library.make()
        defer { library.remove() }
        let fake = FakeRecording(directory: library.take)
        let model = StudioModel(library: library.url, services: .fake(calls: Calls(), start: { fake }))
        await model.startRecording()
        await model.stopRecording()
        let editor = try #require(model.openEditor)

        await model.stopRecording()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.openEditor === editor)
        #expect(fake.stopCount == 1)
    }

    @Test func aStreamThatEndsOnItsOwnAlsoOpensTheEditor() async throws {
        let library = try await Library.make()
        defer { library.remove() }
        let calls = Calls()
        let fake = FakeRecording(directory: library.take)
        let model = StudioModel(library: library.url, services: .fake(calls: calls, start: { fake }))

        await model.startRecording()
        fake.end()
        #expect(await eventually { model.phaseName == "editing" })
        #expect(fake.stopCount == 0)
        #expect(calls.hidden == [true, false])
    }

    @Test func aFailedStartReturnsToWhereItCameFromWithAnAlert() async throws {
        let library = try await Library.make()
        defer { library.remove() }
        let calls = Calls()
        let model = StudioModel(library: library.url, services: .fake(calls: calls, start: { () throws(RecordingError) in
            throw .missingPermissions([.screenRecording])
        }))

        await model.startRecording()
        #expect(model.phaseName == "home")
        #expect(model.alert?.title == "Recording did not start")
        #expect(calls.hidden.isEmpty)

        model.alert = nil
        await model.open(library.take)
        let editor = try #require(model.openEditor)
        await model.startRecording()
        #expect(model.phaseName == "editing")
        #expect(model.openEditor === editor)
        #expect(model.alert != nil)
    }
}

@MainActor
@Suite(.serialized)
struct ExportJobSpec {
    @Test func theJobExportsTheProjectAsItWasWhenTheExportStarted() async throws {
        let library = try await Library.make()
        defer { library.remove() }
        let gate = Gate()
        let received = ReceivedProject()
        let model = StudioModel(library: library.url, services: .fake(calls: Calls(), export: { project, _, _ throws(ExportError) in
            await gate.wait()
            await received.set(project.edits)
            throw .cancelled
        }))
        await model.open(library.take)
        let editor = try #require(model.openEditor)
        let atStart = editor.project.edits

        model.export(to: library.url.appending(path: "out.mp4"))
        editor.apply("Change Padding") { $0.style.padding = 0.2 }
        editor.deleteZoom(editor.zooms[0].id)
        await gate.open()

        #expect(await eventually { if case .failed = model.exportJob?.status { true } else { false } })
        #expect(await received.edits == atStart)
        #expect(await received.edits != editor.project.edits)
    }

    @Test func aRealExportFinishesWithTheFileAtTheDestination() async throws {
        let library = try await Library.make()
        defer { library.remove() }
        var services = StudioServices.live
        services.setAppHidden = { _ in }
        let model = StudioModel(library: library.url, services: services)
        await model.open(library.take)
        let editor = try #require(model.openEditor)
        editor.apply("Change Output Format") { $0.format = OutputFormat(size: .hd1080, frameRate: .fps30, codec: .h264) }
        let destination = model.defaultExportDestination(for: editor)
        #expect(destination == library.url.appending(path: "20261013-120000.mp4"))

        model.export(to: destination)
        #expect(await eventually(.seconds(60)) { !(model.exportJob?.isRunning ?? true) })
        guard case .finished(let report) = model.exportJob?.status else {
            Issue.record("export did not finish: \(String(describing: model.exportJob?.status))")
            return
        }
        #expect(report.frames == 60)
        #expect(FileManager.default.fileExists(atPath: destination.path))

        await model.dismissExport()
        #expect(model.phaseName == "editing")
    }
}

actor ReceivedProject {
    private(set) var edits: Edits?
    func set(_ edits: Edits) { self.edits = edits }
}

@MainActor
@Suite(.serialized)
struct EditorSpec {
    private func openEditor(_ library: Library) async throws -> (Editor, UndoManager) {
        let model = StudioModel(library: library.url, services: .fake(calls: Calls()))
        await model.open(library.take)
        let editor = try #require(model.openEditor)
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        return (editor, undo)
    }

    @Test func aDragIsOneUndoStepAndUndoRedoRestoreTheEdits() async throws {
        let library = try await Library.make()
        defer { library.remove() }
        let (editor, undo) = try await openEditor(library)
        let original = editor.project.edits
        let first = editor.zooms[0]

        for step in [100, 200, 300] {
            undo.beginUndoGrouping()
            editor.moveZoom(first.id, toStart: first.range.start + .milliseconds(Int64(step)))
            undo.endUndoGrouping()
        }
        #expect(undo.undoActionName == "")
        undo.beginUndoGrouping()
        editor.endDrag()
        undo.endUndoGrouping()
        let moved = editor.project.edits
        #expect(editor.zooms[0].range.start == first.range.start + .milliseconds(300))
        #expect(undo.undoActionName == "Move Zoom")

        undo.undo()
        #expect(editor.project.edits == original)
        while undo.canUndo { undo.undo() }
        #expect(editor.project.edits == original)
        undo.redo()
        #expect(editor.project.edits == moved)
    }

    @Test func zoomEditsGoThroughTheTrackAndClampToTheRecording() async throws {
        let library = try await Library.make()
        defer { library.remove() }
        let (editor, _) = try await openEditor(library)
        let first = editor.zooms[0]

        editor.resizeZoom(first.id, edge: .start, to: .seconds(-5))
        editor.endDrag()
        #expect(editor.zooms[0].range.start == .zero)

        editor.selection = first.id
        editor.deleteSelection()
        #expect(editor.zooms.count == 1)
        #expect(editor.selection == nil)

        #expect(!editor.canAddZoom(at: .seconds(8)))
        editor.addZoom(at: .seconds(8))
        #expect(editor.zooms.count == 1)
        editor.addZoom(at: .seconds(2))
        #expect(editor.zooms.count == 2)
        #expect(editor.selection == editor.zooms[0].id)
        #expect(editor.zooms[0].range.duration == .seconds(3))
    }

    @Test func editsAutosaveAfterADelayAndFlushSavesAtOnce() async throws {
        let library = try await Library.make()
        defer { library.remove() }
        let (editor, _) = try await openEditor(library)
        #expect(!FileManager.default.fileExists(atPath: library.projectFile.path))

        editor.apply("Change Padding") { $0.style.padding = 0.15 }
        #expect(editor.saveState == .pending)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: library.projectFile.path))
        #expect(await eventually(.seconds(3)) { editor.saveState == .saved })
        #expect(try Project.open(library.take).edits.style.padding == 0.15)

        editor.apply("Change Padding") { $0.style.padding = 0.05 }
        editor.flush()
        #expect(editor.saveState == .saved)
        #expect(try Project.open(library.take).edits.style.padding == 0.05)
    }

    @Test func anEditThatChangesNothingRecordsNoUndoAndSavesNothing() async throws {
        let library = try await Library.make()
        defer { library.remove() }
        let (editor, undo) = try await openEditor(library)
        undo.beginUndoGrouping()
        editor.apply("Change Padding") { $0.style.padding = $0.style.padding }
        editor.drag("Move Zoom") { _ in }
        editor.endDrag()
        undo.endUndoGrouping()
        #expect(editor.saveState == .saved)
        #expect(undo.undoActionName == "")
    }
}

extension EditorSpec {
    @Test func anEditDuringADragClosesTheDragSoALaterEndRecordsNothing() async throws {
        let library = try await Library.make()
        defer { library.remove() }
        let (editor, undo) = try await openEditor(library)
        let original = editor.project.edits
        let first = editor.zooms[0]

        undo.beginUndoGrouping()
        editor.moveZoom(first.id, toStart: first.range.start + .milliseconds(300))
        editor.deleteZoom(editor.zooms[1].id)
        undo.endUndoGrouping()
        let deleted = editor.project.edits
        #expect(editor.zooms.count == 1)

        undo.undo()
        #expect(editor.project.edits == original)
        undo.redo()
        #expect(editor.project.edits == deleted)
        undo.beginUndoGrouping()
        editor.endDrag()
        undo.endUndoGrouping()
        #expect(undo.undoActionName == "")
    }
}

@MainActor
@Suite(.serialized)
struct HandOffSpec {
    private func savedPadding(_ library: Library) throws -> Double {
        try Project.open(library.take).edits.style.padding
    }

    @Test func leavingTheEditorSavesEditsMadeWithinTheAutosaveDelay() async throws {
        let library = try await Library.make()
        defer { library.remove() }
        let fake = FakeRecording(directory: library.take)
        let model = StudioModel(library: library.url, services: .fake(calls: Calls(), start: { fake }))

        await model.open(library.take)
        model.openEditor?.apply("Change Padding") { $0.style.padding = 0.11 }
        model.export(to: library.url.appending(path: "out.mp4"))
        #expect(try savedPadding(library) == 0.11)
        await model.dismissExport()

        model.openEditor?.apply("Change Padding") { $0.style.padding = 0.12 }
        model.closeEditor()
        #expect(try savedPadding(library) == 0.12)

        await model.open(library.take)
        model.openEditor?.apply("Change Padding") { $0.style.padding = 0.13 }
        await model.startRecording()
        #expect(try savedPadding(library) == 0.13)
    }

    @Test func aDragThatNeverEndedIsSavedWhenTheEditorCloses() async throws {
        let library = try await Library.make()
        defer { library.remove() }
        let model = StudioModel(library: library.url, services: .fake(calls: Calls()))
        await model.open(library.take)
        model.openEditor?.drag("Change Padding") { $0.style.padding = 0.14 }
        model.closeEditor()
        #expect(model.phaseName == "home")
        #expect(try savedPadding(library) == 0.14)
    }

    @Test func openingTheTakeAlreadyOpenKeepsTheEditorAndItsEdits() async throws {
        let library = try await Library.make()
        defer { library.remove() }
        let model = StudioModel(library: library.url, services: .fake(calls: Calls()))
        await model.open(library.take)
        let editor = try #require(model.openEditor)
        editor.apply("Change Padding") { $0.style.padding = 0.15 }

        await model.open(library.take)
        #expect(model.openEditor === editor)
        #expect(editor.project.edits.style.padding == 0.15)
    }

    @Test func aLateEndFromThePreviousTakeLeavesTheNextOneRecording() async throws {
        let library = try await Library.make()
        defer { library.remove() }
        let first = FakeRecording(directory: library.take, endsOnStop: false)
        let second = FakeRecording(directory: library.take)
        let starts = Atomic(0)
        let model = StudioModel(library: library.url, services: .fake(calls: Calls(), start: {
            starts.add(1, ordering: .relaxed).newValue == 1 ? first : second
        }))

        await model.startRecording()
        await model.stopRecording()
        #expect(model.phaseName == "editing")
        await model.startRecording()
        #expect(model.phaseName == "recording.live")

        first.end()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.phaseName == "recording.live")
        #expect(second.stopCount == 0)
    }

    @Test func dismissingARunningExportWaitsForItToStop() async throws {
        let library = try await Library.make()
        defer { library.remove() }
        let gate = Gate()
        let model = StudioModel(library: library.url, services: .fake(calls: Calls(), export: { _, _, _ throws(ExportError) in
            await gate.wait()
            throw .cancelled
        }))
        await model.open(library.take)
        model.export(to: library.url.appending(path: "out.mp4"))
        let job = try #require(model.exportJob)

        let dismissed = Task { await model.dismissExport() }
        #expect(await eventually { job.isCancelling })
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.phaseName == "exporting")

        await gate.open()
        await dismissed.value
        #expect(model.phaseName == "editing")
    }
}

struct StripScaleSpec {
    let scale = StripScale(width: 800, duration: .seconds(10))

    @Test func xAndTimeAreInverseAcrossTheStrip() {
        #expect(scale.x(at: .zero) == 0)
        #expect(scale.x(at: .seconds(10)) == 800)
        #expect(scale.x(at: .seconds(2.5)) == 200)
        #expect(scale.time(atX: 200) == .seconds(2.5))
        for x in stride(from: 0.0, through: 800, by: 37) {
            #expect(abs(scale.x(at: scale.time(atX: x)) - x) < 0.001)
        }
    }

    @Test func timePinsToTheEndsOutsideTheStrip() {
        #expect(scale.time(atX: -50) == .zero)
        #expect(scale.time(atX: 5000) == .seconds(10))
    }

    @Test func anEmptyStripMapsEverythingToZero() {
        #expect(StripScale(width: 0, duration: .seconds(10)).time(atX: 100) == .zero)
        #expect(StripScale(width: 800, duration: .zero).x(at: .seconds(1)) == 0)
    }
}

struct LibrarySpec {
    @Test func takesAreListedNewestFirstWithTheirHealth() async throws {
        let library = try await Library.make()
        defer { library.remove() }
        let older = library.url.appending(path: "20261001-090000.osrec", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: library.take, to: older)
        let empty = library.url.appending(path: "20261020-090000.osrec", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: library.url.appending(path: "not-a-take", directoryHint: .isDirectory), withIntermediateDirectories: true)

        let takes = await TakeLibrary.recoverAndScan(library.url)
        #expect(takes.map(\.name) == ["20261020-090000", "20261013-120000", "20261001-090000"])
        #expect(takes.map(\.health) == [.nothingRecorded, .ready, .ready])
        #expect(takes.map { $0.health.canOpen } == [false, true, true])
    }
}
