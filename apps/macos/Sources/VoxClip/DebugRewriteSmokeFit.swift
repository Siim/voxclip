#if DEBUG
import Foundation
import VoxClipCore

// MVP32 Clip 7 (2026-11-05, "still stuck??"): a Viral YouTuber rewrite padded each line with connectors, the fit rounds
// left them long, a take's render recipe failed at Use, and the footer said "Changes 3, 5 and 6 need a shorter wording
// before takes. Fix the problem above to go on." beside only Keep All. Every step of both scenarios is also checked by I10
// (the footer always has a step forward while nothing runs).
// - S-viral-fit: the reply pads one change with filler and its one free fit is still long; that change keeps the speaker's
//   words, the other is voiced and Use applies it (VF1). The rewrite request listed each span's time and word budget, and
//   said why the length is fixed (VF2).
// - S-make-it-long: ✦ Make it postable (the driver ✦ Claude does it all runs too) plans a padded line; its one free fit is
//   still long, so the driver keeps it as recorded with no click and the run is ready to export (MK1).
// - S-render-recipe: phrase 1's take can't be made into a render recipe; Use keeps phrase 1 as recorded with one line of
//   why and applies phrase 2 (RR1).
// - S-duration-short: phrase 1's rewrite is "bits.", a 0.41 s take for a 1.7 s slot that no video duration can carry (too
//   short to keep the source, no clean cut, outside the matched speed). Rewrite keeps phrase 1's recorded audio with one line
//   and no click, and Use applies phrase 2 (DS1). Before, the footer read "Choose the video duration for phrase 1." with no
//   duration to choose.
// - S-duration-claude: ✦ Make it postable (the driver ✦ Claude does it all runs too) makes the same 0.41 s take; the run keeps
//   that phrase as recorded with no click, says why, and is ready to export (DC1).

extension DebugRewriteSmoke {
    /// Change 1 padded the way the user's Viral YouTuber reply was ("or, put differently", "and then, in addition to that").
    nonisolated static let paddedChanges = [("record a short clip in one take",
        "film, or put differently, record a short clip, and then, in addition to that, all of it in one single continuous take"),
        twoChanges[1]]

    static var fitScenarios: [Definition] { [
        Definition(id: "S-viral-fit", title: "a padded line still long after its one free fit keeps your words; the other is voiced, Use",
            voiced: 1, fixture: Fixture(rewrites: [.passage(replace(paddedChanges))], fits: [.sameWords],
                                        voice: RewriteSmokeVoiceScript(offset: -0.2))) { harness in
            try await harness.start()
            await harness.viralFitSettled()
            try await harness.finish()
        },
        Definition(id: "S-make-it-long", title: "✦ Make it postable with a padded line still long after its fit: kept as recorded, no click, finished",
            requiresCompletion: false, fixture: Fixture(rewrites: [], fits: [.sameWords], voice: RewriteSmokeVoiceScript(offset: -0.2))) { harness in
            try await harness.makeItLongLine()
        },
        Definition(id: "S-render-recipe", title: "phrase 1's take has no valid render recipe: it keeps your audio, phrase 2 is used",
            voiced: 1, fixture: Fixture(rewrites: [.passage(replace(twoChanges))], voice: RewriteSmokeVoiceScript(offset: -0.2))) { harness in
            harness.session?.publishOverride = { phrase, published in
                guard phrase == 0 else { return published }
                return VoiceLabPublishedTake(assets: published.assets, audio: published.audio, outDuration: published.outDuration,
                                             words: [], chunks: published.chunks)
            }
            try await harness.start()
            try await harness.finish()
            harness.renderRecipeSettled()
        },
        Definition(id: "S-duration-short", title: "a 0.41 s take for a long slot fits no video duration: it keeps your audio, the other is used",
            voiced: 1, fixture: Fixture(firstWord: 23, rewrites: [.passage(replace([("words we got wrong.", "bits."), twoChanges[1]])
                .split(separator: " ").dropFirst(23).joined(separator: " "))], fits: [.sameWords, .sameWords, .sameWords],
                voice: RewriteSmokeVoiceScript(offset: -0.1, seconds: ["bits.": 0.325]))) { harness in
            try await harness.start()
            try await harness.finish()
            harness.durationShortSettled()
        },
        Definition(id: "S-duration-claude", title: "✦ Make it postable rewrites a line to a 0.41 s take no duration carries: kept as recorded, no click, ready to export",
            requiresCompletion: false, fixture: Fixture(rewrites: [], voice: RewriteSmokeVoiceScript(offset: -0.1, seconds: ["bits.": 0.325]))) { harness in
            try await harness.makeItDurationShort()
        },
    ] }
}

extension DebugRewriteSmoke.Harness {
    /// VF1 and VF2, once the reply and its automatic fit have landed.
    func viralFitSettled() async {
        guard let session else { return }
        let records = await connector?.records ?? []
        let fits = records.filter { $0.tag == "voice-rewrite-fit" }.count
        // The padded change's ordinal depends on how the reply's diff splits; it is the one the fit kept.
        let kept = session.wordingFit.kept.count == 1 && session.wordingFit.kept.allSatisfy { session.ownProposal?[$0]?.state == .excluded }
        let note = session.autoFix.notes.contains { $0.contains("keeps your original words: still longer than its time in the video") }
        makeItAppend([DebugRewriteSmoke.Check(invariant: "VF1", passed: kept && note && fits == 1 && session.blockedVoiceOrdinals.isEmpty,
            detail: "\(fits) fit request\(fits == 1 ? "" : "s") · changes \(session.wordingFit.kept.sorted()) " + (kept ? "kept as recorded" : "not kept")
                + (note ? " · said why" : " · no note") + " · footer [\(session.task.footer.primary?.title ?? "none")] '\(session.task.footer.note ?? "")'")])
        let slots = records.first { $0.tag == "voice-rewrite" }?.slots == true
        makeItAppend([DebugRewriteSmoke.Check(invariant: "VF2", passed: slots,
            detail: slots ? "the rewrite request listed each span's time and word budget, and why" : "no slots in the rewrite request")])
        // Reading the connector's record lets queued work run; let it finish before the next click.
        await settle()
    }

    /// ✦ Make it postable rewrites sentence 2 with padding; MK1: its one fit request leaves it long, the driver keeps it as
    /// recorded with no click, nothing is spent and the run is ready to export.
    func makeItLongLine() async throws {
        let editor = try makeItPrepare { range, words in
            guard let first = DebugRewriteSmoke.wordIndex("record", in: words, from: range.lowerBound),
                  let last = DebugRewriteSmoke.wordIndex("take.", in: words, from: first) else { return nil }
            return DebugRewriteSmoke.makeItPlan(span: range, cut: nil, rewrite: (first...last,
                "record, or put differently, film a short clip, and then, in addition to that, all of it in one single continuous take."),
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
        let segments = editor.project.voiceLab.segments.count
        try await act("click [\(editor.makeItTitle(clipID: "smoke-clip"))]", clicked: "makeIt") {
            editor.makeItPostable("smoke-clip")
            await editor.makeIt.run(for: "smoke-clip")?.task?.value
        }
        ended = true
        guard let run = editor.makeIt.run(for: "smoke-clip") else { throw DebugRewriteSmoke.Failure.setup("no run") }
        let rewrite = run.rows.first { $0.id == "rewrite-0" }
        let next = editor.makeItNextStep(run)
        let fits = (await connector?.records ?? []).filter { $0.tag == "voice-rewrite-fit" }.count
        let kept = rewrite.map { $0.text.hasPrefix("Kept your words") } ?? false
        completed = kept
        makeItAppend([DebugRewriteSmoke.Check(invariant: "MK1",
            passed: kept && fits <= 1 && run.phase == .ready && next.hasPrefix("Next: Export") && run.spent == 0
                && editor.project.voiceLab.segments.count == segments && editor.openRewrite?.isOpen != true,
            detail: (rewrite.map { "\($0.text) · \($0.detail)" } ?? "no rewrite row") + " · \(fits) fit · \(next) · spent \(EditorModel.makeItDollars(run.spent))"
                + (editor.openRewrite?.isOpen == true ? " · Rewrite left open" : ""))])
    }

    /// DS1: phrase 1's 0.41 s take fits no video duration, so it kept the recorded audio with one line, said once and with
    /// no click; no footer asked for a duration no control makes, and Use applied phrase 2.
    func durationShortSettled() {
        let line = "Phrase 1's take can't fit its place in the video, so it keeps your original audio."
        let said = editor?.announcements.filter { $0 == line }.count ?? 0
        let asked = steps.contains { $0.snapshot.footer?.contains("Choose the video duration") == true }
        let clickedKeep = steps.contains { $0.action.contains("Keep Original Audio") || $0.action.contains("take 1 on phrase 1") }
        makeItAppend([DebugRewriteSmoke.Check(invariant: "DS1", passed: completed && said == 1 && !asked && !clickedKeep && appliedVideoModes.count == 1,
            detail: (completed ? "Use applied " : "Use not applied ") + "\(appliedVideoModes.count) phrase · said \(said)× '\(line)'"
                + (asked ? " · a footer asked for a duration" : "") + (clickedKeep ? " · phrase 1 needed a click" : ""))])
    }

    /// ✦ Make it postable (the driver ✦ Claude does it all runs too) rewrites "the words we got wrong." to "the bits.", whose
    /// 0.41 s take no video duration carries. DC1: the driver keeps it as recorded with no click, its row says why, nothing
    /// is voiced into the project and the run is ready to export.
    func makeItDurationShort() async throws {
        let editor = try makeItPrepare { range, words in
            guard let first = DebugRewriteSmoke.wordIndex("words", in: words, from: range.lowerBound),
                  let last = DebugRewriteSmoke.wordIndex("wrong.", in: words, from: first) else { return nil }
            return DebugRewriteSmoke.makeItPlan(span: range, cut: nil, rewrite: (first...last, "bits."),
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
        let segments = editor.project.voiceLab.segments.count
        try await act("click [\(editor.makeItTitle(clipID: "smoke-clip"))]", clicked: "makeIt") {
            editor.makeItPostable("smoke-clip")
            await editor.makeIt.run(for: "smoke-clip")?.task?.value
        }
        ended = true
        guard let run = editor.makeIt.run(for: "smoke-clip") else { throw DebugRewriteSmoke.Failure.setup("no run") }
        let rewrite = run.rows.first { $0.id == "rewrite-0" }
        let next = editor.makeItNextStep(run)
        let line = "Phrase 1's take can't fit its place in the video, so it keeps your original audio."
        let kept = rewrite.map { $0.text.hasPrefix("Kept your words") && $0.detail.contains("can't fit its place in the video") } ?? false
        let paid = (RewriteSmokeHTTP.script.withLock { $0.syntheses }) > 0
        completed = kept
        makeItAppend([DebugRewriteSmoke.Check(invariant: "DC1",
            passed: kept && paid && run.phase == .ready && next.hasPrefix("Next: Export") && editor.announcements.contains(line)
                && editor.project.voiceLab.segments.count == segments && editor.openRewrite?.isOpen != true,
            detail: (rewrite.map { "\($0.text) · \($0.detail)" } ?? "no rewrite row") + " · \(next) · spent \(EditorModel.makeItDollars(run.spent))"
                + (paid ? "" : " · no take was made") + (editor.openRewrite?.isOpen == true ? " · Rewrite left open" : ""))])
    }

    /// RR1: Use went on past phrase 1's unusable take, said why once, and applied phrase 2.
    func renderRecipeSettled() {
        let line = "Phrase 1 couldn't be made part of the video, so it keeps your original audio."
        let said = editor?.announcements.filter { $0 == line }.count ?? 0
        makeItAppend([DebugRewriteSmoke.Check(invariant: "RR1", passed: completed && said == 1 && appliedVideoModes.count == 1,
            detail: (completed ? "Use applied " : "Use not applied ") + "\(appliedVideoModes.count) phrase · said \(said)× '\(line)'")])
    }
}
#endif
