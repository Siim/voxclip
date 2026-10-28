import SwiftUI
import VoxClipCore

func timelineSpokenTime(_ time: Double) -> String {
    let finite: Double = time.isFinite ? max(0, time) : 0
    let rounded: Double = finite.rounded(.toNearestOrEven)
    let seconds: Int = Int(min(rounded, Double(Int32.max)))
    guard seconds >= 60 else { return "\(seconds) seconds" }
    let minutes: Int = seconds / 60
    let remainder: Int = seconds % 60
    let tail: String = remainder < 10 ? "0\(remainder)" : String(remainder)
    return "\(minutes) \(seconds < 120 ? "minute" : "minutes") \(tail)"
}

func timelineValueText(time: Double, total: Double, cuts: Int, edited: Bool) -> String {
    "\(timelineSpokenTime(time)) of \(timelineSpokenTime(total))\(edited ? " after cuts" : " source"), \(cuts) cuts"
}

struct TimelineBlock: Sendable {
    let source: ClosedRange<Double>
    let edited: ClosedRange<Double>
    let cut: Bool
    let pause: Bool
    let filler: Bool
    let inScope: Bool
}
struct TimelineClip: Sendable {
    enum State: Sendable { case neutral, selected, suggested }
    let source: ClosedRange<Double>
    let edited: ClosedRange<Double>
    let number: Int
    let state: State
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

func timelineZoom(clip: ClosedRange<Double>?, duration: Double) -> ClosedRange<Double> {
    guard let clip else { return 0...max(0.001, duration) }
    let length = clip.upperBound - clip.lowerBound
    let padding = (length * 0.1).clamped(to: 1.5...3)
    return max(0, clip.lowerBound - padding)...min(max(duration, clip.upperBound), clip.upperBound + padding)
}

struct TimelineBand: Sendable, Equatable {
    let source: ClosedRange<Double>
    let edited: ClosedRange<Double>
}
struct TimelineProjection: Sendable {
    var revision = 0
    var waveformRevision = 0
    var blocks: [TimelineBlock] = []
    var clips: [TimelineClip] = []
    var zoom: ClosedRange<Double> = 0...1
    var duration = 1.0
    var selection: TimelineBand?
    var rewrite: TimelineBand?
    var scope: TimelineBand?
    var sourceWaveform: [Float] = []
    var editedWaveform: [Float] = []
    init() {}
    func visible(edited: Bool) -> ClosedRange<Double> { edited ? 0...max(0.001, duration) : zoom }
    func fraction(_ time: Double, edited: Bool) -> Double {
        let span = visible(edited: edited)
        return (time - span.lowerBound) / max(0.001, span.upperBound - span.lowerBound)
    }
    func time(_ fraction: Double, edited: Bool) -> Double {
        let span = visible(edited: edited)
        return span.lowerBound + fraction.clamped(to: 0...1) * (span.upperBound - span.lowerBound)
    }
    @MainActor init(model: EditorModel) {
        revision = model.transcriptRevision
        waveformRevision = model.waveformRevision
        duration = model.duration
        var mapping = TimelineTimeIndex(plan: model.plan)
        let words = model.words
        let voicePlan = model.voiceLabPlan
        func isReplaced(_ start: Double, _ end: Double) -> Bool {
            guard let voicePlan else { return false }
            return voicePlan.pieces.contains { $0.kind == .synth && start >= Double($0.sourceStartSample) / voicePlan.sampleRate && end <= Double($0.sourceEndSample) / voicePlan.sampleRate }
        }
        func ranges(_ start: Double, _ end: Double) -> TimelineBand {
            let lower = voicePlan?.mapTime(start) ?? mapping.map(start)
            let upper = voicePlan?.mapTime(end) ?? mapping.map(end)
            return TimelineBand(source: start...max(start, end), edited: lower...max(lower, upper))
        }
        blocks = words.enumerated().map { index, word in
            let band = ranges(word.start, word.end)
            return TimelineBlock(source: band.source, edited: band.edited,
                cut: model.cutWordIDs.contains(word.id) && !isReplaced(word.start, word.end), pause: false,
                filler: model.fillerIDs.contains(word.id), inScope: model.scopeBounds?.contains(index) ?? true)
        }
        blocks += model.pauses.filter { model.cutPauseIDs.contains($0.id) && !isReplaced($0.start, $0.end) }.map { pause in
            let band = ranges(pause.start, pause.end)
            return TimelineBlock(source: band.source, edited: band.edited, cut: true, pause: true, filler: false,
                inScope: model.scopeBounds?.contains(pause.afterIndex) ?? true)
        }
        clips = model.sortedClips.compactMap { clip in
            guard let lower = model.index(clip.startWordId), let upper = model.index(clip.endWordId), lower <= upper,
                  let number = model.clipNumber(clip.id) else { return nil }
            let band = ranges(words[lower].start, words[upper].end)
            let state: TimelineClip.State = clip.id == model.activeClip?.id ? .selected : model.isSuggestion(clip.id) ? .suggested : .neutral
            return TimelineClip(source: band.source, edited: band.edited, number: number, state: state)
        }
        if let bounds = model.scopeBounds { scope = ranges(words[bounds.lowerBound].start, words[bounds.upperBound].end) }
        zoom = timelineZoom(clip: scope?.source, duration: model.sourceDuration)
        if let waveform = model.waveform {
            sourceWaveform = waveform.buckets
            let requestedBuckets: Double = ceil(max(0, duration) / 0.05)
            let bucketCount: Int = Int(requestedBuckets)
            editedWaveform = [Float](repeating: 0, count: bucketCount)
            var waveMap = TimelineTimeIndex(plan: model.plan)
            for (index, amplitude) in waveform.buckets.enumerated() {
                let convertedIndex: Double = Double(index)
                let source: Double = convertedIndex * 0.05
                let end = source + 0.05
                let lower = voicePlan?.mapTime(source) ?? waveMap.map(source)
                let upper = voicePlan?.mapTime(end) ?? waveMap.map(end)
                guard upper > lower, !isReplaced(source, end) else { continue }
                let bucketPosition: Double = lower / 0.05
                let target: Int = Int(bucketPosition)
                if editedWaveform.indices.contains(target) { editedWaveform[target] = max(editedWaveform[target], amplitude) }
            }
        }
    }
}

@MainActor struct TimelineTrack: View, Equatable {
    let projection: TimelineProjection
    let edited: Bool
    var forceHighContrast = false
    @Environment(\.colorSchemeContrast) private var contrast
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.edited == rhs.edited && lhs.forceHighContrast == rhs.forceHighContrast && lhs.projection.revision == rhs.projection.revision && lhs.projection.waveformRevision == rhs.projection.waveformRevision && lhs.projection.selection == rhs.projection.selection && lhs.projection.rewrite == rhs.projection.rewrite
    }
    var body: some View {
        Canvas { context, size in
            drawTrack(context: context, size: size)
            drawBrackets(context: context, size: size)
        }
    }
    private func rect(_ range: ClosedRange<Double>, width: CGFloat, minimum: CGFloat = 0) -> CGRect {
        let lower = projection.fraction(range.lowerBound, edited: edited) * width
        let upper = projection.fraction(range.upperBound, edited: edited) * width
        return CGRect(x: lower, y: 28, width: max(minimum, upper - lower), height: 30)
    }
    private func drawTrack(context: GraphicsContext, size: CGSize) {
        let bounds = CGRect(x: 0, y: 28, width: size.width, height: 30)
        var track = context
        track.clip(to: Path(roundedRect: bounds, cornerRadius: 6))
        track.fill(Path(bounds), with: .color(DesignValues.color("timeline.track")))
        let stroke = DesignValues.color("cut.stroke")
        for block in projection.blocks {
            if edited && !block.inScope { continue }
            let range = edited ? block.edited : block.source
            let area = rect(range, width: size.width, minimum: block.cut && edited ? 1 : 0)
            guard area.maxX >= 0, area.minX <= size.width else { continue }
            if block.cut {
                if edited { track.fill(Path(CGRect(x: area.minX, y: 28, width: 1, height: 30)), with: .color(stroke)) }
                else {
                    track.fill(Path(area), with: .color(stroke.opacity(block.pause ? 0.10 : 0.16)))
                    var hatching = track
                    hatching.clip(to: Path(area))
                    var stripes = Path()
                    let pitch: CGFloat = block.pause ? 9 : 6
                    let start = floor((max(0, area.minX) - 30) / pitch) * pitch
                    for offset in stride(from: start, through: min(size.width, area.maxX), by: pitch) {
                        stripes.move(to: CGPoint(x: offset, y: area.maxY))
                        stripes.addLine(to: CGPoint(x: offset + 30, y: area.minY))
                    }
                    hatching.stroke(stripes, with: .color(stroke), lineWidth: 2)
                }
            } else if !block.pause {
                track.fill(Path(area), with: .color(DesignValues.color("timeline.keptBackground")))
                if projection.sourceWaveform.isEmpty {
                    let inset: CGFloat = min(2, area.width / 4)
                    let capsule = CGRect(x: area.minX + inset, y: 39, width: max(0, area.width - inset * 2), height: 8)
                    track.fill(Path(roundedRect: capsule, cornerRadius: 4), with: .color(DesignValues.color("timeline.waveform")))
                }
                if block.filler { track.fill(Path(CGRect(x: area.minX, y: 56, width: area.width, height: 2)), with: .color(DesignValues.color("word.filler"))) }
            }
        }
        drawWaveform(context: track, width: size.width)
        if let scope = projection.scope, contrast != .increased, !forceHighContrast {
            let area = rect(edited ? scope.edited : scope.source, width: size.width)
            let left = CGRect(x: 0, y: 28, width: max(0, area.minX), height: 30)
            let right = CGRect(x: max(0, area.maxX), y: 28, width: max(0, size.width - area.maxX), height: 30)
            track.fill(Path(left), with: .color(DesignValues.color("timeline.scopeDim")))
            track.fill(Path(right), with: .color(DesignValues.color("timeline.scopeDim")))
        }
        if let band = projection.selection {
            let area = rect(edited ? band.edited : band.source, width: size.width)
            track.fill(Path(area), with: .color(Color(nsColor: .selectedTextBackgroundColor)))
            var edges = Path(); edges.move(to: CGPoint(x: area.minX, y: 28)); edges.addLine(to: CGPoint(x: area.minX, y: 58))
            edges.move(to: CGPoint(x: area.maxX, y: 28)); edges.addLine(to: CGPoint(x: area.maxX, y: 58))
            track.stroke(edges, with: .color(DesignValues.accentText), lineWidth: 1.5)
        }
        if let band = projection.rewrite {
            let area = rect(edited ? band.edited : band.source, width: size.width)
            track.fill(Path(area), with: .color(DesignValues.color("accent.soft")))
            track.stroke(Path(area.insetBy(dx: 0.5, dy: 0.5)), with: .color(DesignValues.accentText), lineWidth: 1)
        }
    }
    private func drawWaveform(context: GraphicsContext, width: CGFloat) {
        let samples = edited ? projection.editedWaveform : projection.sourceWaveform
        guard !samples.isEmpty, width > 0 else { return }
        let visible = projection.visible(edited: edited)
        let span = visible.upperBound - visible.lowerBound
        let step = span * 3 / width
        var bars = Path()
        for offset in stride(from: CGFloat.zero, to: width, by: 3) {
            let time = visible.lowerBound + offset / width * span
            let firstBucket: Double = time / 0.05
            let lastBucket: Double = ceil((time + step) / 0.05)
            let firstIndex: Int = Int(firstBucket)
            let lastIndex: Int = Int(lastBucket)
            let first: Int = max(0, firstIndex)
            let last: Int = min(samples.count, max(first + 1, lastIndex))
            guard first < last else { continue }
            let amplitude = samples[first..<last].max() ?? 0
            guard amplitude > 0 else { continue }
            let convertedAmplitude: CGFloat = CGFloat(amplitude)
            let scaledAmplitude: CGFloat = convertedAmplitude * 52
            let height: CGFloat = max(2, min(26, scaledAmplitude))
            bars.addRoundedRect(in: CGRect(x: offset, y: 43 - height / 2, width: 2, height: height), cornerSize: CGSize(width: 1, height: 1))
        }
        var waveform = context
        var kept = Path()
        for block in projection.blocks where !block.cut && !block.pause && (!edited || block.inScope) {
            kept.addRect(rect(edited ? block.edited : block.source, width: width))
        }
        waveform.clip(to: kept)
        waveform.fill(bars, with: .color(DesignValues.color("timeline.waveform")))
    }
    private func drawBrackets(context: GraphicsContext, size: CGSize) {
        var brackets = context
        brackets.clip(to: Path(CGRect(origin: .zero, size: size)))
        for clip in projection.clips {
            let range = edited ? clip.edited : clip.source
            let area = rect(range, width: size.width)
            guard area.width > 0, area.maxX >= 0, area.minX < size.width else { continue }
            let color = clip.state == .selected ? DesignValues.accentText : DesignValues.color("line.strong")
            var path = Path(); path.move(to: CGPoint(x: area.minX, y: 23)); path.addLine(to: CGPoint(x: area.minX, y: 17))
            path.addLine(to: CGPoint(x: area.maxX, y: 17)); path.addLine(to: CGPoint(x: area.maxX, y: 23))
            brackets.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, dash: clip.state == .suggested ? [4, 3] : []))
            let badge = CGRect(x: area.minX, y: 1, width: 16, height: 16)
            let background = clip.state == .selected ? color : DesignValues.color("clip.badgeBackground")
            let foreground = clip.state == .selected ? DesignValues.color("bg.surface") : DesignValues.color("text.primary")
            brackets.fill(Path(roundedRect: badge, cornerRadius: 4), with: .color(background))
            brackets.draw(Text("\(clip.number)").font(DesignValues.mono(10)).foregroundStyle(foreground), at: CGPoint(x: badge.midX, y: badge.midY))
        }
    }
}

@MainActor struct TimelinePlayhead: View {
    let fraction: Double
    var body: some View {
        Canvas { context, size in
            let current = fraction.clamped(to: 0...1) * size.width
            let color = DesignValues.color("timeline.playhead")
            context.fill(Path(CGRect(x: current - 1, y: 28, width: 2, height: 30)), with: .color(color))
            var head = Path(); head.move(to: CGPoint(x: current - 6, y: 21)); head.addLine(to: CGPoint(x: current + 6, y: 21)); head.addLine(to: CGPoint(x: current, y: 28)); head.closeSubpath()
            context.fill(head, with: .color(color))
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
