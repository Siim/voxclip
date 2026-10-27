import Foundation

public struct EditingImportResult: Sendable, Equatable {
    public var words: [TimedWord]
    public var pauses: [Pause]
    public var pauseThresholdSeconds: Double
}

public enum EditingImport {
    public static func cleanWords(_ words: [RawWord], timing: TimingSource) -> [TimedWord] {
        var output: [TimedWord] = []
        var prefix = ""
        for word in words {
            let kind: WordKind = word.kind == .event ? .event : .word
            let text = EditingPrimitives.jsTrim(EditingPrimitives.nfc(word.text))
            guard !text.isEmpty else { continue }
            if kind == .word, text.unicodeScalars.allSatisfy({ isPunctuation($0) }) {
                if text.unicodeScalars.allSatisfy({ isOpening($0) }) { prefix += text }
                else if let last = output.indices.last, output[last].kind == .word { output[last].text += text }
                continue
            }
            guard let start = word.start, let end = word.end, start.isFinite, end.isFinite, start >= 0, end > start else { continue }
            let confidence = word.conf.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
            output.append(TimedWord(id: "", text: kind == .word ? prefix + text : text, kind: kind, start: start, end: end,
                                    rawStart: start, rawEnd: end, conf: confidence, speaker: word.speaker, timing: timing))
            if kind == .word { prefix = "" }
        }
        return EditingPrimitives.stableSorted(output, by: \.start)
    }

    static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation: true
        default: false
        }
    }

    static func isOpening(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .openPunctuation || scalar.properties.generalCategory == .initialPunctuation || scalar == "¿" || scalar == "¡"
    }

    public static func tightenIntoSound(_ words: [TimedWord], envelope: AudioEnvelope, timing: TimingSource) -> [TimedWord] {
        guard let analysis = LevelAnalysis(words: words, envelope: envelope) else { return words }
        return words.map { word in
            let first = analysis.frameAt(word.start)
            let last = analysis.boundedFrame(ceil(word.end / analysis.frameLength) - 1)
            guard first <= last else { return word }
            var islands: [ClosedRange<Int>] = []
            for run in analysis.runs(from: first, to: last) {
                if let previous = islands.last, run.lowerBound - previous.upperBound - 1 < 15 {
                    islands[islands.count - 1] = previous.lowerBound...run.upperBound
                } else { islands.append(run) }
            }
            guard let island = timing == .runGrouped ? islands.last : islands.first else { return word }
            var result = word
            if island.lowerBound - first >= 7 { result.start = max(word.start, Double(island.lowerBound) * analysis.frameLength) }
            if last - island.upperBound >= 7 { result.end = min(word.end, Double(island.upperBound + 1) * analysis.frameLength) }
            if result.end - result.start < 0.04 {
                result.start = max(word.start, result.end - 0.04)
                result.end = min(word.end, result.start + 0.04)
            }
            return result
        }
    }

    public static func findUnlabeledSpeech(_ words: [TimedWord], envelope: AudioEnvelope, duration: Double? = nil) -> [TimedWord] {
        guard let analysis = LevelAnalysis(words: words, envelope: envelope, duration: duration) else { return [] }
        var result: [TimedWord] = []
        var reached = 0.0
        for index in 0...words.count {
            let gapStart = reached
            let gapEnd = index < words.count ? words[index].start : analysis.total
            if index < words.count { reached = max(reached, words[index].end) }
            guard gapEnd - gapStart >= 0.25 else { continue }
            let firstFrame = max(0, ceil(gapStart / analysis.frameLength))
            let lastFrame = min(Double(analysis.levels.count - 1), floor(gapEnd / analysis.frameLength) - 1)
            guard firstFrame.isFinite, lastFrame.isFinite, firstFrame <= lastFrame else { continue }
            let first = Int(firstFrame), last = Int(lastFrame)
            for run in analysis.runs(from: first, to: last) {
                let peak = run.map { Double(analysis.levels[$0]) }.max() ?? 0
                if run.count >= 10, peak >= analysis.speechLevel * 0.25 {
                    result.append(TimedWord(id: "", text: "…", kind: .unlabeledSpeech, start: Double(run.lowerBound) * analysis.frameLength,
                                            end: Double(run.upperBound + 1) * analysis.frameLength, timing: .detected))
                }
            }
        }
        return result
    }

    public static func pipeline(_ rawWords: [RawWord], envelope: AudioEnvelope?, timing: TimingSource, verbatim: Bool, duration: Double? = nil) throws -> EditingImportResult {
        var words = cleanWords(rawWords, timing: timing)
        if let envelope {
            if [.runGrouped, .tokenGrouped, .dtw].contains(timing) { words = tightenIntoSound(words, envelope: envelope, timing: timing) }
            words = try refineWordBoundaries(words, envelope: envelope, duration: duration)
            if !verbatim { words = EditingPrimitives.stableSorted(words + findUnlabeledSpeech(words, envelope: envelope, duration: duration), by: \.start) }
        }
        for index in words.indices { words[index].id = "w\(index + 1)" }
        let threshold = envelope == nil ? 1.0 : 0.8
        return EditingImportResult(words: words, pauses: try detectPauses(words, thresholdSeconds: threshold), pauseThresholdSeconds: threshold)
    }
}

struct LevelAnalysis {
    let levels: [Float]
    let frameLength: Double
    let total: Double
    let speechLevel: Double
    let threshold: Double

    init?(words: [TimedWord], envelope: AudioEnvelope, duration: Double? = nil) {
        guard !words.isEmpty, envelope.levels.count >= 10, envelope.sampleRate.isFinite, envelope.sampleRate > 0,
              envelope.levels.allSatisfy({ $0.isFinite && $0 >= 0 }),
              words.allSatisfy({ $0.start.isFinite && $0.end.isFinite }) else { return nil }
        levels = envelope.levels
        frameLength = max(1, EditingPrimitives.jsRound(envelope.sampleRate * 0.01)) / envelope.sampleRate
        guard frameLength.isFinite, frameLength > 0 else { return nil }
        total = duration ?? Double(levels.count) * frameLength
        var speech: [Float] = []
        let count = envelope.levels.count
        let length = frameLength
        func frame(_ time: Double) -> Int { Int(min(Double(count - 1), max(0, floor(time / length)))) }
        for word in words {
            let first = frame(word.start), last = frame(word.end)
            if first <= last { speech.append(contentsOf: levels[first...last]) }
        }
        speech.sort()
        speechLevel = speech.isEmpty ? 0 : Double(speech[speech.count / 2])
        let quietest = Double(levels.sorted()[Int(floor(Double(levels.count) * 0.1))])
        threshold = max(quietest * 2, speechLevel * 0.08)
        guard threshold > 0 else { return nil }
    }

    func boundedFrame(_ frame: Double) -> Int { Int(min(Double(levels.count - 1), max(0, frame))) }
    func frameAt(_ time: Double) -> Int { boundedFrame(floor(time / frameLength)) }
    func audible(_ frame: Int) -> Bool { Double(levels[frame]) >= threshold }

    func runs(from first: Int, to last: Int) -> [ClosedRange<Int>] {
        guard first >= 0, last < levels.count, first <= last else { return [] }
        var result: [ClosedRange<Int>] = []
        var frame = first
        while frame <= last {
            if !audible(frame) { frame += 1; continue }
            var end = frame, quiet = 0, next = frame + 1
            while next <= last {
                if audible(next) { end = next; quiet = 0 } else { quiet += 1; if quiet > 2 { break } }
                next += 1
            }
            result.append(frame...end)
            frame = end + 1
        }
        return result
    }

    func edge(from: Int, step: Int, inside: (Int) -> Bool) -> Int {
        var found = -1, quiet = 0, frame = from
        while frame >= 0, frame < levels.count, inside(frame) {
            if audible(frame) { found = frame; quiet = 0 } else { quiet += 1; if quiet > 2 { break } }
            frame += step
        }
        return found
    }
}

public func refineWordBoundaries(_ words: [TimedWord], envelope: AudioEnvelope) throws -> [TimedWord] {
    try refineWordBoundaries(words, envelope: envelope, duration: nil)
}

public func refineWordBoundaries(_ words: [TimedWord], envelope: AudioEnvelope, duration: Double?) throws -> [TimedWord] {
    guard let analysis = LevelAnalysis(words: words, envelope: envelope, duration: duration) else { return words }
    var refined = words.enumerated().map { index, word in
        let previousEnd = index > 0 ? words[index - 1].end : nil
        let nextStart = index + 1 < words.count ? words[index + 1].start : nil
        let earliest = max(0, word.start - 0.35, previousEnd.map { ($0 + word.start) / 2 } ?? 0)
        let latest = min(analysis.total, word.end + 0.3, nextStart.map { (word.end + $0) / 2 } ?? analysis.total)
        let first = analysis.edge(from: analysis.frameAt(word.start), step: -1) { Double($0) * analysis.frameLength >= earliest }
        let last = analysis.edge(from: analysis.frameAt(word.end), step: 1) { Double($0 + 1) * analysis.frameLength <= latest }
        var result = word
        if first >= 0 { result.start = min(word.start, Double(first) * analysis.frameLength) }
        if last >= 0 { result.end = max(word.end, Double(last + 1) * analysis.frameLength) }
        return result
    }
    if refined.count > 1 {
        for index in 1..<refined.count {
            let previous = refined[index - 1], next = refined[index]
            if next.start - previous.end > 0.03 { continue }
            let middle = (previous.end + next.start) / 2
            let firstFrame = ceil(max(middle - 0.07, previous.start + 0.04) / analysis.frameLength)
            let lastFrame = floor(min(middle + 0.07, next.end - 0.04) / analysis.frameLength) - 1
            guard firstFrame.isFinite, lastFrame.isFinite, firstFrame >= 0, firstFrame <= lastFrame, lastFrame < Double(analysis.levels.count) else { continue }
            let first = Int(firstFrame), last = Int(lastFrame)
            var valley = first
            for frame in first...last where analysis.levels[frame] < analysis.levels[valley] { valley = frame }
            if Double(analysis.levels[valley]) > Double(analysis.levels[analysis.frameAt(middle)]) * 0.5 { continue }
            let edge = (Double(valley) + 0.5) * analysis.frameLength
            refined[index - 1].end = edge
            refined[index].start = edge
        }
    }
    return refined
}
