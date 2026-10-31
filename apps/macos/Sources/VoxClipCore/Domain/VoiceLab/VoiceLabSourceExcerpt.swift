import Foundation

/// The frames of a source track that a Rewrite take run reads (voice-lab.md §8.7–8.9): the window's neighbourhood,
/// the speaker-check span, the seam handles and the room-tone run. They are held as a few regions at absolute frame
/// positions, so a long recording never sits in memory whole.
public struct VoiceLabSourceExcerpt: Sendable, Equatable {
    public struct Region: Sendable, Equatable {
        /// The absolute frame of `samples[0]`.
        public let start: Int
        public let samples: [Float]
        public var end: Int { start + samples.count }
        public init(start: Int, samples: [Float]) { self.start = start; self.samples = samples }
    }
    /// The frame count of the whole track.
    public let totalFrames: Int
    /// Sorted by `start`; regions do not overlap.
    public let regions: [Region]
    public init(totalFrames: Int, regions: [Region]) {
        self.totalFrames = totalFrames
        self.regions = regions.sorted { $0.start < $1.start }
    }
    /// A track held whole, as short sources and tests pass it.
    public init(whole samples: [Float]) { self.init(totalFrames: samples.count, regions: [Region(start: 0, samples: samples)]) }
    /// The frames `range` of the track, or nil when no single region holds all of them.
    public func samples(_ range: Range<Int>) -> ArraySlice<Float>? {
        guard range.lowerBound >= 0, range.upperBound <= totalFrames,
              let region = regions.first(where: { $0.start <= range.lowerBound && range.upperBound <= $0.end }) else { return nil }
        return region.samples[(range.lowerBound - region.start)..<(range.upperBound - region.start)]
    }
    public var isFinite: Bool { regions.allSatisfy { $0.samples.allSatisfy(\.isFinite) } }
}
