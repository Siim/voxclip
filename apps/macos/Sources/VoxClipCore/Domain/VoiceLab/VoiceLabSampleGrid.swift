import Foundation

/// Words meet a replace range on the source sample grid (voice-lab §10.1, 2026-11-10). The fit and the recipe store a
/// range's edges as their sample over the source rate (§8.9.2), so a touching word boundary off the grid would otherwise
/// sit under a sample inside or outside a stored edge. Every time here is rounded with the JavaScript half-up rule the fit
/// uses, `jsRound(seconds × rate)`. Samples stay binary64 so a time outside the take never traps.
public struct VoiceLabSampleGrid: Sendable, Equatable {
    public let rate: Double

    public init(rate: Double) { self.rate = rate }

    /// The sample a time rounds to.
    public func sample(_ seconds: Double) -> Double { EditingPrimitives.jsRound(seconds * rate) }

    /// Whether an item from `start` to `end` lies wholly inside the range from `lower` to `upper`. A stored edge that rounds
    /// to the same sample as a touching boundary meets it.
    public func contains(_ lower: Double, _ upper: Double, start: Double, end: Double) -> Bool {
        sample(start) >= sample(lower) && sample(end) <= sample(upper)
    }

    /// Whether an item from `start` to `end` crosses the edge at `edge` seconds: the edge's sample lies strictly between
    /// the item's rounded boundaries.
    public func crosses(start: Double, end: Double, edge: Double) -> Bool {
        crosses(start: start, end: end, edgeSample: sample(edge))
    }

    /// Whether an item from `start` to `end` crosses the edge at source sample `edgeSample`.
    public func crosses(start: Double, end: Double, edgeSample: Double) -> Bool {
        sample(start) < edgeSample && edgeSample < sample(end)
    }

    /// Whether an item from `start` to `end` shares at least one sample with the range from `lower` to `upper`.
    public func overlaps(_ lower: Double, _ upper: Double, start: Double, end: Double) -> Bool {
        sample(end) > sample(lower) && sample(start) < sample(upper)
    }
}

extension VoiceLabReplacement {
    /// Whether this replace range covers the item from `start` to `end` on the source grid at `rate` (§10.1).
    public func covers(start: Double, end: Double, rate: Double) -> Bool {
        VoiceLabSampleGrid(rate: rate).contains(self.start, self.end, start: start, end: end)
    }
}
