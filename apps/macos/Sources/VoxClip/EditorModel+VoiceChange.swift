import Foundation
import AVFoundation
import VoxClipCore
import VoxClipMedia

extension VoiceChangeSession {
    struct Services {
        let recordLanguage: @MainActor (VoiceConsentRecord) -> String
        let quotePolicy: @MainActor (VoiceConsentRecord) throws -> OwnVoicePolicy
        let convert: @MainActor (ElevenLabsVoiceLab, Prepared, Request, VoiceLabVoiceChoice,
            @escaping VoiceLabTakeDispatchBoundary, @escaping @Sendable (UUID) async -> Void) async throws -> VoiceLabAudioResult
        let finish: @MainActor (Snapshot, Prepared, [Output], URL) async throws -> Payload
        let audition: @MainActor (VoiceLabRenderInput) throws -> Void
        let stopAudition: @MainActor () -> Void
        let prepareAudition: @MainActor (Snapshot, VoiceLabRenderInput) async throws -> Void
    }

    static func productionServices(scratchRoot: URL, isCurrent: @escaping @MainActor @Sendable () -> Bool,
                                   stopSource: @escaping @MainActor () -> Void) -> Services {
        let playback = VoiceChangePlayback()
        return Services(recordLanguage: { $0.language }, quotePolicy: { record in
            OwnVoicePolicy(recordID: record.id, cloneVoiceID: record.voiceId, recordActive: record.status == .active,
                providerConsentGranted: true, statementVerified: record.consentMethod == .recordedStatement,
                speakerMatched: true, consentMethod: record.consentMethod)
        }, convert: { client, prepared, request, choice, boundary, accepted in
            try await client.convert(audio: request.audio, modelID: prepared.modelID, voice: choice,
                language: prepared.record.language, seed: prepared.seed, cleanAudioOn: false,
                requestID: request.quote.requestID, authorization: VoiceLabAuthorization(quote: request.quote, approved: true),
                dispatchIfCurrent: boundary, accepted: accepted)
        }, finish: { snapshot, prepared, outputs, paidRoot in
            let result = try await VoiceChangeFinisher.finish(project: snapshot.project, scope: snapshot.outputScope,
                window: snapshot.window, record: prepared.record, modelID: prepared.modelID, seed: prepared.seed,
                requests: prepared.requests.map { VoiceChangeFinisher.Request(sourceRange: $0.sourceRange, audio: $0.audio, quote: $0.quote) },
                outputs: outputs.map { VoiceChangeFinisher.Output(requestID: $0.requestID, asset: $0.asset, receipt: $0.receipt) },
                paidRoot: paidRoot, scratchRoot: scratchRoot, isCurrent: { await isCurrent() })
            return Payload(segments: result.segments, assets: result.assets, voice: result.voice)
        }, audition: { stopSource(); try playback.play($0) }, stopAudition: { playback.stop() }, prepareAudition: { snapshot, input in
            guard isCurrent() else { throw Failure.stale }
            try await playback.prepare(input: input, source: snapshot.source, scratchRoot: scratchRoot)
            guard isCurrent() else { playback.stop(); throw Failure.stale }
        })
    }

    static func makeSnapshot(project: Project, scope: RewriteScope, envelope: AudioEnvelope) throws -> Snapshot {
        guard let transcript = project.transcript, !transcript.words.isEmpty,
              let audio = project.media.source.audio, audio.sampleRate > 0,
              project.media.source.durationSeconds.isFinite, project.media.source.durationSeconds > 0,
              project.voiceLab.cleanAudio?.mode != .on else { throw Failure.unsupportedScope }
        let rate = Double(audio.sampleRate), words = transcript.words
        let totalValue = EditingPrimitives.jsRound(project.media.source.durationSeconds * rate)
        guard totalValue > 0, totalValue < 0x1p53, envelope.sampleRate == rate,
              abs(envelope.frameSeconds - 0.01) < 1e-12, envelope.levels.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw VoiceLabError.invalidInput }
        let total = Int64(totalValue)
        let frame = max(1, Int(EditingPrimitives.jsRound(rate * 0.01)))
        guard envelope.levels.count == Int(total) / frame else { throw VoiceLabError.invalidInput }
        let indices: [Int]
        let output: VoiceLabOutputScope
        let start: Int64, end: Int64
        switch scope {
        case .fullTake:
            guard project.edits.activeClipId == nil, project.edits.cutWordIds.isEmpty,
                  project.edits.cutPauseIds.isEmpty else { throw Failure.unsupportedScope }
            indices = words.indices.filter { words[$0].kind == .word }
            output = .full; start = 0; end = total
            let plan = try VoiceLabOutputPlanner.build(project, scope: output)
            guard plan.pieces.allSatisfy({ $0.kind == .source }), plan.outputSamples == total else { throw Failure.unsupportedScope }
        case .selection(let range):
            guard range.lowerBound >= 0, range.upperBound < words.count else { throw Failure.unsupportedScope }
            indices = range.filter { words[$0].kind == .word }
            guard let first = indices.first, let last = indices.last,
                  !words[range].contains(where: { project.edits.cutWordIds.contains($0.id) }) else { throw Failure.unsupportedScope }
            output = project.edits.activeClipId.map(VoiceLabOutputScope.clip) ?? .full
            let priorEnd = first == 0 ? 0 : words[first - 1].end
            let nextStart = last + 1 == words.count ? project.media.source.durationSeconds : words[last + 1].start
            start = Int64(EditingPrimitives.jsRound(max(0, max(priorEnd, words[first].start - 0.1)) * rate))
            end = Int64(EditingPrimitives.jsRound(min(project.media.source.durationSeconds, min(nextStart, words[last].end + 0.1)) * rate))
        case .clip: throw Failure.unsupportedScope
        }
        guard let first = indices.first, let last = indices.last, start >= 0, end <= total, end > start,
              !project.voiceLab.segments.contains(where: { $0.enabled && $0.replace.start < Double(end) / rate && $0.replace.end > Double(start) / rate })
        else { throw Failure.unsupportedScope }
        func seam(_ position: Int64) -> VoiceLabSeamPlacement {
            let edge = position == 0 || position == total
            return VoiceLabSeamPlacement(kind: edge ? .none : .hard, time: Double(position) / rate, sample: position,
                fadeSamples: edge ? 0 : Int64(EditingPrimitives.jsRound(0.012 * rate)))
        }
        let window = VoiceLabWindow(firstWordId: words[first].id, lastWordId: words[last].id,
            leftBridgeWordIds: [], rightBridgeWordIds: [], start: Double(start) / rate, end: Double(end) / rate,
            startSample: start, endSample: end, leftSeam: seam(start), rightSeam: seam(end))
        let pauses = try detectPauses(words, thresholdSeconds: project.edits.pauseThresholdSeconds)
        guard !pauses.contains(where: { project.edits.cutPauseIds.contains($0.id) && $0.start < window.end && $0.end > window.start }) else {
            throw Failure.unsupportedScope
        }
        try VoiceLabRenderContract.validatePlacement(project, scope: output, window: window)
        return Snapshot(project: project, scope: scope, outputScope: output,
            source: URL(fileURLWithPath: project.media.source.absolutePath), window: window, envelope: envelope)
    }

    static func chunkRanges(_ snapshot: Snapshot) throws -> [Range<Int64>] {
        let rate = Int64(snapshot.sampleRate)
        guard rate > 0, rate <= 192_000 else { throw VoiceLabError.invalidInput }
        let maximum = min(290 * rate, (50_000_000 - 1 - 44) / 2) - Int64(EditingPrimitives.jsRound(0.020 * Double(rate)))
        let frame = Int64(EditingPrimitives.jsRound(Double(rate) * snapshot.envelope.frameSeconds))
        let words = snapshot.project.transcript?.words ?? []
        var cursor = snapshot.window.startSample
        var result: [Range<Int64>] = []
        while cursor < snapshot.window.endSample {
            var end = min(snapshot.window.endSample, cursor + maximum)
            if end < snapshot.window.endSample {
                let target = cursor + maximum - 10 * rate
                let gaps = zip(words, words.dropFirst()).compactMap { left, right -> Range<Int64>? in
                    guard right.start - left.end >= 0.4 else { return nil }
                    let lower = max(cursor + frame, Int64(EditingPrimitives.jsRound(left.end * Double(rate))))
                    let upper = min(end, Int64(EditingPrimitives.jsRound(right.start * Double(rate))))
                    return upper > lower ? lower..<upper : nil
                }
                guard let gap = gaps.min(by: { abs(($0.lowerBound + $0.upperBound) / 2 - target) < abs(($1.lowerBound + $1.upperBound) / 2 - target) }) else {
                    throw Failure.unsupportedScope
                }
                let firstFrame = Int((gap.lowerBound + frame - 1) / frame)
                let lastFrame = min(snapshot.envelope.levels.count, Int(gap.upperBound / frame))
                guard firstFrame < lastFrame,
                      let quietest = (firstFrame..<lastFrame).min(by: { left, right in
                          let leftLevel = snapshot.envelope.levels[left], rightLevel = snapshot.envelope.levels[right]
                          if leftLevel != rightLevel { return leftLevel < rightLevel }
                          return abs(Int64(left) * frame - target) < abs(Int64(right) * frame - target)
                      }) else { throw VoiceLabError.invalidInput }
                end = Int64(quietest) * frame
            }
            guard end > cursor, end - cursor <= maximum else { throw VoiceLabError.invalidInput }
            result.append(cursor..<end); cursor = end
        }
        return result
    }

    static func uploadRange(body: Range<Int64>, index: Int, count: Int, snapshot: Snapshot) throws -> Range<Int64> {
        guard index >= 0, index < count, body.lowerBound >= snapshot.window.startSample,
              body.upperBound <= snapshot.window.endSample, !body.isEmpty else { throw VoiceLabError.invalidInput }
        let internalFade = Int64(EditingPrimitives.jsRound(0.020 * Double(snapshot.sampleRate)))
        let incoming = index == 0 ? snapshot.window.leftSeam.fadeSamples : internalFade
        let outgoing = index + 1 == count ? snapshot.window.rightSeam.fadeSamples : internalFade
        let total = Int64(EditingPrimitives.jsRound(snapshot.project.media.source.durationSeconds * Double(snapshot.sampleRate)))
        return max(0, body.lowerBound - incoming / 2)..<min(total, body.upperBound + outgoing - outgoing / 2)
    }
}

actor VoiceChangePinnedKeys: KeyProvider {
    private let source: any KeyProvider
    private var fingerprint: String?
    init(source: any KeyProvider) { self.source = source }
    func key(for provider: String) async throws -> String? {
        guard provider == "elevenlabs", let key = try await source.key(for: provider), !key.isEmpty else {
            throw VoiceLabError.missingKey
        }
        let observed = VoiceLabFingerprint.bytes(Data(key.utf8))
        guard fingerprint == nil || fingerprint == observed else { throw VoiceConsentError.creatorMismatch }
        fingerprint = observed
        return key
    }
}

@MainActor private final class VoiceChangePlayback {
    private var input: VoiceLabRenderInput?
    private var lease: VoiceLabRenderLease?
    private var player: AVAudioPlayer?
    func prepare(input: VoiceLabRenderInput, source: URL, scratchRoot: URL) async throws {
        stop()
        let staged = try await VoiceChangeFinisher.prepareAudition(input: input, source: source, scratchRoot: scratchRoot)
        try Task.checkCancellation()
        let audio = try AVAudioPlayer(contentsOf: staged.mixedAudioURL)
        guard audio.prepareToPlay() else { throw VoiceLabError.invalidAudio }
        self.input = input; lease = staged; player = audio
    }
    func play(_ input: VoiceLabRenderInput) throws {
        guard self.input == input, lease != nil, let player else { throw VoiceChangeSession.Failure.invalidReview }
        player.currentTime = 0
        guard player.play() else { throw VoiceLabError.invalidAudio }
    }
    func stop() { player?.stop() }
}

@MainActor private final class VoiceChangeInventory {
    var choices: VoiceChangeSession.Choices?
    var creator: String?
    var activity: VoiceLabAssetActivity?
}

private struct VoiceChangeSourcePin: Equatable {
    let size: Int64
    let modified: Date
    let inode: UInt64
    let device: UInt64
    init(_ url: URL) throws {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeRegular,
              let size = values[.size] as? NSNumber, let modified = values[.modificationDate] as? Date,
              let inode = values[.systemFileNumber] as? NSNumber, let device = values[.systemNumber] as? NSNumber else {
            throw VoiceChangeSession.Failure.stale
        }
        self.size = size.int64Value; self.modified = modified; self.inode = inode.uint64Value; self.device = device.uint64Value
    }
}

extension EditorModel {
    var voiceChangeSelection: RewriteScope? {
        guard selectedPauseIDs.isEmpty else { return nil }
        let indices = words.indices.filter { selectedWordIDs.contains(words[$0].id) }
        guard let first = indices.first, let last = indices.last,
              words[first...last].filter({ $0.kind == .word }).allSatisfy({ selectedWordIDs.contains($0.id) }) else { return nil }
        return .selection(first...last)
    }

    func openVoiceChange(scope: RewriteScope) async {
        if voiceChange == nil, let recovery = VoiceChangeSession.recoverable(for: project).first {
            voiceChange = recovery
            app.shell.choosePanelJob(.voice, for: self)
            announce("Paid audio still needs a local save. Retry Saving Locally before making another conversion.")
            return
        }
        guard voiceChange == nil, !isLeaving, app.voiceLabRewriteEnabled, capabilities.writable,
              capabilities.edit, capabilities.media, !capabilities.exporting, !capabilities.aiBusy else {
            announce("Finish the current voice review, or turn on Voice Lab in Settings first."); return
        }
        let original = project, selection = selectedWordIDs, pauses = selectedPauseIDs
        let region = ElevenLabsRegion(rawValue: app.string("transcription.elevenlabs.region", fallback: "default")) ?? .default
        let source = URL(fileURLWithPath: original.media.source.absolutePath)
        do {
            let pin = try VoiceChangeSourcePin(source)
            let stillCurrent: @MainActor @Sendable () -> Bool = { [weak self] in
                guard let self else { return false }
                return !isLeaving && project == original && selectedWordIDs == selection && selectedPauseIDs == pauses && app.voiceLabRewriteEnabled &&
                    capabilities.writable && capabilities.edit && capabilities.media && !capabilities.exporting && !capabilities.aiBusy &&
                    app.string("transcription.elevenlabs.region", fallback: "default") == region.rawValue &&
                    (try? VoiceChangeSourcePin(source)) == pin
            }
            if !app.bool("voiceLab.providerConsent.elevenlabs") {
                guard !sendConfirmation.isPresented else { announce("Finish the open permission request first."); return }
                var prompt = ConnectorSendPrompt(reason: .privacy, title: "Allow ElevenLabs", message: VoiceLabSession.providerCopy,
                    confirm: "Allow ElevenLabs")
                prompt.firstUse = true; prompt.providerID = "elevenlabs"; prompt.providerName = "ElevenLabs"
                prompt.details = ["Opening this review sends nothing. Loading voices checks your account; source audio still needs a separate exact quote and approval."]
                let allowed = await sendConfirmation.present(prompt, isCurrent: stillCurrent) { [app] value in
                    try await app.secrets.save(value, for: "elevenlabs")
                }
                guard allowed, stillCurrent(), voiceChange == nil else { return }
                app.set("voiceLab.providerConsent.elevenlabs", .bool(true))
            }
            guard stillCurrent(), app.speakerModelLibrary.installed, let audio = original.media.source.audio else {
                announce("The local own-voice check and source audio must be ready first. Nothing was sent."); return
            }
            let envelope = try await VoiceLabSourceAudio.sourceEnvelope(source: source,
                durationSeconds: original.media.source.durationSeconds, sampleRate: audio.sampleRate)
            try Task.checkCancellation()
            guard stillCurrent(), voiceChange == nil else { return }
            _ = try VoiceChangeSession.makeSnapshot(project: original, scope: scope, envelope: envelope)
            let speaker = try await app.speakerModelLibrary.check(language: original.transcript?.language ?? "en")
            try Task.checkCancellation()
            guard stillCurrent(), voiceChange == nil else { return }
            let client = ElevenLabsVoiceLab(keys: VoiceChangePinnedKeys(source: app.secrets), region: region, logger: app.log,
                spend: VoiceLabSpendLedger(locations: app.locations))
            let services = VoiceChangeSession.productionServices(
                scratchRoot: app.locations.root.appendingPathComponent("VoiceLabScratch", isDirectory: true),
                isCurrent: { [weak self] in stillCurrent() && self?.app.bool("voiceLab.providerConsent.elevenlabs") == true },
                stopSource: { [weak self] in self?.preview.pause(); self?.isPlaying = false })
            voiceChange = try makeVoiceChangeSession(scope: scope, envelope: envelope, client: client,
                store: VoiceConsentStore(locations: app.locations), speaker: speaker, services: services,
                accountIsCurrent: { [weak self] in stillCurrent() && self?.app.speakerModelLibrary.installed == true })
            app.shell.choosePanelJob(.voice, for: self)
            if app.shell.editor === self, !app.shell.viewerShown { app.shell.toggleViewer() }
            announce(scope == .fullTake ? "Change Full Take Voice. Nothing was sent." : "Change Passage Voice. Nothing was sent.")
        } catch { announce(VoiceChangeSession.copy(error)) }
    }

    func closeVoiceChange() {
        guard let session = voiceChange, session.close() else { return }
        voiceChange = nil
    }

    func makeVoiceChangeSession(scope: RewriteScope, envelope: AudioEnvelope, client: ElevenLabsVoiceLab,
                                store: VoiceConsentStore, speaker: VoiceSpeakerCheck,
                                services: VoiceChangeSession.Services,
                                accountIsCurrent: @escaping @MainActor () -> Bool) throws -> VoiceChangeSession {
        guard app.voiceLabRewriteEnabled, app.bool("voiceLab.providerConsent.elevenlabs"), !isLeaving,
              capabilities.writable, capabilities.edit, capabilities.media, !capabilities.exporting, !capabilities.aiBusy else {
            throw VoiceLabError.consentRequired
        }
        let snapshot = try VoiceChangeSession.makeSnapshot(project: project, scope: scope, envelope: envelope)
        let sourcePin = try VoiceChangeSourcePin(snapshot.source)
        guard sourcePin.size == project.media.source.sizeBytes else { throw VoiceChangeSession.Failure.stale }
        let selection = selectedWordIDs, pauses = selectedPauseIDs
        let paidRoot = app.locations.root.appendingPathComponent("VoiceLab", isDirectory: true)
        let inventory = VoiceChangeInventory()
        let useGuard = VoiceUseGuard(store: store, check: speaker)
        let clock = VoiceLabQuoteClock.continuousSource()
        let current: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return !isLeaving && project == snapshot.project && selectedWordIDs == selection && selectedPauseIDs == pauses && app.voiceLabRewriteEnabled &&
                app.bool("voiceLab.providerConsent.elevenlabs") && capabilities.writable && capabilities.edit && capabilities.media &&
                !capabilities.exporting && !capabilities.aiBusy && accountIsCurrent() &&
                (try? VoiceChangeSourcePin(snapshot.source)) == sourcePin
        }
        let validateRecord: @MainActor (VoiceConsentRecord) async throws -> Void = { record in
            guard current(), record.recordedRegion == client.region,
                  let expected = record.creator?.keyFingerprint else { throw VoiceConsentError.creatorMismatch }
            let creator = try await client.creatorKeyFingerprint()
            guard creator == inventory.creator, creator == expected, current() else { throw VoiceConsentError.creatorMismatch }
            try await store.validateUse(record)
            guard try await store.load(record.id) == record, current() else { throw VoiceChangeSession.Failure.stale }
        }
        let backend = VoiceChangeSession.Backend(discover: { snapshot in
            guard current(), speaker.available else { throw VoiceConsentError.speakerUnavailable }
            let creator = try await client.creatorKeyFingerprint()
            guard current() else { throw VoiceChangeSession.Failure.stale }
            let models = try await client.models().filter { $0.canConvert && $0.languages.contains(snapshot.language) }
            guard current() else { throw VoiceChangeSession.Failure.stale }
            let remote = try await client.listOwnClones(creatorKeyFingerprint: creator)
            guard current() else { throw VoiceChangeSession.Failure.stale }
            let voices = try await store.activeVoices().filter { record in
                services.recordLanguage(record) == snapshot.language && record.recordedRegion == client.region &&
                    record.creator?.keyFingerprint == creator && remote.contains { voice in
                        voice.id == record.voiceId && voice.isOwner && voice.category == "cloned" && (!voice.requiresVerification || voice.isVerified)
                    }
            }
            guard current() else { throw VoiceChangeSession.Failure.stale }
            inventory.creator = creator
            let choices = VoiceChangeSession.Choices(voices: voices, models: models)
            inventory.choices = choices
            return choices
        }, prepare: { snapshot, recordID, modelID, seed in
            guard current(), let record = inventory.choices?.voices.first(where: { $0.id == recordID }),
                  inventory.choices?.models.contains(where: { $0.id == modelID }) == true else { throw VoiceLabError.consentRequired }
            try await validateRecord(record)
            guard try JSONProjectStore.contentKey(for: snapshot.source) == snapshot.project.media.source.contentKey else { throw VoiceChangeSession.Failure.stale }
            let ranges = try VoiceChangeSession.chunkRanges(snapshot)
            guard ranges.count <= 32 else { throw VoiceChangeSession.Failure.unsupportedScope }
            inventory.activity = try VoiceLabAssetActivity(paidRoot: paidRoot)
            let started = clock()
            var requests: [VoiceChangeSession.Request] = []
            for (index, range) in ranges.enumerated() {
                try Task.checkCancellation()
                guard current() else { throw VoiceChangeSession.Failure.stale }
                let upload = try VoiceChangeSession.uploadRange(body: range, index: index, count: ranges.count, snapshot: snapshot)
                let wav = try await VoiceLabSourceAudio.conversionInput(source: snapshot.source,
                    startSample: upload.lowerBound, endSample: upload.upperBound, sourceSampleRate: Double(snapshot.sampleRate))
                guard current() else { throw VoiceChangeSession.Failure.stale }
                let choice = VoiceLabVoiceChoice.own(voiceID: record.voiceId, policy: try services.quotePolicy(record))
                let quote = try await client.prepareConversion(audio: wav, modelID: modelID, voice: choice,
                    language: snapshot.language, seed: seed, cleanAudioOn: false, requestID: UUID())
                requests.append(VoiceChangeSession.Request(sourceRange: range, audio: wav, quote: quote))
            }
            try await validateRecord(record)
            return VoiceChangeSession.Prepared(id: UUID(), record: record, modelID: modelID, seed: seed,
                requests: requests, preparedAt: started)
        }, validate: { value in
            try await validateRecord(value.record)
        }, checkSpend: { [weak app] quotes in
            guard current(), let app else { throw VoiceChangeSession.Failure.stale }
            guard let limit = Decimal(string: app.string("voiceLab.monthlyCapUsd.elevenlabs"), locale: Locale(identifier: "en_US_POSIX")) else { return }
            let total = await VoiceLabSpendLedger(locations: app.locations).total(provider: "elevenlabs", at: Date())
            guard current(), let total, total.unknownCount == 0 else { throw ClipTakePlan.Failure.unknownSpend }
            let estimate = VoiceChangeSession.total(quotes.map(\.estimate))
            guard let usd = estimate.usd else { throw ClipTakePlan.Failure.unknownSpend }
            guard total.usd + usd <= limit else { throw ClipTakePlan.Failure.spendingCap }
        }, approve: { prepared in
            try await client.approveConversionBatch(id: prepared.id, quotes: prepared.requests.map(\.quote))
        }, discard: { prepared in
            await client.discardConversionBatch(id: prepared.id, quotes: prepared.requests.map(\.quote))
        }, convert: { prepared, request, boundary, accepted in
            try await validateRecord(prepared.record)
            let policy = try await useGuard.authorizeConversion(quote: request.quote,
                contentKey: snapshot.project.media.source.contentKey, recordID: prepared.record.id, audio: request.audio, approved: true)
            guard current() else { throw VoiceChangeSession.Failure.stale }
            return try await services.convert(client, prepared, request, .own(voiceID: prepared.record.voiceId, policy: policy), boundary, accepted)
        }, preserve: { result, request in
            let asset = try VoiceLabAssetStore.write(pcm16: result.pcm, sampleRate: result.sampleRate,
                projectId: snapshot.project.id, assetId: UUID().uuidString.lowercased(), paidRoot: paidRoot, createdAt: Date())
            return VoiceChangeSession.Output(requestID: request.quote.requestID, asset: asset, receipt: result.receipt)
        }, review: { snapshot, prepared, outputs in
            let payload = try await services.finish(snapshot, prepared, outputs, paidRoot)
            try await validateRecord(prepared.record)
            let review = try Self.prepareVoiceChangeReview(snapshot: snapshot, prepared: prepared, payload: payload,
                paidRoot: paidRoot, services: services)
            guard let media = review.media else { throw VoiceChangeSession.Failure.invalidReview }
            try await services.prepareAudition(snapshot, media)
            guard current() else { throw VoiceChangeSession.Failure.stale }
            return review
        }, chargesChanged: { [weak app] in await app?.refreshMonthlySpend() })
        return VoiceChangeSession(snapshot: snapshot, backend: backend, isCurrent: current, commit: { [weak self] review in
            guard let self, current() else { throw VoiceChangeSession.Failure.stale }
            try commitVoiceChange(review, snapshot: snapshot)
        }, now: clock)
    }

    static func prepareVoiceChangeReview(snapshot: VoiceChangeSession.Snapshot, prepared: VoiceChangeSession.Prepared,
                                        payload: VoiceChangeSession.Payload, paidRoot: URL,
                                        services: VoiceChangeSession.Services) throws -> VoiceChangeSession.Review {
        guard !payload.segments.isEmpty, payload.voice.consentRecordId == prepared.record.id,
              payload.voice.voiceId == prepared.record.voiceId, payload.voice.status == .active,
              payload.segments.allSatisfy({ $0.kind == .voiceChanger && $0.enabled && $0.text == nil && $0.words == nil &&
                  $0.replace.start >= snapshot.window.start && $0.replace.end <= snapshot.window.end &&
                  $0.provenance.voiceId == prepared.record.voiceId && $0.provenance.consentRecordId == prepared.record.id }),
              Set(payload.segments.flatMap { segment in segment.candidates.compactMap(\.recipe).flatMap(\.chunks).map(\.requestId) }) == Set(prepared.requests.map { $0.quote.requestID.uuidString }) else {
            throw VoiceChangeSession.Failure.invalidReview
        }
        let ordered = payload.segments.sorted { $0.replace.start < $1.replace.start }
        var cursor = snapshot.window.startSample
        for segment in ordered {
            let start = Int64(EditingPrimitives.jsRound(segment.replace.start * Double(snapshot.sampleRate)))
            let end = Int64(EditingPrimitives.jsRound(segment.replace.end * Double(snapshot.sampleRate)))
            guard start == cursor, end > start,
                  segment.candidates.allSatisfy({ candidate in
                      guard let recipe = candidate.recipe else { return false }
                      return recipe.seed == prepared.seed && recipe.voiceSource == .own &&
                          recipe.provenance.model == prepared.modelID && recipe.provenance.region == prepared.requests.first?.quote.region.rawValue &&
                          recipe.chunks.allSatisfy { $0.seed == prepared.seed }
                  }) else { throw VoiceChangeSession.Failure.invalidReview }
            cursor = end
        }
        guard cursor == snapshot.window.endSample else { throw VoiceChangeSession.Failure.invalidReview }
        let changed = try VoiceLabEditCommand.acceptAll(segments: payload.segments, assets: payload.assets, voice: payload.voice)
            .applying(to: snapshot.project, outputScope: snapshot.outputScope)
        guard changed.schemaVersion >= snapshot.project.schemaVersion else { throw VoiceChangeSession.Failure.invalidReview }
        let contract = try VoiceLabRenderContract.prepare(changed, scope: snapshot.outputScope, labelPosition: .topRight)
        guard let media = try VoiceLabRenderPreflight.prepare(project: changed, scope: snapshot.outputScope, paidRoot: paidRoot) else {
            throw VoiceChangeSession.Failure.invalidReview
        }
        return VoiceChangeSession.Review(project: changed, contract: contract, media: media,
            play: { try services.audition(media) }, stop: services.stopAudition, verify: {
                guard try JSONProjectStore.contentKey(for: snapshot.source) == snapshot.project.media.source.contentKey else {
                    throw VoiceChangeSession.Failure.stale
                }
                try contract.verify(project: changed, scope: snapshot.outputScope, labelPosition: .topRight)
                guard try VoiceLabRenderPreflight.prepare(project: changed, scope: snapshot.outputScope, paidRoot: paidRoot) != nil else {
                    throw VoiceChangeSession.Failure.invalidReview
                }
            })
    }

    func commitVoiceChange(_ review: VoiceChangeSession.Review, snapshot: VoiceChangeSession.Snapshot) throws {
        var onlyVoiceChanged = snapshot.project
        onlyVoiceChanged.schemaVersion = max(3, snapshot.project.schemaVersion)
        onlyVoiceChanged.voiceLab = review.project.voiceLab
        guard project == snapshot.project, app.voiceLabRewriteEnabled, app.bool("voiceLab.providerConsent.elevenlabs"),
              capabilities.writable, capabilities.edit, capabilities.media, !capabilities.exporting, !capabilities.aiBusy,
              review.project.schemaVersion >= project.schemaVersion, review.project.transcript == project.transcript,
              review.project.edits == project.edits, review.project.media == project.media,
              review.project == onlyVoiceChanged else { throw VoiceChangeSession.Failure.stale }
        try review.verify()
        try review.contract.verify(project: review.project, scope: snapshot.outputScope, labelPosition: review.contract.disclosure.position)
        replace(review.project, name: snapshot.title)
    }
}
