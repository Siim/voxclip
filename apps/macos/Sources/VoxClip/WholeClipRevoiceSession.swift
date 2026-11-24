import Foundation
import Observation
import VoxClipCore
import VoxClipMedia

/// Revoice the whole clip (ADR-R46, design.md R2 "How should it sound?"): one AI voice for every word of the clip,
/// laid out on the clip as edited and lip synced. Choose → Running (Script, Voice, Fit, Lip sync, with Cancel) → Review (Play,
/// A/B, the match line, Undo, Use Whole Clip). The paid steps go through Rewrite's own take path and
/// lip sync (`RewriteWholeClip.swift`); this session owns the order, the prices, the ledger that never pays a step twice,
/// and what the panel says. Cancel or a failure keeps the clip as it was, and never forgets what was paid: a paid voice
/// stays usable until an edit changes what it was made from (then Undo brings it back), and a paid lip sync stays applied
/// through Try Again and a failed Use.
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
        var wordChecksUSD: Decimal? = nil
        var pricesJournaledVoice = false
        var voicePassUSD: Decimal? { voiceUSD.map { $0 + (wordChecksUSD ?? 0) } }
        var wholeUSD: Decimal? {
            guard let voicePassUSD, let lipsyncUSD else { return nil }
            return voicePassUSD + lipsyncUSD
        }
    }
    /// The paid voice: one take for the whole script, in parts.
    struct Voice: Equatable {
        let key: WholeClipRevoiceLedger.VoiceKey
        let seconds: Double
        let parts: Int
        let usd: Decimal
        /// How far the longest part's laid-out take runs past its window on the clip as edited (laid out ÷ window, above 1)
        /// when no picture can carry it: not its source, not its cuts, not a retime within the fit tolerance. The Fit step
        /// then asks for a shorter wording and keeps the voice, rather than matching a picture it can't. Nil when every
        /// part's picture can be matched.
        var overrun: Double? = nil
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
    /// A shorter wording the Fit step got back and checked before paying, whose voice is not covered by the click that
    /// started the run (a manual run's extra voice, or one past an automatic run's budget): "Voice the Shorter Wording · ≈ $Y"
    /// is its own approval. `usd` is what that click charges: the new voice, and the lip sync still to pay.
    struct ShorterWording: Equatable {
        let script: WholeClipScript
        let usd: Decimal?
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
        /// An AI is there to ask for a shorter wording. Without one the check before the first voice can't reword, so it
        /// leaves the length to the Fit step's measured check.
        var canReword: @MainActor () -> Bool = { true }
        /// The calibrated speaking-rate estimate of a script's seconds, free; nil when there is none. Check before paying
        /// compares it with the clip as edited before the first voice, and a reworded script's with the measured voice.
        var estimate: @MainActor (WholeClipScript) -> Double? = { _ in nil }
        var unfinishedVoicePrice: @MainActor () -> Decimal? = { nil }
        /// What the voice plan held now has paid for parts of a voice not finished yet (a retired plan's is `retiredVoiceSpend`).
        var unsettledVoiceSpend: @MainActor () -> Decimal = { 0 }
        /// What plans let go (Start Over, a new voice) had paid for parts of voices never finished: counted, no longer held.
        var retiredVoiceSpend: @MainActor () -> Decimal = { 0 }
        /// The voice plan held now is for `script` and has paid for some of its parts: the check before paying keeps them.
        var partlyVoiced: @MainActor (WholeClipScript) -> Bool = { _ in false }
        /// What stops the Voice step before anything is sent until something outside the card changes: no voice chosen,
        /// Voice Lab not ready, a project that can't be edited, or a clip edited since the Rewrite was made. Nil when ready.
        var voiceReadiness: @MainActor () -> Stop? = { nil }
        /// The picture match and the lip sync's free checks on this Mac, at the Fit step: every part's picture matched to its
        /// laid-out take (the cut recipe, the speed-up and the trims), and the merged window one fal.ai can take. Throws what
        /// failed; nothing is sent.
        var picture: @MainActor (Voice) async throws -> Picture = { _ in Picture(speed: 1, outputSeconds: 0, laidOut: false) }
        /// The lip sync over the whole clip, the picture sped up by `factor` (the Fit step's), paid.
        var lipsync: @MainActor (Voice, Double, Lipsync, @escaping @MainActor (Double?) -> Void) async throws -> Synced
        /// The lip sync's price, free to check.
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
        /// Whether the fal.ai key is there (presence only, free): without it nothing is priced, and the card opens Settings.
        var hasKey: @MainActor () async -> Bool = { true }
        /// The free checks on the source before any voice is paid for: the source and the clip as edited within the lip
        /// sync's limits (the Voice step checks the fal.ai key). Throws what failed; nothing is sent.
        var preflight: @MainActor () async throws -> Void = {}
        /// The paid voice's parts can be used as made: their plan is current again (an Undo after an edit of the clip).
        var voiceCurrent: @MainActor (Voice) -> Bool = { _ in true }
        /// The lip syncs applied to the voice's parts now (the plan's `Applied` entries), kept beside `synced`.
        var appliedLipsync: @MainActor () -> [Int: RewriteLipsyncSession.Applied] = { [:] }
        /// Puts kept entries back on the parts when they are no longer applied (for free: nothing is sent). True when the
        /// parts hold them now, or there is nothing to put back.
        var restoreLipsync: @MainActor ([Int: RewriteLipsyncSession.Applied]) async -> Bool = { _ in true }
        /// Puts the paid voice in without lip sync: its parts as ordinary Voice Lab segments over the matched picture, one
        /// undo step, no whole-clip record (the project format is unchanged). Free: nothing is sent.
        var useVoiceOnly: @MainActor (Voice) async throws -> Void = { _ in throw Stop.unavailable }
        /// Something paid, or where the run stopped, changed: the live one saves the Rewrite with its whole clip beside the
        /// project's Voice Lab data (`RewriteSession.persistPaidWork`), so a relaunch or a crash offers it back.
        var persist: @MainActor () -> Void = {}
        /// The key a voice of `script` would carry if made now: the voice chosen and the model. Nil while no voice is chosen.
        /// A voice restored after a relaunch comes back for free only under its own key (`restoredVoiceChosen`).
        var voiceKey: @MainActor (WholeClipScript) -> WholeClipRevoiceLedger.VoiceKey? = { _ in nil }
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
        /// Use couldn't put the result in: Try Use Again is free, and nothing is voiced or patched instead.
        var atUse = false
        /// A Fit stop whose way on is a shorter wording (none came back, or one that still runs long), with a round left:
        /// Shorter Wording · free asks again, and no priced Try Again is offered.
        var rewordable = false
        /// Two stops are the same stop by where they stopped and what follows; the log kind only says why.
        static func == (lhs: Failure, rhs: Failure) -> Bool {
            lhs.step == rhs.step && lhs.part == rhs.part && lhs.repeats == rhs.repeats && lhs.again == rhs.again && lhs.atUse == rhs.atUse
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
    /// The paid voice went in without lip sync (Use the Voice Without Lip Sync): `.used` with no whole-clip record.
    private(set) var usedVoiceOnly = false
    private(set) var ledger = WholeClipRevoiceLedger()
    private(set) var started: Date?
    private(set) var progress: Double?
    /// Set when the last run failed (not when it was cancelled).
    private(set) var failure: Failure?
    /// The choice on the Choose card: true for the whole clip.
    var wholeSelected = true
    /// Set while a run was started by ✦ Claude does it all, so Review applies on its own.
    private(set) var automatic = false
    /// The fal.ai key is there (read with the price, and again when Settings changes): without it nothing is priced.
    private(set) var keyAvailable = true
    /// A shorter wording waiting for its own click (`ShorterWording`), nil otherwise.
    private(set) var shorterWording: ShorterWording?
    /// The proposal the card was made for (`RewriteSession.proposalID`): a new one makes a fresh card and default.
    @ObservationIgnored var proposalID: UUID?
    @ObservationIgnored var backend: Backend?
    @ObservationIgnored private var run: Task<Void, Never>?
    /// The stop the last run ended in, read once by the next run's failure (`Failure.again`).
    @ObservationIgnored private var previousFailure: Failure?
    @ObservationIgnored private var rewordRound = 0
    /// The clip's own script the last run started from (before any measured wording).
    @ObservationIgnored private var baseScript: WholeClipScript?
    /// The script a run stopped at the Fit step for (the voice can't fit, or a reword came back no shorter): Try Again over
    /// the same script would only meet the same fit, so the patch becomes the primary (ADR-R46).
    @ObservationIgnored private var fitStoppedScript: WholeClipScript?
    /// The step the run is in, and the one the last run stopped in (a failure or a cancel): what a Try Again may keep.
    @ObservationIgnored private var currentStep: Step = .script
    @ObservationIgnored private var stoppedAt: Step?
    /// The error the last run stopped with, for the stopped card's actions.
    @ObservationIgnored private(set) var stopError: (any Error)?
    /// What an automatic run may still spend (✦ Claude does it all's cap), read before a reworded voice; nil: no extra voice.
    @ObservationIgnored private(set) var budget: Decimal?
    @ObservationIgnored private(set) var journalVoiceApproval: Decimal?
    /// The plan's `Applied` lip syncs for `synced`: put back when a step took them off (`Backend.restoreLipsync`).
    @ObservationIgnored private(set) var syncedEntries: [Int: RewriteLipsyncSession.Applied] = [:]
    /// False while the lip sync may only put back one already paid for (the window's imported index answers it for free).
    @ObservationIgnored private(set) var lipsyncMayPay = true
    /// The user checked fal.ai's request history after a lost submit answer and asked to lip sync again (it may charge
    /// twice): the next lip sync starts past that check, once. Only the user's click sets it.
    @ObservationIgnored private(set) var checkedFal = false
    /// The Fit step's picture for the current voice.
    private(set) var picture: Picture?

    var running: Bool { run != nil }
    /// Waits for the run under way, if any.
    func waitForRun() async { await run?.value }
    /// Failed lip syncs fal.ai charged for, by request: in the spent total until a free re-import puts one in the ledger.
    private(set) var billedLipsyncs: [String: Decimal] = [:]
    /// The last lip sync failed with its paid result kept: Try Again re-imports it and pays nothing for the lip sync.
    private(set) var lipsyncKept = false
    /// The last lip sync's submit answer was lost: only the user's "I Checked fal.ai" click starts another (may charge twice).
    private(set) var submissionUnconfirmed = false
    /// What an earlier run of this Rewrite paid before VoxClip quit or crashed (`restore`): its voice, by key, which E's
    /// journal gives back with only the parts' word checks to pay (`restoredVoiceUSD`), and its lip syncs, which C's index
    /// re-imports for free. Each moves into the ledger as it comes back; one that can't is let go and still counted.
    private(set) var restoredVoices: [WholeClipRevoiceLedger.VoiceKey: Decimal] = [:]
    private(set) var restoredLipsyncs: [WholeClipRevoiceLedger.LipsyncKey: Decimal] = [:]
    /// What putting the restored voice back costs, part by part (`RewriteSession.restoredVoiceUSD`): the word checks of the
    /// parts the journal gives back and a new voice for the others. Nil when that can't be made exact.
    private(set) var restoredVoiceUSD: Decimal?
    /// The restored voice's parts, how many of them the journal gives back, and one part's word check.
    private(set) var restoredParts = 0
    private(set) var restoredPartsBack = 0
    private(set) var restoredPartRequests: [String] = []
    @ObservationIgnored var pendingLipsync: RewriteSavedProposal.PendingLipsync?
    @ObservationIgnored private var restoredCheckUSD: Decimal?
    /// Every part of the restored voice comes back from the journal: the voice is the one its lip sync was made over, so
    /// C's index re-imports that lip sync for free. With a part voiced again the clip's audio differs, and the lip sync is
    /// paid for again (priced on Try Again, never expected back).
    var restoredVoiceWhole: Bool { restoredParts > 0 && restoredPartsBack == restoredParts }
    /// What Try Again pays to put the restored voice back: `restoredVoiceUSD`, or, when that couldn't be made exact, the
    /// voice as new with a word check per part, which the fresh plan never exceeds. Nil before the card is priced.
    var restoredRetryVoiceUSD: Decimal? {
        if let restoredVoiceUSD { return restoredVoiceUSD }
        guard let voice = quote?.voiceUSD else { return nil }
        let checks: Decimal = (restoredCheckUSD ?? 0) * Decimal(max(restoredParts, 1))
        return voice + checks
    }
    /// What was paid before and let go since (a lip sync C's index couldn't give back, Start Over over a restored voice).
    private(set) var restoredLetGo: Decimal = 0
    /// The restored lip sync the current run's Lip sync step is putting back, which is let go if that fails.
    @ObservationIgnored private var restoringLipsync: WholeClipRevoiceLedger.LipsyncKey?
    private var restoredSpent: Decimal { restoredVoices.values.reduce(0, +) + restoredLipsyncs.values.reduce(0, +) + restoredLetGo }
    var spent: Decimal {
        ledger.total + billedLipsyncs.values.reduce(0, +) + (backend?.unsettledVoiceSpend() ?? 0) + (backend?.retiredVoiceSpend() ?? 0) + restoredSpent
    }
    /// What the whole clip's voices cost so far: the paid voices and the parts of ones never finished, let go or not.
    var voiceSpent: Decimal {
        ledger.voices.values.reduce(0, +) + (backend?.unsettledVoiceSpend() ?? 0) + (backend?.retiredVoiceSpend() ?? 0) + restoredVoices.values.reduce(0, +)
    }
    /// What the voice still held cost: the run's voice, the paid parts of the one its plan is still making, or a restored
    /// one. A voice let go (Start Over, the patch) or replaced by a shorter wording's counts in `spent`, never here: no stop
    /// or label says a paid voice is kept or dropped for it.
    var heldVoiceSpent: Decimal {
        (voice.flatMap { ledger.voices[$0.key] } ?? 0) + (backend?.unsettledVoiceSpend() ?? 0) + restoredVoices.values.reduce(0, +)
    }

    /// What Try Again would pay for the whole clip: what's left after the paid steps, and nothing for a lip sync already
    /// paid over this voice and picture (the ledger) or a kept result. Once the Fit step matched the picture, the lip sync
    /// is priced on that picture, as its step pays it.
    var retryUSD: Decimal? {
        if let model = pictureRedoModel { return pictureRedoPrice(model) }
        guard repeatedWordCheckPart == nil, let quote, let voicePrice = quote.voicePassUSD, let quoted = quote.lipsyncUSD else { return nil }
        let kept = voice.flatMap { $0.key.script == script?.text && ledger.paid($0.key) ? $0 : nil }
        // A voice paid before a relaunch comes back for its parts' word checks, and its lip sync for free, only under its own
        // key: the voice and model chosen now are the ones it was made with.
        let restored = kept == nil ? restoredVoiceChosen : false
        let remainingVoice = kept != nil ? 0 : restored ? (restoredRetryVoiceUSD ?? voicePrice) : (backend?.unfinishedVoicePrice() ?? voicePrice)
        let lipsyncPaid = synced.map { synced in
            kept.map { ledger.paid(WholeClipRevoiceLedger.LipsyncKey(voice: $0.key, retime: synced.factor, model: synced.model)) } ?? false
        } ?? false
        let lipsyncRestored = restored && restoredLipsyncModel != nil
        let matched: Decimal? = picture != nil ? ((try? backend?.lipsyncPrice(synced?.model ?? .standard)) ?? nil) : nil
        let lipsyncPrice = matched ?? quoted
        return remainingVoice + (lipsyncKept || lipsyncPaid || lipsyncRestored ? 0 : lipsyncPrice)
    }

    /// The voice paid before a relaunch (`restore`) for the card's script, while it is still to come back.
    var restoredVoiceKey: WholeClipRevoiceLedger.VoiceKey? {
        guard let text = script?.text else { return nil }
        return restoredVoices.keys.filter { $0.script == text }.min { $0.recordId < $1.recordId }
    }

    private var restoredLipsyncModel: Lipsync? {
        guard restoredVoiceChosen, restoredVoiceWhole, let key = restoredVoiceKey else { return nil }
        return [Lipsync.standard, .lipsync2].first { model in
            restoredLipsyncs.keys.contains { $0.voice == key && $0.model == model }
        }
    }

    /// The restored voice is the one a voice of the script would be made with now (`Backend.voiceKey`): its voice and model
    /// are chosen, so the journal gives its parts back for their word checks. False while another voice (or none) is
    /// chosen: nothing paid comes back then, and nothing is paid in its place.
    var restoredVoiceChosen: Bool {
        guard let key = restoredVoiceKey, let script else { return false }
        return backend?.voiceKey(script) == key
    }

    /// The stopped card's line under a restored voice, as things are now: what Try Again puts back and for how much, or,
    /// while its voice isn't chosen, that it can't come back. Nil with nothing restored. The price is the one on Try Again.
    var restoredVoiceNote: String? {
        guard isStopped, restoredVoiceKey != nil else { return nil }
        guard restoredVoiceChosen else {
            return "The voice it was made with isn't chosen now, so it can't be put back. Nothing was sent. Start Over pays for a new voice."
        }
        guard restoredVoiceWhole else {
            // What the click pays in all: the parts voiced again, every word check and the lip sync.
            let price = retryUSD.map { " (" + VoiceLabCostPresentation.format($0) + ")" } ?? ""
            let missing = max(1, restoredParts - restoredPartsBack)
            if restoredPartsBack == 0 { return "Its paid parts can't be put back, so Try Again voices it again and lip syncs it again\(price)." }
            let them = missing == 1 ? "the other part" : "the other \(missing) parts"
            return "Try Again puts back \(restoredPartsBack) of its \(restoredParts) paid parts for their word checks, voices \(them) again and lip syncs the clip again\(price)."
        }
        let price = restoredVoiceUSD.map { $0 > 0 ? " for its word checks (\(VoiceLabCostPresentation.format($0)))" : " for free" } ?? ""
        return "Try Again puts it back\(price), without voicing it again."
    }

    /// The fresh price of putting the restored voice back went up past what the button approved (a part's journal entry went
    /// after the card was priced, or another run holds it): the button carries the new price, which its own click approves.
    /// `partsBack` is how many parts the fresh plan adopts: with one voiced again the lip sync can't come back either, so
    /// Try Again prices a new one and the line names the parts ("k of n", or "can't be put back"); nil keeps the count.
    func repriceRestoredVoice(_ usd: Decimal, partsBack: Int?) {
        guard restoredVoiceKey != nil else { return }
        restoredVoiceUSD = usd
        if let partsBack { restoredPartsBack = min(max(partsBack, 0), restoredParts) }
    }

    @ObservationIgnored private var quoteTask: Task<Void, Never>?

    /// Prices the card and reads the fal.ai key. Free.
    func refreshQuote() async {
        if let quoteTask { await quoteTask.value; return }
        guard let backend, !running else { return }
        quoting = true
        let task = Task { [self] in
            await readQuote(backend)
            quoting = false
            quoteTask = nil
        }
        quoteTask = task
        await task.value
    }

    private func readQuote(_ backend: Backend) async {
        keyAvailable = await backend.hasKey()
        let script = try? backend.script()
        quotedScript = script
        quotedVoiceKey = script.flatMap(backend.voiceKey)
        guard let script else { quote = nil; return }
        // A stopped or reviewed run keeps its own script (a reworded one is what its paid voice says).
        if phase == .choose { self.script = script }
        quote = try? await backend.quote(script, .standard)
    }

    /// The script the card's prices were made for: Start Over and the Choose card price the clip as it is, so a change of
    /// its words or included changes prices it again (`needsRequote`).
    @ObservationIgnored private(set) var quotedScript: WholeClipScript?
    @ObservationIgnored private var quotedVoiceKey: WholeClipRevoiceLedger.VoiceKey?

    /// The clip's script is no longer the one the shown price was made for, on a card whose button prices the clip as it
    /// is now (Choose, or a stop whose way on is Start Over): `refreshQuote` prices it again. Free.
    var needsRequote: Bool {
        guard !running, !quoting, phase == .choose || stoppedForInputs, let backend else { return false }
        let script = try? backend.script()
        return script != quotedScript || script.flatMap(backend.voiceKey) != quotedVoiceKey
    }

    /// The fal.ai key again (Settings changed): the card then offers the price, or Settings, as it is now. Free.
    func refreshReadiness() async {
        guard let backend else { return }
        keyAvailable = await backend.hasKey()
        if needsRequote { await refreshQuote() }
    }

    /// Revoice Whole Clip · ≈ $X: the click is the approval for one voice and the lip sync at the shown price. Try Again
    /// pays only what is left. `budget` is what an automatic run may still spend, which a reworded voice must stay within.
    func start(automatic: Bool = false, budget: Decimal? = nil) {
        guard backend != nil, !running, phase != .used, !submissionUnconfirmed, repeatedWordCheckPart == nil else { return }
        if let model = pictureRedoModel {
            if let price = retryUSD { runPictureRedo(model, approved: price) }
            return
        }
        // A retry priced for the picture and the lip sync can't buy speech: it keeps the voice it stopped with.
        let retained = retainedVoice
        let model: Lipsync = retained != nil ? (synced?.model ?? .standard) : (restoredLipsyncModel ?? .standard)
        rewordRound = 0
        begin(automatic: automatic, budget: budget)
        launch { await $0.perform(model: model, retaining: retained) }
    }

    /// The voice a Try Again keeps: the last run stopped at the lip sync, or at the Fit after its picture was matched, over
    /// the script that voice says. A stop at the voice keeps none: its Try Again voices only the unfinished parts, at the
    /// price the button shows.
    private var retainedVoice: Voice? {
        guard isStopped, let voice, voice.key.script == script?.text, ledger.paid(voice.key) else { return nil }
        switch stoppedAt {
        case .lipsync: return voice
        case .fit: return picture != nil ? voice : nil
        default: return nil
        }
    }

    private func begin(automatic: Bool, budget: Decimal?) {
        self.automatic = automatic
        self.budget = automatic ? budget : nil
        journalVoiceApproval = quote?.pricesJournaledVoice == true ? quote?.voicePassUSD : nil
        previousFailure = failure
        // A run after Use was undone makes new work: a Redo of the old commit no longer marks the card used.
        undoneUse = nil
        phase = .running; started = Date(); progress = nil; failure = nil; fitStoppedScript = nil; picture = nil
        shorterWording = nil; stoppedAt = nil; stopError = nil; lipsyncMayPay = true; currentStep = .script
        steps = Dictionary(uniqueKeysWithValues: Step.allCases.map { ($0, StepState.waiting) })
    }

    private func launch(_ body: @escaping @MainActor (WholeClipRevoiceSession) async -> Void) {
        run = Task { [weak self] in
            guard let self else { return }
            await body(self)
            self.run = nil
        }
    }

    /// Voice the Shorter Wording · ≈ $Y: the click approves that voice at that price, and the lip sync after it.
    func voiceShorterWording() {
        guard backend != nil, !running, isStopped, shorterWording != nil else { return }
        begin(automatic: false, budget: nil)
        launch { await $0.perform(model: .standard, retaining: nil) }
    }

    /// The stop's way on is a shorter wording, a round is left, and an AI is there to ask: Shorter Wording · free.
    var canAskShorterWording: Bool {
        isStopped && failure?.rewordable == true && rewordRound < WholeClipRevoice.maximumRewordRounds && backend?.canReword() == true
    }

    /// Start Over · ≈ $Y, clicked at `approved`: the clip as it is now is priced first. When it costs more than the click
    /// approved, nothing is let go or paid: the stop stays, its button carrying the new price, which a new click approves.
    /// Otherwise the voice that no longer matches is let go (what it cost stays counted) and true: the run may start.
    func startOver(approved: Decimal) async -> Bool {
        guard let backend, !running, isStopped, repeatedWordCheckPart == nil || stoppedForInputs else { return false }
        let script = try? backend.script()
        let voiceKey = script.flatMap(backend.voiceKey)
        let fresh: Quote? = if let script { try? await backend.quote(script, .standard) } else { nil }
        quotedScript = script
        quotedVoiceKey = voiceKey
        quote = fresh
        keyAvailable = await backend.hasKey()
        guard let usd = fresh?.wholeUSD, usd <= approved, keyAvailable, !running, isStopped,
              (try? backend.script()) == script, script.flatMap(backend.voiceKey) == voiceKey else { return false }
        await discard()
        self.script = script
        return true
    }

    /// Shorter Wording · free: asks the AI for a shorter wording again (the Fit step's free round), checks it before
    /// paying, and stops with its priced voice, which waits for its own click. Nothing is paid.
    func askShorterWording() {
        guard backend != nil, !running, canAskShorterWording, let script else { return }
        previousFailure = failure
        automatic = false; budget = nil
        phase = .running; started = Date(); progress = nil; failure = nil; shorterWording = nil; stopError = nil
        currentStep = .fit
        launch { await $0.performShorterWording(script) }
    }

    private func pictureRedoPrice(_ model: Lipsync) -> Decimal? {
        guard let voice, let picture, backend?.voiceCurrent(voice) == true else { return nil }
        let key = WholeClipRevoiceLedger.LipsyncKey(voice: voice.key, retime: picture.speed, model: model)
        if lipsyncKept || ledger.paid(key) || restoredLipsyncs[key] != nil { return 0 }
        return (try? backend?.lipsyncPrice(model)) ?? nil
    }

    private(set) var pictureRedoModel: Lipsync?
    @ObservationIgnored private(set) var redoLipApproval: Decimal?

    func holdPictureRedo(script: WholeClipScript, voice: Voice, picture: Picture, model: Lipsync) {
        self.script = script; baseScript = script; self.voice = voice; self.picture = picture; pictureRedoModel = model
        ledger.record(voice.key, usd: 0)
        steps[.script] = .done("Script · kept from your used take")
        steps[.voice] = .done("Voice · kept from your used take")
        steps[.fit] = .done("Fit · kept from your used take")
    }

    func restorePictureRedo(paid: [WholeClipRevoiceLedger.LipsyncKey: Decimal], billed: [String: Decimal],
                            pending: RewriteSavedProposal.PendingLipsync?, uncertain: Bool) {
        restoredLipsyncs = paid; billedLipsyncs = billed; pendingLipsync = pending
        submissionUnconfirmed = uncertain
        stoppedAt = .lipsync; currentStep = .lipsync
        phase = .stopped(uncertain ? Self.copy(LipsyncError.submissionUncertain) : "Your used take is kept. Try Again brings back the paid lip sync.")
    }

    func runPictureRedo(_ model: Lipsync, approved: Decimal) {
        guard !running, let price = pictureRedoPrice(model), price <= approved, let voice, let picture else { return }
        redoLipApproval = approved
        phase = .running; started = Date(); progress = nil; failure = nil; currentStep = .lipsync
        launch {
            await $0.performLipsyncOnly(voice: voice, picture: picture, model: model)
            $0.redoLipApproval = nil
        }
    }

    /// I Checked fal.ai · Lip Sync Again · ≈ $X (fal.ai may charge twice): the user looked at fal.ai's request history after
    /// a lost submit answer. Only this click clears the stop; it runs only the lip sync, over the voice already paid for.
    /// Automatic runs never call it.
    func lipsyncAfterCheckingFal() {
        guard backend != nil, !running, isStopped, submissionUnconfirmed, let voice, let picture else { return }
        submissionUnconfirmed = false; checkedFal = true
        if let model = pictureRedoModel, let price = checkedFalUSD {
            runPictureRedo(model, approved: price)
            return
        }
        previousFailure = failure
        phase = .running; started = Date(); progress = nil; failure = nil; stopError = nil; currentStep = .lipsync
        steps[.lipsync] = .waiting
        let model = synced?.model ?? .standard
        launch { await $0.performLipsyncOnly(voice: voice, picture: picture, model: model) }
    }

    /// Cancel keeps the clip: nothing is put in, and what was paid stays in the ledger, so Try Again pays only what is left.
    func cancel() {
        guard let run else { return }
        run.cancel()
    }

    private func perform(model: Lipsync, retaining retained: Voice?) async {
        guard let backend else { return }
        do {
            // Script: free. A run again over the same clip keeps a wording the Fit step asked for, and so its paid voice.
            let base = try backend.script()
            var script = base
            if base == baseScript, let kept = self.script { script = kept }
            if let retained {
                guard base == baseScript, script.text == retained.key.script, ledger.paid(retained.key) else {
                    throw inputsChanged(usd: ledger.voices[retained.key] ?? retained.usd)
                }
            } else if let baseScript, base != baseScript, heldVoiceSpent > 0 {
                // The clip's words changed since its voice was paid: a Try Again priced for that voice can't buy one for
                // the new words. Undo brings the paid voice back; Start Over prices the new one.
                throw inputsChanged(usd: heldVoiceSpent)
            }
            baseScript = base
            self.script = script
            steps[.script] = .done(script == base ? "Script · \(script.words) words, your edits applied" : "Script · \(script.words) words, reworded to fit")
            try Task.checkCancellation()
            if !voicePaid(script) {
                // Checks before paying, all free: the lip sync's limits on this source (the Voice step checks the fal.ai key
                // first), then the script's calibrated length against the clip as edited (a script plainly too long is
                // reworded before any voice).
                currentStep = .voice
                try await backend.preflight()
                // Every first voice of a script gets this check, after Start Over or a paid lip sync too; only parts
                // already paid for this script keep it as it is (a shorter wording would let them go).
                // A voice paid before a relaunch is put back as it was said, never reworded first.
                let pricedAdoption = quotedScript == script && journalVoiceApproval != nil
                if script == base, !pricedAdoption, !backend.partlyVoiced(script), !restoredVoices.keys.contains(where: { $0.script == script.text }) {
                    script = try await rewordBeforePaying(script, backend: backend)
                }
            }
            // A voice paid before a relaunch comes back only with the voice and model it was made with: with another one
            // chosen, or none, nothing is voiced in its place and nothing is sent (Start Over pays for a new one).
            if !voicePaid(script), let restored = restoredVoiceKey, restored.script == script.text, !restoredVoiceChosen {
                throw Stop.voiceInputsChanged(clip: quote?.clipNumber ?? 1, usd: restoredVoices[restored] ?? 0, voiceSwitched: true)
            }
            var voice = try await voiceStep(script, backend: backend)
            // Fit: free, on the clip as edited. Only a voice too long for it asks for a measured wording, which is checked
            // against the clip before it is said again (a new script, a new voice); a shorter voice is laid out, never padded.
            var verdict: String
            while true {
                currentStep = .fit
                let video = backend.videoSeconds()
                let measured = "Fit · \(Self.clock(voice.seconds)) for \(Self.clock(video)) of video"
                var fit = WholeClipRevoice.fit(voiceSeconds: voice.seconds, videoSeconds: video, words: script.words, round: rewordRound)
                // A part whose laid-out take runs past its own window can't be matched however the total compares: the
                // fit is a shorter wording (or can't fit), known now and kept with its voice, never a picture stop later.
                if let overrun = voice.overrun {
                    switch fit {
                    case .matched, .laidOut:
                        fit = rewordRound < WholeClipRevoice.maximumRewordRounds && script.words > 0
                            ? .reword(targetWords: max(1, Int((Double(script.words) / overrun).rounded())))
                            : .cannotFit(voiceSeconds: voice.seconds, videoSeconds: video)
                    case .reword, .cannotFit: break
                    }
                }
                switch fit {
                case .matched(let matched):
                    verdict = measured + ", " + WholeClipRevoice.matchedCopy(factor: matched)
                case .laidOut(let laid):
                    verdict = measured + ", " + WholeClipRevoice.laidOutCopy(factor: laid)
                case .reword(let target):
                    // A retry that kept its voice met a fit its own run had passed: the clip as edited changed under it.
                    if let retained { throw inputsChanged(usd: ledger.voices[retained.key] ?? retained.usd) }
                    let next = try await shorter(script, target: target, voiceSeconds: voice.seconds, video: video, measured: measured, backend: backend)
                    try await approveVoice(next, extra: true, backend: backend)
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
            // Lip sync: paid once per voice, picture speed and model. One already paid is kept as it is applied, or put back
            // for free; only a lip sync never paid is paid.
            currentStep = .lipsync
            let key = WholeClipRevoiceLedger.LipsyncKey(voice: voice.key, retime: factor, model: model)
            let price = (try? backend.lipsyncPrice(model)).flatMap { $0 }
            steps[.lipsync] = .running("Lip sync · fal.ai \(model.name) · usually 1–2 min")
            if let previous = self.synced, previous.model == model, ledger.paid(key), await backend.restoreLipsync(syncedEntries) {
                self.synced = previous
            } else {
                // A lip sync paid before a relaunch over this voice is only re-imported (C's index), never paid again here,
                // when every part of the voice came back. A part voiced again changed the audio it was made over, so it
                // can't come back: Try Again priced a new one, and this step pays for it.
                restoringLipsync = restoredVoiceWhole ? restoredLipsyncs.keys.first { $0.voice == key.voice && $0.model == model } : nil
                lipsyncMayPay = model == .standard && !ledger.paid(key) && restoringLipsync == nil
                _ = try await lipsyncStep(voice: voice, factor: factor, model: model, backend: backend)
            }
            try Task.checkCancellation()
            steps[.lipsync] = .done("Lip sync · fal.ai \(model.name)" + (price.map { " · " + VoiceLabCostPresentation.format($0) } ?? ""))
            match = await backend.match(voice)
            phase = .review
            backend.persist()
            if automatic { await use() }
        } catch {
            await stopped(error, backend: backend)
        }
    }

    /// The lip sync, paid or put back: what it cost goes in the ledger, and the result is kept with its applied entries
    /// before anything else can stop the run, so a cancel that lands now never loses it.
    @discardableResult private func lipsyncStep(voice: Voice, factor: Double, model: Lipsync, backend: Backend) async throws -> Synced {
        let key = WholeClipRevoiceLedger.LipsyncKey(voice: voice.key, retime: factor, model: model)
        let made = try await backend.lipsync(voice, factor, model) { [weak self] value in self?.progress = value }
        // A kept result's re-import moves its charge from the failed attempts into the ledger; a new paid one adds to it;
        // one put back for a lip sync already in the ledger costs nothing again.
        if made.recovered, let request = made.requestID { billedLipsyncs.removeValue(forKey: request) }
        // A lip sync paid before a relaunch is in the ledger again at what it cost then.
        let restored = restoringLipsync.flatMap { restoredLipsyncs.removeValue(forKey: $0) }
        restoringLipsync = nil
        if !ledger.paid(key) { ledger.record(key, usd: restored ?? made.usd) }
        lipsyncKept = false; lipsyncMayPay = true; checkedFal = false
        synced = made
        syncedEntries = backend.appliedLipsync()
        backend.persist()
        return made
    }

    private func performLipsyncOnly(voice: Voice, picture: Picture, model: Lipsync) async {
        guard let backend else { return }
        steps[.lipsync] = .running("Lip sync · fal.ai \(model.name) · usually 1–2 min")
        do {
            let price = (try? backend.lipsyncPrice(model)).flatMap { $0 }
            // A lip sync already paid over this voice, picture speed and model is only put back (its imported index), never
            // paid again, as in a run's own Lip sync step.
            let key = WholeClipRevoiceLedger.LipsyncKey(voice: voice.key, retime: picture.speed, model: model)
            if restoredLipsyncs[key] != nil { restoringLipsync = key }
            lipsyncMayPay = model == .standard && !ledger.paid(key) && !lipsyncKept && restoringLipsync == nil
            try await lipsyncStep(voice: voice, factor: picture.speed, model: model, backend: backend)
            try Task.checkCancellation()
            steps[.lipsync] = .done("Lip sync · fal.ai \(model.name)" + (price.map { " · " + VoiceLabCostPresentation.format($0) } ?? ""))
            match = await backend.match(voice)
            phase = .review
        } catch {
            checkedFal = false; lipsyncMayPay = true
            await stopped(error, backend: backend)
        }
    }

    /// What "I Checked fal.ai · Lip Sync Again" charges: nothing when this lip sync was already paid over the voice and
    /// picture (it is only put back), else the lip sync's price. Nil while unpriced.
    var checkedFalUSD: Decimal? {
        if let model = pictureRedoModel { return pictureRedoPrice(model) }
        guard let voice, let picture else { return quote?.lipsyncUSD }
        let model = synced?.model ?? .standard
        if ledger.paid(WholeClipRevoiceLedger.LipsyncKey(voice: voice.key, retime: picture.speed, model: model)) { return 0 }
        return (try? backend?.lipsyncPrice(model)).flatMap { $0 } ?? quote?.lipsyncUSD
    }

    private func performShorterWording(_ script: WholeClipScript) async {
        guard let backend else { return }
        do {
            let video = backend.videoSeconds()
            // What the round measures against: the voice already made for this wording, else the script's estimate.
            let voiced = voice.flatMap { $0.key.script == script.text && ledger.paid($0.key) ? $0.seconds : nil }
            guard let seconds = voiced ?? backend.estimate(script) else { throw Stop.cannotFit(voice: 0, video: video) }
            let words = script.words
            guard case .reword(let target) = WholeClipRevoice.fit(voiceSeconds: seconds, videoSeconds: video, words: words, round: rewordRound) else {
                throw Stop.cannotFit(voice: seconds, video: video)
            }
            let measured = (voiced != nil ? "Fit · " : "Fit · ≈ ") + "\(Self.clock(seconds)) for \(Self.clock(video)) of video"
            let next = try await shorter(script, target: target, voiceSeconds: seconds, video: video, measured: measured, backend: backend)
            // Free so far: the new wording's voice waits for its own priced click.
            throw await holdForClick(next, backend: backend)
        } catch {
            await stopped(error, backend: backend)
        }
    }

    /// The measured-wording round: one round, then the check before paying on its wording.
    private func shorter(_ script: WholeClipScript, target: Int, voiceSeconds: Double, video: Double, measured: String,
                         backend: Backend) async throws -> WholeClipScript {
        currentStep = .fit
        rewordRound += 1
        steps[.fit] = .running(measured + " · asking for a shorter wording (≈ \(target) words)")
        guard let next = try await backend.reword(script, target, voiceSeconds, video) else {
            throw Stop.noShorterWording(voice: voiceSeconds, video: video)
        }
        try Task.checkCancellation()
        // Check before paying: the new wording is voiced only when its estimate fits the clip.
        if let before = backend.estimate(script), let after = backend.estimate(next),
           !WholeClipRevoice.rewordFits(voiceSeconds: voiceSeconds, estimateSeconds: before, newEstimateSeconds: after, videoSeconds: video) {
            let predicted = WholeClipRevoice.predictedSeconds(voiceSeconds: voiceSeconds, estimateSeconds: before, newEstimateSeconds: after)
            throw Stop.rewordTooLong(predicted: predicted ?? voiceSeconds, video: video)
        }
        return next
    }

    /// Check before paying the first voice (wholeclip-no-prepay-fit-check): a script whose calibrated estimate runs past the
    /// clip as edited (by more than the fit tolerance) gets its free shorter wording first, as the Fit step's first round,
    /// and only that wording is voiced. Otherwise the script as it is.
    private func rewordBeforePaying(_ script: WholeClipScript, backend: Backend) async throws -> WholeClipScript {
        let video = backend.videoSeconds()
        guard backend.canReword(), let estimate = backend.estimate(script), video > 0, estimate > video * (1 + WholeClipRevoice.fitTolerance) + 1e-9,
              case .reword(let target) = WholeClipRevoice.fit(voiceSeconds: estimate, videoSeconds: video, words: script.words, round: rewordRound)
        else { return script }
        currentStep = .fit
        rewordRound += 1
        let measured = "Fit · ≈ \(Self.clock(estimate)) for \(Self.clock(video)) of video"
        steps[.fit] = .running(measured + " · asking for a shorter wording before the voice (≈ \(target) words)")
        guard let next = try await backend.reword(script, target, estimate, video) else {
            throw Stop.scriptTooLong(predicted: estimate, video: video)
        }
        try Task.checkCancellation()
        if let after = backend.estimate(next),
           !WholeClipRevoice.rewordFits(voiceSeconds: estimate, estimateSeconds: estimate, newEstimateSeconds: after, videoSeconds: video) {
            throw Stop.rewordTooLong(predicted: after, video: video)
        }
        // The click approved one voice at the clip's price; the shorter wording is that voice when it costs no more.
        try await approveVoice(next, extra: false, backend: backend)
        self.script = next
        steps[.script] = .done("Script · \(next.words) words, reworded to fit")
        steps[.fit] = .waiting
        currentStep = .voice
        return next
    }

    /// Whether this run may pay for `next`'s voice. A manual click approved the run's first voice at the clip's price (a
    /// shorter wording before it costs no more), never an extra one; an automatic run may pay one only within what is left
    /// of its budget, with the lip sync still to pay. Otherwise the wording is kept and waits for its own priced click.
    private func approveVoice(_ next: WholeClipScript, extra: Bool, backend: Backend) async throws {
        let price = (try? await backend.quote(next, .standard))?.voicePassUSD
        let allowed: Decimal? = automatic ? budget.map { $0 - spent - lipsyncDue } : extra ? nil : quote?.voicePassUSD
        if let price, let allowed, price <= allowed { return }
        throw await holdForClick(next, price: price)
    }

    /// The lip sync a new voice still has to pay for: none when a kept result is put back for free.
    private var lipsyncDue: Decimal { lipsyncKept ? 0 : (quote?.lipsyncUSD ?? 0) }

    /// Keeps `next` for its own priced click (Voice the Shorter Wording · ≈ $Y): the stop the run ends with.
    private func holdForClick(_ next: WholeClipScript, backend: Backend) async -> Stop {
        await holdForClick(next, price: (try? await backend.quote(next, .standard))?.voicePassUSD)
    }

    private func holdForClick(_ next: WholeClipScript, price: Decimal?) async -> Stop {
        let usd = price.map { $0 + lipsyncDue }
        shorterWording = ShorterWording(script: next, usd: usd)
        self.script = next
        steps[.script] = .done("Script · \(next.words) words, reworded to fit")
        return .shorterWordingReady(words: next.words, usd: usd)
    }

    private func inputsChanged(usd: Decimal) -> Stop {
        .voiceInputsChanged(clip: quote?.clipNumber ?? 1, usd: usd)
    }

    private func voicePaid(_ script: WholeClipScript) -> Bool {
        voice.map { $0.key.script == script.text && ledger.paid($0.key) } ?? false
    }

    /// The run stopped: its step, what fal.ai charged and kept, the failure and its log line, and the line the card shows.
    private func stopped(_ error: any Error, backend: Backend) async {
        let cancelled = Task.isCancelled || error is CancellationError
        let step = currentStep
        stoppedAt = step
        stopError = error
        for each in Step.allCases {
            if case .running = steps[each] { steps[each] = cancelled ? .waiting : .failed(Self.copy(error)) }
        }
        var line = Self.copy(error)
        if let failed = error as? LipsyncFailed {
            submissionUnconfirmed = Self.cause(failed) as? LipsyncError == .submissionUncertain
            if !submissionUnconfirmed, let id = failed.requestID, let usd = failed.usd { billedLipsyncs[id] = usd }
            lipsyncKept = failed.freeRetry
            // A cancel that landed after fal.ai finished the job: billed, and kept for a free Try Again.
            if cancelled, failed.freeRetry, let usd = failed.usd {
                line = "Cancelled. fal.ai finished the lip sync (\(VoiceLabCostPresentation.format(usd))); it's kept, so Try Again is free."
            }
        }
        if Self.cause(error) as? LipsyncError == .missingKey { keyAvailable = false }
        if !cancelled {
            if steps[step] == .waiting { steps[step] = .failed(Self.copy(error)) }
            let part = Self.part(error)
            let kind = Self.failureKind(error)
            let again = previousFailure.map { $0.step == step && $0.part == part && $0.kind == kind } ?? false
            var made = Failure(step: step, part: part, repeats: step == .script || Self.repeats(error), kind: kind, again: again)
            made.rewordable = step == .fit && Self.rewordable(error) && rewordRound < WholeClipRevoice.maximumRewordRounds
            failure = made
            // A plan let go with nothing paid is made fresh by the next click: that Try Again meets no fit it met before.
            if step == .fit, !Self.isStale(error) { fitStoppedScript = baseScript }
            backend.report("whole clip failure step=\(step) " + kind + (part.map { " part=\($0)" } ?? ""))
        } else if !line.hasPrefix("Cancelled.") {
            line = "Cancelled. Your clip is unchanged."
        }
        // A plain stale stop means the plan was let go with nothing paid in it (`RewriteSession.checkWholeClipPlan`), or
        // no plan holds the voice now: that voice can't be laid out or lip synced again, so the next click makes a fresh
        // one (a free take a journal adopts costs nothing; the button prices it as a new voice) instead of meeting the
        // same stale stop again.
        if pictureRedoModel == nil, case ClipTakePlan.Failure.stale? = error as? ClipTakePlan.Failure { forgetVoice() }
        // A stop whose way on is a fresh price (the clip changed, a plan made fresh) prices the clip as it is now. Free.
        if case Stop.voiceInputsChanged = error { await requote(backend) }
        else if Self.isStale(error) { await requote(backend) }
        // A lip sync paid before a relaunch that C's index couldn't give back is let go (still counted): the next Try Again
        // prices it and may pay for it, so the stop is never one Try Again meets again.
        if let restoring = restoringLipsync, let usd = restoredLipsyncs.removeValue(forKey: restoring) { restoredLetGo += usd }
        restoringLipsync = nil
        phase = .stopped(line + paidNote)
        backend.persist()
    }

    /// Lets go of the run's voice and what was made over it, keeping the ledger (what was paid stays counted).
    private func forgetVoice() {
        voice = nil; synced = nil; picture = nil; match = nil; syncedEntries = [:]; lipsyncKept = false
    }

    private func requote(_ backend: Backend) async {
        guard let script = try? backend.script() else { return }
        quotedScript = script
        quotedVoiceKey = backend.voiceKey(script)
        if let fresh = try? await backend.quote(script, .standard) { quote = fresh }
        keyAvailable = await backend.hasKey()
    }

    /// What was paid, fal.ai's charges for failed lip syncs included (MVP46 showed only the voice's ≈ $0.04).
    private var paidNote: String {
        spent > 0 ? " Spent so far: \(VoiceLabCostPresentation.format(spent))." : ""
    }

    private func voiceStep(_ script: WholeClipScript, backend: Backend) async throws -> Voice {
        if let voice, voice.key.script == script.text, ledger.paid(voice.key) {
            steps[.voice] = .done(Self.voiceLine(voice, quote: quote))
            return voice
        }
        currentStep = .voice
        steps[.voice] = .running("Voice · saying \(script.words) words")
        let made = try await backend.voice(script) { [weak self] line in self?.steps[.voice] = .running("Voice · " + line) }
        // What this voice cost so far: an earlier one for the same key (paid before a relaunch, or let go by a stale plan)
        // and this one, which a journal's adopted takes make only their word checks.
        let before = (ledger.voices[made.key] ?? 0) + (restoredVoices.removeValue(forKey: made.key) ?? 0)
        ledger.record(made.key, usd: before + made.usd)
        voice = made
        synced = nil; picture = nil; syncedEntries = [:]; lipsyncKept = false
        steps[.voice] = .done(Self.voiceLine(made, quote: quote))
        backend.persist()
        return made
    }

    /// Use Whole Clip: one undo step, with the lip sync that was paid for (put back first when a step took it off).
    func use() async {
        guard let backend, phase == .review, let voice, let synced else { return }
        do {
            guard await backend.restoreLipsync(syncedEntries) else { throw Stop.lipsyncMissing }
            record = try await backend.use(voice, synced, match)
            usedFrom = .review; undoneUse = nil
            phase = .used
            backend.persist()
        } catch {
            stopError = error
            let kind = Self.failureKind(error)
            if case Stop.voiceInputsChanged = error {
                // An edit since Review: as any stop over a paid voice, Undo makes it usable again.
                currentStep = .lipsync
                await stopped(error, backend: backend)
                return
            }
            stoppedAt = .lipsync
            if case Stop.lipsyncMissing = error {
                // Try Again puts the paid lip sync back for free (its imported index), then Review again.
                failure = Failure(step: .lipsync, part: nil, repeats: false, kind: kind)
                steps[.lipsync] = .failed(Self.copy(error))
                phase = .stopped(Self.copy(error) + paidNote)
            } else {
                // Use failed: Try Use Again is free, and nothing is voiced or patched instead.
                failure = Failure(step: .lipsync, part: nil, repeats: false, kind: kind, atUse: true)
                phase = .stopped("Couldn't put the whole clip in: " + Self.copy(error) + " Your clip is unchanged." + paidNote)
            }
            backend.report("whole clip failure step=use " + kind)
        }
    }

    /// Try Use Again · free: Review's result again, nothing new paid.
    func useAgain() async {
        guard isStopped, failure?.atUse == true, voice != nil, synced != nil else { return }
        previousFailure = failure
        failure = nil; stopError = nil
        phase = .review
        await use()
    }

    /// A paid voice for this script whose lip sync can't run: the run stopped at the lip sync (a failure, a lost submit
    /// answer, a lip sync that couldn't be put back), or at the Fit on the lip sync's own check. Its words still match.
    var canUseVoiceOnly: Bool {
        guard pictureRedoModel == nil, isStopped, failure?.atUse != true, !stoppedForInputs, let voice, voice.key.script == script?.text,
              ledger.paid(voice.key) else { return false }
        switch stoppedAt {
        case .lipsync?: return true
        case .fit?: return stopError is LipsyncFailed || (stopError as? Unsent)?.error is LipsyncFailed
        default: return false
        }
    }

    /// Use the Voice Without Lip Sync (lead decision): the paid voice goes in as ordinary Voice Lab segments over the
    /// matched picture, free. Only the user's click takes it; ✦ Claude does it all never does (the result has no lip sync).
    /// A failure keeps the stop and its actions, and says the clip is unchanged.
    func useVoiceOnly() async {
        guard let backend, canUseVoiceOnly, let voice else { return }
        let from = phase
        do {
            try await backend.useVoiceOnly(voice)
            record = nil
            usedVoiceOnly = true
            usedFrom = from; undoneUse = nil
            phase = .used
            backend.persist()
        } catch {
            if case Stop.voiceInputsChanged = error {
                await stopped(error, backend: backend)
                return
            }
            backend.report("whole clip failure step=voiceOnly " + Self.failureKind(error))
            phase = .stopped("Couldn't put the voice in without lip sync: " + Self.copy(error) + " Your clip is unchanged." + paidNote)
        }
    }

    /// Undo on Review, Start Over or the patch: the original audio and video stay, and the paid voice is let go (what it
    /// cost stays in the spent total).
    func discard() async {
        guard let backend, phase == .review || isStopped else { return }
        await backend.discard()
        failure = nil; stopError = nil; stoppedAt = nil; shorterWording = nil
        baseScript = nil; rewordRound = 0; usedVoiceOnly = false; usedFrom = nil; undoneUse = nil
        // What was paid before a relaunch goes with it, and stays counted.
        restoredLetGo += restoredVoices.values.reduce(0, +) + restoredLipsyncs.values.reduce(0, +)
        restoredVoices = [:]; restoredLipsyncs = [:]; restoredVoiceUSD = nil; restoringLipsync = nil
        restoredParts = 0; restoredPartsBack = 0; restoredCheckUSD = nil
        restoredPartRequests = []
        pendingLipsync = nil
        backend.persist()
    }

    /// Where Use was clicked from (Review, or the stop Use the Voice Without Lip Sync was clicked on), while its commit is in
    /// the project or undone; and what the editor's Undo took out of it, for its Redo.
    @ObservationIgnored private var usedFrom: Phase?
    @ObservationIgnored private var undoneUse: (record: WholeClipRevoiceRecord?, voiceOnly: Bool)?
    /// The editor's Undo took Use's commit out and no Redo or new Use followed.
    var useWasUndone: Bool { undoneUse != nil && phase == usedFrom }

    /// The editor's Undo (⌘Z) took Use's commit back out of the project (`RewriteSession.followOwnCommit`): the card is back
    /// where Use was clicked, its paid voice and lip sync unused again, so closing asks first, the saved record is written
    /// again (a relaunch offers them back) and Use puts them in again for free.
    func useUndone() {
        guard phase == .used, let from = usedFrom else { return }
        undoneUse = (record, usedVoiceOnly)
        record = nil; usedVoiceOnly = false
        phase = from
        backend?.persist()
    }

    /// The editor's Redo put Use's commit back: the card is used again and the saved record goes again.
    func useRedone() {
        guard useWasUndone, let undone = undoneUse else { return }
        record = undone.record; usedVoiceOnly = undone.voiceOnly
        undoneUse = nil
        phase = .used
        backend?.persist()
    }

    /// Undo after Use (the autopilot's step list).
    func undoUse() {
        guard let backend, phase == .used, let record else { return }
        backend.undo(record)
        self.record = nil
        phase = .review
    }

    var isStopped: Bool { if case .stopped = phase { true } else { false } }

    /// What this Rewrite's whole clip had paid for when VoxClip quit or crashed (`RewriteSession.restoreWholeClip`): its
    /// script, the paid voice and lip sync by key, fal.ai's charges for failed attempts, what putting the voice back costs
    /// now (`voiceUSD`, part by part; nil when that can't be made exact), its parts and how many of them the journal gives
    /// back, and one part's word check. It shows as a stop whose Try Again puts back what can come back: the journal adopts
    /// the paid takes and, when every part is back, C's index re-imports the lip sync; parts that can't come back are
    /// voiced again and the clip lip synced again, at the price the button shows.
    struct Restored: Equatable {
        var script: WholeClipScript
        var baseScript: WholeClipScript
        var voices: [WholeClipRevoiceLedger.VoiceKey: Decimal]
        var lipsyncs: [WholeClipRevoiceLedger.LipsyncKey: Decimal]
        var billed: [String: Decimal]
        var voiceUSD: Decimal?
        var parts = 0
        var partsBack = 0
        var checkUSD: Decimal?
        var partRequests: [String] = []
        var awaitingLipsync = false
    }

    /// The clip's own script the last run started from, as `RewriteSession.persistPaidWork` saves it.
    var savedBaseScript: WholeClipScript? { baseScript }

    /// Offers back what `restored` paid for, on a fresh card (`.choose`, nothing run yet): a stop at the Voice step whose
    /// Try Again is priced at what putting it back costs, once the card prices the clip (`refreshQuote`). Free.
    func restore(_ restored: Restored) {
        guard phase == .choose, !running else { return }
        script = restored.script; baseScript = restored.baseScript
        restoredVoices = restored.voices; restoredLipsyncs = restored.lipsyncs; billedLipsyncs = restored.billed
        restoredVoiceUSD = restored.voiceUSD
        restoredParts = restored.parts; restoredPartsBack = restored.partsBack; restoredCheckUSD = restored.checkUSD
        restoredPartRequests = restored.partRequests
        steps = Dictionary(uniqueKeysWithValues: Step.allCases.map { ($0, StepState.waiting) })
        steps[.script] = .done(restored.script == restored.baseScript ? "Script · \(restored.script.words) words, your edits applied"
                                                                    : "Script · \(restored.script.words) words, reworded to fit")
        failure = Failure(step: .voice, part: nil, repeats: false, kind: "restored")
        stoppedAt = .voice; currentStep = .voice
        // What Try Again does with it depends on the voice chosen, which can change: `restoredVoiceNote` says it.
        phase = .stopped(Self.restoredLine(restored) + paidNote)
    }

    func restoreUnconfirmedSubmission(_ pending: RewriteSavedProposal.PendingLipsync?) {
        pendingLipsync = pending
        submissionUnconfirmed = true
    }

    /// The restored stop's line: what of the paid whole clip is kept. A voice the journal gives back only in part keeps
    /// only those parts, and its lip sync can't come back over the parts voiced again.
    static func restoredLine(_ restored: Restored) -> String {
        let whole = restored.parts > 0 && restored.partsBack == restored.parts
        if whole {
            if restored.awaitingLipsync { return "Your paid voice is kept. Lip sync was submitted before VoxClip closed. Try Again checks that job without paying for lip sync again." }
            return restored.lipsyncs.isEmpty ? "Your paid whole-clip voice from before VoxClip closed is kept."
                : "Your paid whole-clip voice and lip sync from before VoxClip closed are kept."
        }
        if restored.partsBack == 0 { return "Your paid whole-clip voice from before VoxClip closed can't be put back." }
        let verb = restored.partsBack == 1 ? "is" : "are"
        return "\(restored.partsBack) of the \(restored.parts) parts of your paid whole-clip voice from before VoxClip closed \(verb) kept."
    }

    /// The last run stopped at the Fit step and the clip's script is still the one it stopped for: Try Again would meet
    /// the same fit, so the card makes the patch its primary (ADR-R46, "Try Again doesn't repeat a failure").
    var repeatsFit: Bool {
        guard isStopped, failure?.step == .fit, let stopped = fitStoppedScript, let backend else { return false }
        return (try? backend.script()) == stopped
    }

    /// The paid voice no longer matches what it was made from: the stop said so, or the clip's words changed since. A Try
    /// Again priced for that voice could only stop again; Start Over prices the clip as it is.
    var stoppedForInputs: Bool {
        guard isStopped else { return false }
        if case Stop.voiceInputsChanged? = stopError { return true }
        if case Stop.repeatedWordCheck(_, _, let recordID)? = stopError, let script,
           let chosen = backend?.voiceKey(script), chosen.recordId != recordID { return true }
        // A restored voice whose voice or model isn't the one chosen now (`restoredVoiceChosen`).
        if restoredVoiceKey != nil, !restoredVoiceChosen { return true }
        guard heldVoiceSpent > 0, let baseScript, let now = try? backend?.script() else { return false }
        return now != baseScript
    }

    /// The stop is one the Voice step meets until something outside the card changes (`Backend.voiceReadiness`: a voice
    /// chosen, Voice Lab ready, the project editable again, an Undo back to the Rewrite's clip), and it hasn't yet: Try
    /// Again waits until it has, so it is never offered to meet the same stop.
    var waitsForReadiness: Bool {
        guard isStopped, let stop = stopError.map(Self.cause) as? Stop, Self.isReadiness(stop) else { return false }
        return backend?.voiceReadiness() != nil
    }

    /// A stop only the user can take on, which ✦ Claude does it all leaves to them with Rewrite open, never voicing the
    /// changed phrases on top: money was spent on this clip (a voice, parts of one, a lip sync), a shorter wording waits
    /// for its priced click, the clip changed under the paid voice, a lost submit answer waits for the user's fal.ai
    /// check, the paid voice can go in without lip sync, or Use couldn't put the result in.
    var needsYou: Bool {
        guard isStopped else { return false }
        return spent > 0 || shorterWording != nil || stoppedForInputs || submissionUnconfirmed || canUseVoiceOnly || failure?.atUse == true
    }

    /// An Undo made the paid voice match again: Try Again uses it.
    var inputsRestored: Bool {
        guard repeatedWordCheckPart == nil, stoppedForInputs, let backend, let baseScript, (try? backend.script()) == baseScript else { return false }
        // A restored voice is usable again once its own voice and model are chosen.
        if restoredVoiceKey != nil { return restoredVoiceChosen }
        return voice.map { backend.voiceCurrent($0) } ?? true
    }

    var repeatedWordCheckPart: Int? {
        guard case Stop.repeatedWordCheck(let part, _, _)? = stopError else { return nil }
        return part
    }

    enum Stop: Error, Equatable {
        case cannotFit(voice: Double, video: Double)
        /// The measured-wording round brought no shorter wording back (the AI declined, or none is chosen).
        case noShorterWording(voice: Double, video: Double)
        /// Check before paying: the shorter wording's estimate still runs `predicted` for `video`, so no voice was made.
        case rewordTooLong(predicted: Double, video: Double)
        /// Check before paying the first voice: the script's estimate runs `predicted` for `video`, and no shorter wording
        /// came back, so no voice was made.
        case scriptTooLong(predicted: Double, video: Double)
        case noVoice(String)
        /// No voice is chosen for the Rewrite. Choosing one lets Try Again pass (`waitsForReadiness`).
        case voiceMissing
        /// Voice Lab can't make takes for this Rewrite (its voice provider or the source audio isn't ready).
        case unavailable
        /// The project can't be edited now (its media or transcript isn't available, or it is read-only).
        case locked
        /// Clip `clip`'s words, cuts or pauses changed since this Rewrite was made, with no paid voice held: Undo makes it
        /// current again; otherwise the Rewrite is sent again for the clip as it is.
        case rewriteChanged(clip: Int)
        case partVoice(part: Int, reason: String, checks: [VoiceLabTakeQAFailure])
        case repeatedWordCheck(part: Int, kept: Int, recordID: String)
        /// Part `part` (1-based)'s picture allows no cut or kept-source video under its laid-out take.
        case pictureUnmatched(part: Int)
        /// The user edited what the paid voice (`usd`) was made from: its words, cuts, pauses or corrections, the source or the
        /// clean audio, or (`voiceSwitched`) chose another voice. Undo, or that voice again, makes it usable again; Start
        /// Over pays for a new one.
        case voiceInputsChanged(clip: Int, usd: Decimal, voiceSwitched: Bool = false)
        /// A shorter wording of `words` is ready, its voice (`usd`, the lip sync still to pay included) waiting for its own
        /// click (`ShorterWording`).
        case shorterWordingReady(words: Int, usd: Decimal?)
        /// The paid lip sync is no longer on the parts and couldn't be put back, so Use put nothing in.
        case lipsyncMissing
    }

    /// What the Voice step and the card say. A part that can't be placed says which part and why; only a lip-sync error uses
    /// the lip-sync copy; everything else is Rewrite's own copy, which falls back to `UserMessages.message`.
    static func copy(_ error: any Error) -> String {
        switch error {
        case let unsent as Unsent: return copy(unsent.error)
        case Stop.cannotFit(let voice, let video), Stop.noShorterWording(let voice, let video):
            // A part that runs past its own place while the whole voice is shorter than the clip (`Voice.overrun`).
            if voice > 0, voice <= video {
                return "Part of the new voice runs longer than its place in the clip as edited, so the picture can't follow it."
            }
            return "The new voice runs \(clock(voice)) for \(clock(video)) of video, longer than the clip can hold."
        case Stop.rewordTooLong(let predicted, let video):
            return "The shorter wording would still run about \(clock(predicted)) for \(clock(video)) of video, so no new voice was made."
        case Stop.scriptTooLong(let predicted, let video):
            return "The script would run about \(clock(predicted)) for \(clock(video)) of video, and no shorter wording came back, so no voice was made."
        case Stop.noVoice(let reason): return reason
        case Stop.voiceMissing: return "Make your voice in Rewrite first. Nothing was sent."
        case Stop.unavailable: return "Voice Lab can't make takes for this Rewrite yet. Nothing new was sent."
        case Stop.locked:
            return "This project can't be edited right now (its media or transcript isn't available), so the whole clip can't go on. Nothing new was sent."
        case Stop.rewriteChanged(let clip):
            return "You edited Clip \(clip) after this Rewrite was made, so its changes may no longer fit. Nothing was sent. "
                + "Undo the edit to go on, or send the Rewrite again."
        case Stop.partVoice(let part, let reason, _): return "Part \(part): " + reason
        case Stop.repeatedWordCheck(let part, let kept, _):
            let saved = kept > 0 ? " \(kept) verified \(kept == 1 ? "part is" : "parts are") kept." : ""
            return "Part \(part): " + ClipTakePlan.repeatedWordCheckCopy + saved
        case Stop.pictureUnmatched(let part):
            return "Part \(part)'s picture can't be matched to its voice on the clip as edited. Nothing was sent for lip sync."
        case Stop.voiceInputsChanged(let clip, let usd, let switched):
            let paid = "the paid voice (\(VoiceLabCostPresentation.format(usd))) no longer matches"
            if switched {
                return "You chose another voice after Clip \(clip)'s voice was made, so \(paid). "
                    + "Choose the voice it was made with again to use it, or start over, which pays for the voice again."
            }
            return "You edited Clip \(clip) after its voice was made, so \(paid). "
                + "Undo the edit to use it, or start over, which pays for the voice again."
        case Stop.shorterWordingReady(let words, let usd):
            return "A shorter wording of \(words) words fits the clip. Voicing it is a new voice" + (usd.map { " (\(VoiceLabCostPresentation.format($0)) with the lip sync)" } ?? "") + "."
        case Stop.lipsyncMissing:
            return "The paid lip sync is no longer on the clip's parts, so nothing was put in. Try Again puts it back for free."
        case let unmatched as Unmatched:
            let reason = ClipTakePlan.copy(unmatched.error)
            return "The picture couldn't be matched to the voice: " + reason + (reason.hasSuffix(".") ? "" : ".") + " Nothing was sent for lip sync."
        case let failed as LipsyncFailed:
            let charge: String
            if failed.local { charge = " Nothing was sent to fal.ai." }
            else if failed.requestID != nil, Self.cause(failed) as? LipsyncError != .submissionUncertain, let usd = failed.usd {
                // A result set aside already says it's kept and free to put in: the free-retry sentence is said once.
                let aside = Self.cause(failed) is RewriteLipsyncSession.SetAside
                charge = " fal.ai accepted the job (estimated cost: \(VoiceLabCostPresentation.format(usd)))."
                    + (failed.freeRetry && !aside ? " Try Again checks the same job for free." : "")
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
        case let unsent as LipsyncNotSubmitted: return cause(unsent.error)
        default: return error
        }
    }

    /// The refused part, 1-based, of a placement refusal or a picture that can't be matched.
    static func part(_ error: any Error) -> Int? {
        if case Stop.partVoice(let part, _, _) = cause(error) { return part }
        if case Stop.repeatedWordCheck(let part, _, _) = error { return part }
        if case Stop.pictureUnmatched(let part) = error { return part }
        if let unmatched = error as? Unmatched, let part = unmatched.part { return part }
        if case ClipTakePlan.Failure.placement(_, let index) = cause(error) { return index + 1 }
        return nil
    }

    private static func failureKind(_ error: any Error) -> String {
        let error = cause(error)
        let kind = RewriteSession.failureKind(error)
        guard case Stop.partVoice(_, _, let checks) = error, !checks.isEmpty else { return kind }
        return kind + " checks=" + checks.map { String(describing: $0) }.joined(separator: ",")
    }

    /// A plan made fresh by the next click: nothing paid went stale.
    private static func isStale(_ error: any Error) -> Bool {
        if case ClipTakePlan.Failure.stale = cause(error) { return true }
        return false
    }

    /// A Voice step stop before anything is sent whose cause the user changes outside the card (`Backend.voiceReadiness`).
    static func isReadiness(_ stop: Stop) -> Bool {
        switch stop {
        case .voiceMissing, .unavailable, .locked, .rewriteChanged: return true
        default: return false
        }
    }

    /// A Fit stop a shorter wording can pass: none came back, or one that still runs long.
    private static func rewordable(_ error: any Error) -> Bool {
        switch error {
        case Stop.noShorterWording, Stop.rewordTooLong, Stop.scriptTooLong: return true
        default: return false
        }
    }

    /// The lip sync's own submit was refused for its media (HTTP 422): the same inputs meet it again.
    private static func refusedMedia(_ error: any Error) -> Bool {
        var current: any Error = error
        while true {
            if let failure = current as? LipsyncAttemptFailure { current = failure.error; continue }
            if let unsent = current as? LipsyncNotSubmitted {
                if unsent.queueRefused, case LipsyncError.http(422) = unsent.error { return true }
                current = unsent.error; continue
            }
            return false
        }
    }

    /// Trying again would only stop the same way: the parts can't be placed, nothing is left to voice, too many parts, the
    /// voice no longer matches the clip, or a stop before anything paid was sent. A network or provider failure can succeed
    /// on a retry; so can a stop whose cause the user fixes outside the card (a fal.ai key; a voice chosen, Voice Lab ready,
    /// an editable project or an Undo, `isReadiness`, whose Try Again waits for it) and a plan the next click makes fresh
    /// (stale with nothing paid).
    static func repeats(_ error: any Error) -> Bool {
        if let unsent = error as? Unsent {
            if case ClipTakePlan.Failure.stale = unsent.error { return false }
            if cause(unsent.error) as? LipsyncError == .missingKey { return false }
            if let stop = unsent.error as? Stop, isReadiness(stop) { return false }
            return true
        }
        if case Stop.voiceInputsChanged = error { return true }
        if case Stop.repeatedWordCheck = error { return true }
        if error is Unmatched { return true }
        if case Stop.pictureUnmatched = error { return true }
        if let failed = error as? LipsyncFailed {
            let cause = cause(failed) as? LipsyncError
            if cause == .missingKey { return false }
            return failed.local || cause == .submissionUncertain || refusedMedia(failed.error)
        }
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
