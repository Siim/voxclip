import Foundation

public struct VoiceLabSpeechContextPlan: Sendable, Equatable {
    public struct Reservation: Sendable, Equatable {
        public let hunkIndices: [Int]
        public let text: String
        public let window: VoiceLabWindow

        public init(hunkIndices: [Int], text: String, window: VoiceLabWindow) {
            self.hunkIndices = hunkIndices; self.text = text; self.window = window
        }
    }

    public struct Request: Sendable, Equatable {
        public let project: Project
        public let scope: VoiceLabOutputScope
        public let approvedSourceWordIDs: [String]
        public let reviewHunks: [VoiceLabDiffHunk]
        public let selectedHunkIndices: [Int]
        public let expandingHunkIndices: [Int]
        public let reservations: [Reservation]
        public let revision: String
        public let contentKey: String
        public let maximumRequestCharacters: Int

        public init(project: Project, scope: VoiceLabOutputScope, approvedSourceWordIDs: [String],
                    reviewHunks: [VoiceLabDiffHunk], selectedHunkIndices: [Int], expandingHunkIndices: [Int],
                    reservations: [Reservation] = [], revision: String, contentKey: String, maximumRequestCharacters: Int) {
            self.project = project; self.scope = scope; self.approvedSourceWordIDs = approvedSourceWordIDs
            self.reviewHunks = reviewHunks; self.selectedHunkIndices = selectedHunkIndices
            self.expandingHunkIndices = expandingHunkIndices; self.reservations = reservations
            self.revision = revision; self.contentKey = contentKey; self.maximumRequestCharacters = maximumRequestCharacters
        }
    }

    public struct Phrase: Sendable, Equatable {
        public let hunkIndex: Int
        public let hunk: VoiceLabDiffHunk
        public let text: String
        public let sourceWords: [TimedWord]
        public let window: VoiceLabWindow
        public let estimatedSpeechSeconds: Double
        public let marginSeconds: Double
    }

    public enum Failure: Error, Sendable, Equatable {
        case invalidInput
        case insufficientSpeech(hunkIndex: Int)
        case budget
        case placement(VoiceLabGeometryError)
        case staleReview
        case quoteBinding
    }

    public enum Outcome: Sendable, Equatable {
        case reviewRequired(VoiceLabSpeechContextPlan)
        case mergeRequired(hunkIndices: [Int])
        case refused(Failure)
    }

    public static let minimumGeneratedSpeechSeconds = Double(SpeakerAudio.windowSize) / 16_000
    public let request: Request
    public let phrases: [Phrase]
    public let totalVoiceTokenCount: Int
    private let identity: Data
    private let envelope: AudioEnvelope

    private struct Merge: Error { let indices: [Int] }

    public static func propose(_ request: Request, envelope: AudioEnvelope) -> Outcome {
        do { return .reviewRequired(try make(request, envelope: envelope)) }
        catch let merge as Merge { return .mergeRequired(hunkIndices: merge.indices.sorted()) }
        catch let failure as Failure { return .refused(failure) }
        catch { return .refused(.invalidInput) }
    }

    public func validateCurrent(_ current: Request, envelope: AudioEnvelope) throws {
        guard current == request, envelope == self.envelope, (try? Self.identity(current)) == identity else {
            throw Failure.staleReview
        }
    }

    public func validateQuotedInputs(_ inputs: [VoiceLabTakeInput], current: Request, envelope: AudioEnvelope) throws {
        try validateCurrent(current, envelope: envelope)
        let project = Self.reviewedProject(current)
        let items = Self.correctedWords(project)
        guard inputs.count == phrases.count else { throw Failure.quoteBinding }
        for (input, phrase) in zip(inputs, phrases) {
            let silence = try VoiceLabWindowPlanner.lendableSilence(project: project, scope: current.scope, window: phrase.window)
            guard input.text.utf8.elementsEqual(phrase.text.utf8), input.window == phrase.window,
                  input.contentKey.utf8.elementsEqual(request.contentKey.utf8),
                  input.sourceSampleRate == project.media.source.audio?.sampleRate,
                  input.sourceEnvelope == envelope, input.incomingSilence == silence.incoming,
                  input.outgoingSilence == silence.outgoing,
                  input.items == items, input.cutWordIDs == Set(project.edits.cutWordIds),
                  try Self.encoded(input.items) == Self.encoded(items) else {
                throw Failure.quoteBinding
            }
        }
    }

    private static func make(_ request: Request, envelope: AudioEnvelope) throws -> VoiceLabSpeechContextPlan {
        let identity = try Self.identity(request)
        let words = request.project.transcript?.words ?? []
        let selected = Set(request.selectedHunkIndices), expanding = Set(request.expandingHunkIndices)
        guard !words.isEmpty, !request.revision.isEmpty, !request.contentKey.isEmpty,
              request.contentKey.utf8.elementsEqual(request.project.media.source.contentKey.utf8),
              request.maximumRequestCharacters > 0, request.maximumRequestCharacters <= 5_000,
              selected.count == request.selectedHunkIndices.count, expanding.count == request.expandingHunkIndices.count,
              !expanding.isEmpty, expanding.isSubset(of: selected),
              selected.allSatisfy({ request.reviewHunks.indices.contains($0) }),
              expanding.allSatisfy({ request.reviewHunks[$0].kind == .voice }),
              expanding.count + request.reservations.count <= VoiceLabTakeBatch.maximumWindows else { throw Failure.invalidInput }
        let positions = Dictionary(words.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        guard positions.count == words.count else { throw Failure.invalidInput }
        let originalWords = correctedWords(request.project)
        let sourceTokenCount = originalWords.reduce(0) { $0 + EditingPrimitives.splitWords($1.text).count }
        guard request.reviewHunks.allSatisfy({ $0.sourceEndIndex <= sourceTokenCount }) else { throw Failure.invalidInput }
        let duration = request.project.media.source.durationSeconds
        let sampleRate = Double(request.project.media.source.audio?.sampleRate ?? 48_000)
        guard duration.isFinite, duration > 0, duration * sampleRate < VoiceLabGeometry.sampleLimit else { throw Failure.invalidInput }
        try VoiceLabGeometry.check(rate: sampleRate, totalSamples: VoiceLabGeometry.samples(duration, sampleRate),
                                   envelope: envelope, items: words)
        guard words.allSatisfy({ $0.end <= duration }) else { throw Failure.invalidInput }
        let approved = try approvedRange(request, words: words, positions: positions)
        let ranges = try request.reviewHunks.map { try hunkRange($0, words: originalWords, positions: positions) }
        for index in selected {
            guard approved.contains(ranges[index].lowerBound), approved.contains(ranges[index].upperBound) else {
                throw Failure.invalidInput
            }
        }
        var occupied = Set<String>()
        for index in request.reviewHunks.indices {
            guard request.reviewHunks[index].sourceWordIds.allSatisfy({ occupied.insert($0).inserted }) else {
                throw Failure.invalidInput
            }
        }
        var reservedIndices = Set<Int>()
        for reservation in request.reservations {
            guard !reservation.hunkIndices.isEmpty, !reservation.text.isEmpty,
                  reservation.text.unicodeScalars.count <= request.maximumRequestCharacters,
                  reservation.hunkIndices.allSatisfy({ index in
                      selected.contains(index) && !expanding.contains(index) && request.reviewHunks[index].kind == .voice &&
                          reservedIndices.insert(index).inserted
                  }) else { throw Failure.invalidInput }
        }
        let otherVoice = selected.filter { !expanding.contains($0) && request.reviewHunks[$0].kind == .voice }
        guard reservedIndices == Set(otherVoice) else { throw Failure.invalidInput }
        let project = reviewedProject(request)
        let corrected = correctedWords(project)
        let rate = max(try VoiceLabLengthBudget.generatedRate(project: project).charactersPerSecond, VoiceLabLengthBudget.providerRateFloor)
        let pauses = try detectPauses(words, thresholdSeconds: project.edits.pauseThresholdSeconds)
        let breaks = Set(pauses.map(\.afterIndex))
        let cutPauses = pauses.filter { project.edits.cutPauseIds.contains($0.id) }
        let cuts = Set(project.edits.cutWordIds)
        let boundaries = [0] + words.indices.filter { index in
            index + 1 < words.count && (endsSentence(corrected[index].text) || breaks.contains(index))
        }.map { $0 + 1 } + [words.count]
        let scopeTimes = try Self.scopeTimes(request.scope, project: project, words: words)
        let approvedTimes = try clipTimes(words, startIndex: approved.lowerBound, endIndex: approved.upperBound)
        let lowerTime = max(scopeTimes.start, approved.lowerBound == 0 ? 0 : approvedTimes.start)
        let upperTime = min(scopeTimes.end, approved.upperBound == words.count - 1 ? duration : approvedTimes.end)
        var phrases: [Phrase] = []
        let ordered = expanding.sorted { ranges[$0].lowerBound < ranges[$1].lowerBound }
        for index in ordered {
            let target = ranges[index]
            let starts = boundaries.filter { start in
                start <= target.lowerBound && start >= approved.lowerBound && target.upperBound - start < 60
            }
            var candidates: [Range<Int>] = []
            for start in starts {
                for end in boundaries where end > target.upperBound && end - 1 <= approved.upperBound && end - start <= 60 {
                    candidates.append(start..<end)
                }
            }
            candidates.sort { left, right in
                left.count == right.count ? left.lowerBound < right.lowerBound : left.count < right.count
            }
            var chosen: Phrase?
            for candidate in candidates {
                let source = Array(words[candidate])
                guard source.allSatisfy({ $0.kind == .word && !cuts.contains($0.id) }),
                      Set(source.map(\.speaker)).count <= 1,
                      zip(source, source.dropFirst()).allSatisfy({ $0.end <= $1.start }),
                      !cutPauses.contains(where: { candidate.contains($0.afterIndex) && candidate.contains($0.afterIndex + 1) })
                else { continue }
                let conflicts = request.reviewHunks.indices.filter {
                    $0 != index && ranges[$0].lowerBound < candidate.upperBound && candidate.lowerBound <= ranges[$0].upperBound
                }
                guard !conflicts.contains(where: { !selected.contains($0) || request.reviewHunks[$0].kind == .cut }) else { continue }
                let pieces = Array(corrected[candidate.lowerBound..<target.lowerBound]).map(\.text) +
                    request.reviewHunks[index].newTokens + Array(corrected[(target.upperBound + 1)..<candidate.upperBound]).map(\.text)
                let text = pieces.joined(separator: " ")
                guard text.unicodeScalars.count <= request.maximumRequestCharacters else { continue }
                let sourceSeconds = source.reduce(0.0) { $0 + $1.end - $1.start }
                let sourceCharacters = corrected[candidate].reduce(0) { $0 + VoiceLabTextLength.length($1.text) }
                let conservativeRate = max(rate, Double(sourceCharacters) / sourceSeconds)
                let estimate = try VoiceLabLengthBudget.generatedVoicedSeconds(text: text, rate: conservativeRate)
                let margin = source.map { $0.end - $0.start }.max() ?? 0
                guard estimate.isFinite, margin > 0, estimate >= minimumGeneratedSpeechSeconds + margin else { continue }
                let window: VoiceLabWindow
                do {
                    window = try VoiceLabWindowPlanner.place(project: project, scope: request.scope, envelope: envelope,
                                                            firstWordId: source[0].id, lastWordId: source[source.count - 1].id)
                } catch { continue }
                guard window.leftBridgeWordIds.isEmpty, window.rightBridgeWordIds.isEmpty,
                      window.start >= lowerTime, window.end <= upperTime,
                      !words.contains(where: { cuts.contains($0.id) && $0.start < window.end && window.start < $0.end }),
                      !cutPauses.contains(where: { $0.start < window.end && window.start < $0.end }) else { continue }
                let silence = try VoiceLabWindowPlanner.lendableSilence(project: project, scope: request.scope, window: window)
                let meter = try VoiceLabFitMeter.measure(text: text, window: window, incomingSilence: silence.incoming,
                    outgoingSilence: silence.outgoing, rate: conservativeRate, newWords: text)
                guard meter.upperBoundSeconds >= minimumGeneratedSpeechSeconds + margin else { continue }
                let other = conflicts.filter { request.reviewHunks[$0].kind == .voice }
                if !other.isEmpty { throw Merge(indices: Array(Set([index] + other))) }
                let original = request.reviewHunks[index]
                let prefixCount = originalWords[candidate.lowerBound..<target.lowerBound].reduce(0) {
                    $0 + EditingPrimitives.splitWords($1.text).count
                }
                let suffixCount = originalWords[(target.upperBound + 1)..<candidate.upperBound].reduce(0) {
                    $0 + EditingPrimitives.splitWords($1.text).count
                }
                guard original.sourceStartIndex >= prefixCount else { continue }
                let hunk = VoiceLabDiffHunk(kind: .voice, sourceWordIds: source.map(\.id), newTokens: pieces,
                    correctedTexts: [], absorbedItemIds: [], bridgeWordIds: [], sourceStartIndex: original.sourceStartIndex - prefixCount,
                    sourceEndIndex: original.sourceEndIndex + suffixCount, anchorSeconds: nil,
                    audioTags: VoiceLabAudioTags.shifted(original.audioTags, by: prefixCount))
                chosen = Phrase(hunkIndex: index, hunk: hunk, text: text, sourceWords: source, window: window,
                                estimatedSpeechSeconds: estimate, marginSeconds: margin)
                break
            }
            guard let chosen else { throw Failure.insufficientSpeech(hunkIndex: index) }
            phrases.append(chosen)
        }
        let all = phrases.map { Reservation(hunkIndices: [$0.hunkIndex], text: $0.text, window: $0.window) } + request.reservations
        let orderedWindows = all.sorted { $0.window.startSample < $1.window.startSample }
        for (left, right) in zip(orderedWindows, orderedWindows.dropFirst()) {
            let end = left.window.endSample + (left.window.rightSeam.fadeSamples + 1) / 2
            let start = right.window.startSample - right.window.leftSeam.fadeSamples / 2
            if end >= start { throw Merge(indices: Array(Set(left.hunkIndices + right.hunkIndices))) }
        }
        let budgetHunks = all.map { item in
            VoiceLabDiffHunk(kind: .voice, sourceWordIds: [], newTokens: EditingPrimitives.splitWords(item.text),
                             correctedTexts: [], absorbedItemIds: [], bridgeWordIds: [], sourceStartIndex: 0,
                             sourceEndIndex: 0, anchorSeconds: nil)
        }
        let budget = VoiceLabPatchBudget.evaluate(hunks: budgetHunks, transcript: words)
        guard budget.flag == .allowed else { throw Failure.budget }
        do { try VoiceLabRenderContract.validatePlacement(project, scope: request.scope, windows: orderedWindows.map(\.window)) }
        catch let failure as VoiceLabGeometryError { throw Failure.placement(failure) }
        return VoiceLabSpeechContextPlan(request: request, phrases: phrases, totalVoiceTokenCount: budget.voiceTokenCount,
                                         identity: identity, envelope: envelope)
    }

    private static func hunkRange(_ hunk: VoiceLabDiffHunk, words: [TimedWord], positions: [String: Int]) throws -> ClosedRange<Int> {
        guard let first = hunk.sourceWordIds.first.flatMap({ positions[$0] }),
              let last = hunk.sourceWordIds.last.flatMap({ positions[$0] }), first <= last,
              hunk.sourceWordIds == Array(words[first...last]).map(\.id),
              hunk.sourceStartIndex >= 0, hunk.sourceEndIndex > hunk.sourceStartIndex, hunk.anchorSeconds == nil,
              hunk.sourceEndIndex - hunk.sourceStartIndex == words[first...last].reduce(0, { $0 + EditingPrimitives.splitWords($1.text).count }),
              hunk.absorbedItemIds.isEmpty, hunk.bridgeWordIds.isEmpty,
              hunk.kind == .cut || (!hunk.newTokens.isEmpty && hunk.newTokens.allSatisfy({ VoiceLabTextLength.length($0) > 0 })),
              hunk.kind != .textOnly || (hunk.correctedTexts.count == hunk.sourceWordIds.count &&
                  hunk.newTokens.joined(separator: " ").utf8.elementsEqual(hunk.correctedTexts.joined(separator: " ").utf8))
        else { throw Failure.invalidInput }
        return first...last
    }

    private static func approvedRange(_ request: Request, words: [TimedWord], positions: [String: Int]) throws -> ClosedRange<Int> {
        guard let first = request.approvedSourceWordIDs.first.flatMap({ positions[$0] }),
              let last = request.approvedSourceWordIDs.last.flatMap({ positions[$0] }), first <= last,
              request.approvedSourceWordIDs == Array(words[first...last]).map(\.id) else { throw Failure.invalidInput }
        return first...last
    }

    private static func scopeTimes(_ scope: VoiceLabOutputScope, project: Project, words: [TimedWord]) throws -> TimeRange {
        switch scope {
        case .full: return TimeRange(start: 0, end: project.media.source.durationSeconds)
        case .clip(let id):
            guard let clip = project.edits.clips.first(where: { $0.id == id }), let range = clipIndices(clip, words: words) else {
                throw Failure.invalidInput
            }
            return try clipTimes(words, startIndex: range.lowerBound, endIndex: range.upperBound)
        }
    }

    private static func reviewedProject(_ request: Request) -> Project {
        var project = request.project
        for index in request.selectedHunkIndices where request.reviewHunks.indices.contains(index) {
            let hunk = request.reviewHunks[index]
            if hunk.kind == .cut {
                for id in hunk.sourceWordIds where !project.edits.cutWordIds.contains(id) { project.edits.cutWordIds.append(id) }
            } else if hunk.kind == .textOnly {
                for (id, text) in zip(hunk.sourceWordIds, hunk.correctedTexts) { project.edits.corrections[id] = text }
            }
        }
        return project
    }

    private static func correctedWords(_ project: Project) -> [TimedWord] {
        (project.transcript?.words ?? []).map { original in
            var word = original
            if word.kind == .word { word.text = project.edits.corrections[word.id] ?? word.text }
            return word
        }
    }

    private static func endsSentence(_ text: String) -> Bool {
        let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»"]
        let punctuation: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
        return text.reversed().first(where: { !$0.isWhitespace && !closers.contains($0) }).map { punctuation.contains($0) } ?? false
    }

    private static func identity(_ request: Request) throws -> Data {
        var bytes = try encoded(request.project)
        let scope: [String] = switch request.scope { case .full: ["full"]; case .clip(let id): ["clip", id] }
        let hunks = request.reviewHunks.map { hunk in
            [hunk.kind.rawValue, String(hunk.sourceStartIndex), String(hunk.sourceEndIndex), String(describing: hunk.anchorSeconds)] +
                hunk.sourceWordIds + ["newTokens"] + hunk.newTokens + ["correctedTexts"] + hunk.correctedTexts +
                ["absorbedItemIds"] + hunk.absorbedItemIds + ["bridgeWordIds"] + hunk.bridgeWordIds
        }
        let reservations = request.reservations.map { [$0.text] }
        bytes.append(try encoded([scope, [request.revision, request.contentKey], request.approvedSourceWordIDs] + hunks + reservations))
        return bytes
    }

    private static func encoded<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
