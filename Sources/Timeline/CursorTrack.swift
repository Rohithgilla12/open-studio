/// Precomputed cursor answers.
struct CursorTrack: Sendable {
    let frameSize: Size
    let position: PositionTrack
    /// Sorted by time.
    let images: [CursorChange]
    /// Sorted, disjoint `[down, up)` intervals of any button held, in seconds.
    let presses: [Interval]
    /// Sorted, disjoint intervals during which the cursor is hidden (typing or idle), in seconds.
    /// Intervals closer than the fade duration are merged so the cursor never blinks between them.
    let hidden: [Interval]
    /// The downs that get a click ring, sorted: every button's, except one inside a cut or outside
    /// the area the take shows, which the viewer never sees. Empty when the effect is off.
    let clickDowns: [ButtonEvent]
    let settings: CursorSettings

    struct Interval: Sendable, Equatable {
        var start: Double
        var end: Double

        init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }

        init(_ microseconds: (start: Int64, end: Int64)) {
            self.init(start: Double(microseconds.start) / 1_000_000, end: Double(microseconds.end) / 1_000_000)
        }
    }

    enum PositionTrack: Sendable {
        case spring(SpringTrack<Vector2>)
        /// Sample-and-hold on the filtered samples, for `CursorSmoothing.none`.
        case held([PointerSample])
    }

    init(source: SourceRecording, settings: CursorSettings, retiming: Retiming) {
        self.settings = settings
        frameSize = source.frameSize
        images = source.cursorChanges

        if let spring = settings.smoothing.spring {
            let (initial, changes) = Self.positionChanges(source: source, spring: spring, settings: settings)
            let retimed = retiming.apply(initial: initial, changes, snapsAtJoins: true)
            position = .spring(SpringTrack(initial: retimed.initial, changes: retimed.changes, rescaleShortIntervals: false))
        } else {
            position = .held(ShakeFilter.apply(source.pointer, threshold: settings.shakeThreshold))
        }

        presses = Self.pressIntervals(source.buttons, end: source.duration)
        clickDowns = settings.showsClicks
            ? source.buttons.filter {
                $0.edge == .down && source.visibleRect.contains($0.position) && retiming.cuts.cut(containing: $0.time) == nil
            }
            : []

        // Hides measure durations the viewer sees, so they run over output time; an instant inside
        // a cut is dropped, and a removed wait does not leave the cursor hidden after the join.
        let map = retiming.map
        var activity = source.pointer.map(\.time)
        activity.append(contentsOf: source.buttons.map(\.time))
        activity.sort()
        let shownActivity = activity.compactMap { map.output(at: $0)?.microseconds }
        let shownKeys = source.keyDowns.compactMap { map.output(at: $0)?.microseconds }
        var hidden = Self.typingIntervals(
            keys: shownKeys, activity: shownActivity, count: settings.typingKeyCount, window: settings.typingWindow.microseconds)
        if let idle = settings.idleHideAfter {
            hidden.append(contentsOf: Self.idleIntervals(activity: shownActivity, after: idle.microseconds, end: map.duration.microseconds))
        }
        self.hidden = Self.union(hidden, mergingGapsUnder: settings.fadeDuration.seconds)
    }

    /// A pause longer than this marks a sample the pointer rested on, which thinning must keep.
    static let restGap = RecordingTime.milliseconds(100)

    /// The spring targets the pointer asks for, in recording seconds, before any cut moves them:
    /// the shake-filtered, thinned samples, with the click spring in effect for the lead before each
    /// mouse-down.
    static func positionChanges(
        source: SourceRecording, spring: Spring, settings: CursorSettings
    ) -> (initial: Vector2, changes: [TargetChange<Vector2>]) {
        let steady = ShakeFilter.apply(source.pointer, threshold: settings.shakeThreshold)
        let buttonTimes = Set(source.buttons.map(\.time))
        let samples = Thinning.apply(steady, distance: settings.thinningDistance) { index in
            let isLast = index == steady.count - 1
            let restsHere = !isLast && steady[index + 1].time - steady[index].time > Self.restGap
            return isLast || restsHere || buttonTimes.contains(steady[index].time)
        }
        let downs = source.buttons.filter { $0.edge == .down }.map(\.time)
        let frameCenter = Vector2(x: source.frameSize.width / 2, y: source.frameSize.height / 2)
        var changes = samples.map { TargetChange(time: $0.time.seconds, target: Vector2($0.position), spring: spring) }
        // The rapid spring takes over for `clickSpringLead` before each mouse-down so the cursor lands on
        // the click; the down sample itself switches back.
        let leads = downs.map { down in
            Interval(start: max(down - settings.clickSpringLead, .zero).seconds, end: down.seconds)
        }
        for lead in leads where lead.start < lead.end {
            let inEffect = samples.lastIndex(keyedBy: \.time.seconds, atOrBefore: lead.start)
            let target = samples.isEmpty || samples[inEffect].time.seconds > lead.start
                ? frameCenter : Vector2(samples[inEffect].position)
            changes.append(TargetChange(time: lead.start, target: target, spring: settings.clickSpring))
        }
        changes.sort { $0.time < $1.time }
        var leadIndex = 0
        for index in changes.indices {
            while leadIndex < leads.count, leads[leadIndex].end <= changes[index].time { leadIndex += 1 }
            if leadIndex < leads.count, leads[leadIndex].start <= changes[index].time {
                changes[index].spring = settings.clickSpring
            }
        }
        let initial = samples.first.map { Vector2($0.position) } ?? frameCenter
        return (initial, changes)
    }

    /// Pairs each button's downs with its ups, runs an unmatched down to `end`, and unions across
    /// buttons.
    static func pressIntervals(_ buttons: [ButtonEvent], end: RecordingTime) -> [Interval] {
        var held: [ButtonEvent.Button: RecordingTime] = [:]
        var intervals: [Interval] = []
        for event in buttons {
            switch event.edge {
            case .down:
                if held[event.button] == nil { held[event.button] = event.time }
            case .up:
                if let down = held.removeValue(forKey: event.button), down < event.time {
                    intervals.append(Interval(start: down.seconds, end: event.time.seconds))
                }
            }
        }
        for down in held.values where down < end {
            intervals.append(Interval(start: down.seconds, end: end.seconds))
        }
        return union(intervals, mergingGapsUnder: 0)
    }

    /// Typing hides the cursor from the n-th key of a burst (n keys within the window and no pointer
    /// activity among them) until the earlier of the next pointer activity and the last key plus the
    /// window. A key that lands while the cursor is still hidden extends the hide, so a slow but
    /// continuous typist does not flicker back in. Times are sorted microseconds on one clock.
    static func typingIntervals(keys: [Int64], activity: [Int64], count n: Int, window: Int64) -> [Interval] {
        guard n > 0, keys.count >= n else { return [] }
        var intervals: [Interval] = []
        var open: (start: Int64, end: Int64)?
        for j in keys.indices {
            let last = keys[j]
            let nextActivity = activity[activity.firstIndex(keyedBy: { Double($0) }, after: Double(last))...].first
            let end = min(nextActivity ?? last + window, last + window)
            if let interval = open, last < interval.end {
                open!.end = end
                continue
            }
            if let interval = open { intervals.append(Interval(interval)) }
            open = nil
            guard j >= n - 1 else { continue }
            let first = keys[j - n + 1]
            let latest = activity.isEmpty ? nil : activity[activity.lastIndex(keyedBy: { Double($0) }, atOrBefore: Double(last))]
            let movedSinceFirst = latest.map { $0 > first && $0 <= last } ?? false
            if last - first <= window, !movedSinceFirst {
                open = (last, end)
            }
        }
        if let interval = open { intervals.append(Interval(interval)) }
        return intervals
    }

    static func idleIntervals(activity: [Int64], after idle: Int64, end: Int64) -> [Interval] {
        var intervals: [Interval] = []
        var previous: Int64 = 0
        for next in activity + [end] {
            if next - previous > idle {
                intervals.append(Interval((previous + idle, next)))
            }
            previous = max(previous, next)
        }
        return intervals
    }

    /// Sorted, disjoint intervals; two intervals closer than `gap` become one.
    static func union(_ intervals: [Interval], mergingGapsUnder gap: Double) -> [Interval] {
        var merged: [Interval] = []
        for interval in intervals.filter({ $0.start < $0.end }).sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, interval.start - last.end <= gap {
                merged[merged.count - 1].end = max(last.end, interval.end)
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    /// The spring position and the fades at output seconds; the held position, the image, and the
    /// presses at the recording seconds shown there.
    func state(springAt output: Double, recordingAt recording: Double) -> CursorState {
        let (p, v): (Vector2, Vector2)
        switch position {
        case .spring(let track):
            (p, v) = track.evaluate(at: output)
        case .held(let samples):
            if samples.isEmpty {
                (p, v) = (Vector2(x: frameSize.width / 2, y: frameSize.height / 2), .zero)
            } else {
                let index = samples.lastIndex(keyedBy: \.time.seconds, atOrBefore: recording)
                (p, v) = (Vector2(samples[index].position), .zero)
            }
        }

        var image: CursorImageID?
        if !images.isEmpty {
            let index = images.lastIndex(keyedBy: \.time.seconds, atOrBefore: recording)
            if images[index].time.seconds <= recording { image = images[index].image }
        }

        let press = Self.pressAmount(at: recording, presses: presses, transition: settings.pressTransition.seconds)
        let opacity = settings.isHidden ? 0 : Self.opacity(at: output, hidden: hidden, fade: settings.fadeDuration.seconds)
        let onDisplay = p.x >= 0 && p.x < frameSize.width && p.y >= 0 && p.y < frameSize.height
        return CursorState(
            position: p.point, velocity: v.velocity, image: image,
            isPressed: press.isPressed, pressAmount: press.amount,
            opacity: opacity, isVisible: opacity > 0 && onDisplay)
    }

    /// The rings alive at a recording instant, oldest first. A ring is press state, so it follows the
    /// recording instant like `pressAmount`: a cut that begins while a ring grows cuts it too.
    func clicks(at recording: RecordingTime) -> [ClickPulse] {
        guard !clickDowns.isEmpty else { return [] }
        let duration = CursorSettings.clickDuration.microseconds
        var pulses: [ClickPulse] = []
        var index = clickDowns.lastIndex(keyedBy: \.time.seconds, atOrBefore: recording.seconds)
        while index >= 0 {
            let down = clickDowns[index]
            let age = recording.microseconds - down.time.microseconds
            if age >= duration { break }
            if age >= 0 { pulses.append(ClickPulse(position: down.position, progress: Double(age) / Double(duration))) }
            index -= 1
        }
        return pulses.reversed()
    }

    static func pressAmount(at t: Double, presses: [Interval], transition: Double) -> (isPressed: Bool, amount: Double) {
        guard !presses.isEmpty else { return (false, 0) }
        let press = presses[presses.lastIndex(keyedBy: \.start, atOrBefore: t)]
        guard press.start <= t else { return (false, 0) }
        if t < press.end {
            return (true, transition > 0 ? min(1, (t - press.start) / transition) : 1)
        }
        return (false, transition > 0 ? max(0, 1 - (t - press.end) / transition) : 0)
    }

    /// 1 outside hidden intervals, ramping linearly to 0 over `fade` after an interval starts and back
    /// to 1 over `fade` after it ends.
    static func opacity(at t: Double, hidden: [Interval], fade: Double) -> Double {
        guard !hidden.isEmpty else { return 1 }
        let interval = hidden[hidden.lastIndex(keyedBy: \.start, atOrBefore: t)]
        guard interval.start <= t else { return 1 }
        if t < interval.end {
            return fade > 0 ? max(0, 1 - (t - interval.start) / fade) : 0
        }
        return fade > 0 ? min(1, (t - interval.end) / fade) : 1
    }
}

/// One click ring on one frame.
public struct ClickPulse: Sendable, Hashable {
    /// Where the button went down, in source pixels.
    public let position: Point
    /// 0 at the press, approaching 1 as the ring fades out.
    public let progress: Double

    public init(position: Point, progress: Double) {
        self.position = position
        self.progress = progress
    }
}

public struct CursorState: Sendable, Hashable {
    /// Hotspot position after smoothing, in source pixels.
    public let position: Point
    /// For tilt and motion blur.
    public let velocity: Velocity
    public let image: CursorImageID?
    public let isPressed: Bool
    /// 0 at rest, 1 fully pressed; eases over `pressTransition`. Draw scale is
    /// `1 - (1 - pressedScale) * pressAmount`.
    public let pressAmount: Double
    /// 0...1. Combines the typing fade and idle hide.
    public let opacity: Double
    /// False when the pointer is off this display or opacity is 0. The renderer can skip the cursor
    /// pass entirely.
    public let isVisible: Bool

    public init(
        position: Point, velocity: Velocity, image: CursorImageID?, isPressed: Bool, pressAmount: Double,
        opacity: Double, isVisible: Bool
    ) {
        self.position = position
        self.velocity = velocity
        self.image = image
        self.isPressed = isPressed
        self.pressAmount = pressAmount
        self.opacity = opacity
        self.isVisible = isVisible
    }
}
