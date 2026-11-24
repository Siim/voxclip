import CryptoKit
import Darwin
import Foundation
import Synchronization
import VoxClipCore

/// What a paid take was made from, as the journal matches it (voice-lab §3 "Paid takes are kept"): the consent record and
/// its clone, the model and language, the words as sent with their audio tags, the words before and after the window,
/// and the pace sent (`VoiceLabPace.rounded`). The seed is left out: a new run picks its own.
public struct VoiceLabTakeJournalKey: Sendable, Hashable {
    public let recordID: String
    public let voiceID: String
    public let modelID: String
    public let language: String
    public let requestText: String
    public let previousText: String
    public let nextText: String
    public let pace: Double

    public init(recordID: String, voiceID: String, modelID: String, language: String, requestText: String,
                previousText: String, nextText: String, pace: Double?) {
        self.recordID = recordID; self.voiceID = voiceID; self.modelID = modelID; self.language = language
        self.requestText = requestText; self.previousText = previousText; self.nextText = nextText
        self.pace = VoiceLabPace.rounded(pace)
    }

    /// The key of `input`'s take `take` in the clone `voiceID`.
    public init(input: VoiceLabTakeInput, voiceID: String, take: Int = 0) {
        let options = input.options(take: take)
        self.init(recordID: input.recordID, voiceID: voiceID, modelID: input.modelID, language: input.language,
                  requestText: input.requestText, previousText: options.previousText ?? "", nextText: options.nextText ?? "",
                  pace: options.pace)
    }
}

/// One paid ElevenLabs take as it arrived, written beside its PCM the moment it is stored (voice-lab §3 "Paid takes are
/// kept"): the asset, the request and its receipt, every input the request was made from, its character timing once
/// known, and how it did in its checks once they settle. `shared/fixtures/voice-lab/take-journal-cases.json` pins the
/// shape on both platforms.
public struct VoiceLabTakeJournalEntry: Codable, Sendable, Equatable {
    public static let currentSchema = "voxclip-take-journal/1"

    public struct CharacterTiming: Codable, Sendable, Equatable {
        public let character: String
        public let start: Double
        public let end: Double
        public init(character: String, start: Double, end: Double) { self.character = character; self.start = start; self.end = end }
    }
    /// The take's character timing: the provider's, or `recovered` from its word check or on device (voice-lab §8.5).
    public struct Alignment: Codable, Sendable, Equatable {
        public var recovered: Bool
        public var characters: [CharacterTiming]
        public init(recovered: Bool, characters: [CharacterTiming]) { self.recovered = recovered; self.characters = characters }
    }
    public struct Receipt: Codable, Sendable, Equatable {
        public let provider: String
        public let region: String
        public let endpoint: String
        public init(provider: String, region: String, endpoint: String) { self.provider = provider; self.region = region; self.endpoint = endpoint }
    }
    /// How the take did in its own checks, written when each settles. The same audio fails them the same way, so an entry
    /// with a hard failure is never adopted: adopting it would buy its word check again only to fail again.
    public struct Checks: Codable, Sendable, Equatable {
        public enum Outcome: String, Codable, Sendable { case passed, failed }
        /// The take's own speaker check; nil when it was not measured alone (a short take's check is pooled with other
        /// takes', a verdict on the group rather than on this take).
        public var speaker: Outcome?
        /// The paid word check; nil when it never ran (a take that failed its speaker check first).
        public var words: Outcome?
        /// The failures the same audio repeats: `VoiceLabTakeQAFailure` raw values other than `loudness`, and `timing` when
        /// the take's timing could not be recovered from what its word check heard (voice-lab §8.5).
        public var hardFailures: [String]
        public init(speaker: Outcome?, words: Outcome?, hardFailures: [String]) {
            self.speaker = speaker; self.words = words; self.hardFailures = hardFailures
        }
        /// The verdict of the take's word check and acoustics (`VoiceLabTakeQuality.evaluate`).
        init(_ qa: VoiceLabTakeQAResult, speakerScore: Double?, threshold: Double) {
            self.init(speaker: speakerScore.map { $0 >= threshold ? .passed : .failed },
                      words: qa.failures.contains(.transcript) ? .failed : .passed,
                      hardFailures: qa.hardFailures.map(\.rawValue))
        }
        /// The take's own speaker check failed before its word check was sent.
        static let speakerFailed = Checks(speaker: .failed, words: nil, hardFailures: [VoiceLabTakeQAFailure.speaker.rawValue])
        /// Its word check heard words that could not be lined up with the text, here or on device.
        static let timingUnrecovered = Checks(speaker: nil, words: .failed, hardFailures: ["timing"])
    }

    public let schema: String
    /// `<projectId>/<assetId>.wav` under the paid root: mono PCM16 as the provider returned it.
    public let assetFile: String
    public let assetSha256: String
    /// The request's own ID (lowercase) and the provider's.
    public let requestID: String
    public let providerRequestID: String?
    public let recordID: String
    public let voiceID: String
    public let modelID: String
    public let language: String
    public let requestText: String
    public let previousText: String
    public let nextText: String
    public let pace: Double
    public let seed: UInt32
    public let sampleRate: Int
    public let frames: Int
    public var alignment: Alignment?
    /// Nil until the take's checks settle, and for a take whose run stopped before they did: such a take is adopted.
    public var checks: Checks?
    public let receipt: Receipt
    /// The synthesis request's quoted price in US dollars, as a decimal string; nil when it was unknown.
    public let estimateUSD: String?
    public let createdAt: Date

    public init(assetFile: String, assetSha256: String, requestID: UUID, providerRequestID: String?, key: VoiceLabTakeJournalKey,
                seed: UInt32, sampleRate: Int, frames: Int, alignment: Alignment?, checks: Checks? = nil, receipt: Receipt,
                estimateUSD: Decimal?, createdAt: Date) {
        schema = Self.currentSchema
        self.assetFile = assetFile; self.assetSha256 = assetSha256
        self.requestID = requestID.uuidString.lowercased(); self.providerRequestID = providerRequestID
        recordID = key.recordID; voiceID = key.voiceID; modelID = key.modelID; language = key.language
        requestText = key.requestText; previousText = key.previousText; nextText = key.nextText; pace = key.pace
        self.seed = seed; self.sampleRate = sampleRate; self.frames = frames; self.alignment = alignment
        self.checks = checks; self.receipt = receipt
        self.estimateUSD = estimateUSD.map { NSDecimalNumber(decimal: $0).stringValue }
        self.createdAt = createdAt
    }

    public var key: VoiceLabTakeJournalKey {
        VoiceLabTakeJournalKey(recordID: recordID, voiceID: voiceID, modelID: modelID, language: language, requestText: requestText,
                               previousText: previousText, nextText: nextText, pace: pace)
    }
    /// The asset's ID, the journal file's name.
    public var assetID: String { String((assetFile.split(separator: "/").last ?? "").dropLast(".wav".count)) }
    /// False once a check failed in a way the same audio repeats (`Checks.hardFailures`).
    public var adoptable: Bool { checks?.hardFailures.isEmpty ?? true }
    public var adoptableForSelectedVoice: Bool {
        adoptable || (checks?.hardFailures == [VoiceLabTakeQAFailure.speaker.rawValue] && checks?.words != .failed)
    }
    var timing: [VoiceLabCharacterTiming]? {
        alignment.map { $0.characters.map { VoiceLabCharacterTiming(character: $0.character, start: $0.start, end: $0.end) } }
    }
    var voiceLabReceipt: VoiceLabReceipt? {
        guard let region = ElevenLabsRegion(rawValue: receipt.region), let request = UUID(uuidString: requestID) else { return nil }
        return VoiceLabReceipt(provider: receipt.provider, region: region, endpoint: receipt.endpoint, modelID: modelID, voiceID: voiceID,
                               requestID: request, providerRequestID: providerRequestID, spendWarning: nil, pace: pace)
    }
    var asset: VoiceLabAsset {
        VoiceLabAsset(id: assetID, file: assetFile, sha256: assetSha256, durationSeconds: Double(frames) / Double(sampleRate),
                      sampleRate: sampleRate, createdAt: createdAt)
    }
}

/// The journal of one project's paid takes, under `VoiceLab/<projectId>/takes/` (0700): `<assetId>.json` (0600), each
/// written to a temporary file, flushed and renamed into place, so a crash leaves either the old entry or the new one and at
/// most a `.partial` file that nothing reads. An entry is written when its PCM is stored and before any check that can
/// fail; its timing is updated once recovered, and its checks once they settle. A take run adopts an entry over the same
/// words, voice and model for free unless a check failed it (`match`), retention keeps its asset
/// (`VoiceLabAssetRetention`), and the entry goes once the project uses the asset, or after `unusedLifetime`. No
/// project-format change.
public enum VoiceLabTakeJournal {
    static let folder = "takes"
    /// How long an entry the project never used stays adoptable (the lead's decision, 2026-11-21).
    public static let unusedLifetime: TimeInterval = 60 * 24 * 60 * 60
    static let maximumEntryBytes = 4 * 1_024 * 1_024

    public static func write(_ entry: VoiceLabTakeJournalEntry, projectID: String, paidRoot: URL) throws {
        try validate(entry, projectID: projectID)
        try withFolder(projectID: projectID, paidRoot: paidRoot, create: true) { takes in try store(entry, in: takes) }
    }

    /// The entry of `assetFile` with its character timing, after the take's timing was recovered (voice-lab §8.5).
    public static func updateTiming(assetFile: String, timing: [VoiceLabCharacterTiming], recovered: Bool,
                                    projectID: String, paidRoot: URL) throws {
        try update(assetFile: assetFile, projectID: projectID, paidRoot: paidRoot) { entry in
            entry.alignment = .init(recovered: recovered, characters: timing.map { .init(character: $0.character, start: $0.start, end: $0.end) })
        }
    }

    /// The entry of `assetFile` with how the take did in its checks, once they settle; a later run's verdict replaces it.
    public static func updateChecks(assetFile: String, checks: VoiceLabTakeJournalEntry.Checks, projectID: String, paidRoot: URL) throws {
        try update(assetFile: assetFile, projectID: projectID, paidRoot: paidRoot) { $0.checks = checks }
    }

    private static func update(assetFile: String, projectID: String, paidRoot: URL,
                               _ change: (inout VoiceLabTakeJournalEntry) -> Void) throws {
        try withFolder(projectID: projectID, paidRoot: paidRoot, create: false) { takes in
            let id = String((assetFile.split(separator: "/").last ?? "").dropLast(".wav".count))
            guard var entry = read(takes, "\(id).json", projectID: projectID), entry.assetFile == assetFile else { throw VoiceLabError.invalidInput }
            change(&entry)
            try validate(entry, projectID: projectID)
            try store(entry, in: takes)
        }
    }

    /// Every valid entry, in no particular order. Partial files, foreign names and malformed entries are left out.
    public static func list(projectID: String, paidRoot: URL) -> [VoiceLabTakeJournalEntry] {
        (try? withFolder(projectID: projectID, paidRoot: paidRoot, create: false) { takes in entries(takes, projectID: projectID) }) ?? []
    }

    /// The newest entry over `key` that meets the flow's adoption rules and still has its frame count and
    /// SHA-256, leaving out the asset files in `claimed` (already taken by a live run); nil when none.
    public static func match(_ key: VoiceLabTakeJournalKey, projectID: String, paidRoot: URL,
                             excluding claimed: Set<String> = [], forSelectedVoice: Bool = false) -> VoiceLabTakeJournalEntry? {
        let candidates = list(projectID: projectID, paidRoot: paidRoot)
            .filter { $0.key == key && (forSelectedVoice ? $0.adoptableForSelectedVoice : $0.adoptable)
                && !claimed.contains($0.assetFile) && $0.sampleRate == 24_000 }
            .sorted { $0.createdAt == $1.createdAt ? $0.assetFile > $1.assetFile : $0.createdAt > $1.createdAt }
        return candidates.first { (try? pcm(of: $0, projectID: projectID, paidRoot: paidRoot)) != nil }
    }

    package static func previewAdoptions(_ keys: [VoiceLabTakeJournalKey], projectID: String, paidRoot: URL) -> Set<Int> {
        var excluded = VoiceLabTakeJournalClaims.shared.claimed(under: paidRoot, except: nil)
        var matched = Set<Int>()
        for (index, key) in keys.enumerated() {
            guard !Task.isCancelled else { return [] }
            if let entry = match(key, projectID: projectID, paidRoot: paidRoot, excluding: excluded, forSelectedVoice: true) {
                excluded.insert(entry.assetFile)
                matched.insert(index)
            }
        }
        return matched
    }

    /// Drops the entry of `assetID`; its asset stays.
    public static func remove(assetID: String, projectID: String, paidRoot: URL) {
        _ = try? withFolder(projectID: projectID, paidRoot: paidRoot, create: false) { takes in
            if unlinkat(takes, "\(assetID).json", 0) == 0 { _ = VoiceLabPaidRoot.fullSync(takes) }
        }
    }

    /// The take an entry describes, from its stored PCM, for a run that adopts it: the PCM after its exact canonical header
    /// and SHA-256, the timing and the receipt as they were, and the asset. Nothing is sent.
    static func adopt(_ entry: VoiceLabTakeJournalEntry, projectID: String, paidRoot: URL) throws -> (result: VoiceLabAudioResult, asset: VoiceLabAsset) {
        try validate(entry, projectID: projectID)
        guard let receipt = entry.voiceLabReceipt else { throw VoiceLabError.invalidInput }
        let samples = try pcm(of: entry, projectID: projectID, paidRoot: paidRoot)
        return (VoiceLabAudioResult(pcm: samples, sampleRate: entry.sampleRate, alignment: entry.timing, receipt: receipt), entry.asset)
    }

    /// The entries in the project directory `project`'s journal, for retention, which holds the paid root's lock.
    static func entries(inProject project: Int32, projectID: String) -> [VoiceLabTakeJournalEntry] {
        let takes = openat(project, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard takes >= 0 else { return [] }
        defer { Darwin.close(takes) }
        return entries(takes, projectID: projectID)
    }
    /// Drops entries from the project directory `project`'s journal, for retention.
    static func remove(_ assetIDs: [String], inProject project: Int32) {
        guard !assetIDs.isEmpty else { return }
        let takes = openat(project, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard takes >= 0 else { return }
        defer { Darwin.close(takes) }
        var removed = false
        for id in assetIDs where unlinkat(takes, "\(id).json", 0) == 0 { removed = true }
        if removed { _ = VoiceLabPaidRoot.fullSync(takes) }
    }

    static func encode(_ entry: VoiceLabTakeJournalEntry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(entry)
    }
    static func decode(_ data: Data) throws -> VoiceLabTakeJournalEntry {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VoiceLabTakeJournalEntry.self, from: data)
    }

    static func validate(_ entry: VoiceLabTakeJournalEntry, projectID: String) throws {
        let id = entry.assetID
        guard entry.schema == VoiceLabTakeJournalEntry.currentSchema,
              VoiceLabAssetNaming.isSafeProjectID(projectID),
              (try? VoiceLabAssetNaming.file(projectId: projectID, assetId: id, extension: "wav")) == entry.assetFile,
              entry.assetSha256.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil,
              UUID(uuidString: entry.requestID)?.uuidString.lowercased() == entry.requestID,
              ElevenLabsRegion(rawValue: entry.receipt.region) != nil, !entry.receipt.endpoint.isEmpty,
              !entry.recordID.isEmpty, !entry.voiceID.isEmpty, !entry.modelID.isEmpty, !entry.language.isEmpty, !entry.requestText.isEmpty,
              entry.pace.isFinite, entry.pace > 0, (8_000...192_000).contains(entry.sampleRate),
              (1...VoiceLabAssetStore.maxFrames).contains(entry.frames),
              entry.estimateUSD.map({ Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) != nil }) ?? true,
              entry.alignment?.characters.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }) ?? true,
              entry.checks?.hardFailures.allSatisfy({ (1...64).contains($0.count) }) ?? true
        else { throw VoiceLabError.invalidInput }
    }

    /// The asset's PCM, when the file is a regular file of this user holding exactly the canonical mono PCM16 header for the
    /// entry's frames and rate, then the frames, and its SHA-256 is the entry's.
    private static func pcm(of entry: VoiceLabTakeJournalEntry, projectID: String, paidRoot: URL) throws -> Data {
        let wave = try verifiedWave(of: entry, projectID: projectID, paidRoot: paidRoot)
        return wave.subdata(in: 44..<wave.count)
    }

    package static func verifiedWave(of entry: VoiceLabTakeJournalEntry, projectID: String, paidRoot: URL) throws -> Data {
        try validate(entry, projectID: projectID)
        let root = try VoiceLabPaidRoot.open(paidRoot)
        defer { Darwin.close(root) }
        let project = openat(root, projectID, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard project >= 0 else { throw VoiceLabAssetError.missing(entry.assetFile) }
        defer { Darwin.close(project) }
        let descriptor = openat(project, "\(entry.assetID).wav", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw VoiceLabAssetError.missing(entry.assetFile) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        let size = 44 + 2 * Int64(entry.frames)
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size == size,
              let bytes = try handle.readToEnd(), Int64(bytes.count) == size,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == entry.assetSha256,
              bytes.prefix(44) == VoiceLabAssetStore.wavHeader(frames: entry.frames, sampleRate: entry.sampleRate) else {
            throw VoiceLabAssetError.altered(entry.assetFile)
        }
        return bytes
    }

    private static func entries(_ takes: Int32, projectID: String) -> [VoiceLabTakeJournalEntry] {
        guard let names = try? VoiceLabAssetRecovery.names(takes) else { return [] }
        return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted().compactMap { read(takes, $0, projectID: projectID) }
    }

    private static func read(_ takes: Int32, _ name: String, projectID: String) -> VoiceLabTakeJournalEntry? {
        let descriptor = openat(takes, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              (1...Int64(maximumEntryBytes)).contains(info.st_size), let data = try? handle.readToEnd(),
              let entry = try? decode(data), "\(entry.assetID).json" == name,
              (try? validate(entry, projectID: projectID)) != nil else { return nil }
        return entry
    }

    private static func store(_ entry: VoiceLabTakeJournalEntry, in takes: Int32) throws {
        let data = try encode(entry)
        let name = "\(entry.assetID).json", partial = ".\(entry.assetID).json.partial"
        unlinkat(takes, partial, 0)
        let descriptor = openat(takes, partial, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw VoiceLabAssetStoreError.unwritable(name) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            guard VoiceLabPaidRoot.fullSync(descriptor) else { throw VoiceLabAssetStoreError.unwritable(name) }
            try handle.close()
            guard renameat(takes, partial, takes, name) == 0, VoiceLabPaidRoot.fullSync(takes) else { throw VoiceLabAssetStoreError.unwritable(name) }
        } catch {
            unlinkat(takes, partial, 0)
            throw error
        }
    }

    private static func withFolder<Value>(projectID: String, paidRoot: URL, create: Bool,
                                          _ body: (Int32) throws -> Value) throws -> Value {
        guard VoiceLabAssetNaming.isSafeProjectID(projectID) else { throw VoiceLabError.invalidInput }
        let root = try VoiceLabPaidRoot.open(paidRoot)
        defer { Darwin.close(root) }
        let project: Int32
        if create { project = try VoiceLabPaidRoot.directory(projectID, in: root) }
        else {
            project = openat(root, projectID, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard project >= 0 else { throw VoiceLabAssetStoreError.unsafePath(projectID) }
        }
        defer { Darwin.close(project) }
        let takes: Int32
        if create { takes = try VoiceLabPaidRoot.directory(folder, in: project) }
        else {
            takes = openat(project, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard takes >= 0 else { throw VoiceLabAssetStoreError.unsafePath(folder) }
        }
        defer { Darwin.close(takes) }
        return try body(takes)
    }
}

/// The journal assets live take runs hold in this process, so one paid take is never adopted by two runs, and a run never
/// adopts a take it made or adopted itself: Try Another means a new take. A run's claims go when it is invalidated or freed;
/// a relaunch starts with none.
final class VoiceLabTakeJournalClaims: Sendable {
    static let shared = VoiceLabTakeJournalClaims()
    private let owners = Mutex<[String: UUID]>([:])

    static func key(_ assetFile: String, paidRoot: URL) -> String { paidRoot.standardizedFileURL.path + "/" + assetFile }

    /// True when `key` is now `owner`'s, newly or already.
    func claim(_ key: String, owner: UUID) -> Bool {
        owners.withLock { owners in
            if let held = owners[key] { return held == owner }
            owners[key] = owner
            return true
        }
    }
    func release(_ key: String, owner: UUID) {
        owners.withLock { owners in if owners[key] == owner { owners.removeValue(forKey: key) } }
    }
    func releaseAll(owner: UUID) {
        owners.withLock { owners in owners = owners.filter { $0.value != owner } }
    }
    /// The asset files under `paidRoot` that runs other than `owner` hold.
    func claimed(under paidRoot: URL, except owner: UUID?) -> Set<String> {
        let prefix = paidRoot.standardizedFileURL.path + "/"
        return owners.withLock { owners in
            Set(owners.compactMap { $0.value != owner && $0.key.hasPrefix(prefix) ? String($0.key.dropFirst(prefix.count)) : nil })
        }
    }
}
