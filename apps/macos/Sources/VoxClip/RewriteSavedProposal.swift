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
    /// and the journal requests of the voice's parts, which say which parts can come back with their word check only.
    struct WholeClip: Codable, Equatable {
        var script: WholeClipScript
        var baseScript: WholeClipScript
        var voices: [VoiceEntry]
        var lipsyncs: [LipsyncEntry]
        var billed: [String: Decimal]
        /// The voice's parts, and the journal request of each part's paid take, in part order ("" for a part with none).
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
    /// The patch's paid takes when it was saved, what they cost, and their journal requests, which say how many can still
    /// come back with their word check only.
    var patchTakes: Int
    var patchUSD: Decimal
    var patchRequests: [String]
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

/// Where saved proposals live: `<data>/VoiceLab/<projectId>/rewrite/<sha256 of the scope>.json`, owner-only from the
/// moment it exists (0600 in a 0700 folder), written atomically and fsynced. The Voice Lab's asset retention reads only
/// audio and video files there, so it never takes one. A launch sweeps the records 60 days unused (`sweepStale`).
enum RewriteSavedProposalStore {
    static let folderName = "rewrite"

    static func url(paidRoot: URL, projectId: String, scope: String) -> URL? {
        guard !projectId.isEmpty, projectId != ".", projectId != "..", !projectId.contains("/") else { return nil }
        return paidRoot.appendingPathComponent(projectId, isDirectory: true).appendingPathComponent(folderName, isDirectory: true)
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

    /// Writes `data` at `url` atomically: a temporary file created 0600 in the record's folder (forced to 0700, also when
    /// it already exists), written and fsynced, then renamed over the record and the folder fsynced. No moment shows the
    /// record with other permissions, half written, or under its name before it is complete.
    static func write(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try ownerOnlyFolder(folder)
        let temporary = folder.appendingPathComponent("." + url.lastPathComponent + "." + UUID().uuidString.lowercased() + ".partial")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var renamed = false
        defer {
            close(descriptor)
            if !renamed { unlink(temporary.path) }
        }
        // The umask can only take bits away; the mode is set exactly on the temporary file, before it has the record's name.
        guard fchmod(descriptor, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += written
            }
        }
        guard fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        renamed = true
        let directory = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if directory >= 0 { _ = fsync(directory); close(directory) }
    }

    /// The records' folder, 0700: made so, or set so when it already exists with other permissions. A link or a file in
    /// its place is refused.
    static func ownerOnlyFolder(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw CocoaError(.fileWriteNoPermission) }
        if info.st_mode & 0o777 != 0o700 { guard chmod(folder.path, 0o700) == 0 else { throw CocoaError(.fileWriteNoPermission) } }
    }

    static func remove(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// The launch's sweep, beside the Voice Lab scratch sweep (`AppModel.loadStartup`): every project's records 60 days
    /// unused, unreadable or of another schema go (`load`), and temporary files a quit or crash left mid-write an hour ago
    /// or more. Records still in their 60 days stay. Returns how many files went; one folder's failure never stops the rest.
    @discardableResult static func sweepStale(paidRoot: URL, now: Date = Date()) -> Int {
        let manager = FileManager.default
        guard let projects = try? manager.contentsOfDirectory(at: paidRoot, includingPropertiesForKeys: nil) else { return 0 }
        var removed = 0
        for project in projects {
            let folder = project.appendingPathComponent(folderName, isDirectory: true)
            var info = stat()
            guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  let names = try? manager.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names {
                let file = folder.appendingPathComponent(name)
                if name.hasPrefix("."), name.hasSuffix(".partial") {
                    let modified = (try? manager.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? now
                    if now.timeIntervalSince(modified) >= 60 * 60, (try? manager.removeItem(at: file)) != nil { removed += 1 }
                } else if name.hasSuffix(".json"), load(file, now: now) == nil, !manager.fileExists(atPath: file.path) {
                    removed += 1
                }
            }
        }
        return removed
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

    /// The digest of what the scope reads (`inside`), as a relaunch reads it: the same after a relaunch when nothing in the
    /// scope changed. The project goes through the document's own encoding and decoding first, so what a save rounds or
    /// orders (dates to the millisecond, cuts in transcript order, NFC text) digests the same before the quit and after:
    /// a project imported or transcribed this session holds `Date()`s finer than its .voxclip file keeps. Cached for the
    /// project it was made from.
    var savedProposalInputs: String? {
        if let cached = savedInputsDigest, cached.project == project { return cached.digest }
        let digest = Self.inputsDigest(inside(Self.asReopened(project)))
        if let digest { savedInputsDigest = (project, digest) }
        return digest
    }

    /// `project` as the .voxclip file gives it back (`JSONProjectStore.encode` then `decode`); as it is when it can't be
    /// encoded (it couldn't be saved either).
    static func asReopened(_ project: Project) -> Project {
        (try? JSONProjectStore.decode(JSONProjectStore.encode(project))) ?? project
    }

    /// A plain sorted encoding of the scoped inputs, every date as whole milliseconds as the document writes them: the
    /// scoped inputs are no document of their own (their save dates are cleared), so they are neither validated nor dated
    /// as one.
    static func inputsDigest(_ inputs: Project) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(UTCTimestamp.milliseconds(from: date) ?? 0)
        }
        return (try? encoder.encode(inputs)).map(VoiceLabFingerprint.bytes)
    }

    /// The restored proposal's paid patch takes the journal can still give back (`restoredTakesKept`, read at restore), as
    /// a note: "Your 2 paid takes from before VoxClip closed are kept: Make Takes uses them again and pays only for the word
    /// checks.", or "1 of your 2 paid takes …" when some are gone. Nil once a plan holds takes again, or when none is left.
    var restoredPaidWorkNote: String? {
        guard let saved = restoredProposal, saved.patchTakes > 0, takePlan == nil, restoredTakesKept > 0 else { return nil }
        let kept = min(restoredTakesKept, saved.patchTakes)
        let lead = kept < saved.patchTakes ? "\(kept) of your \(saved.patchTakes) paid takes from before VoxClip closed \(kept == 1 ? "is" : "are") kept"
            : kept == 1 ? "Your paid take from before VoxClip closed is kept" : "Your \(kept) paid takes from before VoxClip closed are kept"
        return lead + ": Make Takes uses \(kept == 1 ? "it" : "them") again and pays only for the word checks."
    }

    /// The journal requests whose paid take can still come back for its word check: adoptable (no check failed it) and
    /// within the journal's 60 days.
    func adoptableJournalRequests(now: Date = Date()) -> Set<String> {
        let paidRoot = editor.app.locations.root.appendingPathComponent("VoiceLab", isDirectory: true)
        return Set(VoiceLabTakeJournal.list(projectID: project.id, paidRoot: paidRoot)
            .filter { $0.adoptable && now.timeIntervalSince($0.createdAt) < VoiceLabTakeJournal.unusedLifetime }.map(\.requestID))
    }

    /// The journal requests of the patch's paid takes (its plan's cloned-voice takes and the generation's). An adopted
    /// take's receipt is the journal entry's own, so a second relaunch finds it under the same request.
    private var patchTakeRequests: [String] {
        let planned = takePlan?.phrases.flatMap { phrase in
            phrase.takes.filter { $0.source == .clonedVoice }.compactMap { $0.row.receipt?.requestID.uuidString.lowercased() }
        } ?? []
        return planned + (generation?.rows.compactMap { $0.receipt?.requestID.uuidString.lowercased() } ?? [])
    }

    /// Paid patch takes saved before VoxClip closed that the journal can still give back, while no plan holds paid patch
    /// work again (before Make Takes adopts them, or while its price waits for the click): unused paid work, which
    /// closing, a new run and a change of the proposal ask about first (`hasUnusedPaidWork`, `changeNeedsDiscard`).
    var restoredTakesPending: Bool { restoredPendingTakes > 0 }

    /// How many of `restoredTakesPending`'s takes the journal can give back; 0 when none pends.
    var restoredPendingTakes: Int {
        guard let saved = restoredProposal, saved.patchTakes > 0, restoredTakesKept > 0, !hasPaidPatchWork else { return 0 }
        return min(restoredTakesKept, saved.patchTakes)
    }

    /// The user let the patch's paid takes go (Discard Takes, Discard Changes): the takes saved before a relaunch go with
    /// them, so the next write finds nothing of them to keep and is not offered them back.
    func letGoOfRestoredTakes() {
        guard restoredProposal != nil else { return }
        restoredProposal?.patchTakes = 0
        restoredProposal?.patchUSD = 0
        restoredProposal?.patchRequests = []
        restoredTakesKept = 0
    }

    /// Saves the proposal with its unused paid work. Free; an unchanged record is not written again, and a proposal with
    /// nothing paid reads nothing. The record stays while the proposal or its take plan is open, whatever the plan holds
    /// at the moment: a plan only priced, or still adopting the takes saved before a relaunch, keeps those takes in it. It
    /// goes on Use (Use Takes, Use Whole Clip, Use the Voice Without Lip Sync), on an explicit discard (the paid-work
    /// question's Discard, Discard Takes, Discard Changes, Undo on a whole clip's Review or the patch over it), on a new
    /// run of the Rewrite that restored or wrote it (which asks first over unused paid work), and after 60 days unused.
    func persistPaidWork() {
        guard isOpen else { return }
        // Use Whole Clip, or Use the Voice Without Lip Sync, put the whole clip's paid work into the project as one undo
        // step. The edit may have set the proposal aside (R3), so this never waits for it: the record goes, and a relaunch
        // never offers that work back to put in or pay for again.
        if wholeClip?.phase == .used, !hasPaidPatchWork {
            if savedProposalData != nil || restoredProposal != nil { forgetSavedProposal() }
            return
        }
        guard !paidWorkUsed, ownProposal != nil else { return }
        let whole = savedWholeClip
        let planTakes = hasPaidPatchWork ? paidTakeCount : 0
        let planUSD = hasPaidPatchWork ? (takePlan.flatMap { $0.isRetired ? nil : $0.spent.usd } ?? 0) : 0
        // Takes saved before a relaunch are still the proposal's until a plan holds paid takes again: Make Takes' price
        // before its click, or a plan still adopting them, holds none yet.
        let restored = planTakes > 0 ? nil : restoredProposal
        let patchTakes = planTakes > 0 ? planTakes : (restored?.patchTakes ?? 0)
        let patchUSD = planTakes > 0 ? planUSD : (restored?.patchUSD ?? 0)
        let patchRequests = planTakes > 0 ? patchTakeRequests : (restored?.patchRequests ?? [])
        // Nothing paid is left in this Rewrite: only the explicit discards above get here with a record to remove.
        guard whole != nil || patchTakes > 0 else {
            if savedProposalData != nil || restoredProposal != nil { forgetSavedProposal() }
            return
        }
        guard let url = savedProposalURL, let inputs = savedProposalInputs else { return }
        let states = Dictionary((ownProposal?.changes ?? []).map { ($0.ordinal, $0.state) }, uniquingKeysWith: { first, _ in first })
        // A restored proposal keeps what it answered, even while another instruction waits for Rewrite Again.
        let record = RewriteSavedProposal(projectId: project.id, scope: savedProposalScope, inputs: inputs, instruction: restoredProposal?.instruction ?? instruction,
            changes: changes.enumerated().map { .init($0.element, state: states[$0.offset + 1] ?? .pending) },
            kept: wordingFit.kept.sorted(), pricedAnyway: pricedAnyway.sorted(), voiceRecordID: generation?.selectedVoiceID ?? restoredProposal?.voiceRecordID,
            patchTakes: patchTakes, patchUSD: patchUSD, patchRequests: patchRequests, wholeClip: whole, savedAt: Date(timeIntervalSince1970: 0))
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
            // In part order, so each part's word check or new voice can be priced on its own (`restoredVoiceUSD`).
            requests = plan.phrases.map { plan.automaticTake(phrase: $0.id)?.row.receipt?.requestID.uuidString.lowercased() ?? "" }
            // Parts paid of a voice not finished yet come back through the journal too.
            if voices.isEmpty, let usd = plan.spent.usd, plan.spent.units > 0, let record = generation?.selectedVoiceID {
                voices[.init(script: script.text, recordId: record, model: plan.modelID ?? VoiceLabWordingFit.modelID)] = usd
            }
        }
        guard !voices.isEmpty else { return nil }
        let savedVoices: [RewriteSavedProposal.VoiceEntry] = voices.map { RewriteSavedProposal.VoiceEntry(key: $0.key, usd: $0.value) }
            .sorted { $0.key.recordId < $1.key.recordId }
        let savedLipsyncs: [RewriteSavedProposal.LipsyncEntry] = lipsyncs.map { RewriteSavedProposal.LipsyncEntry(key: $0.key, usd: $0.value) }
            .sorted { $0.key.retime < $1.key.retime }
        let base: WholeClipScript = whole.savedBaseScript ?? script
        return RewriteSavedProposal.WholeClip(script: script, baseScript: base, voices: savedVoices, lipsyncs: savedLipsyncs,
                                              billed: whole.billedLipsyncs, parts: parts, partRequests: requests)
    }

    /// Puts the restored whole clip on a fresh card: a stop whose Try Again puts the paid voice back for its parts' word
    /// checks, and the paid lip sync for free, when every part is still in the journal (adoptable); otherwise it voices
    /// the parts that can't come back and lip syncs the clip again, priced so before the click.
    func restoreWholeClip(into session: WholeClipRevoiceSession) {
        guard let saved = restoredProposal?.wholeClip else { return }
        restoredProposal?.wholeClip = nil
        let catalog = prices ?? editor.app.shared.flatMap { try? VoiceLabPriceCatalog.load(shared: $0) }
        let adoptable = adoptableJournalRequests()
        let back = saved.partRequests.filter { !$0.isEmpty && adoptable.contains($0) }.count
        session.restore(.init(script: saved.script, baseScript: saved.baseScript,
                              voices: Dictionary(saved.voices.map { ($0.key, $0.usd) }, uniquingKeysWith: +),
                              lipsyncs: Dictionary(saved.lipsyncs.map { ($0.key, $0.usd) }, uniquingKeysWith: +),
                              billed: saved.billed, voiceUSD: Self.restoredVoiceUSD(saved, adoptable: adoptable, catalog: catalog),
                              parts: saved.parts, partsBack: min(back, saved.parts), checkUSD: catalog.flatMap(Self.wordCheckUSD)))
    }

    /// One take's word check, as a take's quote prices it.
    static func wordCheckUSD(_ catalog: VoiceLabPriceCatalog) -> Decimal? {
        try? VoiceLabPricing.estimate(operation: .elevenLabsSpeechToText, model: ElevenLabsScribe.modelID,
                                      units: VoiceLabTakeProcessing.maximumQASeconds, catalog: catalog).usd
    }

    /// What putting the restored voice back costs, part by part as the fresh plan prices it: a part whose paid take the
    /// journal gives back (adoptable, under 60 days) only its word check; any other part a new voice of its words and its
    /// word check. Nil when that can't be made exact (no prices, or parts the record doesn't line up with): the card then
    /// prices the voice as new (`WholeClipRevoiceSession.restoredRetryVoiceUSD`).
    static func restoredVoiceUSD(_ saved: RewriteSavedProposal.WholeClip, adoptable: Set<String>,
                                 catalog: VoiceLabPriceCatalog?) -> Decimal? {
        let parts = saved.script.parts
        guard saved.parts > 0, saved.partRequests.count == saved.parts, parts.count == saved.parts, let catalog,
              let check = wordCheckUSD(catalog) else { return nil }
        var usd = Decimal(0)
        for (part, request) in zip(parts, saved.partRequests) {
            usd += check
            if !request.isEmpty, adoptable.contains(request) { continue }
            let characters: Double = Double(part.text.unicodeScalars.count)
            guard let voice = try? VoiceLabPricing.estimate(operation: .elevenLabsTextToSpeech, model: VoiceLabWordingFit.modelID,
                                                            units: characters, catalog: catalog).usd else { return nil }
            usd += voice
        }
        return usd
    }
}
