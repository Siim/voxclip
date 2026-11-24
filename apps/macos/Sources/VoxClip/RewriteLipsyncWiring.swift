import Foundation
import VoxClipCore
import VoxClipMedia

/// The lip sync's controls read the voice's own currency (`voiceSpendCurrent`), never the AI connector: changing the AI
/// leaves a paid lip sync playable, discardable and offered.
extension RewriteSession {
    func mutateLipsync(phrase: Int, perform: @escaping @MainActor () -> Void) {
        guard let plan = takePlan, plan.stillCurrent else { return }
        guard plan.lipsync.blocksMutation(phrase) else { perform(); return }
        let identity = "discardLipsync-\(phrase)"
        let question = "Changing this phrase discards its lip sync and any shared window. fal.ai charges are not refunded."
        let cancel: PanelAction = PanelAction(id: "keepLipsync", title: "Keep Working") { [weak self] in self?.task.dismissConfirm() }
        let discard: PanelAction = PanelAction(id: identity, title: "Discard Lip Sync") { [weak self, weak plan] in
            guard let self, let plan else { return }
            guard voiceSpendCurrent, takePlan === plan, task.confirm?.confirm.id == identity else { return }
            task.dismissConfirm()
            plan.lipsync.invalidate(phrase)
            perform()
            Task { await plan.lipsync.refresh() }
            showProposal()
        }
        task.ask(PanelConfirm(question: question, cancel: cancel, confirm: discard))
        editor.announce(question)
    }

    func playLipsync(phrase: Int) {
        guard let plan = takePlan, let applied = plan.lipsync.applied[phrase], plan.stillCurrent else { return }
        plan.stopAudition()
        Task { [weak self, weak plan] in
            guard let self, let plan, voiceSpendCurrent, takePlan === plan else { return }
            do {
                let request = try await plan.lipsyncPreview()
                guard voiceSpendCurrent, takePlan === plan, plan.lipsync.applied[phrase]?.result.asset.id == applied.result.asset.id else { return }
                try await editor.preview.load(request)
                try await editor.preview.seek(to: Double(applied.window.outputStartSample) / request.timeline.sampleRate, exact: true)
                editor.preview.play()
            } catch { plan.lipsync.previewFailed() }
        }
    }

    func lipSyncAllAction() -> PanelAction? {
        guard let plan = takePlan, let offer = plan.lipsync.allOffer, plan.lipsync.keyAvailable,
              !plan.lipsync.usingTakes, !takesBusy else { return nil }
        // The formatted charge carries its own "≈" ("free" when every window gets back a result already paid for).
        return PanelAction(id: "lipSyncAll", title: "Lip Sync All \(offer.phraseIDs.count) · \(offer.charge)", priced: !offer.free) { [weak self, weak plan] in
            guard let self, let plan, voiceSpendCurrent, takePlan === plan else { return }
            // A refusal (the takes changed, a lip sync still running) says why under the rows and makes fresh offers.
            plan.lipsync.press(offer)
            showProposal()
        }
    }

    func configureLipsync(_ plan: ClipTakePlan) {
        let app = editor.app
        let paid = app.locations.root.appendingPathComponent("VoiceLab", isDirectory: true)
        let scratch = app.locations.root.appendingPathComponent("VoiceLabScratch", isDirectory: true)
        #if DEBUG
        let smoke = editor.lipsyncSmoke
        #endif
        plan.lipsync.backend = RewriteLipsyncSession.Backend(offers: { [weak plan] in
            guard let plan else { throw CancellationError() }
            return try await plan.makeLipsyncOffers()
        }, hasKey: {
            // Presence only, without reading the secret (no Keychain prompt); tests replace the store.
            await app.providerKeyStore.hasKey(for: "fal")
        }, hasConsent: {
            app.bool("voiceLab.providerConsent.fal")
        }, acceptConsent: {
            app.set("voiceLab.providerConsent.fal", .bool(true))
        }, cap: {
            guard let limit = Decimal(string: app.string("voiceLab.monthlyCapUsd.fal"), locale: Locale(identifier: "en_US_POSIX")) else { return nil }
            guard let spent = await VoiceLabSpendLedger(locations: app.locations).total(provider: "fal", at: Date()),
                  spent.unknownCount == 0 else { throw ClipTakePlan.Failure.unknownSpend }
            return VoiceLabMonthlyCap(limit: limit, spent: spent.usd)
        }, run: { [weak self, weak plan] request, window, recordID, model, mayPay, progress in
            let checkpoint: @MainActor @Sendable (LipsyncQuote) -> Void = { [weak self, weak plan] quote in
                guard let self, let plan, self.wholeClipPlan === plan, let whole = self.wholeClip,
                      let voice = whole.voice, let picture = whole.picture else { return }
                whole.pendingLipsync = .init(key: .init(voice: voice.key, retime: picture.speed, model: model),
                    quoteID: quote.id, videoSHA256: quote.video.sha256, audioSHA256: quote.audio.sha256)
                self.persistPaidWork()
            }
            defer { if let plan, self?.wholeClipPlan === plan { self?.wholeClip?.pendingLipsync = nil } }
            #if DEBUG
            if let smoke { return try await smoke(request, window, recordID, model, mayPay, checkpoint, progress) }
            #endif
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let provider = FalLipsyncProvider(keys: app.secrets, logger: app.log, spend: VoiceLabSpendLedger(locations: app.locations),
                                              onCleanupDenial: { [notice = app.falLipsyncCleanupNotice] fingerprint in
                                                  await notice.recordDenial(forFingerprint: fingerprint)
                                              })
            #if DEBUG
            await provider.setDiagnostic(LipsyncDiagnostic())
            #endif
            var run = LipsyncRun(provider: provider, consentStore: VoiceConsentStore(locations: app.locations), paidRoot: paid, scratchRoot: scratch)
            run.beforeSubmit = checkpoint
            return try await run.execute(request: request, window: window, recordID: recordID, model: model.lipsyncModel, mayPay: mayPay, onProgress: progress)
        }, changed: { [weak self] in
            await app.refreshMonthlySpend()
            self?.showProposal()
        }, indexedWindows: { offer in
            var available = Set<Int>()
            for (index, window) in offer.windows.enumerated() {
                guard offer.isCurrent(), !Task.isCancelled else { return [] }
                if await LipsyncRun.hasIndexedResult(request: offer.request, window: window, model: offer.model.lipsyncModel,
                                                     paidRoot: paid, scratchRoot: scratch) { available.insert(index) }
            }
            return available
        }, report: { line in
            // An offer failure's kind or a result set aside: never a URL, key or file name.
            let entry = LogEntry(level: .warn, category: "rewrite", message: line)
            let log = app.log
            Task { await log.write(entry) }
        })
    }
}
