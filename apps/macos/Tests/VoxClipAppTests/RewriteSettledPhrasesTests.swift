#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

/// Phrases settled for a Rewrite (RewriteSettledPhrases.swift, design.md R2 "Not your voice here"): a phrase the use-time
/// guard blocks is said once with its two actions, the footer's count and next step cover only the phrases that can be
/// voiced, and nothing prices it again, in this plan or a later one. A price that failed reading the source is not
/// offered again either. Headless; nothing is sent.
@Suite("Rewrite settled phrases", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; no windows are shown."), .offlineFixtures)
@MainActor struct RewriteSettledPhrasesTests {
    /// The change list's two-voice scene ("r2-several-voices"), with phrases that can be voiced and the provider allowed.
    private func scene() throws -> (EditorModel, RewriteSession, [DirectorScene]) {
        let app = AppModel(settingsStore: RegressionSettingsStore())
        let shared = try SharedResources.locate()
        let fixture = try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
        let all = DebugRewrite.proposalScenes(app: app, fixture: fixture)
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(true)
        let scene = try #require(all.first { $0.name == "r2-several-voices" })
        let editor = try #require(scene.editor)
        let session = try #require(editor.openRewrite)
        let passage = session.source.compactMap { word -> String? in
            guard let index = Int(word.text.dropFirst(4)) else { return word.text }
            if index == 12 || (21...25).contains(index) || (39...43).contains(index) { return nil }
            if index == 20 || index == 38 { return "Comprehensive terminology demonstrates exceptionally natural pronunciation." }
            return word.text
        }.joined(separator: " ")
        try session.receivePassage(passage)
        session.finishRun(seconds: 14)
        for ordinal in session.blockedVoiceOrdinals { session.pricedAnyway.insert(ordinal) }
        return (editor, session, all)
    }
    private static let pricing = ["prepareTakes", "makeTakes", "takeQuote-", "approveTakeQuote", "priceTake.", "priceAnother.", "freshPrice", "keepFixing"]
    /// Every control the panel offers: the footer's, the context row's and each next-steps card's chips.
    private func offered(_ session: RewriteSession) -> [PanelAction] {
        var actions = [session.task.footer.primary, session.task.footer.link, session.task.contextAction].compactMap { $0 }
        for card in session.task.cards { if case .nextSteps(let steps) = card { actions += steps.chips.map(\.action) } }
        return actions
    }
    private func prices(_ session: RewriteSession) -> [String] {
        offered(session).map(\.id).filter { id in Self.pricing.contains { id.hasPrefix($0) } }
    }

    @Test func aBlockedPhraseIsSaidOnceAndUseKeepsItsAudio() throws {
        let (_, session, scenes) = try scene()
        defer { scenes.forEach { $0.editor?.close() } }
        #expect(session.includedVoice.count == 2)
        try DebugRewriteGeneration.install("guard-blocked", in: session)
        let plan = try #require(session.takePlan)
        for phrase in plan.phrases.dropLast() { #expect(plan.chooseVideo(.source, phrase: phrase.id)) }
        session.takeRowsShown = true
        session.showProposal()
        let blocked = try #require(plan.phrases.last)
        let stop = "This doesn't sound like the voice owner. Voice Lab is only for your own videos. Nothing sent for this phrase."
        #expect(blocked.blocked == stop && blocked.takes.isEmpty && plan.voiceableIndices == [0])
        // The row says the stop once; its two actions are drawn under it (BlockedPhraseRow).
        #expect(session.phraseStatus(blocked, plan: plan) == stop)
        #expect(!session.everyPhraseBlocked(plan) && session.everyPhraseBlockedSteps(plan) == nil)
        // Use applies the voiced phrase and keeps the blocked one's audio; nothing prices it again.
        #expect(session.task.footer.primary?.id == "useTakes" && session.task.footer.primary?.title == "Use 1 Take")
        #expect(session.task.footer.note?.contains("Use keeps phrase 2's original audio.") == true, "\(session.task.footer.note ?? "")")
        #expect(prices(session).isEmpty, "\(prices(session))")
        #expect(session.priceableVoiceCount == 1 && RewriteSession.priceTitle(session.priceableVoiceCount) == "Get Price · 1 phrase")
        // A row's own price control is refused for it.
        #expect(session.pricedTakeAction(phrase: blocked.id) == nil)
        #expect(!(session.task.footer.note ?? "").contains("phrases fit"))
    }

    @Test func everyPhraseBlockedSaysItOnceAtTheTopAndOffersNoPrice() throws {
        let (editor, session, scenes) = try scene()
        defer { scenes.forEach { $0.editor?.close() } }
        try DebugRewriteGeneration.install("guard-all-blocked", in: session)
        let plan = try #require(session.takePlan)
        session.takeRowsShown = true
        session.showProposal()
        #expect(plan.settledWithBlocks && session.everyPhraseBlocked(plan))
        guard case .nextSteps(let steps)? = session.task.cards.first else {
            Issue.record("no card at the top: \(session.task.cards.map(\.id))"); return
        }
        #expect(steps.id == "guardBlocked" && steps.line?.hasPrefix("This doesn't sound like the voice owner.") == true)
        #expect(steps.chips.map(\.action.title) == ["● Say it myself", "Keep all as recorded"])
        // Each row has the short line; the stop is said once, at the top.
        for phrase in plan.phrases { #expect(session.phraseStatus(phrase, plan: plan) == "Not voiced. Nothing sent.") }
        #expect(prices(session).isEmpty, "\(prices(session))")
        let primary = try #require(session.task.footer.primary)
        #expect(["apply", "closeRewrite"].contains(primary.id) && !primary.priced)
        #expect(session.task.footer.note?.hasPrefix("Phrases 1 and 2 keep their original audio. Nothing was sent.") == true, "\(session.task.footer.note ?? "")")
        // Say it myself opens the first phrase's recorder; Keep all as recorded keeps every blocked phrase.
        steps.chips[0].action.perform()
        #expect(plan.phrases[0].wording == .microphone)
        steps.chips[1].action.perform()
        #expect(plan.phrases.allSatisfy(\.leftOut) && plan.settledWithBlocks)
        #expect(prices(session).isEmpty && session.task.footer.primary.map { ["apply", "closeRewrite"].contains($0.id) } == true)
        // The footer's step finishes the Rewrite with the original audio.
        let voiced = editor.project.voiceLab.segments.count
        session.task.footer.primary?.perform()
        #expect(editor.project.voiceLab.segments.count == voiced)
    }

    @Test func aLaterPlanOfTheSameRewriteNeverPricesABlockedPhrase() throws {
        let (_, session, scenes) = try scene()
        defer { scenes.forEach { $0.editor?.close() } }
        try DebugRewriteGeneration.install("guard-blocked", in: session)
        let blocked = try #require(session.takePlan?.phrases.last?.blocked)
        #expect(session.guardBlocked.values.contains(blocked))
        // A fresh plan (as Get Price makes after an edit) starts with the guard's verdict and prices only the rest.
        try DebugRewriteGeneration.install("waiting", in: session)
        let fresh = try #require(session.takePlan)
        #expect(fresh.phrases.allSatisfy { $0.blocked == nil })
        session.applyRememberedBlocks(to: fresh)
        #expect(fresh.phrases.last?.blocked == blocked && fresh.voiceableIndices == Array(fresh.phrases.indices.dropLast()))
        // A new reply is a new Rewrite: the guard judges its phrases again.
        session.receive(session.changes)
        #expect(session.guardBlocked.isEmpty)
    }

    @Test func aSourceThatCannotBeReadIsNotPricedAgain() throws {
        #expect(RewriteSession.settlesPlan(VoiceLabSourceAudioError.rangeOutsideMedia))
        #expect(RewriteSession.settlesPlan(VoiceLabSourceAudioError.noAudioTrack))
        #expect(!RewriteSession.settlesPlan(VoiceLabSourceAudioError.unreadable), "the file may come back")
        #expect(!RewriteSession.settlesPlan(VoiceLabError.network))
        #expect(!RewriteSession.settlesPlan(nil))
        let (_, session, scenes) = try scene()
        defer { scenes.forEach { $0.editor?.close() } }
        try DebugRewriteGeneration.install("range-outside-media", in: session)
        session.takeRowsShown = true
        session.showProposal()
        let note = session.task.footer.note ?? ""
        #expect(note.hasPrefix(VoiceLabSourceAudioError.rangeOutsideMedia.errorDescription ?? "-") && note.contains("Nothing was sent"), "\(note)")
        #expect(prices(session).isEmpty, "\(prices(session))")
        #expect(session.task.footer.primary.map { ["apply", "closeRewrite"].contains($0.id) } == true)
    }
}
#endif
