import Foundation
import VoxClipCore
import VoxClipMedia

/// A Rewrite's proposal with its unused paid work, saved beside the project's Voice Lab data and never in the .voxclip
/// (voice-lab §3 "Paid takes are kept"): after a relaunch or a crash, opening Rewrite on the same scope, as it reads now,
/// shows the proposal again with no AI call, and offers its paid work back. The patch's takes and the whole clip's voice
/// parts come back through the take journal (synthesis free, only each part's word check priced); the whole clip's lip
/// sync through the lip sync's imported index (free). What fal.ai charged for failed lip syncs stays counted. A record
/// goes when its paid work is used, discarded on the user's word, or replaced by a new run, and after 60 days unused, as
/// the journal's takes do.
struct RewriteSavedProposal: Codable, Equatable {
    static let schema = "voxclip-rewrite-proposal/1"
    /// Unused records go with the journal's unused takes (`VoiceLabTakeJournal.unusedLifetime`).
    static let lifetime = VoiceLabTakeJournal.unusedLifetime

    struct Hunk: Codable, Equatable {
        var kind: String
        var sourceWordIds: [String]
        var newTokens: [String]
        var correctedTexts: [String]
        var absorbedItemIds: [String]
        var bridgeWordIds: [String]
        var sourceStartIndex: Int
        var sourceEndIndex: Int
        var anchorSeconds: Double?
        var audioTags: [VoiceLabAudioTag]
    }
    struct Change: Codable, Equatable {
        var hunk: Hunk
        var insertionAfterItemID: String?
        var checkThis: Bool
        var lines: [String]
        var reasons: [String]
        /// "pending", "kept" or "excluded": the change's inclusion as the creator left it.
        var state: String
    }
    struct VoiceEntry: Codable, Equatable {
        var key: WholeClipRevoiceLedger.VoiceKey
        var usd: Decimal
    }
    struct LipsyncEntry: Codable, Equatable {
        var key: WholeClipRevoiceLedger.LipsyncKey
        var usd: Decimal
    }
    /// The whole clip's paid work: its script, what each voice and lip sync cost, fal.ai's charges for failed attempts,
    /// and the journal requests of the voice's parts, which say whether every part can come back with its word check only.
    struct WholeClip: Codable, Equatable {
        var script: WholeClipScript
        var baseScript: WholeClipScript
        var voices: [VoiceEntry]
        var lipsyncs: [LipsyncEntry]
        var billed: [String: Decimal]
        /// The voice's parts, and the journal requests of those whose paid take was made.
        var parts: Int
        var partRequests: [String]
    }

    var schema = Self.schema
    var projectId: String
    var scope: String
    /// SHA-256 of the scope's inputs (`RewriteSession.inside`): a project edited since reads differently and restores nothing.
    var inputs: String
    var instruction: String
    var changes: [Change]
    var kept: [Int]
    var pricedAnyway: [Int]
    var voiceRecordID: String?
    /// The patch's paid takes when it was saved, and what they cost.
    var patchTakes: Int
    var patchUSD: Decimal
    var wholeClip: WholeClip?
    var savedAt: Date
}

extension RewriteSavedProposal.Change {
    init(_ change: RewriteChange, state: TranscriptChange.State) {
        let hunk = change.hunk
        let saved: String = switch state { case .pending: "pending"; case .kept: "kept"; case .excluded: "excluded" }
        self.init(hunk: .init(kind: hunk.kind.rawValue, sourceWordIds: hunk.sourceWordIds, newTokens: hunk.newTokens,
                              correctedTexts: hunk.correctedTexts, absorbedItemIds: hunk.absorbedItemIds, bridgeWordIds: hunk.bridgeWordIds,
                              sourceStartIndex: hunk.sourceStartIndex, sourceEndIndex: hunk.sourceEndIndex, anchorSeconds: hunk.anchorSeconds,
                              audioTags: hunk.audioTags),
                  insertionAfterItemID: change.insertionAfterItemID, checkThis: change.checkThis, lines: change.lines,
                  reasons: change.reasons, state: saved)
    }
    var change: RewriteChange {
        let kind = VoiceLabDiffHunkKind(rawValue: hunk.kind) ?? .textOnly
        return RewriteChange(hunk: VoiceLabDiffHunk(kind: kind, sourceWordIds: hunk.sourceWordIds, newTokens: hunk.newTokens,
                                                    correctedTexts: hunk.correctedTexts, absorbedItemIds: hunk.absorbedItemIds,
                                                    bridgeWordIds: hunk.bridgeWordIds, sourceStartIndex: hunk.sourceStartIndex,
                                                    sourceEndIndex: hunk.sourceEndIndex, anchorSeconds: hunk.anchorSeconds, audioTags: hunk.audioTags),
                             insertionAfterItemID: insertionAfterItemID, checkThis: checkThis, lines: lines, reasons: reasons)
    }
    var transcriptState: TranscriptChange.State {
        switch state { case "kept": .kept; case "excluded": .excluded; default: .pending }
    }
}

/// Where saved proposals live: `<data>/VoiceLab/<projectId>/rewrite/<sha256 of the scope>.json`, owner-only, written
/// atomically. The Voice Lab's asset retention reads only audio and video files there, so it never takes one.
enum RewriteSavedProposalStore {
    static func url(paidRoot: URL, projectId: String, scope: String) -> URL? {
        guard !projectId.isEmpty, projectId != ".", projectId != "..", !projectId.contains("/") else { return nil }
        return paidRoot.appendingPathComponent(projectId, isDirectory: true).appendingPathComponent("rewrite", isDirectory: true)
            .appendingPathComponent(VoiceLabFingerprint.bytes(Data(scope.utf8)) + ".json")
    }

    /// The record at `url`; one of another schema, unreadable or older than its lifetime is removed and nil.
    static func load(_ url: URL?, now: Date = Date()) -> RewriteSavedProposal? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let saved = try? decoder.decode(RewriteSavedProposal.self, from: data), saved.schema == RewriteSavedProposal.schema,
              now.timeIntervalSince(saved.savedAt) < RewriteSavedProposal.lifetime else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return saved
    }

    static func encode(_ saved: RewriteSavedProposal) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(saved)
    }

    static func write(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func remove(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

extension RewriteSession {
    /// The scope a record is saved for: the clip, Full take, or a selection with the clip it sits in.
    var savedProposalScope: String {
        switch rewriteScope {
        case .clip(let id): return "clip:" + id
        case .fullTake: return "full"
        case .selection(let range):
            let clip: String = if case .clip(let id) = scope { id } else { "" }
            return "selection:\(range.lowerBound)-\(range.upperBound):" + clip
        }
    }

    var savedProposalURL: URL? {
        RewriteSavedProposalStore.url(paidRoot: editor.app.locations.root.appendingPathComponent("VoiceLab", isDirectory: true),
                                      projectId: project.id, scope: savedProposalScope)
    }

    /// The digest of what the scope reads (`inside`): the same after a relaunch when nothing in the scope changed.
    var savedProposalInputs: String? {
        // A plain sorted encoding: the scoped inputs are no document of their own (their save dates are cleared), so they
        // are neither validated nor dated as one.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(inside(project))).map(VoiceLabFingerprint.bytes)
    }

    /// The restored proposal's paid patch takes, as a note: "Your 2 paid takes from before VoxClip closed are kept: Make
    /// Takes uses them again and pays only for their word checks." Nil once a plan holds takes again, or when none.
    var restoredPaidWorkNote: String? {
        guard let saved = restoredProposal, saved.patchTakes > 0, takePlan == nil else { return nil }
        let takes = saved.patchTakes == 1 ? "Your paid take from before VoxClip closed is kept" : "Your \(saved.patchTakes) paid takes from before VoxClip closed are kept"
        return takes + ": Make Takes uses \(saved.patchTakes == 1 ? "it" : "them") again and pays only for the word checks."
    }

    /// Saves the proposal with its unused paid work, or removes the record when nothing paid is left unused. Free; an
    /// unchanged record is not written again, and a proposal with nothing paid reads nothing.
    func persistPaidWork() {
        guard isOpen, !paidWorkUsed, ownProposal != nil else { return }
        let whole = savedWholeClip
        let planTakes = hasPaidPatchWork ? paidTakeCount : 0
        let planUSD = hasPaidPatchWork ? (takePlan.flatMap { $0.isRetired ? nil : $0.spent.usd } ?? 0) : 0
        // Takes saved before a relaunch are still the proposal's until a plan holds takes again.
        let restored = takePlan == nil ? restoredProposal : nil
        let patchTakes = planTakes > 0 ? planTakes : (restored?.patchTakes ?? 0)
        let patchUSD = planTakes > 0 ? planUSD : (restored?.patchUSD ?? 0)
        guard whole != nil || patchTakes > 0 else {
            if savedProposalData != nil || restoredProposal != nil { forgetSavedProposal() }
            return
        }
        guard let url = savedProposalURL, let inputs = savedProposalInputs else { return }
        let states = Dictionary((ownProposal?.changes ?? []).map { ($0.ordinal, $0.state) }, uniquingKeysWith: { first, _ in first })
        let record = RewriteSavedProposal(projectId: project.id, scope: savedProposalScope, inputs: inputs, instruction: instruction,
            changes: changes.enumerated().map { .init($0.element, state: states[$0.offset + 1] ?? .pending) },
            kept: wordingFit.kept.sorted(), pricedAnyway: pricedAnyway.sorted(), voiceRecordID: generation?.selectedVoiceID ?? restoredProposal?.voiceRecordID,
            patchTakes: patchTakes, patchUSD: patchUSD, wholeClip: whole, savedAt: Date(timeIntervalSince1970: 0))
        guard let shape = try? RewriteSavedProposalStore.encode(record), shape != savedProposalData else { return }
        var dated = record
        dated.savedAt = Date()
        guard let data = try? RewriteSavedProposalStore.encode(dated) else { return }
        do {
            try RewriteSavedProposalStore.write(data, to: url)
            savedProposalData = shape
        } catch {
            Task { [log = editor.app.log] in await log.write(LogEntry(level: .warn, category: "voice-lab", message: "rewrite proposal save failed")) }
        }
    }

    /// The paid work is gone from this Rewrite (used, discarded on the user's word, or replaced by a new run): its record
    /// goes. The journal keeps unused takes for their own 60 days.
    func forgetSavedProposal() {
        restoredProposal = nil
        savedProposalData = nil
        RewriteSavedProposalStore.remove(savedProposalURL)
    }

    /// The whole clip's unused paid work, as saved: the session's ledger and its restored amounts, or the restored record
    /// while no card has taken it yet. Nil when it holds nothing paid, or once used.
    private var savedWholeClip: RewriteSavedProposal.WholeClip? {
        guard let whole = wholeClip, whole.phase != .choose else { return restoredProposal?.wholeClip }
        guard whole.phase != .used, let script = whole.script else { return nil }
        // Only the voice for the script the card holds, and lip syncs over it: one let go (Start Over) is not offered back.
        var voices = whole.ledger.voices.filter { $0.key.script == script.text }
        for (key, usd) in whole.restoredVoices where key.script == script.text { voices[key, default: 0] += usd }
        var lipsyncs = whole.ledger.lipsyncs.filter { $0.key.voice.script == script.text }
        for (key, usd) in whole.restoredLipsyncs where key.voice.script == script.text { lipsyncs[key, default: 0] += usd }
        var parts = restoredProposal?.wholeClip?.parts ?? 0
        var requests = restoredProposal?.wholeClip?.partRequests ?? []
        if let plan = wholeClipPlan, wholeClipPlanScript == script, !plan.isRetired {
            parts = plan.phrases.count
            requests = plan.phrases.compactMap { plan.automaticTake(phrase: $0.id)?.row.receipt?.requestID.uuidString.lowercased() }
            // Parts paid of a voice not finished yet come back through the journal too.
            if voices.isEmpty, let usd = plan.spent.usd, plan.spent.units > 0, let record = generation?.selectedVoiceID {
                voices[.init(script: script.text, recordId: record, model: plan.modelID ?? VoiceLabWordingFit.modelID)] = usd
            }
        }
        guard !voices.isEmpty else { return nil }
        return .init(script: script, baseScript: whole.savedBaseScript ?? script,
                     voices: voices.map { .init(key: $0.key, usd: $0.value) }.sorted { $0.key.recordId < $1.key.recordId },
                     lipsyncs: lipsyncs.map { .init(key: $0.key, usd: $0.value) }.sorted { $0.key.retime < $1.key.retime },
                     billed: whole.billedLipsyncs, parts: parts, partRequests: requests)
    }

    /// Puts the restored whole clip on a fresh card: a stop whose Try Again puts the paid voice back for its parts' word
    /// checks (every part still in the journal, adoptable) and the paid lip sync for free.
    func restoreWholeClip(into session: WholeClipRevoiceSession) {
        guard let saved = restoredProposal?.wholeClip else { return }
        restoredProposal?.wholeClip = nil
        session.restore(.init(script: saved.script, baseScript: saved.baseScript,
                              voices: Dictionary(saved.voices.map { ($0.key, $0.usd) }, uniquingKeysWith: +),
                              lipsyncs: Dictionary(saved.lipsyncs.map { ($0.key, $0.usd) }, uniquingKeysWith: +),
                              billed: saved.billed, voiceUSD: restoredVoiceUSD(saved)))
    }

    /// What putting the restored voice back costs: each part's word check, when every part's paid take is in the journal
    /// and adoptable; nil otherwise (the voice is priced as new).
    private func restoredVoiceUSD(_ saved: RewriteSavedProposal.WholeClip) -> Decimal? {
        guard saved.parts > 0, saved.partRequests.count == saved.parts,
              let catalog = prices ?? editor.app.shared.flatMap({ try? VoiceLabPriceCatalog.load(shared: $0) }) else { return nil }
        let paidRoot = editor.app.locations.root.appendingPathComponent("VoiceLab", isDirectory: true)
        let journal = VoiceLabTakeJournal.list(projectID: project.id, paidRoot: paidRoot)
        let adoptable = Set(journal.filter(\.adoptable).map(\.requestID))
        guard saved.partRequests.allSatisfy(adoptable.contains),
              let check = try? VoiceLabPricing.estimate(operation: .elevenLabsSpeechToText, model: ElevenLabsScribe.modelID,
                                                        units: VoiceLabTakeProcessing.maximumQASeconds, catalog: catalog).usd else { return nil }
        return check * Decimal(saved.partRequests.count)
    }
}
