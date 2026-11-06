#if DEBUG
import Foundation
import VoxClipCore
import VoxClipMedia

// A matching voice for each video (doc/release.md; voice-lab §6.13, ADR-R45), with the scripted ElevenLabs and an attested
// anchor voice "siim".
// S-voice-per-video, two projects in sequence:
// - PV1: video 1's first Rewrite asks once, inline: [Match this video · free] [Use siim]. Nothing has been sent.
// - PV2: Match this video makes video 1's voice from its own verified speech (the anchor's consent clip first, so the
//   consent embedding stays the same, through the journal), and every take of the Rewrite uses it.
// - PV3: video 2 runs ✦ Make it postable (the driver ✦ Claude does it all runs too) with the stored answer: it is never
//   asked, video 2's voice is made, video 1's is removed through the deletion, the anchor stays, and video 2's take uses
//   video 2's voice.
// S-voice-per-video-short:
// - PV4: a video with too little of its own clear speech keeps the anchor: nothing is created, the takes use siim, and it
//   says so once.

extension DebugRewriteSmoke {
    /// The base script's first six sentences: under the 30 s of its own speech a video's voice needs, though with the
    /// anchor's 8 s consent clip the set would reach 30 s.
    nonisolated static let shortVideoScript = baseScript.components(separatedBy: ". ").prefix(6).joined(separator: ". ") + "."

    static var videoVoiceScenarios: [Definition] { [
        Definition(id: "S-voice-per-video", title: "a matching voice for each video: asked once, made from video 1, its takes use it; video 2 by ✦ Make it postable makes its own and removes video 1's",
            requiresCompletion: false, fixture: Fixture(rewrites: [.passage(replace(twoChanges))], voice: RewriteSmokeVoiceScript(offset: -0.2))) { harness in
            let saved = try harness.saveVoices()
            let setup = try await harness.videoVoiceSetup()
            defer { harness.endVideoVoices(setup, saved: saved) }
            try await harness.start()
            harness.videoVoiceAsked(setup)
            try await harness.click(["videoVoiceMatch"])
            await setup.voiceLab.videoVoices.values.first?.task?.value
            try await harness.finish()
            let first = try await harness.videoVoiceUsed(setup)
            try await harness.videoVoiceSecondVideo(setup, first: first)
        },
        Definition(id: "S-voice-per-video-short", title: "too little of the video's own speech keeps the anchor and says so once",
            requiresCompletion: false, fixture: Fixture(script: shortVideoScript, rewrites: [.passage(shortVideoScript.replacingOccurrences(of: twoChanges[0].0, with: twoChanges[0].1))],
                voice: RewriteSmokeVoiceScript(offset: -0.2))) { harness in
            let saved = try harness.saveVoices()
            let setup = try await harness.videoVoiceSetup(mode: .match)
            defer { harness.endVideoVoices(setup, saved: saved) }
            try await harness.start()
            try await harness.finish()
            try await harness.videoVoiceShort(setup)
        },
    ] }
}

extension DebugRewriteSmoke.Harness {
    struct VideoVoiceSetup {
        let voiceLab: VoiceLabSession
        let previous: VoiceLabSession
        let anchor: VoiceConsentRecord
        let client: ElevenLabsVoiceLab
    }

    /// The attested anchor "siim" (its consent clip 8 s of the statement's voice), Settings' Rewrite voice, and a Voice Lab
    /// session on the scripted ElevenLabs in place of the app's, with `mode` as the stored answer.
    func videoVoiceSetup(mode: VoicePerVideo.Mode = .ask) async throws -> VideoVoiceSetup {
        guard let store, let shared = app.shared else { throw DebugRewriteSmoke.Failure.setup("no store") }
        let prices = try VoiceLabPriceCatalog(data: Data(contentsOf: shared.root.appendingPathComponent("catalog/voice-lab.json")))
        let client = ElevenLabsVoiceLab.rewriteSmoke(prices: prices, spend: VoiceLabSpendLedger(locations: app.locations))
        let tone = (0..<(8 * 16_000)).map { index -> Float in
            let seconds: Double = Double(index) / 16_000
            return Float(0.1 * sin(2 * Double.pi * 120 * seconds))
        }
        let reference = try VoiceTrainingAudio.wav(tone, rate: 16_000)
        let hash = VoiceLabFingerprint.bytes(reference)
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record-project.json"))) as? [String: Any] ?? [:]
        object["recordId"] = UUID().uuidString.lowercased(); object["voiceId"] = "fixtureAnchorVoice"; object["voiceName"] = "siim (VoxClip)"
        object["samples"] = [["sha256": hash, "seconds": 8, "source": "project", "speakerScore": 1],
                             ["sha256": String(repeating: "1", count: 64), "seconds": 24, "source": "project", "speakerScore": 1]]
        var consent = object["projectConsent"] as? [String: Any] ?? [:]; consent["audioSha256"] = hash; object["projectConsent"] = consent
        let embedding = try await VoiceSpeakerCheck.rewriteSmoke.embedding(VoiceConsentAudio.pcm16k(reference))
        var speaker = object["speaker"] as? [String: Any] ?? [:]
        speaker["model"] = VoiceSpeakerCheck.rewriteSmoke.embedder?.modelID ?? ""; speaker["threshold"] = 0.45
        speaker["embedding"] = VoiceConsentRecord.encodeEmbedding(embedding); object["speaker"] = speaker
        object["creator"] = ["region": "default", "keyFingerprint": try await client.creatorKeyFingerprint()]
        let anchor = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: object))
        try await store.saveReferenceAudio(reference, recordID: anchor.id); try await store.save(anchor)
        RewriteSmokeHTTP.script.withLock { $0.voices.append(anchor.voiceId) }
        app.set(VoiceLabSession.rewriteVoiceKey, .string(anchor.id))
        app.set(VoicePerVideo.settingKey, mode.setting.map(JSONValue.bool) ?? .null)
        let voiceLab = VoiceLabSession(app: app, store: store, reconciler: VoiceOperationReconciler(store: store, client: client))
        voiceLab.stageEnrollmentForTests(client: client, speaker: .rewriteSmoke)
        voiceLab.pendingTakeVoices = { [] }
        await voiceLab.load(recover: false)
        let previous = app.voiceLabSession
        app.voiceLabSession = voiceLab
        return VideoVoiceSetup(voiceLab: voiceLab, previous: previous, anchor: anchor, client: client)
    }

    /// Later scenarios get the app's Voice Lab session, the fixture's voices, no answer and no per-video book back.
    func endVideoVoices(_ setup: VideoVoiceSetup, saved: URL) {
        setup.voiceLab.removalRetry?.cancel()
        app.voiceLabSession = setup.previous
        restoreVoices(saved)
        app.set(VoicePerVideo.settingKey, .null)
        try? FileManager.default.removeItem(at: setup.voiceLab.perVideoStore.url)
    }

    /// PV1: the question, once, inline, with both answers; nothing sent.
    func videoVoiceAsked(_ setup: VideoVoiceSetup) {
        let chips = session?.task.cards.compactMap { card -> NextSteps? in if case .nextSteps(let steps) = card, steps.id == "videoVoice" { steps } else { nil } }.first
        let titles = chips?.chips.map(\.action.title) ?? []
        let sent = RewriteSmokeHTTP.script.withLock { $0.requests }.filter { $0 == "POST /v1/voices/add" }
        makeItAppend([DebugRewriteSmoke.Check(invariant: "PV1",
            passed: titles == ["Match this video · free", "Use siim"] && chips?.line?.hasPrefix(VoiceLabSession.videoVoiceQuestion) == true && sent.isEmpty,
            detail: (chips?.line ?? "no question") + " · [" + titles.joined(separator: "] [") + "]" + (sent.isEmpty ? " · nothing sent" : " · a voice was created"))])
    }

    struct VideoVoice {
        let recordID: String
        let voiceID: String
        let contentKey: String
    }

    /// PV2: video 1's own voice, made through the attested creation with the anchor's consent clip first; every take used it.
    func videoVoiceUsed(_ setup: VideoVoiceSetup) async throws -> VideoVoice {
        guard let store, let editor else { throw DebugRewriteSmoke.Failure.setup("no store") }
        let key = editor.project.media.source.contentKey
        guard let video = setup.voiceLab.perVideoBook.video(key) else {
            throw DebugRewriteSmoke.Failure.setup("no voice for video 1: \(setup.voiceLab.videoVoices[key]?.line ?? "")")
        }
        let record = try await store.load(video.recordId)
        let requests = RewriteSmokeHTTP.script.withLock { $0.requests }
        let voices = RewriteSmokeHTTP.script.withLock { $0.synthesisVoices }
        let segments = editor.project.voiceLab.segments
        let settled = try await store.operations().allSatisfy(\.finished)
        let linked = record.projectConsent?.audioSha256 == setup.anchor.projectConsent?.audioSha256 && record.speaker.embedding == setup.anchor.speaker.embedding
            && video.anchorId == setup.anchor.id && record.attestations == setup.anchor.attestations
        let created = requests.filter { $0 == "POST /v1/voices/add" }.count == 1
        let used = completed && !voices.isEmpty && voices.allSatisfy { $0 == record.voiceId } && !segments.isEmpty
            && segments.allSatisfy { $0.provenance.consentRecordId == record.id }
        makeItAppend([DebugRewriteSmoke.Check(invariant: "PV2",
            passed: created && settled && linked && record.status == .active && used && setup.voiceLab.videoVoiceMode == .match,
            detail: "\(record.voiceName) \(record.voiceId) · \(VoiceRebuild.amount(Int(video.videoSeconds * 1_000))) of video 1 · journal \(settled ? "settled" : "open") · "
                + (linked ? "the anchor's consent clip and embedding" : "not linked to the anchor") + " · \(voices.count) takes with \(Set(voices).sorted().joined(separator: ", "))"
                + " · \(segments.count) segments" + (completed ? "" : " · Rewrite not applied"))])
        return VideoVoice(recordID: record.id, voiceID: record.voiceId, contentKey: key)
    }

    /// PV3: video 2 by ✦ Make it postable with the stored answer: never asked, its own voice made, video 1's removed.
    func videoVoiceSecondVideo(_ setup: VideoVoiceSetup, first: VideoVoice) async throws {
        guard let store else { throw DebugRewriteSmoke.Failure.setup("no store") }
        // A second video: the same script, recorded on another microphone (the scripted voice check's 135 Hz, 35° away).
        // The account outlives the project: its voices and the ids it has handed out stay.
        let (listed, created) = RewriteSmokeHTTP.script.withLock { ($0.voices, $0.created) }
        session?.close(); editor?.closeRewrite(returnFocus: false)
        try await open(DebugRewriteSmoke.Fixture(rewrites: [], voice: RewriteSmokeVoiceScript(offset: -0.2),
                                                ownerPitches: Dictionary(uniqueKeysWithValues: (0..<8).map { ($0, 135.0) })))
        RewriteSmokeHTTP.script.withLock { $0.voices = listed; $0.created = created }
        let before = RewriteSmokeHTTP.script.withLock { $0.synthesisVoices.count }
        let editor = try makeItPrepare { range, words in
            guard let start = DebugRewriteSmoke.wordIndex("record", in: words, from: range.lowerBound),
                  let end = DebugRewriteSmoke.wordIndex("take.", in: words, from: start) else { return nil }
            return DebugRewriteSmoke.makeItPlan(span: range, cut: nil, rewrite: (start...end, "film quick footage at once."),
                                                zoom: nil, music: false, score: 8, title: "Edit video like a doc")
        }
        let words = editor.project.transcript?.words ?? []
        guard let start = DebugRewriteSmoke.wordIndex("first", in: words), let end = DebugRewriteSmoke.wordIndex("drag.", in: words, from: start) else {
            throw DebugRewriteSmoke.Failure.setup("the script lost its second to fourth sentences")
        }
        editor.apply(.addClip(ClipRange(id: "smoke-clip", startWordId: words[start].id, endWordId: words[end].id, title: "Smoke clip",
                                        origin: .manual, selected: true)), name: "Make clip")
        _ = editor.setScope("smoke-clip")
        await editor.makeIt.refreshVoiceReady(editor)
        try await act("click [\(editor.makeItTitle(clipID: "smoke-clip"))]", clicked: "makeIt") {
            editor.makeItPostable("smoke-clip")
            await editor.makeIt.run(for: "smoke-clip")?.task?.value
        }
        ended = true
        let key = editor.project.media.source.contentKey
        let video = setup.voiceLab.perVideoBook.video(key)
        let second = video.flatMap { video in setup.voiceLab.records.first { $0.id == video.recordId } }
        let old = try await store.load(first.recordID), anchor = try await store.load(setup.anchor.id)
        // Since video 2 opened (the scripted account's request log starts again with each project).
        let requests = RewriteSmokeHTTP.script.withLock { $0.requests }
        let voices = Array(RewriteSmokeHTTP.script.withLock { $0.synthesisVoices }.dropFirst(before))
        let asked = steps.contains { step in step.snapshot.controls.contains { $0.id == "videoVoiceMatch" || $0.id == "videoVoiceAnchor" } && step.action.contains("Make it") }
        let removed = requests.contains("DELETE /v1/voices/\(first.voiceID)") && old.status == .deleted
        let made = second.map { $0.status == .active && $0.id != first.recordID && $0.speaker.embedding == setup.anchor.speaker.embedding } ?? false
        let segments = editor.project.voiceLab.segments
        let used = !voices.isEmpty && voices.allSatisfy { $0 == second?.voiceId } && !segments.isEmpty && segments.allSatisfy { $0.provenance.consentRecordId == second?.id }
        let book = setup.voiceLab.perVideoBook
        completed = used
        makeItAppend([DebugRewriteSmoke.Check(invariant: "PV3",
            passed: !asked && made && removed && anchor.status == .active && used && book.videos.map(\.contentKey) == [key] && book.removals.isEmpty
                && requests.filter { $0 == "POST /v1/voices/add" }.count == 1 && !requests.contains("DELETE /v1/voices/\(setup.anchor.voiceId)"),
            detail: (asked ? "asked again · " : "not asked · ") + "video 2: \(second.map { "\($0.voiceName) \($0.voiceId)" } ?? "no voice") · video 1's voice \(old.status.rawValue)"
                + (removed ? " (deleted in the account)" : "") + " · anchor \(anchor.status.rawValue) · \(voices.count) takes with \(Set(voices).sorted().joined(separator: ", "))"
                + " · \(segments.count) segments · " + (setup.voiceLab.perVideoNote ?? "no removal owed"))])
    }

    /// PV4: too little of the video's own speech: the anchor, nothing created, said once.
    func videoVoiceShort(_ setup: VideoVoiceSetup) async throws {
        guard let editor else { throw DebugRewriteSmoke.Failure.setup("no editor") }
        let key = editor.project.media.source.contentKey
        let line = setup.voiceLab.videoVoices[key]?.line ?? ""
        let requests = RewriteSmokeHTTP.script.withLock { $0.requests }
        let voices = RewriteSmokeHTTP.script.withLock { $0.synthesisVoices }
        let shown = steps.filter { step in step.snapshot.texts.contains { $0.hasPrefix("This video has only") } || step.snapshot.cards.contains { $0.contains("This video has only") } }.count
        let segments = editor.project.voiceLab.segments
        let noted = setup.voiceLab.perVideoBook.shortNoted.contains(key)
        makeItAppend([DebugRewriteSmoke.Check(invariant: "PV4",
            passed: line.hasPrefix("This video has only") && line.hasSuffix("so takes use siim. A matching voice needs 30 s.") && noted
                && !requests.contains("POST /v1/voices/add") && !voices.isEmpty && voices.allSatisfy { $0 == setup.anchor.voiceId }
                && segments.allSatisfy { $0.provenance.consentRecordId == setup.anchor.id } && shown >= 1,
            detail: "\(line) · shown in \(shown) step(s) · \(voices.count) takes with \(Set(voices).sorted().joined(separator: ", ")) · "
                + (requests.contains("POST /v1/voices/add") ? "a voice was created" : "nothing created"))])
    }
}
#endif
