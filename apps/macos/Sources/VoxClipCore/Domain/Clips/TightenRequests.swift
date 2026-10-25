import Foundation

struct TightenRequestBuilder: Sendable {
    let document: JSONValue
    let tokenPolicy: AITokenPolicy

    init(document: JSONValue, policy: JSONValue = .null) throws {
        guard document[ai: "schemaVersion"].aiInt == 1,
              document[ai: "system"].aiString != nil,
              CanonicalResponseParser.validateSchemaSubset(document[ai: "output"][ai: "schema"]) else {
            throw VoxClipError.sharedResourcesMissing
        }
        self.document = document
        self.tokenPolicy = AITokenPolicy(policy)
    }

    func request(entries: [ClipWord], window: ClipWindow, strength: String, instruction: String? = nil, windowIndex: Int = 0, windowCount: Int = 1, timeout: Duration, language: String? = nil) throws -> LLMRequest {
        guard !entries.isEmpty else { throw ClipFinderGateError.noWords(message: document[ai: "messages"][ai: "noWords"].aiString ?? "no words") }
        let block = (document[ai: "transcriptBlock"][ai: "prefix"].aiString ?? "") + window.rendered + (document[ai: "transcriptBlock"][ai: "suffix"].aiString ?? "")
        return LLMRequest(feature: .aiTighten, system: document[ai: "system"].aiString ?? "", cachedBlock: block,
                          instruction: try renderInstruction(lines: window.lines, strength: strength, instruction: instruction, windowCount: windowCount),
                          schemaName: document[ai: "output"][ai: "name"].aiString ?? "tighten_edits", schema: document[ai: "output"][ai: "schema"],
                          maxOutputTokens: window.maxOutputTokens ?? document[ai: "generation"][ai: "maxOutputTokens"].aiInt ?? 16000,
                          effort: Effort(rawValue: document[ai: "generation"][ai: "effort"].aiString ?? "medium"), timeout: timeout,
                          language: language, tag: "tighten/\(strength)\(windowCount > 1 ? " part \(windowIndex + 1) of \(windowCount)" : "")")
    }

    func windows(entries: [ClipWord], strength: String, instruction: String? = nil, contextTokens: Int, maxOutputTokensCap: Int? = nil, localServer: Bool = false) throws -> [ClipWindow] {
        guard !entries.isEmpty else { return [] }
        let lines = try formatTranscript(entries).lines
        let overheadInstruction = try renderInstruction(lines: AIWindowPacking.longestTimeLines(lines), strength: strength, instruction: instruction, windowCount: 2)
        let output = aiOutputReserve(generation: document[ai: "generation"][ai: "maxOutputTokens"].aiInt ?? 16000, cap: maxOutputTokensCap, context: contextTokens, localServer: localServer)
        let overhead = tokenPolicy.estimate(document[ai: "system"].aiString ?? "") + tokenPolicy.estimate(overheadInstruction) + tokenPolicy.estimate(try document[ai: "output"][ai: "schema"].aiCompact()) + 64
        let budget = Int(floor(Double(contextTokens - overhead - output) * tokenPolicy.safetyFactor))
        return try AIWindowPacking.pack(lines: lines, budget: budget, maxWords: document[ai: "limits"][ai: "maxWordsPerRequest"].aiInt ?? 2000, overlap: 0, tokenPolicy: tokenPolicy)
            .map { ClipWindow(lines: Array(lines[$0.range]), estimatedTokens: $0.estimatedCost, tokenBudget: budget, maxClips: 0, maxOutputTokens: output) }
    }

    private func renderInstruction(lines: [TranscriptLine], strength: String, instruction: String?, windowCount: Int) throws -> String {
        let settings = document[ai: "request"]
        guard let choice = settings[ai: "strengths"].aiArray.first(where: { $0[ai: "id"].aiString == strength }),
              let base = choice[ai: "instruction"].aiString else { throw VoxClipError.sharedResourcesMissing }
        var parts = [base]
        let custom = AIText.prefix(AIText.trim(instruction ?? ""), utf16: settings[ai: "maxInstructionsLength"].aiInt ?? 200)
        if !custom.isEmpty { parts.append((settings[ai: "alsoPrefix"].aiString ?? "") + custom) }
        if windowCount > 1 {
            parts.append((settings[ai: "windowLine"].aiString ?? "")
                .replacingOccurrences(of: "{windowStart}", with: AIText.formatTime(lines.first?.start ?? 0))
                .replacingOccurrences(of: "{windowEnd}", with: AIText.formatTime(lines.last?.end ?? 0)))
        }
        return parts.joined(separator: "\n")
    }
}
