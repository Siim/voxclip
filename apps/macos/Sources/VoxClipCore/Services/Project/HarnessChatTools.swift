import CryptoKit
import Foundation

enum HarnessChatTools {
    static func text(_ value: JSONValue?, max: Int) throws -> String {
        guard case .string(let text) = value, !text.isEmpty, text.unicodeScalars.count <= max,
              text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.unicodeScalars.contains(where: { [.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) }) else {
            throw HarnessError.invalid("Unexpected or invalid text argument.")
        }
        return text
    }

    static func strings(_ value: JSONValue?, maxCount: Int, maxLength: Int) throws -> [String] {
        guard let value else { return [] }
        guard case .array(let items) = value, items.count <= maxCount else { throw HarnessError.invalid("Unexpected or invalid list argument.") }
        return try items.map { try text($0, max: maxLength) }
    }

    static func timeline(_ arguments: JSONValue) throws -> (JSONValue, String?, [JSONValue]) {
        var fields = try HarnessTimeline.requireObject(arguments, keys: HarnessTool.proposeTimeline.keys.union(["revises", "label"]))
        let revises = try fields.removeValue(forKey: "revises").map { try text($0, max: 200) }
        func takeLabel(_ fields: inout [String: JSONValue]) throws -> JSONValue {
            try fields.removeValue(forKey: "label").map { .string(try text($0, max: 120)) } ?? .null
        }
        if let value = fields["timelines"] {
            _ = try HarnessTimeline.requireObject(.object(fields), keys: ["timelines"])
            guard case .array(let items) = value, (1...6).contains(items.count) else { throw HarnessError.invalid("Propose one to six timelines.") }
            var labels: [JSONValue] = []
            let timelines = try items.map { item in
                var timeline = try HarnessTimeline.requireObject(item, keys: HarnessTimeline.keys.union(["label"]))
                labels.append(try takeLabel(&timeline))
                return JSONValue.object(timeline)
            }
            return (.object(["timelines": .array(timelines)]), revises, labels)
        }
        let label = try takeLabel(&fields)
        return (.object(fields), revises, [label])
    }

    static func pointTo(_ fields: [String: JSONValue]) throws -> HarnessResult {
        let panel = try text(fields["panel"], max: 32)
        let labels = ["captions": "Open Captions", "music": "Open Music", "rewrite": "Open Rewrite", "export": "Open Export",
                      "settingsAI": "Open AI Settings", "outline": "Open Outline"]
        guard let label = labels[panel] else { throw HarnessError.invalid("Choose a supported panel.") }
        var result: [String: JSONValue] = ["panel": .string(panel), "label": .string(label)]
        if let target = fields["target"] { result["target"] = .string(try text(target, max: 200)) }
        return .init(result)
    }

    static func offer(_ fields: [String: JSONValue], project: Project, shared: SharedResources, postableCap: Decimal?) throws -> HarnessResult {
        let kind = try text(fields["kind"], max: 32)
        let target = try text(fields["target"], max: 200)
        guard project.edits.clips.contains(where: { $0.id == target }) else { throw HarnessError.invalid("Choose a clip id from read_clips.") }
        let brief = try fields["brief"].map { try text($0, max: 2000) }
        let wordIDs = try strings(fields["words"], maxCount: 500, maxLength: 200)
        let wordsByID = Dictionary(uniqueKeysWithValues: ProjectClock.build(project).words.map { ($0.id, $0) })
        let words = wordIDs.compactMap { wordsByID[$0] }
        guard words.count == wordIDs.count else { throw HarnessError.invalid("Choose word ids from read_transcript.") }
        let quote: String?
        switch kind {
        case "generateMusic": quote = try HarnessProposal.musicPrice(in: project, shared: shared, clipID: target)
        case "illustration": quote = try ClipIllustrationQuote.load(shared: shared).price
        case "revoice":
            let script = brief ?? words.map { project.edits.corrections[$0.id] ?? $0.text }.joined(separator: " ")
            guard !script.isEmpty else { throw HarnessError.invalid("Give replacement text or choose word ids from read_transcript.") }
            let estimate = try VoiceLabPricing.estimate(operation: .elevenLabsTextToSpeech, model: "eleven_multilingual_v2",
                units: Double(VoiceLabTextLength.length(script)), catalog: VoiceLabPriceCatalog.load(shared: shared))
            quote = estimate.usd.map { "about " + VoiceLabCostPresentation.format($0) }
        case "lipSync":
            let seconds: Double
            if let start = words.map(\.start).min(), let end = words.map(\.end).max() { seconds = end - start }
            else { seconds = try HarnessProposal.renderedSeconds(in: project, clipID: target) }
            let estimate = try WholeClipRevoice.lipsyncPrice(videoSeconds: seconds, lipsync: .standard, catalog: VoiceLabPriceCatalog.load(shared: shared))
            quote = estimate.usd.map { "about " + VoiceLabCostPresentation.format($0) }
        case "makeItPostable": quote = postableCap.map { "up to " + VoiceLabCostPresentation.format($0) }
        default: throw HarnessError.invalid("Choose a supported offer kind.")
        }
        var result = fields
        result["offerId"] = .string(UUID().uuidString.lowercased())
        result["quote"] = quote.map(JSONValue.string) ?? .null
        return .init(result)
    }
}

public actor HarnessMusicLibrary {
    private let library: OpenverseMusicClient?
    private let folder: URL?
    private let materialize: (@Sendable (MusicCandidate, String) async throws -> ProjectMusic)?
    private var discoveries: [String: MusicCandidate] = [:]

    public init(library: OpenverseMusicClient? = nil, folder: URL? = nil,
                materialize: (@Sendable (MusicCandidate, String) async throws -> ProjectMusic)? = nil) {
        self.library = library
        self.folder = folder
        self.materialize = materialize
    }

    func search(mood: String, seconds: Double) async throws -> [JSONValue] {
        let brief = MusicBrief(mood: mood)
        var candidates: [MusicCandidate] = []
        if let library {
            do { candidates = Array(try await library.search(brief.searchText, keywords: brief.keywords, clipSeconds: seconds).prefix(8)) }
            catch { try Task.checkCancellation() }
        }
        if let local = MusicLibraryFolder.best(MusicLibraryFolder.files(in: folder), keywords: brief.keywords) { candidates.append(local) }
        return candidates.filter { $0.source == .library || $0.source == .file }.map { candidate in
            let digest = SHA256.hash(data: Data(candidate.id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
            let id = "free-" + digest
            discoveries[id] = candidate
            return .object(["id": .string(id), "title": .string(candidate.title), "source": .string(candidate.source.rawValue),
                            "durationSeconds": candidate.durationSeconds.map(JSONValue.number) ?? .null,
                            "license": .string(candidate.license.rawValue)])
        }
    }

    func prepare(_ ids: [String], projectID: String) async throws -> [ProjectMusic] {
        var result: [ProjectMusic] = []
        for id in ids {
            guard let candidate = discoveries[id], let materialize else { throw HarnessError.invalid("Choose a saved music track or a track from find_music.") }
            var track = try await materialize(candidate, projectID)
            guard track.source == candidate.source else { throw HarnessError.invalid("This free music track couldn't be used.") }
            track.id = id
            track.clipId = nil
            result.append(track)
        }
        return result
    }
}
