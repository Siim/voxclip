import Foundation
import VoxClipCore

@MainActor struct RewriteSpeechContextReview: Equatable {
    enum Failure: Error {
        case unsupported, mergeRequired, stale, placementChanged
    }

    let plan: VoiceLabSpeechContextPlan
    let targetPhraseID: Int
    let selectedOriginalIndices: [Int]
    var phrase: VoiceLabSpeechContextPlan.Phrase { plan.phrases[0] }
    var ordinal: Int { phrase.hunkIndex + 1 }

    static func propose(request: VoiceLabSpeechContextPlan.Request, envelope: AudioEnvelope,
                        targetPhraseID: Int, selectedOriginalIndices: [Int]) throws -> Self {
        guard request.expandingHunkIndices.count == 1,
              selectedOriginalIndices == request.selectedHunkIndices,
              selectedOriginalIndices == selectedOriginalIndices.sorted() else { throw Failure.unsupported }
        switch VoiceLabSpeechContextPlan.propose(request, envelope: envelope) {
        case .reviewRequired(let plan):
            guard plan.phrases.count == 1 else { throw Failure.unsupported }
            return Self(plan: plan, targetPhraseID: targetPhraseID, selectedOriginalIndices: selectedOriginalIndices)
        case .mergeRequired: throw Failure.mergeRequired
        case .refused(let failure): throw failure
        }
    }

    func replacingHunks(current: VoiceLabSpeechContextPlan.Request, envelope: AudioEnvelope) throws -> [VoiceLabDiffHunk] {
        try plan.validateCurrent(current, envelope: envelope)
        return selectedOriginalIndices.map { $0 == phrase.hunkIndex ? phrase.hunk : current.reviewHunks[$0] }
    }

    func validatePreparedPhrases(_ phrases: [ClipTakePlan.Phrase], current: VoiceLabSpeechContextPlan.Request,
                                 envelope: AudioEnvelope) throws {
        try plan.validateCurrent(current, envelope: envelope)
        guard phrases.count == current.reservations.count + 1, phrases.indices.contains(targetPhraseID) else {
            throw Failure.placementChanged
        }
        for candidate in phrases {
            guard candidate.indices.allSatisfy(selectedOriginalIndices.indices.contains) else { throw Failure.placementChanged }
            let original = candidate.indices.map { selectedOriginalIndices[$0] }
            if candidate.id == targetPhraseID {
                guard original == [phrase.hunkIndex], candidate.text.utf8.elementsEqual(phrase.text.utf8),
                      candidate.window == phrase.window else { throw Failure.placementChanged }
            } else {
                guard current.reservations.contains(where: {
                    $0.hunkIndices == original && $0.text.utf8.elementsEqual(candidate.text.utf8) && $0.window == candidate.window
                }) else { throw Failure.placementChanged }
            }
        }
    }

    func validateQuotedInputs(_ inputs: [VoiceLabTakeInput], current: VoiceLabSpeechContextPlan.Request,
                              envelope: AudioEnvelope) throws {
        guard inputs.indices.contains(targetPhraseID) else { throw Failure.stale }
        try plan.validateQuotedInputs([inputs[targetPhraseID]], current: current, envelope: envelope)
    }

    static func placedPhrases(project: Project, scope: VoiceLabOutputScope, envelope: AudioEnvelope,
                              hunks: [VoiceLabDiffHunk]) throws -> [ClipTakePlan.Phrase] {
        let texts = Dictionary(RewriteSession.corrected(project).map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        var phrases: [ClipTakePlan.Phrase] = []
        for placement in VoiceLabWindowPlanner.placeAll(project: project, scope: scope, envelope: envelope, hunks: hunks) {
            switch placement {
            case .refused: throw Failure.unsupported
            case .placed(let indices, let hunk, let window):
                let text = (window.leftBridgeWordIds.compactMap { texts[$0] } + hunk.newTokens +
                    window.rightBridgeWordIds.compactMap { texts[$0] }).joined(separator: " ")
                phrases.append(.init(id: phrases.count, indices: indices, text: text, window: window))
            }
        }
        return phrases
    }

    static func copy(_ error: any Error) -> String {
        switch error {
        case Failure.mergeRequired:
            "This sentence overlaps another selected change. Review a combined rewrite instead. No changes were merged and nothing was sent."
        case Failure.stale, VoiceLabSpeechContextPlan.Failure.staleReview:
            "The rewrite or source changed. Review the surrounding sentence again. Nothing was sent."
        case Failure.placementChanged, VoiceLabSpeechContextPlan.Failure.quoteBinding:
            "The complete sentence no longer matches the reviewed text and source range. Nothing was sent. Review it again."
        default:
            "Its whole sentence can't fit inside this clip. Other changes and takes are kept. Nothing was sent."
        }
    }
}

extension RewriteSession {
    private func speechContextRequest(targetPhraseID: Int, includingOrdinal: Int? = nil) throws -> VoiceLabSpeechContextPlan.Request {
        let included = Array(Set(includedVoice + [includingOrdinal].compactMap { $0 })).sorted()
        guard current, !takesBusy, acceptedSpeechContext == nil, let envelope, let generation,
              let model = generation.models.first(where: { $0.id == generation.selectedModelID }),
              let limit = model.maximumTextLength, limit > 0, !included.isEmpty else {
            throw RewriteSpeechContextReview.Failure.unsupported
        }
        let selected = changes.indices.filter { index in
            changes[index].hunk.kind == .voice ? included.contains(index + 1) : ownProposal?[index + 1]?.state != .excluded
        }
        let final = try editor.voiceLabReviewProject(localCommands: localCommands)
        let placements = try RewriteSpeechContextReview.placedPhrases(project: final, scope: scope, envelope: envelope,
            hunks: selected.map { changes[$0].hunk })
        guard placements.indices.contains(targetPhraseID), placements[targetPhraseID].indices.count == 1,
              placements[targetPhraseID].indices.allSatisfy(selected.indices.contains) else {
            throw RewriteSpeechContextReview.Failure.unsupported
        }
        let expanding = placements[targetPhraseID].indices.map { selected[$0] }
        if let existing = takePlan {
            guard existing.stillCurrent, existing.phrases.count == placements.count,
                  canReviewSpeechContext(phrase: existing.phrases[targetPhraseID]),
                  zip(existing.phrases, placements).allSatisfy({ $0.indices == $1.indices &&
                      $0.text.utf8.elementsEqual($1.text.utf8) && $0.window == $1.window }) else {
                throw RewriteSpeechContextReview.Failure.unsupported
            }
        }
        let reservations = placements.filter { $0.id != targetPhraseID }.map { phrase in
            VoiceLabSpeechContextPlan.Reservation(hunkIndices: phrase.indices.map { selected[$0] }, text: phrase.text, window: phrase.window)
        }
        return .init(project: final, scope: scope, approvedSourceWordIDs: source.map(\.id), reviewHunks: changes.map(\.hunk),
            selectedHunkIndices: selected, expandingHunkIndices: expanding, reservations: reservations,
            revision: "\(revision):\(generation.selectedVoiceID ?? ""): \(model.id):\(takeRegion?.rawValue ?? "")",
            contentKey: final.media.source.contentKey, maximumRequestCharacters: min(5_000, limit))
    }

    func canReviewSpeechContext(phrase: ClipTakePlan.Phrase) -> Bool {
        guard acceptedSpeechContext == nil else { return false }
        if takePlan?.canExpandTimingShortPhrase(phrase.id) == true { return true }
        guard phrase.selected == nil || phrase.selected?.row.voiceCheck.evidence?.mode == .unmeasured else { return false }
        if phrase.estimatedVoicedSeconds.map({ $0 < ClipTakePlan.minimumGeneratedSpeechSeconds }) == true { return true }
        return phrase.takes.contains { take in
            if take.row.voiceCheck.evidence?.mode == .unmeasured { return true }
            if case .qa(let failures) = take.row.failure, failures.contains(.insufficientGeneratedSpeech) { return true }
            return take.row.qa?.failures.contains(.insufficientGeneratedSpeech) == true
        }
    }

    func timingSpeechContextReview(ordinal: Int) throws -> RewriteSpeechContextReview {
        guard current, !takesBusy, let envelope, reviewedVoiceOrdinals.contains(ordinal) else {
            throw RewriteSpeechContextReview.Failure.unsupported
        }
        let included = Array(Set(includedVoice + [ordinal])).sorted()
        let selected = changes.indices.filter {
            changes[$0].hunk.kind == .voice ? included.contains($0 + 1) : ownProposal?[$0 + 1]?.state != .excluded
        }
        let final = try editor.voiceLabReviewProject(localCommands: localCommands)
        let placements = try RewriteSpeechContextReview.placedPhrases(project: final, scope: scope,
            envelope: envelope, hunks: selected.map { changes[$0].hunk })
        guard let phrase = placements.first(where: { $0.indices.contains(where: { selected[$0] == ordinal - 1 }) }) else {
            throw RewriteSpeechContextReview.Failure.unsupported
        }
        let request = try speechContextRequest(targetPhraseID: phrase.id, includingOrdinal: ordinal)
        return try RewriteSpeechContextReview.propose(request: request, envelope: envelope,
            targetPhraseID: phrase.id, selectedOriginalIndices: request.selectedHunkIndices)
    }

    func reviewTimingSpeechContext(ordinal: Int) {
        do {
            let review = try timingSpeechContextReview(ordinal: ordinal)
            speechContextOffer = review; speechContextReview = review; speechContextProblem = ""
        } catch {
            speechContextOffer = nil; speechContextReview = nil
            surroundingSentenceOrdinal = nil
            speechContextProblem = RewriteSpeechContextReview.copy(error)
            speechContextRefusedOrdinals = [ordinal]
            // Once automatic fixes are armed it is handled without a click: the changed words alone, a rewrite inside the
            // change, or left out (RewriteAutoFix.swift). A manual try shows its acting chips instead.
            if autoFix.armed { Task { @MainActor [weak self] in self?.resolveRefusedContext() } }
        }
    }

    func reviewSpeechContext(phrase: Int? = nil) {
        do {
            guard let envelope else { throw RewriteSpeechContextReview.Failure.unsupported }
            if let phrase {
                guard let row = takePlan?.phrases.first(where: { $0.id == phrase }), canReviewSpeechContext(phrase: row) else { return }
                let request = try speechContextRequest(targetPhraseID: phrase)
                speechContextOffer = try .propose(request: request, envelope: envelope, targetPhraseID: phrase,
                    selectedOriginalIndices: request.selectedHunkIndices)
            }
            guard let offer = speechContextOffer else { return }
            try offer.plan.validateCurrent(currentSpeechContextRequest(offer), envelope: envelope)
            speechContextReview = offer
            speechContextProblem = ""
        } catch {
            let ordinals = phrase.flatMap { id in takePlan?.phrases.first { $0.id == id } }.map(takePhraseOrdinals)
                ?? speechContextOffer.map { $0.plan.request.expandingHunkIndices.map { $0 + 1 } } ?? []
            speechContextOffer = nil; speechContextReview = nil
            surroundingSentenceOrdinal = nil
            speechContextProblem = RewriteSpeechContextReview.copy(error)
            speechContextRefusedOrdinals = ordinals
        }
    }

    func cancelSpeechContextReview() { speechContextReview = nil; surroundingSentenceOrdinal = nil }

    func currentSpeechContextRequest(_ review: RewriteSpeechContextReview) throws -> VoiceLabSpeechContextPlan.Request {
        guard current, let envelope, let generation,
              generationIsCurrent(region: takeRegion ?? .default) else { throw RewriteSpeechContextReview.Failure.stale }
        let captured = review.plan.request
        let expanding = captured.expandingHunkIndices.map { $0 + 1 }.filter { reviewedVoiceOrdinals.contains($0) }
        let included = Set(includedVoice + expanding)
        let selected = changes.indices.filter { index in
            changes[index].hunk.kind == .voice ? included.contains(index + 1) : ownProposal?[index + 1]?.state != .excluded
        }
        guard let model = generation.models.first(where: { $0.id == generation.selectedModelID }),
              let limit = model.maximumTextLength else { throw RewriteSpeechContextReview.Failure.stale }
        let request = VoiceLabSpeechContextPlan.Request(project: try editor.voiceLabReviewProject(localCommands: localCommands),
            scope: scope, approvedSourceWordIDs: source.map(\.id), reviewHunks: changes.map(\.hunk),
            selectedHunkIndices: selected, expandingHunkIndices: captured.expandingHunkIndices, reservations: captured.reservations,
            revision: "\(revision):\(generation.selectedVoiceID ?? ""): \(model.id):\(takeRegion?.rawValue ?? "")",
            contentKey: editor.project.media.source.contentKey, maximumRequestCharacters: min(5_000, limit))
        try review.plan.validateCurrent(request, envelope: envelope)
        return request
    }

    func bindSpeechContext(_ review: RewriteSpeechContextReview, to plan: ClipTakePlan) {
        plan.bindSpeechContext({ [weak self] inputs in
            guard let self, acceptedSpeechContext == review, let envelope else { throw RewriteSpeechContextReview.Failure.stale }
            try review.validateQuotedInputs(inputs, current: currentSpeechContextRequest(review), envelope: envelope)
        }, current: { [weak self] in
            guard let self, acceptedSpeechContext == review else { return false }
            return (try? currentSpeechContextRequest(review)) != nil
        })
    }

    func acceptSpeechContextReview() async {
        guard let reviewed = speechContextReview, !takesBusy else { return }
        do {
            guard let envelope else { throw RewriteSpeechContextReview.Failure.stale }
            let request = try currentSpeechContextRequest(reviewed)
            let hunks = try reviewed.replacingHunks(current: request, envelope: envelope)
            let prepared = try ClipTakePlan.preparePlan(project: request.project, scope: scope, envelope: envelope, hunks: hunks)
            try reviewed.validatePreparedPhrases(prepared, current: request, envelope: envelope)
            task.dismissConfirm()
            speechContextReview = nil; speechContextOffer = nil; acceptedSpeechContext = reviewed
            surroundingSentenceOrdinal = nil
            includedVoicesSeen = includedVoice
            speechContextProblem = ""
            if let plan = takePlan {
                bindSpeechContext(reviewed, to: plan)
                takeQuotePhrase = reviewed.targetPhraseID
                try await plan.replaceSpeechContext(hunks: hunks, envelope: envelope, phrase: reviewed.targetPhraseID)
            } else {
                await prepareTakes()
            }
        } catch {
            speechContextProblem = RewriteSpeechContextReview.copy(error)
            speechContextRefusedOrdinals = reviewed.plan.request.expandingHunkIndices.map { $0 + 1 }
        }
    }
}
