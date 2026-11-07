import Foundation

public struct ClipPromptDocument: Sendable, Equatable {
    public let document: JSONValue
    public let presets: [ClipPreset]

    public init(data: Data) throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard value[ai: "schemaVersion"].aiInt == 1, value[ai: "system"].aiString != nil,
              CanonicalResponseParser.validateSchemaSubset(value[ai: "output"][ai: "schema"]) else { throw VoxClipError.sharedResourcesMissing }
        document = value
        presets = try JSONDecoder().decode([ClipPreset].self, from: value[ai: "presets"].aiEncoded())
    }
}

public struct ClipWindow: Sendable, Equatable {
    public let lines: [TranscriptLine]
    public let estimatedTokens: Int
    public let tokenBudget: Int
    public let maxClips: Int
    public var maxOutputTokens: Int? = nil
    public var rendered: String { lines.flatMap { [$0.text] + ($0.pauseAfter.map { [$0] } ?? []) }.joined(separator: "\n") }
}

public struct ClipRequestBuilder: Sendable {
    public let prompt: ClipPromptDocument
    let tokenPolicy: AITokenPolicy
    public init(prompt: ClipPromptDocument, policy: JSONValue = .null) { self.prompt = prompt; tokenPolicy = AITokenPolicy(policy) }

    public func clipWords(_ transcript: Transcript, corrections: [String: String] = [:]) -> [ClipWord] {
        let limit = prompt.document[ai: "limits"][ai: "maxWordTextLength"].aiInt ?? 100
        return transcript.words.enumerated().map { index, word in
            let text: String
            switch word.kind {
            case .word: text = corrections[word.id] ?? word.text
            case .event: text = word.text
            case .unlabeledSpeech: text = "…"
            }
            return ClipWord(index: index, text: AIText.prefix(text, utf16: limit), start: word.start, end: word.end)
        }
    }

    public func instructions(_ text: String?) -> String {
        AIText.prefix(AIText.trim(text ?? ""), utf16: prompt.document[ai: "request"][ai: "maxInstructionsLength"].aiInt ?? 500)
    }

    public func windows(words: [ClipWord], preset: ClipPreset, instruction: String? = nil, contextTokens: Int, maxOutputTokensCap: Int? = nil, localServer: Bool = false) throws -> [ClipWindow] {
        guard !words.isEmpty else { return [] }
        let formatted = try formatTranscript(words)
        let document = prompt.document
        let outputReserve = aiOutputReserve(generation: document[ai: "generation"][ai: "maxOutputTokens"].aiInt ?? 16000, cap: maxOutputTokensCap, context: contextTokens, localServer: localServer)
        let overheadInstruction = renderInstruction(words: words, lines: AIWindowPacking.longestTimeLines(formatted.lines), preset: preset, instruction: instruction, windowCount: 2, maxClips: 99, lastTopicEnd: words.last?.index)
        let overhead = tokenPolicy.estimate(document[ai: "system"].aiString ?? "") + tokenPolicy.estimate(overheadInstruction) + tokenPolicy.estimate(try document[ai: "output"][ai: "schema"].aiCompact()) + 64
        let budget = Int(floor(Double(contextTokens - overhead - outputReserve) * tokenPolicy.safetyFactor))
        guard budget >= 600 else { throw LLMError.contextTooLong }
        let maxWords = document[ai: "limits"][ai: "maxWordsPerRequest"].aiInt ?? 8000
        let overlap = min(preset.maxSeconds, document[ai: "limits"][ai: "windowOverlapMaxSeconds"].aiDouble ?? 90)
        let packed = try AIWindowPacking.pack(lines: formatted.lines, budget: budget, maxWords: maxWords, overlap: overlap, tokenPolicy: tokenPolicy)
        let factor = document[ai: "limits"][ai: "windowClipFactor"].aiDouble ?? 1.5
        let minimum = document[ai: "limits"][ai: "windowMinClips"].aiInt ?? 2
        let clipBudget = max(minimum, Int(ceil(Double(preset.maxClips) * factor / Double(packed.count))))
        return packed.map { ClipWindow(lines: Array(formatted.lines[$0.range]), estimatedTokens: $0.estimatedCost, tokenBudget: budget, maxClips: clipBudget, maxOutputTokens: outputReserve) }
    }

    public func request(words: [ClipWord], window: ClipWindow, preset: ClipPreset, instruction: String? = nil, windowIndex: Int = 0, windowCount: Int = 1, lastTopicEnd: Int? = nil, timeout: Duration, language: String? = nil) -> LLMRequest {
        let document = prompt.document
        let block = sentenceBlock(words: words, lines: window.lines)
        return LLMRequest(feature: .clipFinder, system: document[ai: "system"].aiString ?? "", cachedBlock: block,
                          instruction: renderInstruction(words: words, lines: window.lines, preset: preset, instruction: instruction, windowCount: windowCount, maxClips: window.maxClips, lastTopicEnd: windowIndex > 0 ? lastTopicEnd : nil),
                          schemaName: document[ai: "output"][ai: "name"].aiString ?? "clips", schema: document[ai: "output"][ai: "schema"],
                          maxOutputTokens: window.maxOutputTokens ?? document[ai: "generation"][ai: "maxOutputTokens"].aiInt ?? 16000,
                          effort: Effort(rawValue: document[ai: "generation"][ai: "effort"].aiString ?? Effort.decision.rawValue), timeout: timeout, language: language,
                          tag: "clips/\(preset.id.rawValue)\(windowCount > 1 ? " part \(windowIndex + 1) of \(windowCount)" : "")")
    }

    /// The clip finder's transcript block (ai.md §11.3, `voxclip-sentence-lines-v1`): `lines`, a window of `formatTranscript`'s
    /// lines over all of `words`, each as its number over the whole transcript (from 1), its start time and its words. No
    /// word range and no pause line: the reply names lines, and `wordRange` maps them back to words.
    public func sentenceBlock(words: [ClipWord], lines: [TranscriptLine]) -> String {
        let all = (try? formatTranscript(words).lines) ?? []
        let positions = Dictionary(all.enumerated().map { ($0.element.firstIndex, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let template = prompt.document[ai: "transcriptBlock"][ai: "line"].aiString ?? "{line} {time} {text}"
        let rendered = lines.compactMap { line -> String? in
            guard let position = positions[line.firstIndex] else { return nil }
            let own = all[position]
            let text = words[own.firstPos...own.lastPos].map(\.text).joined(separator: " ")
            let values = ["line": String(position + 1), "time": AIText.formatTime(own.start), "text": text]
            return template.replacing(#/\{(line|time|text)\}/#) { values[String($0.1)] ?? String($0.0) }
        }
        let block = prompt.document[ai: "transcriptBlock"]
        return (block[ai: "prefix"].aiString ?? "") + rendered.joined(separator: "\n") + (block[ai: "suffix"].aiString ?? "")
    }

    /// The inclusive word range of a reply's inclusive 1-based line range over `lines` (all of the transcript's lines): the
    /// first line's first word to the last line's last word. A range that names no lines, or names them backwards, maps to
    /// (-1, -1), which `finalizeClips` drops.
    public static func wordRange(startLine: Double, endLine: Double, lines: [TranscriptLine]) -> (start: Double, end: Double) {
        let count = Double(lines.count)
        guard startLine.isFinite, endLine.isFinite, startLine == startLine.rounded(.down), endLine == endLine.rounded(.down),
              startLine >= 1, startLine <= endLine, endLine <= count else { return (-1, -1) }
        return (Double(lines[Int(startLine) - 1].firstIndex), Double(lines[Int(endLine) - 1].lastIndex))
    }

    /// The inclusive 1-based line range a reply names for words `span` of `words`: the lines that hold its first and last
    /// word, over `formatTranscript`'s lines with corrections left out (stub connectors and fixtures).
    public static func lineRange(of span: ClosedRange<Int>, words: [TimedWord]) -> ClosedRange<Int> {
        let entries = words.enumerated().map { index, word in
            ClipWord(index: index, text: word.kind == .unlabeledSpeech ? "…" : word.text, start: word.start, end: word.end)
        }
        let lines = (try? formatTranscript(entries).lines) ?? []
        return lineNumber(of: span.lowerBound, in: lines)...max(lineNumber(of: span.lowerBound, in: lines), lineNumber(of: span.upperBound, in: lines))
    }

    /// The 1-based number of the line of `lines` that holds word `index`; the last line when it is past the end.
    static func lineNumber(of index: Int, in lines: [TranscriptLine]) -> Int {
        (lines.firstIndex { $0.lastIndex >= index } ?? lines.count - 1) + 1
    }

    private func renderInstruction(words: [ClipWord], lines: [TranscriptLine], preset: ClipPreset, instruction: String?, windowCount: Int, maxClips: Int, lastTopicEnd: Int?) -> String {
        let templates = prompt.document[ai: "request"]
        var parts = [(templates[ai: "durationLine"].aiString ?? "").replacingOccurrences(of: "{duration}", with: AIText.formatTime(words.last?.end ?? 0))]
        if !preset.instruction.isEmpty { parts.append(preset.instruction) }
        let custom = instructions(instruction)
        if !custom.isEmpty { parts.append((preset.instruction.isEmpty ? "" : templates[ai: "alsoPrefix"].aiString ?? "") + custom) }
        if windowCount > 1 {
            for template in templates[ai: "windowLines"].aiArray.compactMap(\.aiString) {
                parts.append(template.replacingOccurrences(of: "{windowStart}", with: AIText.formatTime(lines.first?.start ?? 0))
                    .replacingOccurrences(of: "{windowEnd}", with: AIText.formatTime(lines.last?.end ?? 0))
                    .replacingOccurrences(of: "{maxClips}", with: String(maxClips)))
            }
            if preset.id == .topics, let lastTopicEnd {
                let lastLine = Self.lineNumber(of: lastTopicEnd, in: (try? formatTranscript(words).lines) ?? [])
                parts.append((templates[ai: "topicsContinuationLine"].aiString ?? "")
                    .replacingOccurrences(of: "{lastLine}", with: String(lastLine))
                    .replacingOccurrences(of: "{nextLine}", with: String(lastLine + 1)))
            }
        }
        return parts.joined(separator: "\n")
    }
}
