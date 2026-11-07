import Foundation
import VoxClipCore
import VoxClipMedia

extension RewriteSession {
    func mutateLipsync(phrase: Int, perform: @escaping @MainActor () -> Void) {
        guard let plan = takePlan, plan.stillCurrent else { return }
        guard plan.lipsync.blocksMutation(phrase) else { perform(); return }
        let identity = "discardLipsync-\(phrase)"
        let question = "Changing this phrase discards its lip sync and any shared window. fal.ai charges are not refunded."
        task.ask(PanelConfirm(question: question,
            cancel: PanelAction(id: "keepLipsync", title: "Keep Working") { [weak self] in self?.task.dismissConfirm() },
            confirm: PanelAction(id: identity, title: "Discard Lip Sync") { [weak self, weak plan] in
                guard let self, let plan, current, takePlan === plan, task.confirm?.confirm.id == identity else { return }
                task.dismissConfirm()
                plan.lipsync.invalidate(phrase)
                perform()
                Task { await plan.lipsync.refresh() }
                showProposal()
            }))
        editor.announce(question)
    }

    func playLipsync(phrase: Int) {
        guard let plan = takePlan, let applied = plan.lipsync.applied[phrase], plan.stillCurrent else { return }
        plan.stopAudition()
        Task { [weak self, weak plan] in
            guard let self, let plan, current, takePlan === plan else { return }
            do {
                let request = try await plan.lipsyncPreview()
                guard current, takePlan === plan, plan.lipsync.applied[phrase]?.result.asset.id == applied.result.asset.id else { return }
                try await editor.preview.load(request)
                try await editor.preview.seek(to: Double(applied.window.outputStartSample) / request.timeline.sampleRate, exact: true)
                editor.preview.play()
            } catch { plan.lipsync.previewFailed() }
        }
    }

    func lipSyncAllAction() -> PanelAction? {
        guard let plan = takePlan, let offer = plan.lipsync.allOffer, plan.lipsync.keyAvailable,
              !plan.lipsync.usingTakes, !takesBusy else { return nil }
        return PanelAction(id: "lipSyncAll", title: "Lip Sync All \(offer.phraseIDs.count) · ≈ \(offer.price)", priced: true) { [weak self, weak plan] in
            guard let self, let plan, current, takePlan === plan else { return }
            plan.lipsync.start(offer)
            showProposal()
        }
    }

    func configureLipsync(_ plan: ClipTakePlan) {
        let app = editor.app
        let paid = app.locations.root.appendingPathComponent("VoiceLab", isDirectory: true)
        let scratch = app.locations.root.appendingPathComponent("VoiceLabScratch", isDirectory: true)
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
        }, run: { request, window, recordID, model, progress in
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let provider = FalLipsyncProvider(keys: app.secrets, logger: app.log, spend: VoiceLabSpendLedger(locations: app.locations))
            #if DEBUG
            await provider.setDiagnostic(LipsyncDiagnostic())
            #endif
            return try await LipsyncRun(provider: provider, consentStore: VoiceConsentStore(locations: app.locations),
                paidRoot: paid, scratchRoot: scratch).execute(request: request, window: window, recordID: recordID,
                    model: model.lipsyncModel, onProgress: progress)
        }, changed: { [weak self] in
            await app.refreshMonthlySpend()
            self?.showProposal()
        })
    }
}
