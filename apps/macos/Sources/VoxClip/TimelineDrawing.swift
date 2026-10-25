import SwiftUI
import VoxClipCore

struct TimelineBlock: Sendable {
    let source: ClosedRange<Double>
    let edited: ClosedRange<Double>
    let cut: Bool
    let pause: Bool
}
struct TimelineClip: Sendable {
    let source: ClosedRange<Double>
    let edited: ClosedRange<Double>
    let number: Int
    let active: Bool
}
struct TimelineTimeIndex {
    let plan: EditPlan?
    private let removed: [Int64]
    private var previousSample: Int64 = 0
    private var position = 0
    init(plan: EditPlan?) {
        self.plan = plan
        var prefix: [Int64] = [0]
        for cut in plan?.cuts ?? [] { prefix.append(prefix.last! + cut.count) }
        removed = prefix
    }
    mutating func map(_ time: Double) -> Double {
        guard let plan else { return time }
        let rounded = floor((time.isFinite ? time : 0) * plan.sampleRate + 0.5)
        let sample = rounded >= Double(plan.totalSamples) ? plan.totalSamples : Int64(max(0, rounded))
        if sample < previousSample {
            var lower = 0, upper = position
            while lower < upper {
                let middle = (lower + upper) / 2
                if plan.cuts[middle].startSample < sample { lower = middle + 1 } else { upper = middle }
            }
            position = lower
        } else {
            while position < plan.cuts.count, plan.cuts[position].startSample < sample { position += 1 }
        }
        previousSample = sample
        var cutSamples = removed[position]
        if position > 0 { cutSamples -= max(0, plan.cuts[position - 1].endSample - sample) }
        return Double(min(plan.outputSamples, max(0, sample - cutSamples))) / plan.sampleRate
    }
}
struct TimelineProjection: Sendable {
    var revision = 0
    var blocks: [TimelineBlock] = []
    var clips: [TimelineClip] = []
    init() {}
    @MainActor init(model: EditorModel) {
        revision = model.transcriptRevision
        var mapping = TimelineTimeIndex(plan: model.plan)
        let sourceDuration = max(0.001, model.sourceDuration), duration = max(0.001, model.duration)
        let words = model.words, cutWordIDs = model.cutWordIDs, cutPauseIDs = model.cutPauseIDs
        let activeClipID = model.project.edits.activeClipId
        func ranges(_ start: Double, _ end: Double) -> (ClosedRange<Double>, ClosedRange<Double>) {
            let lower = mapping.map(start), upper = mapping.map(end)
            return ((start / sourceDuration)...(max(start, end) / sourceDuration), (lower / duration)...(max(lower, upper) / duration))
        }
        blocks = words.map { word in
            let (source, edited) = ranges(word.start, word.end)
            return TimelineBlock(source: source, edited: edited, cut: cutWordIDs.contains(word.id), pause: false)
        }
        blocks += model.pauses.filter { cutPauseIDs.contains($0.id) }.map { pause in
            let (source, edited) = ranges(pause.start, pause.end)
            return TimelineBlock(source: source, edited: edited, cut: true, pause: true)
        }
        clips = model.sortedClips.enumerated().compactMap { number, clip in
            guard let lower = model.index(clip.startWordId), let upper = model.index(clip.endWordId), lower <= upper else { return nil }
            let (source, edited) = ranges(words[lower].start, words[upper].end)
            return TimelineClip(source: source, edited: edited, number: number + 1, active: clip.id == activeClipID)
        }
    }
}

@MainActor struct TimelineTrack: View, Equatable {
    let projection: TimelineProjection
    let edited: Bool
    nonisolated static func == (left: Self, right: Self) -> Bool { left.projection.revision == right.projection.revision && left.edited == right.edited }
    var body: some View {
        Canvas { context, size in
            let track = DesignValues.color("timeline.track"), kept = DesignValues.color("timeline.kept"), cut = DesignValues.color("cut.fill"), pause = DesignValues.color("cut.pauseFill"), hatch = DesignValues.color("bg.surface")
            context.fill(Path(roundedRect: CGRect(x: 0, y: 18, width: size.width, height: 24), cornerRadius: 4), with: .color(track))
            var keptPath = Path(), cutPath = Path(), pausePath = Path(), stripes = Path()
            for block in projection.blocks {
                let range = edited ? block.edited : block.source
                let rect = CGRect(x: range.lowerBound * size.width, y: 18, width: max(block.cut && edited ? 1 : 2, (range.upperBound - range.lowerBound) * size.width), height: 24)
                if block.pause { pausePath.addRect(rect) }
                else if block.cut { cutPath.addRect(rect) }
                else { keptPath.addRect(rect) }
                if block.cut && (!edited || block.pause) {
                    for offset in stride(from: rect.minX, to: rect.maxX, by: 6) {
                        stripes.move(to: CGPoint(x: offset, y: rect.maxY))
                        stripes.addLine(to: CGPoint(x: min(rect.maxX, offset + 24), y: max(rect.minY, rect.maxY - (rect.maxX - offset))))
                    }
                }
            }
            context.fill(keptPath, with: .color(kept)); context.fill(cutPath, with: .color(cut)); context.fill(pausePath, with: .color(pause))
            context.stroke(stripes, with: .color(hatch), lineWidth: 2)
            let band = DesignValues.color("timeline.clipBand"), bracketColor = DesignValues.color("timeline.clipBracket")
            for clip in projection.clips {
                let range = edited ? clip.edited : clip.source
                let lower = range.lowerBound * size.width, upper = range.upperBound * size.width
                if clip.active { context.fill(Path(CGRect(x: lower, y: 16, width: max(1, upper - lower), height: 28)), with: .color(band)) }
                var bracket = Path(); bracket.move(to: CGPoint(x: lower, y: 12)); bracket.addLine(to: CGPoint(x: lower, y: 6)); bracket.addLine(to: CGPoint(x: upper, y: 6)); bracket.addLine(to: CGPoint(x: upper, y: 12))
                context.stroke(bracket, with: .color(bracketColor), lineWidth: 2)
                context.draw(Text("\(clip.number)").font(DesignValues.mono(9)), at: CGPoint(x: lower + 6, y: 10))
            }
        }
    }
}

@MainActor struct TimelinePlayhead: View {
    let model: EditorModel
    var body: some View {
        let duration = max(0.001, model.editedTimeline ? model.duration : model.sourceDuration)
        let fraction = (model.editedTimeline ? model.playhead : model.sourceTime) / duration
        Canvas { context, size in
            let current = min(1, max(0, fraction)) * size.width
            var head = Path(); head.move(to: CGPoint(x: current, y: 16)); head.addLine(to: CGPoint(x: current, y: 44))
            let color = DesignValues.color("timeline.playhead")
            context.stroke(head, with: .color(color), lineWidth: 2)
            var triangle = Path(); triangle.move(to: CGPoint(x: current - 3.5, y: 12)); triangle.addLine(to: CGPoint(x: current + 3.5, y: 12)); triangle.addLine(to: CGPoint(x: current, y: 19)); triangle.closeSubpath()
            context.fill(triangle, with: .color(color))
        }.allowsHitTesting(false)
    }
}
