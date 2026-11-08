import Foundation

/// What a render puts in its export, in output seconds (the edited time at the clip's speed): the words to hear, the
/// phrases Voice Lab speaks, the cuts and the caption cards. The export check (ADR-R49) compares the exported file with
/// these, so they come from the same plan and layout the renderer used, never from the file's pixels.
public enum ExportCheckExpectation {
    public struct Edit: Sendable, Equatable {
        public var words: [ExportCheckInput.Word]
        public var phrases: [ExportCheckInput.Phrase]
        public var cuts: [Double]
        /// The rendered length, seconds.
        public var duration: Double
        public init(words: [ExportCheckInput.Word], phrases: [ExportCheckInput.Phrase], cuts: [Double], duration: Double) {
            self.words = words; self.phrases = phrases; self.cuts = cuts; self.duration = duration
        }
    }

    /// The render's words: on the Voice Lab path the output plan's own words (each Rewrite's or revoiced phrase's words
    /// at their placed times, the kept source words mapped around them); otherwise the kept source words of `state`'s
    /// active clip through the render's plan, corrections applied, as the captions read them. A bleeped or muted word
    /// isn't heard and isn't expected; a kept filler is optional. Nil `state` (no transcript) expects no words.
    public static func edit(render: RenderRequest, state: EditState?) throws -> Edit {
        try edit(timeline: render.timeline, speed: render.speedTiming, effects: render.effects?.effects ?? [], state: state,
                 duration: render.renderedDuration)
    }

    /// `edit(render:state:)` from its parts: the render's timeline, the clip's speed, its effects and its rendered length.
    public static func edit(timeline: RenderTimeline, speed: ClipSpeedTiming, effects: [ClipEffect], state: EditState?,
                            duration: Double) throws -> Edit {
        let censoring = effects.filter(\.kind.usesWords)
        let bleeped = Set(censoring.flatMap { $0.wordIds ?? [] })
        func word(_ caption: CaptionWord, phrase: String? = nil) -> ExportCheckInput.Word {
            ExportCheckInput.Word(text: caption.text, start: speed.rendered(caption.start), end: speed.rendered(caption.end),
                                  optional: EditingPrimitives.filler(caption.text), phrase: phrase)
        }
        switch timeline {
        case .voiceLab(let plan):
            let rate = plan.sampleRate
            var phrases: [ExportCheckInput.Phrase] = []
            for piece in plan.pieces where piece.kind == .synth {
                guard let id = piece.segmentId else { continue }
                let start = speed.rendered(Double(piece.outputStartSample) / rate), end = speed.rendered(Double(piece.outputEndSample) / rate)
                if let index = phrases.firstIndex(where: { $0.id == id }) {
                    phrases[index].start = min(phrases[index].start, start); phrases[index].end = max(phrases[index].end, end)
                } else { phrases.append(ExportCheckInput.Phrase(id: id, start: start, end: end)) }
            }
            let words = plan.captions.filter { !bleeped.contains($0.id) }.map { caption -> ExportCheckInput.Word in
                let start = speed.rendered(caption.start)
                return word(caption, phrase: phrases.first { start >= $0.start && start < $0.end }?.id)
            }
            // A seam wherever the next piece doesn't continue the previous one's source, or is generated.
            var cuts: [Double] = []
            for (previous, next) in zip(plan.pieces, plan.pieces.dropFirst())
            where previous.kind != next.kind || next.kind == .synth || next.sourceStartSample != previous.sourceEndSample {
                cuts.append(speed.rendered(Double(next.outputStartSample) / rate))
            }
            return Edit(words: words, phrases: phrases, cuts: cuts, duration: duration)
        case .legacy(let plan):
            var cuts: [Double] = []
            var position: Int64 = 0
            for interval in plan.kept.dropLast() {
                position += interval.count
                cuts.append(speed.rendered(Double(position) / plan.sampleRate))
            }
            guard let state, !state.transcript.words.isEmpty else { return Edit(words: [], phrases: [], cuts: cuts, duration: duration) }
            let activeClip = state.clips.first { $0.id == state.activeClipId }
            let captions = captionCopy(try buildSegments(state, activeClip: activeClip), plan: plan)
            return Edit(words: captions.filter { !bleeped.contains($0.id) }.map { word($0) }, phrases: [], cuts: cuts, duration: duration)
        }
    }

    /// Each caption card the render draws: the page's visual rect (after the layout's clamp) with its boxes and emoji,
    /// top-left origin, in fractions of the output frame, at the page's first output second. Empty without captions.
    public static func captionBoxes(render: RenderRequest) -> [ExportCheckInput.Box] {
        guard let layout = render.captionLayout else { return [] }
        let width = Double(render.output.size.width), height = Double(render.output.size.height)
        guard width > 0, height > 0 else { return [] }
        return layout.pages.compactMap { page -> ExportCheckInput.Box? in
            let emoji: [CaptionRect] = page.emoji.map { [$0.rect] } ?? []
            let rects = [page.page.visual] + page.boxes.map(\.rect) + emoji
            let drawn = rects.filter { $0.width > 0 && $0.height > 0 }
            guard let first = drawn.first else { return nil }
            var minX = first.x, minY = first.y, maxX = first.x + first.width, maxY = first.y + first.height
            for rect in drawn.dropFirst() {
                minX = min(minX, rect.x); minY = min(minY, rect.y)
                maxX = max(maxX, rect.x + rect.width); maxY = max(maxY, rect.y + rect.height)
            }
            let rect = CaptionRect(x: minX / width, y: minY / height, width: (maxX - minX) / width, height: (maxY - minY) / height)
            return ExportCheckInput.Box(kind: .caption, time: render.speedTiming.rendered(page.page.start), rect: rect)
        }
    }
}
