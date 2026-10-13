import Testing
@testable import Recording

/// The only part of Recording that runs without a display and permissions.
@Suite struct StateMachineTests {
    @Test func stopIsIdempotent() {
        // TODO: next(.stopping, .stopRequested) == .noop; next(.finished(r), .stopRequested) == .noop
        fatalError("not implemented")
    }

    @Test func lateFramesAfterStopAreIgnored() {
        // TODO: next(.stopping, .firstFrame(...)) == .noop
        fatalError("not implemented")
    }

    @Test func writerFinishedWhilePreparingIsInvalid() {
        fatalError("not implemented")
    }
}
