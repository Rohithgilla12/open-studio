import CoreGraphics
import Foundation
import Recording
@testable import Studio
import Testing

@MainActor
@Suite(.serialized)
struct TargetSpec {
    let library = FileManager.default.temporaryDirectory.appending(path: "StudioTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let remembered = CGRect(x: 100, y: 80, width: 1280, height: 720)
    let editor = WindowInfo(
        id: 42, appName: "TextEdit", title: "Notes", processID: 501, frame: CGRect(x: 0, y: 0, width: 800, height: 600), displayID: 3)

    private func model(_ scratch: ScratchDefaults, _ calls: Calls, kind: CaptureKind, areas: [CGDirectDisplayID: CGRect] = [:],
                       selectArea: AreaSelection = .cancelled, windows: [WindowInfo] = []) -> StudioModel {
        RecordingPreferences(display: .id(3), microphone: .none, captureKind: kind, areas: areas).save(to: scratch.defaults)
        return StudioModel(
            library: library, services: .fake(calls: calls, selectArea: selectArea, windows: windows), defaults: scratch.defaults)
    }

    @Test func entireScreenRecordsTheChosenDisplay() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let calls = Calls()
        let model = model(scratch, calls, kind: .screen, areas: [3: remembered])
        #expect(model.configuration?.target == .display(.id(3)))

        await model.record()
        #expect(calls.areaRequests.isEmpty)
        #expect(calls.configurations.map(\.target) == [.display(.id(3))])
    }

    @Test func areaRecordsTheLastAreaOfTheChosenDisplayOnly() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        #expect(model(scratch, Calls(), kind: .area, areas: [3: remembered]).configuration?.target == .area(.id(3), remembered))

        let elsewhere = model(scratch, Calls(), kind: .area, areas: [4: remembered])
        #expect(elsewhere.configuration == nil)
        #expect(elsewhere.readiness != .needsWindow)
    }

    @Test func windowNeedsAChosenWindowBeforeRecording() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let calls = Calls()
        let model = model(scratch, calls, kind: .window, windows: [editor])
        model.refreshWindows()
        #expect(model.configuration == nil)
        #expect(model.readiness == .needsWindow)
        #expect(!model.canStartRecording)
        await model.record()
        #expect(calls.starts == 0)

        model.selectedWindowID = editor.id
        #expect(model.readiness != .needsWindow)
        await model.record()
        #expect(calls.configurations.map(\.target) == [.window(42)])
    }

    @Test func aChosenWindowThatClosesIsDeselectedOnRefresh() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let open = model(scratch, Calls(), kind: .window, windows: [editor])
        open.refreshWindows()
        open.selectedWindowID = editor.id
        open.refreshWindows()
        #expect(open.selectedWindowID == editor.id)

        let closed = model(scratch, Calls(), kind: .window, windows: [])
        closed.selectedWindowID = editor.id
        closed.refreshWindows()
        #expect(closed.selectedWindowID == nil)
        #expect(closed.readiness == .needsWindow)
    }

    @Test func confirmingAnAreaSavesItForTheDisplayAndRecordsIt() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let calls = Calls()
        let chosen = CGRect(x: 40, y: 30, width: 640, height: 360)
        let model = model(scratch, calls, kind: .area, areas: [3: remembered], selectArea: .selected(chosen))

        await model.record()
        #expect(calls.areaRequests.map(\.display) == [.id(3)])
        #expect(calls.areaRequests.map(\.preset) == [remembered])
        #expect(calls.configurations.map(\.target) == [.area(.id(3), chosen)])
        #expect(RecordingPreferences.load(from: scratch.defaults).area(on: .id(3)) == chosen)
    }

    @Test func selectingAnAreaFromAnotherKindSwitchesToArea() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let calls = Calls()
        let chosen = CGRect(x: 0, y: 0, width: 200, height: 100)
        let model = model(scratch, calls, kind: .screen, selectArea: .selected(chosen))

        await model.selectAreaThenRecord(preset: nil)
        #expect(model.preferences.captureKind == .area)
        #expect(calls.configurations.map(\.target) == [.area(.id(3), chosen)])
    }

    @Test func cancellingTheOverlayRecordsNothingAndKeepsTheLastArea() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let calls = Calls()
        let model = model(scratch, calls, kind: .area, areas: [3: remembered], selectArea: .cancelled)

        await model.record()
        #expect(calls.areaRequests.count == 1)
        #expect(calls.starts == 0)
        #expect(model.alert == nil)
        #expect(RecordingPreferences.load(from: scratch.defaults).area(on: .id(3)) == remembered)
    }

    @Test func aDisconnectedDisplayIsReportedInsteadOfRecording() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let calls = Calls()
        let model = model(scratch, calls, kind: .area, selectArea: .displayUnavailable)

        await model.record()
        #expect(calls.starts == 0)
        #expect(model.alert?.title == "The chosen display is not connected")
    }
}

struct LaunchArgumentSpec {
    @Test func selectAreaReadsFourNumbersInDisplayPoints() {
        #expect(CGRect(launchArgument: "100,80,1280,720") == CGRect(x: 100, y: 80, width: 1280, height: 720))
        #expect(CGRect(launchArgument: "0.5, 0, 64, 32.25") == CGRect(x: 0.5, y: 0, width: 64, height: 32.25))
        #expect(CGRect(launchArgument: "100,x,1280,720") == nil)
        #expect(CGRect(launchArgument: "100,x,80,1280,720") == nil)
        #expect(CGRect(launchArgument: "100,80,1280") == nil)
        #expect(CGRect(launchArgument: "100,80,-1280,720") == nil)
    }

    @Test func captureTargetNamesAreTheStoredRawValues() {
        #expect(["screen", "area", "window"].map(CaptureKind.init(rawValue:)) == [.screen, .area, .window])
    }
}
