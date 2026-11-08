import Foundation

/// What a clip's plan request shows the AI of its picture (ADR-R48 part 2, ai.md §19.6): the frame sheet's text summary,
/// always, and its small JPEGs when the connector takes images and the run may send them; plus the candidates the local
/// analysis names, so the reply can pick among them by id. Blur candidates are `B1…` (`FrameBlurSpans.merge` over the
/// sentence frames), cover candidates `C1…C3` (the best three by `CoverFrame.score`). The opening frame and the face-follow
/// crop are local decisions and are not offered.
public struct ClipAutopilotFrames: Sendable, Equatable {
    /// A screen with text the reply decides to blur or leave sharp.
    public struct BlurCandidate: Codable, Sendable, Equatable {
        public var id: String
        /// Source seconds, padded and clipped to the clip's own time.
        public var start: Double
        public var end: Double
        /// Picture space, top-left origin: the union of the screen's rects over the span.
        public var rect: ClipEffect.Rect
        /// Sentence frames the screen was seen in.
        public var frames: Int
        public init(id: String, start: Double, end: Double, rect: ClipEffect.Rect, frames: Int) {
            self.id = id; self.start = start; self.end = end; self.rect = rect; self.frames = frames
        }
    }

    /// A frame the reply may pick as the cover.
    public struct CoverCandidate: Codable, Sendable, Equatable {
        public var id: String
        /// The sheet frame's number ("Frame 3").
        public var frame: Int
        /// The frame's source second.
        public var time: Double
        public var score: Double
        public init(id: String, frame: Int, time: Double, score: Double) { self.id = id; self.frame = frame; self.time = time; self.score = score }
    }

    /// The sheet's text summary; every connector gets it in the instruction.
    public var summary: String
    /// The 320 px frames, labelled "Frame n at s.ss s"; empty for a text-only send.
    public var images: [LLMImage]
    public var blur: [BlurCandidate]
    public var cover: [CoverCandidate]
    /// The sheet's frames, sent as images or described in the summary.
    public var frames: [FrameSheetFrame]
    /// Anthropic's estimate of the images' input tokens (`FrameSheet.imageTokens`); 0 for a text-only send.
    public var estimatedImageTokens: Int

    public init(summary: String, images: [LLMImage], blur: [BlurCandidate], cover: [CoverCandidate], frames: [FrameSheetFrame],
                estimatedImageTokens: Int) {
        self.summary = summary; self.images = images; self.blur = blur; self.cover = cover; self.frames = frames
        self.estimatedImageTokens = estimatedImageTokens
    }

    /// The frames of `sheet` for a clip that plays `clipStart...clipEnd` (source seconds), with the images when `images`.
    public init(sheet: FrameSheet, clipStart: Double, clipEnd: Double, images: Bool) {
        let observations = sheet.frames.map(\.observation)
        self.init(summary: sheet.summary, images: images ? sheet.images : [],
                  blur: ClipFrameCandidates.blur(observations, clipStart: clipStart, clipEnd: clipEnd),
                  cover: ClipFrameCandidates.cover(sheet.frames), frames: sheet.frames,
                  estimatedImageTokens: images ? sheet.estimatedImageTokens : 0)
    }

    /// The same frames as a text-only send: the summary and the candidates, no images.
    public var textOnly: ClipAutopilotFrames {
        ClipAutopilotFrames(summary: summary, images: [], blur: blur, cover: cover, frames: frames, estimatedImageTokens: 0)
    }

    public var sendsImages: Bool { !images.isEmpty }

    /// The candidate a reply's blur id names.
    public func blurCandidate(_ id: String) -> BlurCandidate? { blur.first { $0.id == id } }
    public func coverCandidate(_ id: String) -> CoverCandidate? { cover.first { $0.id == id } }
}

/// The candidates of a clip's frames, pure so tests feed fabricated observations.
public enum ClipFrameCandidates {
    /// Sentence frames are one per sentence, seconds apart: a screen seen again within this many seconds is the same one.
    public static let blurMaxGap = 8.0
    /// Each blur span reaches this far past the first and last frame that saw its screen, into the time between frames.
    public static let blurPad = 1.0
    /// At most this many cover candidates.
    public static let maximumCovers = 3

    /// `B1…` in start order: the screens merged over the frames, each span padded and kept inside the clip.
    public static func blur(_ frames: [FrameObservation], clipStart: Double, clipEnd: Double) -> [ClipAutopilotFrames.BlurCandidate] {
        let spans = FrameBlurSpans.merge(frames, maxGap: blurMaxGap, pad: blurPad)
        var result: [ClipAutopilotFrames.BlurCandidate] = []
        for span in spans {
            let start = max(span.start, clipStart), end = min(span.end, clipEnd)
            guard end > start, span.rect.isValid else { continue }
            result.append(.init(id: "B\(result.count + 1)", start: start, end: end, rect: span.rect, frames: span.frames))
        }
        return result
    }

    /// `C1…C3`: the best frames by `CoverFrame.score`, best first; the earlier frame wins a tie.
    public static func cover(_ frames: [FrameSheetFrame]) -> [ClipAutopilotFrames.CoverCandidate] {
        let observations = frames.map(\.observation)
        let scored = frames.compactMap { frame -> (FrameSheetFrame, Double)? in
            CoverFrame.score(frame.observation, neighbours: observations).map { (frame, $0) }
        }
        let ranked = scored.enumerated().sorted { left, right in
            abs(left.element.1 - right.element.1) > 1e-12 ? left.element.1 > right.element.1 : left.offset < right.offset
        }
        return ranked.prefix(maximumCovers).enumerated().map { rank, item in
            .init(id: "C\(rank + 1)", frame: item.element.0.index, time: item.element.0.observation.time, score: item.element.1)
        }
    }
}
