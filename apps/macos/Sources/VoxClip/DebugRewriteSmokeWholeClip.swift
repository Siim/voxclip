#if DEBUG
import Foundation
import VoxClipCore
import VoxClipMedia

// Revoice the whole clip (doc/release.md; ADR-R46, design.md R2 "How should it sound?"), over one clip of the script with
// most of its sentences rewritten. The voice is the scripted ElevenLabs through Rewrite's own take path (the script's
// parts, the guard, the takes' checks, the matched picture); fal.ai is the one stand-in: its lip sync returns at once at
// the tables' price, after the picture is matched, so nothing leaves the Mac.
// - S-revoice-whole: W1 the card with the callout, both prices from the tables and the chip; W2 Running then Review with
//   Script, Voice, Fit and Lip sync done, nothing in the clip yet; W3 Use Whole Clip is one undo step with the record,
//   the stage tag over the clip and the export's disclosure line; the project saves and reopens with it; Undo takes it out.
// - S-revoice-whole-claude: Claude mode's quote says stitched and the price fits the cap: revoiced with no click.
// - S-revoice-whole-over-cap: the price passes the cap: the patch goes on, the offer waits, nothing is sent.
// - S-revoice-whole-cancel: Cancel during the lip sync keeps the clip; Try Again pays only the lip sync.
// - S-revoice-whole-upgrade: Review's Sharper Lip Sync · sync-3 re-runs only the lip sync and Use saves sync-3.
// - S-revoice-whole-cuts: the same clip with a cut "um" before each of its later sentences (voice-lab §8.14 item 3): the
//   parts tile the clip, so a filler before a part's first word is absorbed and the run reaches Review and Use (WK1).
// - S-revoice-whole-midtake: the clip opens mid-take on a word touching the one before it, with no silence (voice-lab §8.4,
//   a clip's own edges): the first part's hard seam is the clip's output edge, the run reaches Review and Use, and the full
//   take renders the clip's segments too (WM1, WM2).
// - S-revoice-whole-tightened: the clip's sentence pauses are tightened, so the clip as edited is shorter than its source span
//   (ADR-R46, "One timeline"): the price, the Fit line and the lip sync read the clip as edited, and Use puts in a picture of
//   the clip's own cuts at zoom 1 that renders the clip's edited length (WT1, WT2).
// - S-revoice-whole-short: the voice comes out 35% shorter than the clip (MVP45's 20.2 s for 31.3 s): the Fit step matches
//   the picture first, plays it 1.2×, lays the rest out on the pauses and trims; the lip sync is priced on that picture and
//   the record keeps its speed; the segment's sped cut renders at its own output length (WS1, WS2).
// - S-revoice-whole-retry: the short voice's sped picture fails its preparation once (MVP45's stale stop): Fit stops with what failed, logged
//   with its real case, no lip-sync call and no priced Try Again; a retry prepares the picture again on the paid voice and
//   reaches Review (WR1, WR2).

extension DebugRewriteSmoke {
    /// Five of the eight sentences said differently: well over 40% of the clip's words.
    nonisolated static let wholeClipChanges = [
        ("Today I want to show you how cloud tools edit video.", "This morning let me walk everyone through hosted apps cutting footage."),
        ("First we record a short clip in one take.", "Initially our team films brief material during single sessions."),
        ("Then we fix the words we got wrong.", "Afterwards mistakes get corrected wherever speech slipped."),
        ("We keep the pauses that sound natural and remove the ones that drag.", "Natural silences remain while slow gaps disappear completely."),
        ("Finally we export the clip and share it with our friends.", "Lastly everyone renders projects then posts them online quickly."),
    ]

    /// The clip and the Rewrite end a sentence before the recording does (the last sentence's 16 words).
    private static func wholeClipFixture() -> Fixture {
        let lastSentence = "That is the whole idea, and it only takes a few minutes from start to finish."
        let reply = replace(wholeClipChanges).replacingOccurrences(of: " " + lastSentence, with: "")
        var fixture = Fixture(rewrites: [.passage(reply)], voice: RewriteSmokeVoiceScript(exactFit: true))
        fixture.lastWord = baseScript.split(separator: " ").count - lastSentence.split(separator: " ").count - 1
        fixture.wholeClip = true
        return fixture
    }

    /// The whole-clip clip with a cut "um" right before each later sentence, touching its first word: a part that starts
    /// there would have its seam beside the cut if the parts didn't tile the clip.
    private static func wholeClipCutsFixture() -> Fixture {
        var fixture = wholeClipFixture()
        let starts = ["First we", "Then we", "We keep", "The captions", "Every change", "Finally we"]
        for start in starts { fixture.script = fixture.script.replacingOccurrences(of: ". " + start, with: ". um " + start) }
        fixture.lastWord = (fixture.lastWord ?? 0) + starts.count
        fixture.cutFillers = true
        return fixture
    }

    /// The whole-clip clip opening mid-take: "And so" comes before it, and "so" ends exactly where the clip's first word
    /// starts, as Whisper's back-to-back word ends do, so no seam can sit in a silence before the clip.
    private static func wholeClipMidTakeFixture() -> Fixture {
        var fixture = wholeClipFixture()
        fixture.script = "And so " + fixture.script
        fixture.firstWord = 2
        fixture.lastWord = (fixture.lastWord ?? 0) + 2
        fixture.touchingAfter = 1
        return fixture
    }

    /// The whole-clip clip with every sentence pause tightened to 0.15 s: the clip as edited is about 3 s shorter than the
    /// source under its parts.
    private static func wholeClipTightenedFixture() -> Fixture {
        var fixture = wholeClipFixture()
        fixture.tightenPauses = true
        return fixture
    }

    /// The whole-clip clip with every take 35% shorter than its slot: the user's MVP45 voice (20.2 s for 0:31.3).
    private static func wholeClipShortFixture() -> Fixture {
        var fixture = wholeClipFixture()
        fixture.voice.lengthFactor = 0.65
        return fixture
    }

    static var wholeClipScenarios: [Definition] { [
        Definition(id: "S-revoice-whole", title: "a heavily rewritten clip: How should it sound? → Revoice Whole Clip → Review → Use, one undo step, saved",
                   requiresCompletion: false, fixture: wholeClipFixture()) { harness in
            try await harness.revoiceWholeClip()
        },
        Definition(id: "S-revoice-whole-cuts", title: "a rewritten clip with a cut filler before each sentence: the parts tile the clip and reach Review",
                   requiresCompletion: false, fixture: wholeClipCutsFixture()) { harness in
            try await harness.revoiceWholeClip(cuts: true)
        },
        Definition(id: "S-revoice-whole-midtake", title: "a rewritten clip that opens mid-take on a word touching the one before it: Review and Use",
                   requiresCompletion: false, fixture: wholeClipMidTakeFixture()) { harness in
            try await harness.revoiceWholeClip(midTake: true)
        },
        Definition(id: "S-revoice-whole-tightened", title: "a rewritten clip with tightened pauses: the voice is laid out on the clip as edited, priced, fitted and rendered at its edited length",
                   requiresCompletion: false, fixture: wholeClipTightenedFixture()) { harness in
            try await harness.revoiceWholeClip(tightened: true)
        },
        Definition(id: "S-revoice-whole-short", title: "a rewritten clip whose voice is 35% short: the picture is matched at Fit and sped up 1.2×, then laid out, lip synced at that speed and rendered",
                   requiresCompletion: false, fixture: wholeClipShortFixture()) { harness in
            try await harness.revoiceWholeClip(short: true)
        },
        Definition(id: "S-revoice-whole-retry", title: "the picture's preparation fails once: Fit stops with its reason and no lip sync; a retry starts clean and reaches Review",
                   requiresCompletion: false, fixture: wholeClipShortFixture()) { harness in
            try await harness.retryWholeClipAfterAPictureFailure()
        },
        Definition(id: "S-revoice-whole-claude", title: "✦ Claude does it all revoices a stitched clip whole within the cap, with no click",
                   requiresCompletion: false, fixture: wholeClipFixture()) { harness in
            try await harness.revoiceWholeClipAutomatically(budget: 2)
        },
        Definition(id: "S-revoice-whole-over-cap", title: "over the cap Claude patches and offers the whole clip; nothing is sent",
                   requiresCompletion: false, fixture: wholeClipFixture()) { harness in
            try await harness.revoiceWholeClipAutomatically(budget: Decimal(string: "0.01")!)
        },
        Definition(id: "S-revoice-whole-cancel", title: "Cancel during the lip sync keeps the clip; Try Again pays only the lip sync",
                   requiresCompletion: false, fixture: wholeClipFixture()) { harness in
            try await harness.cancelWholeClip()
        },
        Definition(id: "S-revoice-whole-upgrade", title: "Review's Sharper Lip Sync · sync-3 re-runs only the lip sync",
                   requiresCompletion: false, fixture: wholeClipFixture()) { harness in
            try await harness.upgradeWholeClip()
        },
    ] }
}

extension DebugRewriteSmoke.Harness {
    /// fal.ai's stand-in: the picture is matched through Rewrite's own path, then the lip sync "returns" at the tables'
    /// price. `hold` keeps it running until Cancel.
    @MainActor final class WholeClipLipsync {
        var calls: [WholeClipRevoice.Lipsync] = []
        var hold = false
        var waiting: CheckedContinuation<Void, Never>?
        /// Resumed once: when the lip sync starts, or when the run ends without reaching it.
        var started: CheckedContinuation<Void, Never>?
        /// Fails the picture's first duration render (S-revoice-whole-retry); counts the renders asked for.
        var failPictureOnce = false
        var renders = 0
        func reached() { started?.resume(); started = nil }
    }

    private func installWholeClipStandIn() -> WholeClipLipsync {
        let lipsync = WholeClipLipsync()
        if let app = editor?.app { app.providerKeyStoreOverride = RewriteSmokeFalKey(base: app.providerKeyStore) }
        editor?.wholeClipPrepared = { [weak self] plan in
            if let real = plan.prepareDurationRender {
                plan.prepareDurationRender = { project, scope in
                    lipsync.renders += 1
                    if lipsync.failPictureOnce { lipsync.failPictureOnce = false; throw VoiceLabProjectError.staleRenderContract }
                    return try await real(project, scope)
                }
            }
            guard let self, let project = self.editor?.project else { return }
            self.recordFitting(plan, edited: try? VoiceLabOutputPlanner.build(project, scope: .clip("clip-whole")))
        }
        editor?.wholeClipSmoke = { session, whole in
            whole.backend?.lipsync = { [weak session] _, factor, model, progress in
                guard let session else { throw CancellationError() }
                _ = try await session.wholeClipMatchPicture()
                lipsync.calls.append(model)
                lipsync.reached()
                progress(0.5)
                if lipsync.hold { await withCheckedContinuation { lipsync.waiting = $0 } }
                try Task.checkCancellation()
                let price = try whole.backend?.lipsyncPrice(model) ?? nil
                // As the live step: the record's retime is the Fit step's picture speed (ADR-R46).
                return .init(model: model, usd: price ?? 0, factor: factor)
            }
            whole.backend?.match = { _ in .init(take: 0.81, anchorBaseline: 0.54, realSpeech: nil) }
        }
        return lipsync
    }

    private var speechRequests: Int {
        RewriteSmokeHTTP.script.withLock { $0.requests }.filter { $0.contains("text-to-speech") || $0.contains("text-to-dialogue") }.count
    }

    /// Opens the Rewrite and shows the card, priced.
    private func openWholeClip() async throws -> (RewriteSession, WholeClipRevoiceSession) {
        try await start()
        guard let session else { throw DebugRewriteSmoke.Failure.setup("no Rewrite") }
        session.showProposal()
        guard let whole = session.wholeClip else {
            throw DebugRewriteSmoke.Failure.missing("the How should it sound? card", session.task.cards.map(\.id).joined(separator: ", "))
        }
        await whole.refreshQuote()
        session.showProposal()
        return (session, whole)
    }

    private func wholeClipCheck(_ invariant: String, _ passed: Bool, _ detail: String) -> DebugRewriteSmoke.Check {
        DebugRewriteSmoke.Check(invariant: invariant, passed: passed, detail: detail)
    }

    private func phaseText(_ whole: WholeClipRevoiceSession) -> String {
        switch whole.phase {
        case .choose: "choose"
        case .running: "running"
        case .review: "review"
        case .used: "used"
        case .stopped(let line): "stopped: " + line
        }
    }

    /// W1: the card, its callout and chip, and both prices from the tables.
    private func checkChoose(_ session: RewriteSession, _ whole: WholeClipRevoiceSession) throws -> String {
        guard let shared = app.shared, let quote = whole.quote, let script = whole.script, let project = editor?.project else {
            throw DebugRewriteSmoke.Failure.setup("no quote")
        }
        let catalog = try VoiceLabPriceCatalog(data: Data(contentsOf: shared.root.appendingPathComponent("catalog/voice-lab.json")))
        // The lip sync is priced on the clip as edited, with Rewrite's one-second handles (ADR-R46).
        let edited = try VoiceLabOutputPlanner.build(project, scope: .clip("clip-whole"))
        let seconds = edited.mapTime(script.sentences.last?.end ?? 0) - edited.mapTime(script.sentences.first?.start ?? 0) + 2
        let expected = try WholeClipRevoice.price(characters: script.characters, ttsModel: VoiceLabWordingFit.modelID, videoSeconds: seconds,
                                                  lipsync: .lipsync2, catalog: catalog)
        let chip = session.wholeClipChipAction()?.title ?? ""
        let primary = session.wholeClipPrimary()?.title ?? ""
        let price = quote.wholeUSD.map(VoiceLabCostPresentation.format) ?? "none"
        makeItAppend([
            wholeClipCheck("W1", session.task.cards.contains(.wholeClip) && whole.phase == .choose && quote.reason != nil
                    && quote.wholeUSD == expected.usd && quote.patchUSD != nil && chip == "Revoice the Whole Clip · " + price
                    && primary == "Revoice Whole Clip · " + price,
                "card \(session.task.cards.contains(.wholeClip)) · reason \(quote.reason.map(WholeClipRevoice.callout) ?? "none") · whole \(price) (tables \(expected.usd.map(VoiceLabCostPresentation.format) ?? "none")) · patch \(quote.patchUSD.map(VoiceLabCostPresentation.format) ?? "none") · [\(chip)] [\(primary)]"),
        ])
        return primary
    }

    /// Clicks the card's primary and waits for the run.
    private func runWholeClip(_ session: RewriteSession, _ whole: WholeClipRevoiceSession, title: String) async throws {
        try await act("click [\(title)]", clicked: "wholeClipRevoice") {
            session.wholeClipPrimary()?.perform()
            await whole.waitForRun()
        }
    }

    /// W2: Review, every step done, nothing in the clip yet.
    private func checkReview(_ whole: WholeClipRevoiceSession, segmentsBefore: Int) {
        let lines = WholeClipRevoiceSession.Step.allCases.map { step -> String in
            if case .done(let line) = whole.steps[step] { return line }
            return "\(step): \(String(describing: whole.steps[step]))"
        }
        let done = WholeClipRevoiceSession.Step.allCases.allSatisfy { if case .done = whole.steps[$0] { true } else { false } }
        makeItAppend([wholeClipCheck("W2", whole.phase == .review && done && (lines[2].contains("video matched") || lines[2].contains("picture 1.")) && whole.spent > 0
                && (editor?.project.voiceLab.segments.count ?? -1) == segmentsBefore,
            phaseText(whole) + " · " + lines.joined(separator: " | ") + " · spent \(VoiceLabCostPresentation.format(whole.spent))")])
    }

    /// W3: Use Whole Clip as one undo step with the record; the stage tag, the disclosure, save and reopen; Undo.
    private func useAndCheck(_ session: RewriteSession, _ whole: WholeClipRevoiceSession, model: WholeClipRevoice.Lipsync,
                             fullTake: Bool = false, afterUse: (() -> Void)? = nil) async throws {
        guard let editor else { return }
        let steps = editor.undoSteps
        try await act("click [Use Whole Clip]", clicked: "wholeClipUse") {
            await session.useWholeClip().value
        }
        let project = editor.project
        let record = project.voiceLab.wholeClipRevoices?.first
        let reopened = try? JSONProjectStore.decode(JSONProjectStore.encode(project))
        let prepared = try? VoiceLabRenderContract.prepare(project, scope: .clip("clip-whole"), labelPosition: .topRight)
        let stage = WholeClipRevoice.isRevoiced(clipId: "clip-whole", in: project)
        let reopenedSame = reopened?.voiceLab.wholeClipRevoices == project.voiceLab.wholeClipRevoices
        makeItAppend([wholeClipCheck("W3", whole.phase == .used && editor.undoSteps == steps + 1 && record?.lipsyncModel == model.rawValue
                && record.map { $0.segmentIds.allSatisfy { id in project.voiceLab.segments.contains { $0.id == id } } } == true
                && reopened?.voiceLab.wholeClipRevoices == project.voiceLab.wholeClipRevoices && stage
                && prepared?.disclosure.postText == WholeClipRevoice.disclosureLine,
            phaseText(whole) + " · undo steps +\(editor.undoSteps - steps) · record \(record.map { "\($0.segmentIds.count) segments, \($0.lipsyncModel), retime \($0.videoRetime)" } ?? "none")"
                + " · reopened \(reopened?.voiceLab.wholeClipRevoices?.count ?? 0) same \(reopenedSame) · stage \(stage) · post text \(prepared?.disclosure.postText ?? "none")")])
        if fullTake { checkFullTake(project, record: record) }
        afterUse?()
        // The step list's Undo (Claude mode), as one undo step: the record goes and its segments are off.
        if let record { editor.removeWholeClip(record) }
        let undone = editor.project.voiceLab.wholeClipRevoices == nil && record.map { record in
            editor.project.voiceLab.segments.filter { record.segmentIds.contains($0.id) }.allSatisfy { !$0.enabled } } == true
        makeItAppend([wholeClipCheck("W4", undone && editor.undoSteps == steps + 2, undone ? "Undo takes the whole clip out" : "the record survived Undo")])
        completed = record != nil; ended = true
    }

    /// WM1: the clip opens on a word that touches the one before it, and the first part's window opens the clip with a hard
    /// seam at the clip's own start.
    private func checkMidTakeEdge(_ session: RewriteSession, _ whole: WholeClipRevoiceSession) {
        guard let project = editor?.project, let words = project.transcript?.words, let clip = project.edits.clips.first,
              let index = words.firstIndex(where: { $0.id == clip.startWordId }), index > 0 else {
            makeItAppend([wholeClipCheck("WM1", false, "no clip opening mid-take")])
            return
        }
        let windows = session.wholeClipPlan?.phrases.map(\.window) ?? []
        let first = windows.min { $0.startSample < $1.startSample }
        let touching = words[index - 1].end == words[index].start
        let seam = first.map { "\($0.leftSeam.kind) at \($0.leftSeam.time)" } ?? "none"
        makeItAppend([wholeClipCheck("WM1", touching && first?.leftSeam.kind == .hard && first?.start == words[index].start
                && whole.phase == .review,
            "\(words[index - 1].text) ends \(words[index - 1].end), \(words[index].text) starts \(words[index].start) · \(windows.count) windows · first seam \(seam) · \(phaseText(whole))")])
    }

    /// WM2: the full take renders the used clip's segments, with the source before the clip beside the opening seam.
    private func checkFullTake(_ project: Project, record: WholeClipRevoiceRecord?) {
        let prepared = Result { try VoiceLabRenderContract.prepare(project, scope: .full, labelPosition: .topRight) }
        let ids = Set(record?.segmentIds ?? [])
        let pieces = (try? prepared.get())?.outputPlan.pieces ?? []
        let opening = pieces.firstIndex { ids.contains($0.segmentId ?? "") }
        let besideSource = opening.map { $0 > 0 && pieces[$0 - 1].kind == .source } ?? false
        let detail: String
        switch prepared {
        case .success: detail = "full take prepares · \(pieces.count) pieces · source before the clip \(besideSource)"
        case .failure(let error): detail = "full take refused: \(error)"
        }
        makeItAppend([wholeClipCheck("WM2", (try? prepared.get()) != nil && besideSource, detail)])
    }

    func revoiceWholeClip(cuts: Bool = false, midTake: Bool = false, tightened: Bool = false, short: Bool = false) async throws {
        let lipsync = installWholeClipStandIn()
        let (session, whole) = try await openWholeClip()
        let primary = try checkChoose(session, whole)
        let before = editor?.project.voiceLab.segments.count ?? 0
        try await runWholeClip(session, whole, title: primary)
        checkReview(whole, segmentsBefore: before)
        if cuts { checkCutsAbsorbed(session, whole) }
        if midTake { checkMidTakeEdge(session, whole) }
        if tightened { checkEditedTimeline(session, whole) }
        if short { checkSpedPicture(session, whole) }
        makeItAppend([wholeClipCheck("W5", lipsync.calls == [.lipsync2] && whole.voice.map { $0.parts >= 1 } == true,
            "lip sync \(lipsync.calls.map(\.name)) · \(whole.voice?.parts ?? 0) parts · \(speechRequests) speech requests")])
        let after: (() -> Void)? = tightened ? { [weak self] in self?.checkEditedRender() }
            : short ? { [weak self, weak whole] in self?.checkSpedRender(whole?.picture) } : nil
        try await useAndCheck(session, whole, model: .lipsync2, fullTake: midTake, afterUse: after)
    }

    /// WS1: a voice 35% short is checked at Fit: its picture is the clip's own cuts sped up evenly (1.2×, the cap) with the
    /// rest laid out on the pauses, the Fit line names the speed, and the lip sync is priced on that picture's output.
    private func checkSpedPicture(_ session: RewriteSession, _ whole: WholeClipRevoiceSession) {
        guard let picture = whole.picture, let voice = whole.voice, let phrases = session.wholeClipPlan?.phrases, !phrases.isEmpty else {
            makeItAppend([wholeClipCheck("WS1", false, "no picture at Fit: \(phaseText(whole))")]); return
        }
        let fit: String = { if case .done(let line) = whole.steps[.fit] { return line } else { return "\(String(describing: whole.steps[.fit]))" } }()
        let video = session.wholeClipEditedSeconds ?? 0
        let sped = phrases.allSatisfy { phrase in phrase.videoChoice == .cut && (phrase.selected?.row.audio?.fit.plan.pictureSpeed ?? 1) > 1 }
        let catalog = try? VoiceLabPriceCatalog.load(shared: SharedResources.locate())
        let expected = catalog.flatMap { try? WholeClipRevoice.lipsyncPrice(videoSeconds: picture.outputSeconds + 2, lipsync: .lipsync2, catalog: $0).usd }
        let priced = (try? whole.backend?.lipsyncPrice(.lipsync2)) ?? nil
        makeItAppend([wholeClipCheck("WS1", voice.seconds < video * 0.75 && abs(picture.speed - WholeClipRevoice.maximumPictureSpeed) < 0.002
                && picture.laidOut && fit.contains("picture 1.20× and laid out on the clip's pauses") && sped
                && picture.outputSeconds < video && priced != nil && priced == expected,
            "voice \(WholeClipRevoiceSession.clock(voice.seconds)) for \(WholeClipRevoiceSession.clock(video)) · \(fit) · speed \(String(format: "%.4f", picture.speed)) · output \(String(format: "%.2f", picture.outputSeconds)) s · lip sync \(priced.map(VoiceLabCostPresentation.format) ?? "none") (expected \(expected.map(VoiceLabCostPresentation.format) ?? "none"))")])
    }

    /// WS2: after Use, the record keeps the picture's speed and the clip's segment is a sped cut (zoom 1, its factor) that
    /// validates and renders at its own output length.
    private func checkSpedRender(_ picture: WholeClipRevoiceSession.Picture?) {
        guard let project = editor?.project, let record = project.voiceLab.wholeClipRevoices?.first, let picture else {
            makeItAppend([wholeClipCheck("WS2", false, "no record or picture")]); return
        }
        let videos = project.voiceLab.segments.filter { record.segmentIds.contains($0.id) }.compactMap { $0.candidates[$0.selectedCandidateIndex].recipe?.video }
        let bases = videos.map { $0.mode == .lipsync ? $0.lipsyncBase : $0 }
        let rate = Double(project.media.source.audio?.sampleRate ?? 48_000)
        let sped = !bases.isEmpty && bases.allSatisfy { $0.mode == .cut && ($0.retimeFactor ?? 1) > 1 && VoiceLabNaturalPacing.validCuts($0, sampleRate: rate) }
        let prepared = try? VoiceLabRenderContract.prepare(project, scope: .clip("clip-whole"), labelPosition: .topRight)
        let rendered = prepared?.outputPlan.duration ?? 0
        makeItAppend([wholeClipCheck("WS2", sped && abs(record.videoRetime - picture.speed) < 1e-9 && prepared != nil
                && rendered >= picture.outputSeconds - 0.05,
            "\(bases.map { "\($0.mode) zoom \($0.zoom ?? 0) · \($0.cuts?.count ?? 0) cuts · factor \($0.retimeFactor.map { String(format: "%.4f", $0) } ?? "none")" }.joined(separator: ", ")) · record \(String(format: "%.4f", record.videoRetime)) · renders \(String(format: "%.2f", rendered)) s for \(String(format: "%.2f", picture.outputSeconds)) s of picture")])
    }

    /// WT1: the clip as edited is shorter than the source under its parts, and the Fit line, the voice's layout and the
    /// picture read the clip as edited, not the source.
    private func checkEditedTimeline(_ session: RewriteSession, _ whole: WholeClipRevoiceSession) {
        guard let project = editor?.project, let edited = try? VoiceLabOutputPlanner.build(project, scope: .clip("clip-whole")),
              let phrases = session.wholeClipPlan?.phrases, !phrases.isEmpty else {
            makeItAppend([wholeClipCheck("WT1", false, "no plan or edited clip")]); return
        }
        let source = phrases.reduce(0.0) { $0 + $1.window.end - $1.window.start }
        let seconds = session.wholeClipEditedSeconds ?? 0
        let fit: String = { if case .done(let line) = whole.steps[.fit] { return line } else { return "\(String(describing: whole.steps[.fit]))" } }()
        let laid = phrases.allSatisfy { phrase in phrase.selected?.row.audio?.fit.plan.editedTimeline == true }
        let choices = phrases.map { $0.videoChoice.map { "\($0)" } ?? "none" }
        makeItAppend([wholeClipCheck("WT1", !project.edits.cutPauseIds.isEmpty && seconds < source - 1 && abs(seconds - edited.duration) < 0.5
                && fit.contains("for \(WholeClipRevoiceSession.clock(seconds)) of video") && laid && phrases.allSatisfy { $0.videoChoice == .cut },
            "\(project.edits.cutPauseIds.count) tightened pauses · source \(String(format: "%.2f", source)) s · as edited \(String(format: "%.2f", seconds)) s (clip \(String(format: "%.2f", edited.duration)) s) · \(fit) · laid out \(laid) · picture \(choices)")])
    }

    /// WT2: after Use, the clip's segment holds the clip's own cuts at zoom 1, and the clip renders at its edited length.
    private func checkEditedRender() {
        guard let project = editor?.project, let record = project.voiceLab.wholeClipRevoices?.first else {
            makeItAppend([wholeClipCheck("WT2", false, "no record")]); return
        }
        let videos = project.voiceLab.segments.filter { record.segmentIds.contains($0.id) }.compactMap { $0.candidates[$0.selectedCandidateIndex].recipe?.video }
        let prepared = try? VoiceLabRenderContract.prepare(project, scope: .clip("clip-whole"), labelPosition: .topRight)
        var plain = project
        plain.voiceLab.segments = plain.voiceLab.segments.map { var segment = $0; segment.enabled = false; return segment }
        plain.voiceLab.wholeClipRevoices = nil
        let edited = (try? VoiceLabOutputPlanner.build(plain, scope: .clip("clip-whole")))?.duration ?? 0
        let rendered = prepared?.outputPlan.duration ?? 0
        let zoomOne = videos.allSatisfy { $0.mode == .cut && $0.zoom == VoiceLabNaturalPacing.EDITED_CUT_ZOOM && ($0.cuts?.count ?? 0) >= 1 }
            || videos.allSatisfy { $0.mode == .source }
        makeItAppend([wholeClipCheck("WT2", !videos.isEmpty && zoomOne && prepared != nil && rendered <= edited + 0.05 && rendered > edited - 1.5
                && record.videoRetime >= 1 && record.videoRetime <= WholeClipRevoice.maximumPictureSpeed,
            "\(videos.map { "\($0.mode) zoom \($0.zoom ?? 0) · \($0.cuts?.count ?? 0) cuts" }.joined(separator: ", ")) · renders \(String(format: "%.2f", rendered)) s for \(String(format: "%.2f", edited)) s as edited · retime \(record.videoRetime)")])
    }

    /// WK1: the clip has cut fillers, at least one right before a later part's first word, and every one lies inside a
    /// placed window, so no seam sits beside a cut.
    private func checkCutsAbsorbed(_ session: RewriteSession, _ whole: WholeClipRevoiceSession) {
        guard let project = editor?.project, let words = project.transcript?.words, let script = whole.script else { return }
        let cuts = Set(project.edits.cutWordIds)
        let fillers = words.filter { cuts.contains($0.id) }
        let windows = session.wholeClipPlan?.phrases.map(\.window) ?? []
        let absorbed = fillers.filter { filler in windows.contains { $0.start <= filler.start && filler.end <= $0.end } }
        // A part boundary that has a cut filler right before its first source word.
        let firsts = script.parts.dropFirst().compactMap { $0.sourceWordIds.first }
        let beside = firsts.filter { id in
            guard let index = words.firstIndex(where: { $0.id == id }), index > 0 else { return false }
            return cuts.contains(words[index - 1].id)
        }
        makeItAppend([wholeClipCheck("WK1", !fillers.isEmpty && !beside.isEmpty && absorbed.count == fillers.count && whole.phase == .review,
            "\(fillers.count) cut fillers, \(beside.count) before a part's first word · \(script.parts.count) parts · \(windows.count) windows absorb \(absorbed.count) · \(phaseText(whole))")])
    }

    /// Claude mode's live services over this clip: quote, the automatic choice against `budget`, then the revoice.
    func revoiceWholeClipAutomatically(budget: Decimal) async throws {
        _ = installWholeClipStandIn()
        guard let editor else { return }
        // Claude mode's Rewrite gets the scripted ElevenLabs, as the Make it postable scenes' does.
        editor.makeItGeneration = { [weak self] session in await self?.adopt(session) }
        defer { editor.makeItGeneration = nil }
        guard let words = editor.project.transcript?.words, let clip = editor.project.edits.clips.first,
              let last = words.firstIndex(where: { $0.id == clip.endWordId }) else { throw DebugRewriteSmoke.Failure.setup("no clip") }
        // The planner's rewrites, as Make it postable maps them: each changed sentence's range and its new words.
        let text = words.map(\.text)
        var rewrites: [(range: ClosedRange<Int>, text: String)] = []
        for (old, new) in DebugRewriteSmoke.wholeClipChanges {
            let tokens = old.split(separator: " ").map(String.init)
            if let start = text.indices.first(where: { Array(text[$0..<min(text.count, $0 + tokens.count)]) == tokens }) {
                rewrites.append((start...(start + tokens.count - 1), new))
            }
        }
        let request = WholeClipAutoRequest(clipID: "clip-whole", range: 0...last, rewrites: rewrites, budget: budget)
        let requestsBefore = speechRequests
        var quote: WholeClipAutoQuote?
        try await act("✦ Claude does it all quotes the whole clip") { quote = await MakeItServices.liveWholeClipQuote(request, editor: editor) }
        let choice = WholeClipRevoice.autoChoice(quote?.reason, price: quote?.price, remaining: budget)
        var outcome: WholeClipAutoOutcome?
        try await act("✦ Claude does it all chooses \(choice)") {
            if case .revoice = choice { outcome = await MakeItServices.liveRevoiceWholeClip(request, editor: editor) }
        }
        let record = editor.project.voiceLab.wholeClipRevoices?.first
        if budget >= 1 {
            let revoiced = if case .revoiced = outcome { true } else { false }
            makeItAppend([wholeClipCheck("WC1", quote?.reason != nil && choice == .revoice(price: quote?.price ?? 0) && revoiced && record != nil
                    && (quote?.price ?? 0) <= budget,
                "quote \(quote?.price.map(VoiceLabCostPresentation.format) ?? "none") within \(budget) · \(String(describing: outcome)) · record \(record?.id ?? "none")")])
            completed = record != nil
        } else {
            let price = quote?.price ?? 0
            makeItAppend([wholeClipCheck("WC2", quote?.reason != nil && choice == .patchAndOffer(price: price) && outcome == nil
                    && record == nil && speechRequests == requestsBefore,
                "quote \(VoiceLabCostPresentation.format(price)) over \(budget): \(choice) · \(speechRequests - requestsBefore) speech requests · record \(record?.id ?? "none")")])
            completed = true
        }
        ended = true
    }

    func cancelWholeClip() async throws {
        let lipsync = installWholeClipStandIn()
        lipsync.hold = true
        let (session, whole) = try await openWholeClip()
        let primary = try checkChoose(session, whole)
        let project = editor?.project
        try await act("click [\(primary)], then Cancel during the lip sync", clicked: "wholeClipCancel") {
            await withCheckedContinuation { continuation in
                lipsync.started = continuation
                session.wholeClipPrimary()?.perform()
                Task { await whole.waitForRun(); lipsync.reached() }
            }
            whole.cancel()
            lipsync.waiting?.resume(); lipsync.waiting = nil
            await whole.waitForRun()
        }
        let speech = speechRequests
        let logged = RewriteSmokeHTTP.script.withLock { $0.requests }.count
        makeItAppend([wholeClipCheck("WX1", whole.isStopped && phaseText(whole).contains("Cancelled. Your clip is unchanged.") && editor?.project == project,
            phaseText(whole) + " · clip unchanged \(editor?.project == project)")])
        lipsync.hold = false
        let retry = session.wholeClipPrimary(retry: true)
        try await act("click [\(retry?.title ?? "Try Again")]", clicked: "wholeClipRetry") {
            retry?.perform()
            await whole.waitForRun()
        }
        makeItAppend([wholeClipCheck("WX2", whole.phase == .review && speechRequests == speech && lipsync.calls == [.lipsync2, .lipsync2],
            phaseText(whole) + " · \(speechRequests - speech) new speech requests · lip sync \(lipsync.calls.map(\.name)) · requests "
                + RewriteSmokeHTTP.script.withLock { $0.requests }.dropFirst(logged).joined(separator: ", "))])
        completed = whole.phase == .review; ended = true
    }

    func retryWholeClipAfterAPictureFailure() async throws {
        let lipsync = installWholeClipStandIn()
        lipsync.failPictureOnce = true
        let (session, whole) = try await openWholeClip()
        let primary = try checkChoose(session, whole)
        try await runWholeClip(session, whole, title: primary)
        let speech = speechRequests
        let fit: String = { if case .failed(let line) = whole.steps[.fit] { return line } else { return "\(String(describing: whole.steps[.fit]))" } }()
        let actions = session.wholeClipStoppedActions()
        makeItAppend([wholeClipCheck("WR1", whole.isStopped && whole.failure?.step == .fit && fit.hasPrefix("The picture couldn't be matched to the voice:")
                && !fit.contains("The job could not be completed") && whole.failure?.kind.contains("VoiceLabProjectError") == true
                && lipsync.calls.isEmpty && actions.map(\.id) == ["wholeClipPatch"] && !actions.contains { $0.priced },
            "\(phaseText(whole)) · fit \(fit) · kind \(whole.failure?.kind ?? "none") · lip sync \(lipsync.calls.map(\.name)) · [\(actions.map(\.title).joined(separator: "] ["))]")])
        let renders = lipsync.renders
        try await act("Try Again over the paid voice") {
            session.startWholeClip()
            await whole.waitForRun()
        }
        makeItAppend([wholeClipCheck("WR2", whole.phase == .review && speechRequests == speech && lipsync.calls == [.lipsync2] && lipsync.renders > renders,
            "\(phaseText(whole)) · \(speechRequests - speech) new speech requests · \(lipsync.renders - renders) new renders · lip sync \(lipsync.calls.map(\.name))")])
        completed = whole.phase == .review; ended = true
    }

    func upgradeWholeClip() async throws {
        let lipsync = installWholeClipStandIn()
        let (session, whole) = try await openWholeClip()
        let primary = try checkChoose(session, whole)
        try await runWholeClip(session, whole, title: primary)
        let speech = speechRequests
        let upgrade = session.wholeClipUpgradeAction()
        let expected = whole.upgradeUSD.map { "Sharper Lip Sync · sync-3 · " + VoiceLabCostPresentation.format($0) }
        try await act("click [\(upgrade?.title ?? "Sharper Lip Sync")]", clicked: "wholeClipUpgrade") {
            upgrade?.perform()
            await whole.waitForRun()
        }
        makeItAppend([wholeClipCheck("WU1", upgrade?.title == expected && upgrade?.priced == true && whole.phase == .review
                && speechRequests == speech && lipsync.calls == [.lipsync2, .sync3] && whole.synced?.model == .sync3,
            "[\(upgrade?.title ?? "none")] · \(phaseText(whole)) · \(speechRequests - speech) new speech requests · lip sync \(lipsync.calls.map(\.name))")])
        try await useAndCheck(session, whole, model: .sync3)
    }
}
#endif
