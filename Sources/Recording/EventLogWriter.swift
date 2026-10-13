import Foundation
internal import RecordingFormat
import Synchronization

actor EventLogWriter {
    private let layout: RecordingLayout
    private let tapBuffer: InputBuffer<CapturedInput>
    private let cursorBuffer: InputBuffer<CapturedCursor>
    private let conversion: EventConversion
    private var handle: FileHandle?
    private var declared: [CursorImage: CursorImageID] = [:]
    private var drainLoop: Task<Void, Never>?
    private var drainFailure: (any Error)?
    private let written = Atomic<Int>(0)

    nonisolated var eventsWritten: Int { written.load(ordering: .relaxed) }

    init(
        layout: RecordingLayout, tapBuffer: InputBuffer<CapturedInput>, cursorBuffer: InputBuffer<CapturedCursor>,
        conversion: EventConversion
    ) {
        self.layout = layout
        self.tapBuffer = tapBuffer
        self.cursorBuffer = cursorBuffer
        self.conversion = conversion
    }

    func begin(snapshot: CapturedSnapshot) throws {
        guard FileManager.default.createFile(atPath: layout.events.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: layout.events.path])
        }
        let handle = try FileHandle(forWritingTo: layout.events)
        self.handle = handle
        var batch = Batch()
        let cursor = try snapshot.cursor.map { try declare($0, into: &batch) }
        try batch.append(conversion.state(snapshot, cursor: cursor))
        try commit(batch)
        drainLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                await self?.drainReportingFailure()
            }
        }
    }

    func drain() throws {
        var batch = Batch()
        for item in Pending.merged(tapBuffer.take(), cursorBuffer.take()) {
            switch item {
            case .input(let input):
                if let event = conversion.event(input) { try batch.append(event) }
            case .cursor(let change):
                guard let t = change.time.mediaTime(since: conversion.origin) else { continue }
                let id = try declare(change.image, into: &batch)
                try batch.append(.cursor(t: t, id: id))
            }
        }
        try commit(batch)
    }

    func finish() async throws -> Int {
        drainLoop?.cancel()
        drainLoop = nil
        guard let handle else { return eventsWritten }
        if let drainFailure { throw drainFailure }
        try drain()
        try handle.close()
        self.handle = nil
        return eventsWritten
    }

    private func drainReportingFailure() {
        guard drainFailure == nil else { return }
        do {
            try drain()
        } catch {
            drainFailure = error
        }
    }

    private func declare(_ image: CursorImage, into batch: inout Batch) throws -> CursorImageID {
        if let id = declared[image] { return id }
        let declaration = try layout.storeCursorImage(png: image.png, hotspot: image.hotspot, size: image.size)
        try batch.append(.cursorImage(declaration))
        declared[image] = declaration.id
        return declaration.id
    }

    private func commit(_ batch: Batch) throws {
        guard batch.lines > 0, let handle else { return }
        try handle.write(contentsOf: batch.bytes)
        written.add(batch.lines, ordering: .relaxed)
    }

    private struct Batch {
        var bytes = Data()
        var lines = 0

        mutating func append(_ event: WireEvent) throws {
            bytes.append(try EventLog.encodeLine(event))
            lines += 1
        }
    }

    private enum Pending {
        case input(CapturedInput)
        case cursor(CapturedCursor)

        var time: HostTime {
            switch self {
            case .input(let input): input.time
            case .cursor(let change): change.time
            }
        }

        static func merged(_ inputs: [CapturedInput], _ cursors: [CapturedCursor]) -> [Pending] {
            let all = inputs.map(Pending.input) + cursors.map(Pending.cursor)
            return all.enumerated()
                .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
                .map(\.element)
        }
    }
}
