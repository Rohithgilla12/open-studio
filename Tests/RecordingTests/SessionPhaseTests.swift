import Foundation
import Testing
@testable import Recording

struct SessionPhaseTests {
    let recording = SessionPhase.recording(RecordingProgress(mediaTime: .zero, framesWritten: 0, eventsWritten: 0))
    let finished = FinishedRecording(
        directory: URL(filePath: "/tmp/x.osrec"), duration: .seconds(5), hasMicrophone: false, termination: .userStopped)

    func run(_ inputs: [SessionInput]) -> (SessionPhase, [SessionEffect]) {
        var phase = recording
        var effects: [SessionEffect] = []
        for input in inputs {
            let transition = SessionPhase.next(phase, input)
            phase = transition.phase
            effects += transition.effects
        }
        return (phase, effects)
    }

    @Test func stopRequestedWhileRecordingStartsFinalizationOnce() {
        let (phase, effects) = run([.stopRequested])
        #expect(phase == .stopping(.userStopped))
        #expect(effects == [.finalize(.userStopped)])
    }

    @Test func secondStopIsNoOp() {
        let (phase, effects) = run([.stopRequested, .stopRequested, .durationReached])
        #expect(phase == .stopping(.userStopped))
        #expect(effects.filter { if case .finalize = $0 { true } else { false } }.count == 1)
    }

    @Test func firstTerminationReasonWins() {
        let (phase, effects) = run([.streamFailed("display unplugged"), .stopRequested])
        #expect(phase == .stopping(.streamFailed("display unplugged")))
        #expect(effects == [.finalize(.streamFailed("display unplugged"))])
    }

    @Test func endedIsEmittedExactlyOnceAndNothingFollows() {
        let (phase, effects) = run([
            .durationReached, .finalized(finished), .stopRequested, .finalized(finished),
            .progress(RecordingProgress(mediaTime: .seconds(9), framesWritten: 1, eventsWritten: 1)),
        ])
        #expect(phase == .finished(finished))
        #expect(effects == [.finalize(.durationReached), .emit(.ended(finished))])
    }

    @Test func progressAndWarningsPassThroughWhileRecording() {
        let progress = RecordingProgress(mediaTime: .seconds(1), framesWritten: 60, eventsWritten: 3)
        let (phase, effects) = run([.progress(progress), .warning(.framesDropped(count: 2))])
        #expect(phase == .recording(progress))
        #expect(effects == [.emit(.progress(progress)), .emit(.warning(.framesDropped(count: 2)))])
    }

    @Test func warningsAfterStopAreDropped() {
        let (_, effects) = run([.stopRequested, .warning(.framesDropped(count: 2))])
        #expect(effects == [.finalize(.userStopped)])
    }
}
