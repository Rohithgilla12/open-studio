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
    let settings: CursorSettings

    struct Interval: Sendable, Equatable {
        var start: Double
        var end: Double
    }

    enum PositionTrack: Sendable {
        case spring(SpringTrack<Vector2>)
        /// Sample-and-hold on the filtered samples, for `CursorSmoothing.none`.
        case held([PointerSample])
    }

    init(source: SourceRecording, settings: CursorSettings) {
        self.settings = settings
        frameSize = source.frameSize
        images = source.cursorChanges

        let steady = ShakeFilter.apply(source.pointer, threshold: settings.shakeThreshold)
        if let spring = settings.smoothing.spring {
            let buttonTimes = Set(source.buttons.map(\.time))
            let samples = Thinning.apply(steady, distance: settings.thinningDistance) { index in
                let isLast = index == steady.count - 1
                let restsHere = !isLast && steady[index + 1].time - steady[index].time > Self.restGap
                return isLast || restsHere || buttonTimes.contains(steady[index].time)
            }
            position = .spring(Self.positionSpring(
                samples: samples, downs: source.buttons.filter { $0.edge == .down }.map(\.time),
                frameCenter: Vector2(x: source.frameSize.width / 2, y: source.frameSize.height / 2),
                spring: spring, settings: settings))
        } else {
            position = .held(steady)
        }

        presses = Self.pressIntervals(source.buttons, end: source.duration)

        var activity = source.pointer.map(\.time)
        activity.append(contentsOf: source.buttons.map(\.time))
        activity.sort()
        var hidden = Self.typingIntervals(keys: source.keyDowns, activity: activity, settings: settings)
        if let idle = settings.idleHideAfter {
            hidden.append(contentsOf: Self.idleIntervals(activity: activity, after: idle, end: source.duration))
        }
        self.hidden = Self.union(hidden, mergingGapsUnder: settings.fadeDuration.seconds)
    }

    /// A pause longer than this marks a sample the pointer rested on, which thinning must keep.
    static let restGap = RecordingTime.milliseconds(100)

    static func positionSpring(
        samples: [PointerSample], downs: [RecordingTime], frameCenter: Vector2, spring: Spring, settings: CursorSettings
    ) -> SpringTrack<Vector2> {
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
        return SpringTrack(initial: initial, changes: changes, rescaleShortIntervals: false)
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
    /// continuous typist does not flicker back in.
    static func typingIntervals(keys: [RecordingTime], activity: [RecordingTime], settings: CursorSettings) -> [Interval] {
        let n = settings.typingKeyCount
        guard n > 0, keys.count >= n else { return [] }
        var intervals: [Interval] = []
        var open: Interval?
        for j in keys.indices {
            let last = keys[j]
            let nextActivity = activity[activity.firstIndex(keyedBy: \.seconds, after: last.seconds)...].first
            let end = min(nextActivity ?? last + settings.typingWindow, last + settings.typingWindow).seconds
            if let interval = open, last.seconds < interval.end {
                open!.end = end
                continue
            }
            if let interval = open { intervals.append(interval) }
            open = nil
            guard j >= n - 1 else { continue }
            let first = keys[j - n + 1]
            let latest = activity.isEmpty ? nil : activity[activity.lastIndex(keyedBy: \.seconds, atOrBefore: last.seconds)]
            let movedSinceFirst = latest.map { $0 > first && $0 <= last } ?? false
            if last - first <= settings.typingWindow, !movedSinceFirst {
                open = Interval(start: last.seconds, end: end)
            }
        }
        if let interval = open { intervals.append(interval) }
        return intervals
    }

    static func idleIntervals(activity: [RecordingTime], after idle: RecordingTime, end: RecordingTime) -> [Interval] {
        var intervals: [Interval] = []
        var previous = RecordingTime.zero
        for next in activity + [end] {
            if next - previous > idle {
                intervals.append(Interval(start: (previous + idle).seconds, end: next.seconds))
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

    func state(at seconds: Double) -> CursorState {
        let (p, v): (Vector2, Vector2)
        switch position {
        case .spring(let track):
            (p, v) = track.evaluate(at: seconds)
        case .held(let samples):
            if samples.isEmpty {
                (p, v) = (Vector2(x: frameSize.width / 2, y: frameSize.height / 2), .zero)
            } else {
                let index = samples.lastIndex(keyedBy: \.time.seconds, atOrBefore: seconds)
                (p, v) = (Vector2(samples[index].position), .zero)
            }
        }

        var image: CursorImageID?
        if !images.isEmpty {
            let index = images.lastIndex(keyedBy: \.time.seconds, atOrBefore: seconds)
            if images[index].time.seconds <= seconds { image = images[index].image }
        }

        let press = Self.pressAmount(at: seconds, presses: presses, transition: settings.pressTransition.seconds)
        let opacity = Self.opacity(at: seconds, hidden: hidden, fade: settings.fadeDuration.seconds)
        let onDisplay = p.x >= 0 && p.x < frameSize.width && p.y >= 0 && p.y < frameSize.height
        return CursorState(
            position: p.point, velocity: v.velocity, image: image,
            isPressed: press.isPressed, pressAmount: press.amount,
            opacity: opacity, isVisible: opacity > 0 && onDisplay)
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
}
