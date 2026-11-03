import SwiftUI
import VoxClipCore

enum PhraseTimingAction { case shorter, surrounding, original, priceAnyway }

extension RewriteSession {
    var blockedVoiceOrdinals: [Int] {
        guard let proposal = ownProposal else { return [] }
        return proposal.changes.filter {
            $0.kind == .voice && $0.state != .excluded && $0.reviewable &&
                voiceReview($0.ordinal)?.timing?.fits == false && !pricedAnyway.contains($0.ordinal) &&
                acceptedSpeechContext?.plan.request.expandingHunkIndices.contains($0.ordinal - 1) != true
        }.map(\.ordinal)
    }

    func phraseTimingAction(_ action: PhraseTimingAction, ordinal: Int) {
        phraseTimingAction(action, ordinals: [ordinal])
    }

    func phraseTimingAction(_ action: PhraseTimingAction, ordinals: [Int]) {
        guard current, !takesBusy, let ordinal = ordinals.first, ordinals.allSatisfy({ ownProposal?[$0] != nil }) else { return }
        if action == .original || action == .priceAnyway {
            if confirmPaidProposalChange(perform: { [weak self] in self?.phraseTimingAction(action, ordinals: ordinals) }) { return }
        }
        let model: EditorModel = editor
        let originalInstruction: String = instruction
        switch action {
        case .surrounding:
            surroundingSentenceOrdinal = ordinal
            takeRowsShown = true
            if generation != nil { reviewTimingSpeechContext(ordinal: ordinal) }
            else { makeTakes() }
        case .original:
            if surroundingSentenceOrdinal.map(ordinals.contains) == true { surroundingSentenceOrdinal = nil }
            for ordinal in ordinals { review(ordinal, .undo) }
        case .priceAnyway:
            surroundingSentenceOrdinal = nil
            pricedAnyway.formUnion(ordinals)
            showProposal()
        case .shorter:
            do {
                let longOrdinals = blockedVoiceOrdinals.filter { voiceReview($0)?.timing?.tooLong == true }
                let feedback = try shorterFeedbackBlock(ordinals: Array(Set(longOrdinals + ordinals)).sorted())
                model.sendRewriteAgain(self, instruction: originalInstruction, feedback: feedback)
            } catch {
                reportGenerationProblem(error)
                showProposal()
            }
        }
    }

    func shorterFeedbackBlock(ordinals: [Int]) throws -> String {
        struct Prompt: Decodable {
            struct Request: Decodable {
                let shorterFeedbackBlock: String
                let shorterPhraseLine: String
            }
            let request: Request
        }
        struct MeasuredFeedback: Decodable {
            let shorterMeasuredFeedbackBlock: String
            let shorterMeasuredPhraseLine: String
        }
        let shared = try SharedResources.locate()
        let data = try Data(contentsOf: shared.root.appendingPathComponent("prompts/voice-rewrite.json"))
        let template = try JSONDecoder().decode(Prompt.self, from: data).request
        let measuredData = try Data(contentsOf: shared.root.appendingPathComponent("prompts/voice-rewrite-shorter-measured.json"))
        let measuredTemplate = try JSONDecoder().decode(MeasuredFeedback.self, from: measuredData)
        let readings = Dictionary(uniqueKeysWithValues: editor.changeReadings.map { ($0.change.ordinal, $0) })
        let measuredPhrases = takePlan?.phrases.filter { phrase in
            !Set(takePhraseOrdinals(phrase)).isDisjoint(with: ordinals) && measuredTakeLength(phrase) != nil
        } ?? []
        let expandedOrdinals = Set(ordinals + measuredPhrases.flatMap(takePhraseOrdinals)).sorted()
        let phrases = try expandedOrdinals.map { ordinal -> String in
            guard let reading = readings[ordinal], let timing = voiceReview(ordinal)?.timing else {
                throw RewriteSessionError.noSourceAudio
            }
            let phrase = measuredPhrases.first { takePhraseOrdinals($0).contains(ordinal) }
            let measured = phrase.flatMap(measuredTakeLength)
            let values = ["original": reading.removed.joined(separator: " "), "proposed": reading.text,
                          "estimateSeconds": toFixed1(timing.estimateSeconds), "measuredSeconds": measured.map(toFixed1) ?? "",
                          "slotSeconds": toFixed1(timing.slotSeconds)]
            let line = measured == nil ? template.shorterPhraseLine : measuredTemplate.shorterMeasuredPhraseLine
            return line.replacing(#/\{(original|proposed|estimateSeconds|measuredSeconds|slotSeconds)\}/#) { match in
                values[String(match.1)] ?? ""
            }
        }
        let block = measuredPhrases.isEmpty ? template.shorterFeedbackBlock : measuredTemplate.shorterMeasuredFeedbackBlock
        return block.replacingOccurrences(of: "{phrases}", with: phrases.joined(separator: "\n\n"))
    }

    private func measuredTakeLength(_ phrase: ClipTakePlan.Phrase) -> Double? {
        if let length = phrase.selected?.length { return length }
        let best = phrase.bestMeasured ?? phrase.takes.filter { $0.length != nil }.max { ($0.row.score ?? 0) < ($1.row.score ?? 0) }
        return best?.length
    }

    func takePhraseOrdinals(_ phrase: ClipTakePlan.Phrase) -> [Int] {
        phrase.indices.compactMap { takePlanOrdinals.indices.contains($0) ? takePlanOrdinals[$0] : nil }
            .filter { ownProposal?[$0]?.kind == .voice }
    }

    func takeNeedsWordingRecovery(_ phrase: ClipTakePlan.Phrase, plan: ClipTakePlan) -> Bool {
        guard phrase.selected != nil else { return false }
        let availability = plan.videoAvailability(phrase: phrase.id)
        return !availability.allows(.source) && !availability.allows(.retimed)
    }

    static func firstTakeVerb(hasTakes: Bool) -> String { hasTakes ? "Try another" : "Make take" }
    static func priceTitle(_ count: Int) -> String { "Get Price · \(count) \(count == 1 ? "phrase" : "phrases")" }
    static func shorterNote(_ count: Int) -> String {
        count == 1 ? "1 phrase needs a shorter wording." : "\(count) phrases need a shorter wording."
    }
    var timingBlockedNote: String {
        let blocked = blockedVoiceOrdinals
        if blocked.allSatisfy({ voiceReview($0)?.timing?.tooLong == true }) { return Self.shorterNote(blocked.count) }
        return blocked.count == 1 ? "1 phrase needs wording that fits." : "\(blocked.count) phrases need wording that fits."
    }
}

struct PhraseTimingRecovery: View {
    var tooLong = true
    let priceAnyway: Bool
    let action: (PhraseTimingAction) -> Void
    var retryTitle: String { tooLong ? "Ask for shorter" : "Use surrounding sentence" }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tooLong ? VoiceLabPhraseTiming.warning : VoiceLabPhraseTiming.shortWarning).font(VCType.callout.font())
                .foregroundStyle(DesignValues.color("status.warning"))
            HStack(spacing: 12) {
                Button(retryTitle) { action(tooLong ? .shorter : .surrounding) }
                Button("Keep original words") { action(.original) }
            }
            .buttonStyle(.plain).font(VCType.callout.font())
            if priceAnyway {
                Button("Price it anyway") { action(.priceAnyway) }
                    .buttonStyle(.plain).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
            }
        }
        .padding(.leading, 8)
        .overlay(alignment: .leading) { Rectangle().fill(DesignValues.color("status.warning")).frame(width: 2) }
    }
}
