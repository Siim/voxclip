import Foundation
import Observation
import VoxClipCore
import VoxClipMedia

/// Revoice the whole clip (ADR-R46, design.md R2 "How should it sound?"): one AI voice for every word of the clip,
/// laid out on the clip as edited and lip synced. Choose → Running (Script, Voice, Fit, Lip sync, with Cancel) → Review (Play,
/// A/B, the match line, Undo, Use Whole Clip, the sync-3 upgrade). The paid steps go through Rewrite's own take path and
/// lip sync (`RewriteWholeClip.swift`); this session owns the order, the prices, the ledger that never pays a step twice,
/// and what the panel says. Cancel or a failure keeps the clip as it was.
@MainActor @Observable final class WholeClipRevoiceSession {
    typealias Lipsync = WholeClipRevoice.Lipsync
    enum Step: Int, CaseIterable, Identifiable {
        case script, voice, fit, lipsync
        var id: Int { rawValue }
    }
    enum StepState: Equatable {
        case waiting
        case running(String)
        case done(String)
        case failed(String)
    }
    enum Phase: Equatable {
        /// The Choose card.
        case choose
        case running
        /// The voice and lip sync are ready; nothing is in the clip yet.
        case review
        /// Use Whole Clip put it into the project as one undo step.
        case used
        /// Cancelled, failed or couldn't fit: the line says so; the clip is unchanged; the chips go on.
        case stopped(String)
    }
    /// What the Choose card prices: the patch and the whole clip, both from the pricing tables.
    struct Quote: Equatable {
        var clipNumber: Int
        var clipSeconds: Double
        var spokenWords: Int
        var reason: WholeClipRevoice.Reason?
        /// The patch's price, nil while unpriced.
        var patchUSD: Decimal?
        var phrases: Int
        var voiceUSD: Decimal?
        var lipsyncUSD: Decimal?
        var voiceName: String
        /// "matched to this video" for a per-video voice (voice-lab §6.13), else empty.
        var voiceNote: String
        var wholeUSD: Decimal? {
            guard let voiceUSD, let lipsyncUSD else { return nil }
            return voiceUSD + lipsyncUSD
        }
    }
    /// The paid voice: one take for the whole script, in parts.
    struct Voice: Equatable {
        let key: WholeClipRevoiceLedger.VoiceKey
        let seconds: Double
        let parts: Int
        let usd: Decimal
    }
    struct Synced: Equatable {
        let model: Lipsync
        let usd: Decimal
        /// The picture's even speed-up under the voice (the record's `videoRetime`), 1 at the clip's own pace.
        let factor: Double
        /// fal.ai's request it came from, and whether it was an earlier billed attempt's kept result (nothing new paid).
        var requestID: String? = nil
        var recovered = false
    }
    /// The Fit step's picture, checked before the lip sync is offered: the clip as edited under the laid-out voice, sped up
    /// evenly by `speed` (ADR-R46, "Your own pace"), `outputSeconds` long, and ready to be sent for lip sync.
    struct Picture: Equatable {
        let speed: Double
        let outputSeconds: Double
        /// The speed-up hit its cap, so the voice's pauses and the trim take the rest.
        let laidOut: Bool
    }
    struct Backend {
        /// The free script: the clip's words with every edit and rewrite applied.
        var script: @MainActor () throws -> WholeClipScript
        /// The whole clip's price with `model`, free (quotes, the guard's free screen, the tables).
        var quote: @MainActor (WholeClipScript, Lipsync) async throws -> Quote
        /// The voice for the script, paid; `progress` gets a line ("part 2 of 3").
        var voice: @MainActor (WholeClipScript, @escaping @MainActor (String) -> Void) async throws -> Voice
        /// The clip's seconds **as edited** (its cuts and tightened pauses applied): the length the user sees, the timeline
        /// the voice is laid out on and the video the lip sync gets (ADR-R46, "One timeline").
        var videoSeconds: @MainActor () -> Double
        /// The measured-wording round: a **shorter** wording of about `targetWords`; nil when none came back. The voice's and
        /// the video's seconds are the round's measured feedback. A shorter voice is never reworded longer.
        var reword: @MainActor (WholeClipScript, Int, Double, Double) async throws -> WholeClipScript?
        /// The speaking-rate estimate of a script's seconds, free; nil when there is none. Check before paying compares a
        /// reworded script's estimate with the clip before a new voice is made.
        var estimate: @MainActor (WholeClipScript) -> Double? = { _ in nil }
        /// The picture match and the lip sync's free checks on this Mac, at the Fit step: every part's picture matched to its
        /// laid-out take (the cut recipe, the speed-up and the trims), and the merged window one fal.ai can take. Throws what
        /// failed; nothing is sent.
        var picture: @MainActor (Voice) async throws -> Picture = { _ in Picture(speed: 1, outputSeconds: 0, laidOut: false) }
        /// The lip sync over the whole clip, the picture sped up by `factor` (the Fit step's), paid.
        var lipsync: @MainActor (Voice, Double, Lipsync, @escaping @MainActor (Double?) -> Void) async throws -> Synced
        /// The lip sync's price for the upgrade, free.
        var lipsyncPrice: @MainActor (Lipsync) throws -> Decimal?
        /// The take-match line's scores, free, on this Mac.
        var match: @MainActor (Voice) async -> WholeClipRevoiceRecord.Match?
        /// Plays the result (`original` false) or the recording (`original` true) from the clip's start.
        var play: @MainActor (_ original: Bool) -> Void
        /// Puts the result into the project as one undo step; returns the record it saved.
        var use: @MainActor (Voice, Synced, WholeClipRevoiceRecord.Match?) async throws -> WholeClipRevoiceRecord
        /// Takes a used revoice back out (the step list's Undo).
        var undo: @MainActor (WholeClipRevoiceRecord) -> Void
        /// Drops the unused paid work (Undo on Review): the original audio and video stay.
        var discard: @MainActor () async -> Void
        /// Writes one `voice-lab` log line (numbers and case names only, never transcript text).
        var report: @MainActor (String) -> Void = { _ in }
    }
    /// Why the last run stopped: the step, the refused part (1-based) of a placement refusal, and whether trying again
    /// would only stop the same way (a placement refusal, or a stop before anything paid was sent).
    struct Failure: Equatable {
        let step: Step
        let part: Int?
        let repeats: Bool
        /// The log line's kind (`RewriteSession.failureKind`): the real error's type and case.
        var kind: String = ""
        /// The run before stopped the same way, at the same step: Try Again is no longer the primary (design.md, Stopped).
        var again = false
        /// Two stops are the same stop by where they stopped and what follows; the log kind only says why.
        static func == (lhs: Failure, rhs: Failure) -> Bool {
            lhs.step == rhs.step && lhs.part == rhs.part && lhs.repeats == rhs.repeats && lhs.again == rhs.again
        }
    }
    /// A stop before anything paid was sent, which trying again would only repeat; `error` says why.
    struct Unsent: Error {
        let error: any Error
    }
    /// The picture can't be matched to the laid-out voice (the Fit step's check): `error` is what the video preparation
    /// said, and trying again over the same voice meets it again. Nothing was sent.
    struct Unmatched: Error {
        let error: any Error
        var part: Int?
    }
    /// The lip sync failed: `error` is the job's or its preparation's own error. `local` failures (the window couldn't be
    /// prepared, no key, outside the provider's limits) happened on this Mac before fal.ai and repeat on a retry.
    struct LipsyncFailed: Error {
        let error: any Error
        let local: Bool
        /// What fal.ai charged for the failed attempt, when it reached fal.ai (`mayBill`); nil for a free Try Again.
        var usd: Decimal? = nil
        /// fal.ai's request for that charge, so a later free re-import of it is not counted twice.
        var requestID: String? = nil
        /// Its result is kept: Try Again re-imports it for free.
        var freeRetry = false
    }

    private(set) var phase: Phase = .choose
    private(set) var steps: [Step: StepState] = [:]
    private(set) var quote: Quote?
    private(set) var quoting = false
    private(set) var script: WholeClipScript?
    private(set) var voice: Voice?
    private(set) var synced: Synced?
    private(set) var match: WholeClipRevoiceRecord.Match?
    private(set) var record: WholeClipRevoiceRecord?
    private(set) var ledger = WholeClipRevoiceLedger()
    private(set) var started: Date?
    private(set) var progress: Double?
    private(set) var upgradeUSD: Decimal?
    /// Set when the last run failed (not when it was cancelled).
    private(set) var failure: Failure?
    /// The choice on the Choose card: true for the whole clip.
    var wholeSelected = true
    /// Set while a run was started by ✦ Claude does it all, so Review applies on its own.
    private(set) var automatic = false
    @ObservationIgnored var backend: Backend?
    @ObservationIgnored private var run: Task<Void, Never>?
    /// The stop the last run ended in, read once by the next run's failure (`Failure.again`).
    @ObservationIgnored private var previousFailure: Failure?
    @ObservationIgnored private var rewordRound = 0
    /// The clip's own script the last run started from (before any measured wording).
    @ObservationIgnored private var baseScript: String?
    /// The script a run stopped at the Fit step for (the voice can't fit, or a reword came back no shorter): Try Again over
    /// the same script would only meet the same fit, so the patch becomes the primary (ADR-R46).
    @ObservationIgnored private var fitStoppedScript: String?
    /// The Fit step's picture for the current voice.
    private(set) var picture: Picture?

    var running: Bool { run != nil }
    /// Waits for the run under way, if any.
    func waitForRun() async { await run?.value }
    /// Failed lip syncs fal.ai charged for, by request: in the spent total until a free re-import puts one in the ledger.
    private(set) var billedLipsyncs: [String: Decimal] = [:]
    /// The last lip sync failed with its paid result kept: Try Again re-imports it and pays nothing for the lip sync.
    private(set) var lipsyncKept = false
    var spent: Decimal { ledger.total + billedLipsyncs.values.reduce(0, +) }

    /// What Try Again would pay for the whole clip: what's left after the paid steps, and nothing for a kept lip sync.
    var retryUSD: Decimal? {
        guard let usd = quote?.wholeUSD else { return nil }
        let kept: Decimal = lipsyncKept ? (quote?.lipsyncUSD ?? 0) : 0
        return max(0, usd - ledger.total - kept)
    }

    /// Prices the card. Free.
    func refreshQuote() async {
        guard let backend, !running, !quoting else { return }
        quoting = true
        defer { quoting = false }
        do {
            let script = try backend.script()
            self.script = script
            quote = try await backend.quote(script, .standard)
        } catch { quote = nil }
    }

    /// Revoice Whole Clip · ≈ $X: the click is the approval for the voice and the lip sync at the shown price.
    func start(automatic: Bool = false) {
        guard backend != nil, !running, phase != .used else { return }
        self.automatic = automatic
        previousFailure = failure
        phase = .running; started = Date(); progress = nil; rewordRound = 0; failure = nil; fitStoppedScript = nil; picture = nil
        steps = Dictionary(uniqueKeysWithValues: Step.allCases.map { ($0, StepState.waiting) })
        run = Task { [weak self] in
            await self?.perform(model: .standard)
            self?.run = nil
        }
    }

    /// Sharper Lip Sync · sync-3: re-runs only the lip sync, over the voice already paid for.
    func upgrade() {
        guard backend != nil, !running, phase == .review, synced?.model != .sync3, voice != nil else { return }
        phase = .running; started = Date(); progress = nil; failure = nil
        steps[.lipsync] = .waiting
        run = Task { [weak self] in
            await self?.perform(model: .sync3)
            self?.run = nil
        }
    }

    /// Cancel keeps the clip: nothing is put in, and what was paid stays in the ledger, so Try Again pays only what is left.
    func cancel() {
        guard let run else { return }
        run.cancel()
    }

    private func perform(model: Lipsync) async {
        guard let backend else { return }
        do {
            // Script: free. A run again over the same clip keeps a wording the Fit step asked for, and so its paid voice.
            let base = try backend.script()
            var script = base
            if base.text == baseScript, let kept = self.script { script = kept }
            baseScript = base.text
            self.script = script
            steps[.script] = .done("Script · \(script.words) words, your edits applied")
            try Task.checkCancellation()
            var voice = try await voiceStep(script, backend: backend)
            // Fit: free, on the clip as edited. Only a voice too long for it asks for a measured wording, which is checked
            // against the clip before it is said again (a new script, a new voice); a shorter voice is laid out, never padded.
            var verdict: String
            while true {
                let video = backend.videoSeconds()
                let measured = "Fit · \(Self.clock(voice.seconds)) for \(Self.clock(video)) of video"
                switch WholeClipRevoice.fit(voiceSeconds: voice.seconds, videoSeconds: video, words: script.words, round: rewordRound) {
                case .matched(let matched):
                    verdict = measured + ", " + WholeClipRevoice.matchedCopy(factor: matched)
                case .laidOut(let laid):
                    verdict = measured + ", " + WholeClipRevoice.laidOutCopy(factor: laid)
                case .reword(let target):
                    rewordRound += 1
                    steps[.fit] = .running(measured + " · asking for a shorter wording (≈ \(target) words)")
                    guard let next = try await backend.reword(script, target, voice.seconds, video) else {
                        throw Stop.cannotFit(voice: voice.seconds, video: video)
                    }
                    try Task.checkCancellation()
                    // Check before paying: the new wording is voiced only when its estimate fits the clip.
                    if let before = backend.estimate(script), let after = backend.estimate(next),
                       !WholeClipRevoice.rewordFits(voiceSeconds: voice.seconds, estimateSeconds: before, newEstimateSeconds: after, videoSeconds: video) {
                        let predicted = WholeClipRevoice.predictedSeconds(voiceSeconds: voice.seconds, estimateSeconds: before, newEstimateSeconds: after)
                        throw Stop.rewordTooLong(predicted: predicted ?? voice.seconds, video: video)
                    }
                    script = next; self.script = next
                    steps[.script] = .done("Script · \(next.words) words, reworded to fit")
                    steps[.voice] = .waiting
                    voice = try await voiceStep(next, backend: backend)
                    continue
                case .cannotFit(let voiceSeconds, let videoSeconds):
                    throw Stop.cannotFit(voice: voiceSeconds, video: videoSeconds)
                }
                break
            }
            // The Fit passes only when the picture can be matched to the laid-out voice and sent for lip sync: the same
            // checks the Lip sync step needs, run here for free, so a reason known now never shows up as a lip-sync stop.
            steps[.fit] = .running(verdict + " · matching the picture")
            let picture = try await backend.picture(voice)
            try Task.checkCancellation()
            self.picture = picture
            let video = backend.videoSeconds()
            let measured = "Fit · \(Self.clock(voice.seconds)) for \(Self.clock(video)) of video"
            // A speed-up too small to show (under 1.005×) keeps the plain verdict.
            let sped = WholeClipRevoice.speedLabel(picture.speed) != WholeClipRevoice.speedLabel(1)
            steps[.fit] = .done(sped ? measured + ", " + WholeClipRevoice.spedCopy(speed: picture.speed, laidOut: picture.laidOut) : verdict)
            let factor = picture.speed
            // Lip sync: paid once per voice, picture speed and model.
            let key = WholeClipRevoiceLedger.LipsyncKey(voice: voice.key, retime: factor, model: model)
            let price = (try? backend.lipsyncPrice(model)).flatMap { $0 }
            steps[.lipsync] = .running("Lip sync · fal.ai \(model.name) · usually 1–2 min")
            let synced: Synced
            if let previous = self.synced, previous.model == model, ledger.paid(key) {
                synced = previous
            } else {
                synced = try await backend.lipsync(voice, factor, model) { [weak self] value in self?.progress = value }
                // A kept result's re-import moves its charge from the failed attempts into the ledger; a new paid one adds to it.
                if synced.recovered, let request = synced.requestID { billedLipsyncs.removeValue(forKey: request) }
                ledger.record(key, usd: (ledger.lipsyncs[key] ?? 0) + synced.usd)
                lipsyncKept = false
            }
            try Task.checkCancellation()
            self.synced = synced
            steps[.lipsync] = .done("Lip sync · fal.ai \(model.name)" + (price.map { " · " + VoiceLabCostPresentation.format($0) } ?? ""))
            match = await backend.match(voice)
            upgradeUSD = model == .sync3 ? nil : (try? backend.lipsyncPrice(.sync3)).flatMap { $0 }
            phase = .review
            if automatic { await use() }
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            // The step it stopped in: the first one not done.
            let step = Step.allCases.first { if case .done = steps[$0] { false } else { true } } ?? .lipsync
            for each in Step.allCases {
                if case .running = steps[each] { steps[each] = cancelled ? .waiting : .failed(Self.copy(error)) }
            }
            if let failed = error as? LipsyncFailed {
                if let usd = failed.usd { billedLipsyncs[failed.requestID ?? UUID().uuidString] = usd }
                lipsyncKept = failed.freeRetry
            }
            if !cancelled {
                if steps[step] == .waiting { steps[step] = .failed(Self.copy(error)) }
                let part = Self.part(error)
                let kind = RewriteSession.failureKind(Self.cause(error))
                let again = previousFailure.map { $0.step == step && $0.kind == kind } ?? false
                failure = Failure(step: step, part: part, repeats: step == .script || Self.repeats(error), kind: kind, again: again)
                if step == .fit { fitStoppedScript = baseScript }
                backend.report("whole clip failure step=\(step) " + kind + (part.map { " part=\($0)" } ?? ""))
            }
            phase = .stopped(cancelled ? "Cancelled. Your clip is unchanged." + paidNote : Self.copy(error) + paidNote)
        }
    }

    private var paidNote: String {
        ledger.total > 0 ? " What was paid (\(VoiceLabCostPresentation.format(ledger.total))) is kept, so trying again pays only what's left." : ""
    }

    private func voiceStep(_ script: WholeClipScript, backend: Backend) async throws -> Voice {
        if let voice, voice.key.script == script.text, ledger.paid(voice.key) {
            steps[.voice] = .done(Self.voiceLine(voice, quote: quote))
            return voice
        }
        steps[.voice] = .running("Voice · saying \(script.words) words")
        let made = try await backend.voice(script) { [weak self] line in self?.steps[.voice] = .running("Voice · " + line) }
        ledger.record(made.key, usd: made.usd)
        voice = made
        synced = nil; picture = nil
        steps[.voice] = .done(Self.voiceLine(made, quote: quote))
        return made
    }

    /// Use Whole Clip: one undo step.
    func use() async {
        guard let backend, phase == .review, let voice, let synced else { return }
        do {
            record = try await backend.use(voice, synced, match)
            phase = .used
        } catch {
            phase = .stopped("Couldn't put the whole clip in: " + Self.copy(error) + " Your clip is unchanged.")
        }
    }

    /// Undo on Review: the original audio and video stay; the paid voice is let go.
    func discard() async {
        guard let backend, phase == .review || isStopped else { return }
        await backend.discard()
        phase = .choose; voice = nil; synced = nil; match = nil; steps = [:]; upgradeUSD = nil
    }

    /// Undo after Use (the autopilot's step list).
    func undoUse() {
        guard let backend, phase == .used, let record else { return }
        backend.undo(record)
        self.record = nil
        phase = .review
    }

    var isStopped: Bool { if case .stopped = phase { true } else { false } }

    /// The last run stopped at the Fit step and the clip's script is still the one it stopped for: Try Again would meet
    /// the same fit, so the card makes the patch its primary (ADR-R46, "Try Again doesn't repeat a failure").
    var repeatsFit: Bool {
        guard isStopped, failure?.step == .fit, let stopped = fitStoppedScript, let backend else { return false }
        return (try? backend.script().text) == stopped
    }

    enum Stop: Error, Equatable {
        case cannotFit(voice: Double, video: Double)
        /// Check before paying: the shorter wording's estimate still runs `predicted` for `video`, so no voice was made.
        case rewordTooLong(predicted: Double, video: Double)
        case noVoice(String)
        /// Part `part` (1-based)'s picture allows no cut or kept-source video under its laid-out take.
        case pictureUnmatched(part: Int)
    }

    /// What the Voice step and the card say. A part that can't be placed says which part and why; only a lip-sync error uses
    /// the lip-sync copy; everything else is Rewrite's own copy, which falls back to `UserMessages.message`.
    static func copy(_ error: any Error) -> String {
        switch error {
        case let unsent as Unsent: return copy(unsent.error)
        case Stop.cannotFit(let voice, let video):
            return "The new voice runs \(clock(voice)) for \(clock(video)) of video, longer than the clip can hold."
        case Stop.rewordTooLong(let predicted, let video):
            return "The shorter wording would still run about \(clock(predicted)) for \(clock(video)) of video, so no new voice was made."
        case Stop.noVoice(let reason): return reason
        case Stop.pictureUnmatched(let part):
            return "Part \(part)'s picture can't be matched to its voice on the clip as edited. Nothing was sent for lip sync."
        case let unmatched as Unmatched:
            let reason = ClipTakePlan.copy(unmatched.error)
            return "The picture couldn't be matched to the voice: " + reason + (reason.hasSuffix(".") ? "" : ".") + " Nothing was sent for lip sync."
        case let failed as LipsyncFailed:
            let charge: String
            if failed.local { charge = " Nothing was sent to fal.ai." }
            else if let usd = failed.usd {
                charge = " fal.ai charged for the attempt (\(VoiceLabCostPresentation.format(usd)))."
                    + (failed.freeRetry ? " Its result is kept, so Try Again is free." : "")
            } else { charge = "" }
            return "Couldn't lip sync: " + RewriteLipsyncSession.reason(failed.error) + charge
        case ClipTakePlan.Failure.placement(let refusal, let index): return placementCopy(refusal, part: index + 1)
        case is LipsyncError, is LipsyncPreparationError: return RewriteLipsyncSession.reason(error)
        default: return RewriteSession.refusal(error)
        }
    }

    /// "Part 2 can't be joined to the recording there. Nothing was sent."
    static func placementCopy(_ refusal: VoiceLabWindowRefusal, part: Int) -> String {
        if let copy = refusal.copy { return "Part \(part): \(copy) Nothing was sent." }
        if case .geometry(let error) = refusal, let isStart = error.takeEdgeIsStart {
            return "Part \(part) can't be joined to the recording there: it is too close to the \(isStart ? "start" : "end") of the take. Nothing was sent."
        }
        return "Part \(part) can't be joined to the recording there. Nothing was sent."
    }

    /// The error a wrapper stands for: what actually failed, for the log line's type and case.
    static func cause(_ error: any Error) -> any Error {
        switch error {
        case let unsent as Unsent: return cause(unsent.error)
        case let unmatched as Unmatched: return cause(unmatched.error)
        case let failed as LipsyncFailed: return cause(failed.error)
        case let failure as LipsyncAttemptFailure: return cause(failure.error)
        default: return error
        }
    }

    /// The refused part, 1-based, of a placement refusal or a picture that can't be matched.
    static func part(_ error: any Error) -> Int? {
        if case Stop.pictureUnmatched(let part) = error { return part }
        if let unmatched = error as? Unmatched, let part = unmatched.part { return part }
        if case ClipTakePlan.Failure.placement(_, let index) = cause(error) { return index + 1 }
        return nil
    }

    /// Trying again would only stop the same way: the parts can't be placed, nothing is left to voice, too many parts, or
    /// a stop before anything paid was sent. A network or provider failure can succeed on a retry.
    static func repeats(_ error: any Error) -> Bool {
        if error is Unsent || error is Unmatched { return true }
        if case Stop.pictureUnmatched = error { return true }
        if let failed = error as? LipsyncFailed { return failed.local }
        switch error {
        case ClipTakePlan.Failure.placement, ClipTakePlan.Failure.nothingToVoice, ClipTakePlan.Failure.tooManyPhrases: return true
        default: return false
        }
    }

    static func voiceLine(_ voice: Voice, quote: Quote?) -> String {
        let parts = voice.parts == 1 ? "one take" : "\(voice.parts) parts, one take"
        return "Voice · \(clock(voice.seconds)) in \(quote?.voiceName ?? "your voice") · \(parts)"
    }

    /// "0:30.6", "0:31".
    static func clock(_ seconds: Double) -> String {
        let value = max(0, seconds.isFinite ? seconds : 0)
        let minutes = Int(value) / 60
        let rest = value - Double(minutes * 60)
        let whole = (rest * 10).rounded() / 10
        if whole == whole.rounded() { return String(format: "%d:%02d", minutes, Int(whole)) }
        return String(format: "%d:%04.1f", locale: Locale(identifier: "en_US_POSIX"), minutes, whole)
    }

    /// What a step's right column says: "free" for the free steps, the price for the paid ones.
    func price(of step: Step) -> String {
        switch step {
        case .script, .fit: return "free"
        case .voice: return voice.map { VoiceLabCostPresentation.format($0.usd) } ?? quote?.voiceUSD.map(VoiceLabCostPresentation.format) ?? ""
        case .lipsync: return synced.map { VoiceLabCostPresentation.format($0.usd) } ?? quote?.lipsyncUSD.map(VoiceLabCostPresentation.format) ?? ""
        }
    }

    #if DEBUG
    /// A fixture state for the scene audit and the smoke's screenshots.
    func showFixture(_ phase: Phase, quote: Quote, voice: Voice? = nil, synced: Synced? = nil, match: WholeClipRevoiceRecord.Match? = nil) {
        self.quote = quote; self.phase = phase; self.voice = voice; self.synced = synced; self.match = match
        started = Date().addingTimeInterval(-42)
    }
    #endif
}
