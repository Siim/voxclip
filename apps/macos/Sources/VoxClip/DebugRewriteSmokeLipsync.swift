#if DEBUG
import Foundation
import VoxClipCore
import VoxClipMedia

// Lip sync through the real run (MVP46, 2026-11-08: fal.ai billed two sync-3 jobs whose results came back 5 frames short and
// were thrown away). fal.ai is stood in under the run (`LipsyncSmokeFalHTTP`): the window is prepared with its tail margin,
// uploaded, quoted, approved and submitted; the result is the upload with its last 5 frames dropped and a 24 kHz AAC track,
// as fal.ai's own example; the import cuts it back to the voice and stores only its picture. Nothing leaves the Mac.
// - S-lipsync-fal-short: a phrase's Lip Sync imports the short result and Use Takes puts the lip-synced picture in (LS1, LS2).
// - S-revoice-whole-fal-short: the whole clip's lip sync imports it and Use Whole Clip puts it in (DebugRewriteSmokeWholeClip.swift).

/// fal.ai's key for the stood-in provider; never a real key, never the keychain.
private struct RewriteSmokeFalSecret: KeyProvider {
    func key(for provider: String) async throws -> String? { provider == "fal" ? "rewrite-smoke-fal-key" : nil }
}

extension DebugRewriteSmoke.Harness {
    /// What the stood-in fal.ai was asked and what the import made of it.
    @MainActor final class FalShortResult {
        let http: LipsyncSmokeFalHTTP
        /// Each import's needed length (the voice's) and its stored asset's length.
        var imports: [(needed: Double, stored: Double, recovered: Bool)] = []
        var failures: [String] = []
        init(http: LipsyncSmokeFalHTTP) { self.http = http }

        func line() async -> String {
            let lengths = imports.map { String(format: "%.3f s for %.3f s%@", $0.stored, $0.needed, $0.recovered ? " (kept)" : "") }
            let submits = await http.submits, deletions = await http.deletions
            return "\(submits) submits · \(deletions) payload deletes · imports \(lengths.joined(separator: ", "))"
                + (failures.isEmpty ? "" : " · failed " + failures.joined(separator: "; "))
        }

        /// One paid import, cut back to the voice within a frame.
        func passed() async -> Bool {
            let submits = await http.submits
            return submits == 1 && failures.isEmpty && imports.count == 1
                && imports.allSatisfy { abs($0.stored - $0.needed) <= 1.0 / 24 && !$0.recovered }
        }
    }

    /// Puts the real lip-sync run over the stood-in fal.ai under every take plan this Rewrite makes.
    func installFalShortResult(droppingFrames: Int = 5) throws -> FalShortResult {
        guard let editor, let shared = app.shared else { throw DebugRewriteSmoke.Failure.setup("no editor") }
        app.providerKeyStoreOverride = RewriteSmokeFalKey(base: app.providerKeyStore)
        let catalog = try VoiceLabPriceCatalog(data: Data(contentsOf: shared.root.appendingPathComponent("catalog/voice-lab.json")))
        let http = LipsyncSmokeFalHTTP(droppingFrames: droppingFrames)
        let fal = FalShortResult(http: http)
        let app = self.app
        editor.lipsyncSmoke = { request, window, recordID, model, mayPay, progress in
            let paid = app.locations.root.appendingPathComponent("VoiceLab", isDirectory: true)
            let scratch = app.locations.root.appendingPathComponent("VoiceLabScratch", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let provider = FalLipsyncProvider(keys: RewriteSmokeFalSecret(), prices: catalog, http: http, logger: app.log,
                                              spend: VoiceLabSpendLedger(locations: app.locations), now: { Date() },
                                              monotonic: VoiceLabQuoteClock.continuousSource(), sleep: { _ in })
            var run = LipsyncRun(provider: provider, consentStore: VoiceConsentStore(locations: app.locations), paidRoot: paid, scratchRoot: scratch)
            // The fixture's picture is synthetic: the face check is the one stand-in on this Mac.
            run.detector = { _ in 0.2 }
            do {
                let result = try await run.execute(request: request, window: window, recordID: recordID, model: model.lipsyncModel,
                                                   mayPay: mayPay, onProgress: progress)
                fal.imports.append((window.seconds(sampleRate: request.timeline.sampleRate), result.asset.durationSeconds, result.recovered))
                return result
            } catch {
                fal.failures.append(RewriteSession.failureKind(WholeClipRevoiceSession.cause(error)))
                throw error
            }
        }
        return fal
    }
}

extension DebugRewriteSmoke {
    static var lipsyncScenarios: [Definition] { [
        Definition(id: "S-lipsync-fal-short", title: "a phrase's Lip Sync: fal.ai's result comes back 5 frames short with its own audio; it is cut back to the voice and Use puts it in",
                   voiced: 1, fixture: Fixture(rewrites: [.passage(replace([twoChanges[0]]))], voice: RewriteSmokeVoiceScript(exactFit: true))) { harness in
            let fal = try harness.installFalShortResult()
            try await harness.start()
            try await harness.click(["prepareTakes", "makeTakes"])
            try await harness.click(["takeQuote-"])
            if harness.session?.task.confirm != nil { try await harness.click(["approveTakeQuote"]) }
            guard let session = harness.session, let plan = session.takePlan, !plan.phrases.isEmpty else {
                throw Failure.setup("S-lipsync-fal-short needs a takes plan")
            }
            guard plan.phrases[0].selected != nil else {
                throw Failure.missing("a passing take on phrase 1", plan.problem.isEmpty ? "no take selected" : plan.problem)
            }
            if plan.phrases[0].videoChoice == nil {
                try await harness.act("choose the source video on phrase 1", clicked: "videoChoice") {
                    _ = plan.chooseVideo(.source, phrase: 0)
                    await plan.prepareVideoChoices()
                }
            }
            await plan.lipsync.refresh()
            guard let offer = plan.lipsync.offers[0] else {
                throw Failure.missing("Lip Sync on phrase 1", plan.lipsync.problem.isEmpty ? "no lip-sync offer" : plan.lipsync.problem)
            }
            try await harness.act("click [Lip Sync · \(offer.price)] on phrase 1", clicked: "lipsync-approve-0") {
                plan.lipsync.start(offer)
                await plan.lipsync.waitForRun()
            }
            let applied = plan.lipsync.applied[0] != nil
            let passed = await fal.passed(), line = await fal.line()
            harness.makeItAppend([Check(invariant: "LS1", passed: applied && passed,
                detail: (applied ? "lip synced" : "not applied: \(String(describing: plan.lipsync.states[0]))") + " · " + line)])
            try await harness.finish()
            let project = harness.editor?.project
            let lipsynced = project?.voiceLab.segments.contains { segment in
                segment.candidates.indices.contains(segment.selectedCandidateIndex)
                    && segment.candidates[segment.selectedCandidateIndex].recipe?.video.mode == .lipsync
            } == true
            let assets = project?.voiceLab.videoAssets ?? []
            harness.makeItAppend([Check(invariant: "LS2", passed: harness.completed && lipsynced && assets.count == 1,
                detail: "used \(harness.completed) · lip-synced segment \(lipsynced) · \(assets.count) video assets"
                    + (assets.first.map { String(format: " · %.3f s", $0.durationSeconds) } ?? ""))])
        },
    ] }
}
#endif
