import Testing
@testable import Timeline

// Each test names the defect it catches.

struct TimeMapSpec {
    /// Catches an off-by-one join: the frame after a cut must be the cut's end, not its start.
    @Test func joinShowsTheFirstKeptInstantAfterTheCut() { fatalError("not implemented") }

    /// Catches drift: recording(at: output(at: r)!) == r for every kept microsecond sampled.
    @Test func roundTripsEveryKeptInstantExactly() { fatalError("not implemented") }

    /// Catches a non-monotone collapse, which would unsort the spring change lists.
    @Test func collapsingIsMonotoneAndLandsOnTheJoin() { fatalError("not implemented") }
}

struct CutsSpec {
    /// Catches representable "nothing kept": cutting [0, duration) returns nil, and decoding it throws.
    @Test func aCutThatLeavesNothingIsRefused() { fatalError("not implemented") }

    /// Catches overlapping or touching cuts: two cuts 50 ms apart merge into one keeping the earlier id.
    @Test func nearbyCutsMerge() { fatalError("not implemented") }

    /// Catches a sliver: a trim that would leave 100 ms before the first cut clamps to minimumKept.
    @Test func editsClampKeptSpansToTheMinimum() { fatalError("not implemented") }

    /// Catches restore leaving residue: cutting then restoring yields `Edits` equal to the original.
    @Test func restoreIsExact() { fatalError("not implemented") }
}

struct TimelineCutSpec {
    /// Catches a zoom inside a cut leaking a zoom-out tail into the kept frames after it: every
    /// frame of the edited take equals the frame of the same take with that zoom deleted.
    @Test func aZoomWhollyInsideACutHasNoEffect() { fatalError("not implemented") }

    /// Catches a camera jump: scale and centre at the last frame before a join and the first after
    /// differ by no more than one frame of spring motion, and velocity is continuous.
    @Test func theCameraCarriesItsSpringAcrossAJoin() { fatalError("not implemented") }

    /// Catches springing in from the recording's start after a head trim: frame(at: .zero) is at
    /// rest on the target in effect at the trim.
    @Test func aTrimmedTakeStartsAtRest() { fatalError("not implemented") }

    /// Catches the cursor image or press state being read at output time: they match the recording
    /// at map.recording(at: t).
    @Test func stepStateCutsWithTheContent() { fatalError("not implemented") }

    /// Catches a broken default: with no cuts, frame(at: OutputTime(µs)) equals today's frame at
    /// RecordingTime(µs) for the determinism fixture.
    @Test func noCutsIsTodaysTimeline() { fatalError("not implemented") }
}

// In RenderTests, against the D4 take:
// - export with cuts: frame count == ceil(map.duration * fps); the pixel test's still at output t
//   equals the uncut still at map.recording(at: t).
// - the audio mix has a ramp pair at every join and a fade at a trimmed end; a mix over a muted
//   source still names only audible tracks.
// - a camera lost before, inside, and after a cut: the instruction split sits at
//   map.output(collapsing: camera end).
// - project.json: no cuts writes version 1; cuts write version 2; a version 2 file with
//   overlapping cuts is .invalidCuts; save, reopen, and the Edits are equal.
