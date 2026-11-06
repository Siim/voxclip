#if DEBUG
import Foundation
import VoxClipCore
import VoxClipMedia

// S-voice-rebuild (doc/release.md; voice-lab §6.12, ADR-R44): Settings › Voices "Rebuild from my videos" with the
// scripted ElevenLabs, then a Rewrite that uses the new voice.
// - V1: the owner's two videos (the car video of S-guard-learns and another on the closer mic) are read on this Mac: the
//   row says how much speech from how many videos, with pieces to play, and nothing has been sent.
// - V2: the three boxes, then Rebuild · $0: the plan check, then one creation, settled through the journal; the new
//   voice is bound to the same account and keeps the car video's learned reference, re-checked against its own
//   embedding. The old voice is untouched.
// - V3: Use the new voice for Rewrite: every phrase of the Rewrite is voiced with the new voice, and each phrase's speech
//   passes the voice check against it (phrase 1, recorded in the car, through the carried reference).
// - V4: Remove the old voice, confirmed inline: the existing deletion removes it; the new voice stays.

extension DebugRewriteSmoke {
    static var rebuildScenarios: [Definition] { [
        Definition(id: "S-voice-rebuild", title: "Rebuild from my videos (stubbed), use the new voice for Rewrite: all three phrases voiced with it, references still pass; Remove the old voice",
            voiced: 3, fixture: Fixture(rewrites: [.passage(replace(threeChanges))], voice: RewriteSmokeVoiceScript(offset: -0.2),
                                        ownerPitches: learningPitches)) { harness in
            // Later scenarios share the data folder: they get the fixture's own voice back, and no preference.
            let saved = try harness.saveVoices()
            defer { harness.restoreVoices(saved) }
            let rebuilt = try await harness.rebuildVoice()
            try await harness.start()
            try await harness.finish()
            harness.guardNeverBlocked()
            try await harness.rebuiltVoiceInUse(rebuilt)
            try await harness.removeOldVoice(rebuilt)
        },
    ] }
}

extension DebugRewriteSmoke.Harness {
    struct Rebuilt {
        let voiceLab: VoiceLabSession
        let state: VoiceRebuildState
        let oldID: String
        let newID: String
        let contentKey: String
    }

    /// The consent records and their operation journal: the rebuild adds a voice and deletes the fixture's.
    private var voiceFolders: [URL] {
        ["VoiceLab/consent", "VoiceLab/voice-ops"].map { app.locations.root.appendingPathComponent($0, isDirectory: true) }
    }
    private var rebuildProjects: [URL] { ["smoke-car.voxclip", "smoke-closer.voxclip"].map { app.locations.root.appendingPathComponent($0) } }

    /// A copy of the voices as they are before the rebuild.
    func saveVoices() throws -> URL {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-smoke-voices-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: false)
        for folder in voiceFolders where FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.copyItem(at: folder, to: copy.appendingPathComponent(folder.lastPathComponent))
        }
        return copy
    }

    /// Puts the voices back as they were, clears the Rewrite voice preference and removes the two projects.
    func restoreVoices(_ copy: URL) {
        for folder in voiceFolders {
            try? FileManager.default.removeItem(at: folder)
            let saved = copy.appendingPathComponent(folder.lastPathComponent)
            if FileManager.default.fileExists(atPath: saved.path) { try? FileManager.default.moveItem(at: saved, to: folder) }
        }
        try? FileManager.default.removeItem(at: copy)
        for url in rebuildProjects { try? FileManager.default.removeItem(at: url) }
        app.set(VoiceLabSession.rewriteVoiceKey, .null)
    }

    private func copyVoice(_ fixture: VoiceConsentRecord, store: VoiceConsentStore) async throws -> VoiceConsentRecord {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture)) as? [String: Any] ?? [:]
        object["recordId"] = UUID().uuidString.lowercased(); object["voiceId"] = "fixtureOldVoice"
        let copy = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: object))
        try await store.saveStatement(store.referenceAudio(recordID: fixture.id), recordID: copy.id)
        try await store.save(copy)
        RewriteSmokeHTTP.script.withLock { $0.voices.append(copy.voiceId) }
        return copy
    }

    /// Learns this video's reference, writes the owner's two videos as projects, and rebuilds the voice from them.
    func rebuildVoice() async throws -> Rebuilt {
        guard let store, let editor, let shared = app.shared,
              let fixture = try await store.activeVoices().first(where: { $0.voiceId == "fixtureOwnVoice" }) else {
            throw DebugRewriteSmoke.Failure.setup("no voice or project")
        }
        // The voice rebuilt and then removed is a copy of the fixture's under its own record and voice id: a deleted
        // record's id stays revoked for this process (VoiceDispatchGate), and every later scenario uses the fixture's.
        let old = try await copyVoice(fixture, store: store)
        let project = editor.project
        let contentKey = project.media.source.contentKey
        _ = await VoiceReferenceLearner(store: store, check: .rewriteSmoke)
            .learn(project: project, media: URL(fileURLWithPath: project.media.source.absolutePath), recordID: old.id)
        let root = app.locations.root
        let closer = Dictionary(uniqueKeysWithValues: (0..<8).map { ($0, 135.0) })
        let (other, _) = try await DebugRewriteSmoke.project(DebugRewriteSmoke.Fixture(rewrites: [], ownerPitches: closer), root: root, shared: shared)
        let urls = rebuildProjects
        try ProjectJSON.encode(project).write(to: urls[0]); try ProjectJSON.encode(other).write(to: urls[1])

        let prices = try VoiceLabPriceCatalog(data: Data(contentsOf: shared.root.appendingPathComponent("catalog/voice-lab.json")))
        let client = ElevenLabsVoiceLab.rewriteSmoke(prices: prices, spend: VoiceLabSpendLedger(locations: app.locations))
        let voiceLab = VoiceLabSession(app: app, store: store, reconciler: VoiceOperationReconciler(store: store, client: client))
        voiceLab.stageEnrollmentForTests(client: client, speaker: .rewriteSmoke)
        await voiceLab.load(recover: false)
        voiceLab.findRebuild(recordID: old.id, projects: urls)
        guard let state = voiceLab.rebuilds[old.id] else { throw DebugRewriteSmoke.Failure.setup("no rebuild row") }
        await state.task?.value
        let sent = RewriteSmokeHTTP.script.withLock { $0.requests }
        let found = state.found
        makeItAppend([DebugRewriteSmoke.Check(invariant: "V1",
            passed: state.phase == .found && found?.plan.videoCount == 2 && (found?.samples.count ?? 0) >= 2 && found?.plan.enough == true && sent.isEmpty,
            detail: "\(state.summary.isEmpty ? state.line : "Rebuild with " + state.summary) · \(found?.samples.count ?? 0) pieces to play · "
                + (sent.isEmpty ? "nothing sent" : "sent: " + sent.joined(separator: ", ")))])

        state.ownVoice = true; state.adult = true; state.ownVideosOnly = true
        await state.task?.value
        let title = voiceLab.rebuildTitle(state)
        await voiceLab.approveRebuild(state)
        guard case .created(let newID) = state.phase else { throw DebugRewriteSmoke.Failure.setup("rebuild: \(state.line)") }
        let new = try await store.load(newID)
        let requests = RewriteSmokeHTTP.script.withLock { $0.requests }
        let plan = requests.firstIndex(of: "GET /v1/user/subscription"), created = requests.firstIndex(of: "POST /v1/voices/add")
        let settled = try await store.operations().allSatisfy(\.finished)
        let carried = VoiceSpeakerReferences.usable(new.speaker).map(\.contentKey)
        let oldStill = try await store.load(old.id).status == .active
        let account = try await client.creatorKeyFingerprint()
        let once: Bool = plan != nil && created != nil && plan! < created! && requests.filter { $0 == "POST /v1/voices/add" }.count == 1
        let bound: Bool = new.voiceId == "fixtureRebuiltVoice" && new.status == .active && new.projectConsent != nil && new.creator?.keyFingerprint == account
        makeItAppend([DebugRewriteSmoke.Check(invariant: "V2",
            passed: title == "Rebuild · $0" && once && bound && settled && carried.contains(contentKey) && oldStill,
            detail: "[\(title)] · \(new.voiceName) \(new.voiceId) · \(new.samples.count) samples · journal \(settled ? "settled" : "open") · "
                + "\(carried.count) reference(s) kept\(carried.contains(contentKey) ? " (this video's)" : "") · old voice \(oldStill ? "kept" : "gone")")])
        voiceLab.useRebuiltVoice(state)
        return Rebuilt(voiceLab: voiceLab, state: state, oldID: old.id, newID: newID, contentKey: contentKey)
    }

    /// V3: the Rewrite voiced every phrase with the new voice, and each phrase's speech passes against it.
    func rebuiltVoiceInUse(_ rebuilt: Rebuilt) async throws {
        guard let store, let editor else { throw DebugRewriteSmoke.Failure.setup("no store") }
        let voices = RewriteSmokeHTTP.script.withLock { $0.synthesisVoices }
        let segments = editor.project.voiceLab.segments
        let speech = try lastPlanInputs.map { try VoiceLabTakeRun.guardSpeech($0) }
        let verdicts = await VoiceUseGuard(store: store, check: .rewriteSmoke).screen(contentKey: rebuilt.contentKey, recordID: rebuilt.newID, speech: speech)
        let passed = verdicts.filter { if case .passes = $0 { true } else { false } }.count
        // The carried reference still vouches for the car phrase on its own, one hop from the new voice's embedding.
        let record = try await store.load(rebuilt.newID)
        let references = VoiceSpeakerReferences.usable(record.speaker).filter { $0.contentKey == rebuilt.contentKey }
        guard let first = speech.first else { throw DebugRewriteSmoke.Failure.setup("no phrase speech") }
        let car = try await VoiceSpeakerCheck.rewriteSmoke.embedding(first)
        let referenceScore = try references.map { try VoiceSpeakerCheck.cosine($0.embedding, car) }.max() ?? -1
        let throughReference = referenceScore >= record.speaker.threshold
        makeItAppend([DebugRewriteSmoke.Check(invariant: "V3",
            passed: completed && !voices.isEmpty && voices.allSatisfy { $0 == "fixtureRebuiltVoice" } && segments.count == 3
                && segments.allSatisfy { $0.provenance.voiceId == "fixtureRebuiltVoice" && $0.provenance.consentRecordId == rebuilt.newID }
                && !verdicts.isEmpty && passed == verdicts.count && throughReference,
            detail: "\(voices.count) takes, voice \(Set(voices).sorted().joined(separator: ", ")) · \(segments.count) segments · voice check "
                + "\(passed)/\(verdicts.count) pass · the carried reference alone scores the car phrase \(String(format: "%.2f", referenceScore))")])
    }

    /// V4: Remove the old voice after its inline confirmation; the new voice stays.
    func removeOldVoice(_ rebuilt: Rebuilt) async throws {
        guard let store else { throw DebugRewriteSmoke.Failure.setup("no store") }
        rebuilt.state.confirmingRemoval = true
        await rebuilt.voiceLab.removeOldVoice(rebuilt.state)
        let old = try await store.load(rebuilt.oldID), new = try await store.load(rebuilt.newID)
        let deleted = RewriteSmokeHTTP.script.withLock { $0.requests }.contains("DELETE /v1/voices/\(old.voiceId)")
        makeItAppend([DebugRewriteSmoke.Check(invariant: "V4",
            passed: deleted && old.status == .deleted && new.status == .active && rebuilt.state.removed
                && app.string(VoiceLabSession.rewriteVoiceKey) == rebuilt.newID,
            detail: "old voice \(old.status.rawValue)\(deleted ? " (deleted in the account)" : "") · new voice \(new.status.rawValue) · \(rebuilt.state.line)")])
    }
}
#endif
