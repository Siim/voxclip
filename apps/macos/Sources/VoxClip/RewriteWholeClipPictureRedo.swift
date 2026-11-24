import Foundation
import VoxClipCore
import VoxClipMedia

struct WholeClipPictureRedo {
    let record: WholeClipRevoiceRecord
    let base: Project
    let indices: [Int]
    let windows: [LipsyncRenderWindow]
    let output: VoiceLabOutputPlan
    let catalog: VoiceLabPriceCatalog

    init(record: WholeClipRevoiceRecord, project: Project, scope: VoiceLabOutputScope, catalog: VoiceLabPriceCatalog) throws {
        var base = project
        let ids = Set(record.segmentIds)
        let indices = project.voiceLab.segments.indices.filter { ids.contains(project.voiceLab.segments[$0].id) }
        guard indices.count == ids.count, !indices.isEmpty else { throw ClipTakePlan.Failure.noLipsyncOffer }
        var sources: [LipsyncWindow] = []
        for (part, index) in indices.enumerated() {
            let segment = base.voiceLab.segments[index]
            let selected = segment.selectedCandidateIndex
            guard segment.enabled, segment.candidates.indices.contains(selected), var recipe = segment.candidates[selected].recipe,
                  recipe.video.mode == .lipsync, let start = recipe.video.windowStartSample, let end = recipe.video.windowEndSample else {
                throw ClipTakePlan.Failure.noLipsyncOffer
            }
            sources.append(.init(startSample: start, endSample: end, phraseIDs: [part]))
            recipe.video = recipe.video.lipsyncBase
            base.voiceLab.segments[index].candidates[selected].recipe = recipe
        }
        base.voiceLab.wholeClipRevoices?.removeAll { $0.id == record.id }
        if base.voiceLab.wholeClipRevoices?.isEmpty == true { base.voiceLab.wholeClipRevoices = nil }
        let output = try VoiceLabOutputPlanner.build(base, scope: scope)
        guard let video = base.media.source.video else { throw LipsyncPreparationError.unsupportedVideo }
        let windows = try LipsyncRenderWindow.jobs(windows: sources, plan: output)
        for window in windows { try LipsyncWindowPreparation.preflight(video: video, outputSeconds: window.seconds(sampleRate: output.sampleRate)) }
        self.record = record; self.base = base; self.indices = indices; self.windows = windows
        self.output = output; self.catalog = catalog
    }

    func estimate(_ model: WholeClipRevoice.Lipsync) throws -> CostEstimate {
        let estimates = try windows.map {
            try WholeClipRevoice.lipsyncPrice(videoSeconds: $0.uploadSeconds(sampleRate: output.sampleRate), lipsync: model, catalog: catalog)
        }
        guard let first = estimates.first, estimates.allSatisfy({ $0.usd != nil }) else { throw ClipTakePlan.Failure.unknownSpend }
        return CostEstimate(provider: first.provider, operation: first.operation, units: estimates.reduce(0) { $0 + $1.units },
                            unit: first.unit, usd: estimates.reduce(Decimal(0)) { $0 + ($1.usd ?? 0) }, basis: first.basis)
    }

    func pictureProject(_ entries: [Int: RewriteLipsyncSession.Applied]) throws -> (Project, [VoiceLabVideoAsset]) {
        var project = base
        var assets: [VoiceLabVideoAsset] = []
        for (part, index) in indices.enumerated() {
            let selected = project.voiceLab.segments[index].selectedCandidateIndex
            guard let entry = entries[part], var recipe = project.voiceLab.segments[index].candidates[selected].recipe else {
                throw WholeClipRevoiceSession.Stop.lipsyncMissing
            }
            let result = entry.result
            recipe.video = recipe.video.addingLipsync(assetID: result.asset.id, requestID: result.provenance.requestID,
                sourceWindow: entry.window.source, syncMode: result.provenance.syncMode, model: result.provenance.model)
            project.voiceLab.segments[index].candidates[selected].recipe = recipe
            if !assets.contains(where: { $0.id == result.asset.id }) { assets.append(result.asset) }
        }
        project.voiceLab.videoAssets = (project.voiceLab.videoAssets ?? []) + assets.filter { asset in
            base.voiceLab.videoAssets?.contains(where: { $0.id == asset.id }) != true
        }
        return (project, assets)
    }
}

extension RewriteSession {
    func wholeClipPictureRedoSource(_ record: WholeClipRevoiceRecord) throws -> WholeClipPictureRedo {
        guard wholeClipReplacement != nil, let catalog = wholeClipCatalog else { throw ClipTakePlan.Failure.noLipsyncOffer }
        return try WholeClipPictureRedo(record: record, project: editor.project, scope: scope, catalog: catalog)
    }

    func configurePictureRedo(_ session: WholeClipRevoiceSession, source: WholeClipPictureRedo) {
        let lipsync = RewriteLipsyncSession()
        lipsync.automaticallyRefreshOffers = false
        lipsync.backend = lipsyncBackend(redoVersion: "picture-\(source.record.id)", wholeClip: { [weak session] in session })
        let stillCurrent = wholeClipInputsStillCurrent()
        let isCurrent: @MainActor () -> Bool = { [weak self] in
            stillCurrent() && self?.usedWholeClip == source.record
        }
        session.backend?.voiceCurrent = { _ in isCurrent() }
        session.backend?.lipsyncPrice = { try source.estimate($0).usd }
        session.backend?.appliedLipsync = { lipsync.applied }
        var latestOffer: RewriteLipsyncSession.Offer?
        session.backend?.restoreLipsync = { entries in
            guard isCurrent(), !entries.isEmpty else { return false }
            if entries.allSatisfy({ lipsync.applied[$0.key]?.result.asset.id == $0.value.result.asset.id }) { return true }
            return lipsync.restore(entries, matching: latestOffer)
        }
        session.backend?.lipsync = { [weak self, weak session] _, factor, model, progress in
            guard let self, let session, isCurrent() else { throw WholeClipRevoiceSession.Stop.rewriteChanged(clip: 1) }
            let request = try await durationRenderPreparer()(source.base, scope)
            let dependencies = Set(source.indices.indices)
            let offer = RewriteLipsyncSession.Offer(id: UUID(), request: request, windows: source.windows, estimate: try source.estimate(model),
                recordID: source.record.consentRecordId, dependencies: dependencies, isCurrent: isCurrent, model: model)
            latestOffer = offer
            for phrase in Array(lipsync.applied.keys) { lipsync.undo(phrase) }
            var prepared = await lipsync.priceIndexed(offer)
            prepared.mayPay = session.lipsyncMayPay
            if prepared.mayPay, let approved = session.redoLipApproval, prepared.chargeUSD.map({ $0 <= approved }) != true {
                throw WholeClipRevoiceSession.LipsyncFailed(error: ClipTakePlan.Failure.unknownSpend, local: true)
            }
            return try await runWholeClipLipsync(lipsync, offer: prepared, factor: factor, progress: progress)
        }
        session.backend?.match = { _ in source.record.match }
        session.backend?.play = { [weak self] original in
            guard let self else { return }
            if original { playUsedWholeClip(original: true); return }
            Task {
                do {
                    guard isCurrent() else { throw CancellationError() }
                    let (preview, _) = try source.pictureProject(lipsync.applied)
                    try await editor.preview.load(durationRenderPreparer()(preview, scope))
                    try await editor.preview.seek(to: 0, exact: true)
                    editor.preview.play()
                } catch { editor.announce("Couldn’t play this version.") }
            }
        }
        session.backend?.use = { [weak self] _, synced, match in
            guard let self, isCurrent(), let replacement = wholeClipReplacement else {
                throw WholeClipRevoiceSession.Stop.rewriteChanged(clip: 1)
            }
            let (project, assets) = try source.pictureProject(lipsync.applied)
            let group = "redo-" + UUID().uuidString.lowercased()
            let segments = source.indices.map { index in
                var segment = project.voiceLab.segments[index]
                segment.id = "redo-" + UUID().uuidString.lowercased()
                if segment.groupId != nil { segment.groupId = group }
                return segment
            }
            let record = WholeClipRevoiceRecord(id: "wholeclip-" + UUID().uuidString.lowercased().prefix(13), clipId: source.record.clipId,
                segmentIds: segments.map(\.id), script: source.record.script, consentRecordId: source.record.consentRecordId,
                videoRetime: synced.factor, lipsyncModel: synced.model.rawValue, usd: NSDecimalNumber(decimal: synced.usd).doubleValue,
                match: match, createdAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
            try commitOwnEdit {
                try editor.applyVoiceLab(segments, assets: [], voice: nil, scope: rewriteScope, videoAssets: assets,
                                         wholeClip: record, replacing: replacement)
            }
            editor.announce("Whole clip revoiced. Undo takes it back.")
            return record
        }
    }

    func holdPictureRedo(_ session: WholeClipRevoiceSession, source: WholeClipPictureRedo, script: WholeClipScript, model: WholeClipRevoice.Lipsync) {
        let record = source.record
        let key = WholeClipRevoiceLedger.VoiceKey(script: script.text, recordId: record.consentRecordId, model: VoiceLabWordingFit.modelID)
        let voice = WholeClipRevoiceSession.Voice(key: key, seconds: source.output.duration, parts: source.indices.count, usd: 0)
        let picture = WholeClipRevoiceSession.Picture(speed: record.videoRetime, outputSeconds: source.output.duration, laidOut: true)
        configurePictureRedo(session, source: source)
        session.holdPictureRedo(script: script, voice: voice, picture: picture, model: model)
    }
}
