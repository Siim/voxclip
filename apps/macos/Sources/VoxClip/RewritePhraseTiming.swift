import SwiftUI
import VoxClipCore

enum PhraseTimingAction { case shorter, again, original, priceAnyway }

extension RewriteSession {
    var blockedVoiceOrdinals: [Int] {
        guard let proposal = ownProposal else { return [] }
        return proposal.changes.filter {
            $0.kind == .voice && $0.state != .excluded && $0.reviewable &&
                voiceReview($0.ordinal)?.timing?.fits == false && !pricedAnyway.contains($0.ordinal)
        }.map(\.ordinal)
    }

    func phraseTimingAction(_ action: PhraseTimingAction, ordinal: Int) {
        guard current, !takesBusy, ownProposal?[ordinal] != nil else { return }
        let model: EditorModel = editor
        let originalInstruction: String = instruction
        switch action {
        case .again: model.sendRewriteAgain(self, instruction: originalInstruction)
        case .original: review(ordinal, .undo)
        case .priceAnyway:
            pricedAnyway.insert(ordinal)
            showProposal()
        case .shorter:
            do {
                let longOrdinals = blockedVoiceOrdinals.filter { voiceReview($0)?.timing?.tooLong == true }
                let feedback = try shorterFeedbackBlock(ordinals: Array(Set(longOrdinals + [ordinal])).sorted())
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
        let shared = try SharedResources.locate()
        let data = try Data(contentsOf: shared.root.appendingPathComponent("prompts/voice-rewrite.json"))
        let template = try JSONDecoder().decode(Prompt.self, from: data).request
        let readings = Dictionary(uniqueKeysWithValues: editor.changeReadings.map { ($0.change.ordinal, $0) })
        let phrases = try ordinals.map { ordinal -> String in
            guard let reading = readings[ordinal], let timing = voiceReview(ordinal)?.timing else {
                throw RewriteSessionError.noSourceAudio
            }
            let values = ["original": reading.removed.joined(separator: " "), "proposed": reading.text,
                          "estimateSeconds": toFixed1(timing.estimateSeconds), "slotSeconds": toFixed1(timing.slotSeconds)]
            return template.shorterPhraseLine.replacing(#/\{(original|proposed|estimateSeconds|slotSeconds)\}/#) { match in
                values[String(match.1)] ?? ""
            }
        }
        return template.shorterFeedbackBlock.replacingOccurrences(of: "{phrases}", with: phrases.joined(separator: "\n\n"))
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
    var retryTitle: String { tooLong ? "Ask for shorter" : "Ask again" }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tooLong ? VoiceLabPhraseTiming.warning : VoiceLabPhraseTiming.shortWarning).font(VCType.callout.font())
                .foregroundStyle(DesignValues.color("status.warning"))
            HStack(spacing: 12) {
                Button(retryTitle) { action(tooLong ? .shorter : .again) }
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
