import Foundation
import Testing
@testable import RecordingFormat

struct EventLogSpec {
    @Test func everyEventKindRoundTrips() { fatalError("not implemented") }
    @Test func tornFinalLineIsReportedWithValidPrefixLength() { fatalError("not implemented") }
    @Test func malformedMiddleLineIsAnError() { fatalError("not implemented") }
    @Test func unknownTypeDecodesAsUnknown() { fatalError("not implemented") }
}

struct ManifestSpec {
    @Test func roundTripsWithSortedKeys() { fatalError("not implemented") }
    @Test func atomicWriteLeavesNoTempFileBehind() { fatalError("not implemented") }
    @Test func readerRejectsNewerVersion() { fatalError("not implemented") }
    @Test func readerRejectsTornTailInFinalizedRecording() { fatalError("not implemented") }
}
