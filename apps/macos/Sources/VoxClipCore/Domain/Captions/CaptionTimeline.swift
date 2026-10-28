import Foundation

public struct CaptionMotion: Sendable, Equatable {
    public var scale: Double = 1
    public var alpha: Double = 1
    public var dy: Double = 0
}

public struct CaptionWordAppearance: Sendable, Equatable {
    public var word: Int
    public var state: String
    public var visible: Bool
    public var opacity: Double
    public var scale: Double
    public var dy: Double
    public var fill: CaptionPaint
    public var fillSource: String
    public var boxContrast: Bool = false
    public var wipeFromBoxContrast: Bool = false
    public var wipe: Double?
    public var wipeFrom: CaptionPaint?
    public var visibleClusters: Int?
}

public struct CaptionCursorGeometry: Sendable, Equatable {
    public var visible: Bool
    public var word: Int
    public var rect: CaptionRect
}

public struct CaptionFrameState: Sendable, Equatable {
    public var time: Double
    public var page: Int?
    public var activeWord: Int?
    public var progress: Double = 0
    public var motion: CaptionMotion = .init()
    public var jitter: CaptionPoint = .init(x: 0, y: 0)
    public var words: [CaptionWordAppearance] = []
    public var cursor: CaptionCursorGeometry?
}

public enum CaptionTimeline {
    public static func entrance(_ animation: CaptionAnim?, time: Double, start: Double, fontPx: Double, target: Double = 1, reduceMotion: Bool = false) -> CaptionMotion {
        guard let animation, animation.type != .none else { return .init(scale: target) }
        let progress = reduceMotion ? 1 : CaptionMath.progress(time, start, animation.durationSec)
        let eased = CaptionMath.ease(animation.easing, progress, overshoot: animation.overshoot)
        switch animation.type {
        case .none: return .init(scale: target)
        case .fade: return .init(scale: target, alpha: CaptionMath.clamp(eased))
        case .pop: return .init(scale: animation.fromScale + (target - animation.fromScale) * eased)
        case .zoom: return .init(scale: animation.fromScale + (target - animation.fromScale) * eased, alpha: CaptionMath.clamp(eased))
        case .slideUp: return .init(scale: target, alpha: CaptionMath.clamp(eased), dy: animation.fromOffsetEm * fontPx * (1 - eased))
        }
    }

    public static func exit(_ animation: CaptionAnim?, time: Double, end: Double, fontPx: Double, reduceMotion: Bool = false) -> CaptionMotion {
        guard let animation, animation.type != .none, !reduceMotion else { return .init() }
        let eased = CaptionMath.ease(animation.easing, CaptionMath.progress(time, end - animation.durationSec, animation.durationSec), overshoot: animation.overshoot)
        switch animation.type {
        case .none: return .init()
        case .fade: return .init(alpha: CaptionMath.clamp(1 - eased))
        case .pop: return .init(scale: 1 + (animation.fromScale - 1) * eased)
        case .zoom: return .init(scale: 1 + (animation.fromScale - 1) * eased, alpha: CaptionMath.clamp(1 - eased))
        case .slideUp: return .init(alpha: CaptionMath.clamp(1 - eased), dy: -animation.fromOffsetEm * fontPx * eased)
        }
    }

    public static func evaluate(_ track: CaptionLayoutResult, time: Double, reduceMotion: Bool = false) -> CaptionFrameState {
        var result = CaptionFrameState(time: time)
        guard time.isFinite else { return result }
        var lower = 0, upper = track.pages.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if track.pages[middle].page.start <= time { lower = middle + 1 } else { upper = middle }
        }
        guard lower > 0 else { return result }
        let layout = track.pages[lower - 1], page = layout.page
        guard page.start <= time, time < page.end else { return result }
        let style = track.style
        let activeLocal = layout.indices.lastIndex { track.words[$0].input.start <= time } ?? 0
        let active = layout.indices[activeLocal], word = track.words[active].input
        result.page = lower - 1; result.activeWord = active
        result.progress = CaptionMath.progress(time, word.start, max(0.001, word.end - word.start))
        let entrance = entrance(style.animation?.pageIn, time: time, start: page.start, fontPx: page.fontPx, reduceMotion: reduceMotion)
        let exit = exit(style.animation?.pageOut, time: time, end: page.end, fontPx: page.fontPx, reduceMotion: reduceMotion)
        result.motion = .init(scale: entrance.scale * exit.scale, alpha: entrance.alpha * exit.alpha, dy: entrance.dy + exit.dy)
        if let jitter = style.effects?.jitter, !reduceMotion {
            let key = CaptionMath.jitterKey(time: time, rateHz: jitter.rateHz)
            var random = Mulberry32(seed: UInt32(truncatingIfNeeded: jitter.seed) ^ key)
            result.jitter = .init(x: (random.next() * 2 - 1) * jitter.amplitudeEm * page.fontPx,
                                  y: (random.next() * 2 - 1) * jitter.amplitudeEm * page.fontPx)
        }
        let reveal = style.reveal ?? CaptionReveal()
        for (local, index) in layout.indices.enumerated() {
            let measured = track.words[index], input = measured.input
            let state = local < activeLocal ? "past" : local == activeLocal ? "active" : "future"
            let appearance = wordState(style, state)
            let stateScale = appearance?.scale ?? 1
            let entrance = state == "future" ? CaptionMotion() : self.entrance(style.animation?.wordIn, time: time, start: input.start, fontPx: page.fontPx, reduceMotion: reduceMotion)
            let activeMotion = state == "active" ? self.entrance(style.animation?.activeIn, time: time, start: input.start, fontPx: page.fontPx, target: stateScale, reduceMotion: reduceMotion) : CaptionMotion(scale: stateScale)
            let palette = layout.emphasised[index]
            let fill = fill(style: style, state: state, emphasised: palette != nil, palette: palette ?? nil)
            var output = CaptionWordAppearance(word: index, state: state, visible: !([.word, .char].contains(reveal.unit) && state == "future"),
                opacity: (appearance?.opacity ?? 1) * entrance.alpha * activeMotion.alpha, scale: activeMotion.scale * entrance.scale,
                dy: entrance.dy + activeMotion.dy, fill: fill.0, fillSource: fill.1, boxContrast: fill.2)
            if reveal.unit == .wipe, state == "active" {
                let underlay = self.fill(style: style, state: "future", emphasised: palette != nil, palette: palette ?? nil, boxState: state)
                output.wipe = result.progress
                output.wipeFrom = underlay.0
                output.wipeFromBoxContrast = underlay.2
            }
            if reveal.unit == .char {
                let count = measured.shaped.clusters
                let duration = min(input.end - input.start, Double(count) / reveal.maxCharsPerSec)
                let visible = (0..<count).filter { time >= input.start + (Double($0) / Double(count)) * duration }.count
                output.visibleClusters = state == "past" ? count : state == "future" ? 0 : visible
                if state == "active", let cursor = reveal.cursor {
                    let typingEnd = input.start + duration
                    let shown = time < typingEnd || cursor.blinkHz == 0 || reduceMotion || Int(floor((time - typingEnd) * cursor.blinkHz * 2)) % 2 == 0
                    let isEmphasised = layout.emphasised.keys.contains(index)
                    let shaped = isEmphasised ? measured.emphasisShaped! : measured.shaped
                    let glyphs = shaped.runs.flatMap { run in run.glyphs.map { (Double($0.advance) * page.fontPx / Double(run.unitsPerEm), $0.cluster) } }
                    let last = glyphs.lastIndex { $0.1 < visible }
                    var pen = 0.0
                    let spacing = Double(CaptionMath.roundHalfUp(style.font.letterSpacingEm * Double(track.unitsPerEm))) * page.fontPx / Double(track.unitsPerEm)
                    if let last { for glyph in 0...last { pen += glyphs[glyph].0; if glyph < last { pen += spacing } } }
                    pen *= isEmphasised ? style.emphasis?.scale ?? 1 : 1
                    let rect = page.wordRects[local]
                    let line = page.lines.first { $0.words.contains(index) }!
                    let cap = Double(track.font.capHeight) / Double(track.unitsPerEm) * page.fontPx
                    result.cursor = .init(visible: shown, word: index, rect: .init(x: rect.x + pen + 0.05 * page.fontPx, y: line.baseline - cap - 0.1 * page.fontPx,
                        width: cursor.widthEm * page.fontPx, height: cap + 0.2 * page.fontPx))
                }
            }
            result.words.append(output)
        }
        return result
    }

    public static func wordState(_ style: CaptionStyle, _ state: String) -> CaptionWordState? {
        state == "active" ? style.words?.active : state == "past" ? style.words?.past : style.words?.future
    }

    static func fill(style: CaptionStyle, state: String, emphasised: Bool, palette: String?, boxState: String? = nil) -> (CaptionPaint, String, Bool) {
        var paint = style.fill, source = "base"
        if let statePaint = wordState(style, state)?.fill { paint = statePaint; source = state }
        if emphasised {
            if let palette { paint = .solid(color: palette); source = "emphasis" }
            else if let emphasisPaint = style.emphasis?.fill { paint = emphasisPaint; source = "emphasis" }
        }
        guard let box = wordState(style, boxState ?? state)?.box?.color ?? style.box?.color else { return (paint, source, false) }
        let resolved = CaptionContrast.text(paint, box: box, accent: style.accent)
        return (resolved, source, resolved != paint)
    }
}
