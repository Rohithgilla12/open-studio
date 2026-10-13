enum Thinning {
    /// Keeps a sample only if it is at least `distance` px (Euclidean) from the last kept one, or
    /// `alwaysKeep` says so. The first sample is always kept.
    static func apply(
        _ samples: [PointerSample], distance: Double, alwaysKeep: (Int) -> Bool = { _ in false }
    ) -> [PointerSample] {
        guard distance > 0, let first = samples.first else { return samples }
        var kept = [first]
        kept.reserveCapacity(samples.count)
        for index in samples.indices.dropFirst() {
            let sample = samples[index]
            let dx = sample.position.x - kept[kept.count - 1].position.x
            let dy = sample.position.y - kept[kept.count - 1].position.y
            if dx * dx + dy * dy >= distance * distance || alwaysKeep(index) {
                kept.append(sample)
            }
        }
        return kept
    }
}

enum ShakeFilter {
    /// Drops sample i when it jumps more than `threshold` (Manhattan) from the last kept sample and
    /// sample i+1 is back within `threshold` of that same sample: a one-sample excursion, typically a
    /// cursor warp glitch. A real fast move does not come back, so it survives.
    static func apply(_ samples: [PointerSample], threshold: Double) -> [PointerSample] {
        guard threshold > 0, samples.count > 2 else { return samples }
        var kept = [samples[0]]
        kept.reserveCapacity(samples.count)
        for index in 1..<samples.count {
            let anchor = kept[kept.count - 1].position
            let isLast = index == samples.count - 1
            let jumped = manhattan(samples[index].position, anchor) > threshold
            let returns = !isLast && manhattan(samples[index + 1].position, anchor) <= threshold
            if jumped, returns { continue }
            kept.append(samples[index])
        }
        return kept
    }

    static func manhattan(_ a: Point, _ b: Point) -> Double { abs(a.x - b.x) + abs(a.y - b.y) }
}

/// The camera's "where to look" policy inside a follow-pointer zoom segment.
enum PointerGroups {
    struct Group: Sendable, Equatable {
        var start: RecordingTime
        var target: Point
    }

    /// `samples` are the pointer samples inside the segment, sorted, including the sample in effect at
    /// the segment's start re-stamped to that start (so a segment with no movement still has a target).
    /// The shake filter runs before thinning, because thinning can drop the sample that proves a
    /// warp returned. Then samples are grouped greedily in time order: a group closes when adding the
    /// next sample would push its bounding box past half the visible viewport. Each group's target is
    /// its time-weighted centroid, weighting each sample by the time until the next sample (the next
    /// group's start, or `segmentEnd`, for the last one).
    static func build(
        samples: [PointerSample], segmentEnd: RecordingTime, visibleViewport: Size,
        thinning: Double, shakeThreshold: Double
    ) -> [Group] {
        let filtered = Thinning.apply(ShakeFilter.apply(samples, threshold: shakeThreshold), distance: thinning)
        guard !filtered.isEmpty else { return [] }
        let limit = Size(width: visibleViewport.width / 2, height: visibleViewport.height / 2)

        var runs: [[PointerSample]] = []
        var current: [PointerSample] = []
        var box = (minX: 0.0, maxX: 0.0, minY: 0.0, maxY: 0.0)
        for sample in filtered {
            let p = sample.position
            if current.isEmpty {
                current = [sample]
                box = (p.x, p.x, p.y, p.y)
                continue
            }
            let grown = (min(box.minX, p.x), max(box.maxX, p.x), min(box.minY, p.y), max(box.maxY, p.y))
            if grown.1 - grown.0 > limit.width || grown.3 - grown.2 > limit.height {
                runs.append(current)
                current = [sample]
                box = (p.x, p.x, p.y, p.y)
            } else {
                current.append(sample)
                box = grown
            }
        }
        runs.append(current)

        return runs.indices.map { index in
            let run = runs[index]
            let runEnd = index + 1 < runs.count ? runs[index + 1][0].time : segmentEnd
            var weighted = Point(x: 0, y: 0)
            var totalWeight = 0.0
            for (position, sample) in run.enumerated() {
                let next = position + 1 < run.count ? run[position + 1].time : runEnd
                let weight = max(0, (next - sample.time).seconds)
                weighted.x += sample.position.x * weight
                weighted.y += sample.position.y * weight
                totalWeight += weight
            }
            let target: Point
            if totalWeight > 0 {
                target = Point(x: weighted.x / totalWeight, y: weighted.y / totalWeight)
            } else {
                let count = Double(run.count)
                target = Point(
                    x: run.reduce(0) { $0 + $1.position.x } / count, y: run.reduce(0) { $0 + $1.position.y } / count)
            }
            return Group(start: run[0].time, target: target)
        }
    }
}
