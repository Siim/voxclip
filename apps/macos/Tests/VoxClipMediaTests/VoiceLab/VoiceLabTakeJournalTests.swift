import Darwin
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

/// The paid-take journal (voice-lab §3 "Paid takes are kept") against `shared/fixtures/voice-lab/take-journal-cases.json`,
/// which the Windows journal replays too, and its durability on disk.
@Suite(.offlineFixtures) struct VoiceLabTakeJournalTests {
    private static let schema = "voxclip-take-journal-cases/1"
    private func document() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/voice-lab/take-journal-cases.json")) as? [String: Any])
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-take-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func entry(_ object: Any) throws -> VoiceLabTakeJournalEntry {
        try VoiceLabTakeJournal.decode(JSONSerialization.data(withJSONObject: object))
    }
    private func key(_ object: [String: Any]) throws -> VoiceLabTakeJournalKey {
        func text(_ name: String) throws -> String { try #require(object[name] as? String) }
        return VoiceLabTakeJournalKey(recordID: try text("recordID"), voiceID: try text("voiceID"), modelID: try text("modelID"),
            language: try text("language"), requestText: try text("requestText"), previousText: try text("previousText"),
            nextText: try text("nextText"), pace: try #require(object["pace"] as? Double))
    }
    /// The fixture's journal on disk: each asset written by the paid-asset writer (its SHA-256 is the fixture's, so both
    /// platforms write the same canonical WAV), then every entry through the journal.
    private func journal(_ document: [String: Any], at paidRoot: URL) throws -> String {
        let project = try #require(document["projectId"] as? String)
        for asset in try #require(document["assets"] as? [[String: Any]]) {
            let frames = try #require(asset["frames"] as? Int), fill = try #require(asset["fill"] as? Int)
            var pcm = Data()
            for _ in 0..<frames { withUnsafeBytes(of: Int16(fill).littleEndian) { pcm.append(contentsOf: $0) } }
            let written = try VoiceLabAssetStore.write(pcm16: pcm, sampleRate: try #require(asset["sampleRate"] as? Int), projectId: project,
                assetId: try #require(asset["assetId"] as? String), paidRoot: paidRoot, createdAt: Date())
            #expect(written.sha256 == asset["sha256"] as? String)
        }
        for object in try #require(document["entries"] as? [Any]) { try VoiceLabTakeJournal.write(entry(object), projectID: project, paidRoot: paidRoot) }
        return project
    }

    @Test func theSharedCasesParseRoundTripAndMatch() throws {
        let document = try document()
        #expect(Set(document.keys) == ["schema", "entrySchema", "projectId", "caseCount", "assets", "entries", "cases"])
        #expect(document["schema"] as? String == Self.schema)
        #expect(document["entrySchema"] as? String == VoiceLabTakeJournalEntry.currentSchema)
        let cases = try #require(document["cases"] as? [[String: Any]])
        #expect(document["caseCount"] as? Int == cases.count && cases.count == 35)
        let paidRoot = try root()
        defer { try? FileManager.default.removeItem(at: paidRoot) }
        let project = try journal(document, at: paidRoot)
        #expect(VoiceLabTakeJournal.list(projectID: project, paidRoot: paidRoot).count == (document["entries"] as? [Any])?.count)
        for item in cases {
            let id = try #require(item["id"] as? String)
            switch item["kind"] as? String {
            case "parse":
                let object = try #require(item["entry"] as? [String: Any])
                let valid = (try? entry(object)).map { (try? VoiceLabTakeJournal.validate($0, projectID: project)) != nil } ?? false
                #expect(valid == (item["valid"] as? Bool), "\(id)")
                guard valid else { continue }
                // The shape is pinned: the journal writes exactly the fixture's keys and values back.
                let written = try JSONSerialization.jsonObject(with: VoiceLabTakeJournal.encode(entry(object))) as? NSDictionary
                #expect(written == object as NSDictionary, "\(id)")
            case "match":
                let claimed = Set(try #require(item["claimed"] as? [String]))
                let found = VoiceLabTakeJournal.match(try key(try #require(item["key"] as? [String: Any])), projectID: project,
                                                      paidRoot: paidRoot, excluding: claimed)
                #expect(found?.assetFile == item["expected"] as? String, "\(id)")
            default: Issue.record("Unknown case kind in \(id)")
            }
        }
    }

    /// The entry is flushed into a 0700 folder as a 0600 file. A crash mid-write leaves a `.partial` file that nothing
    /// reads, and the next write of that entry replaces it; a foreign or malformed file is ignored too.
    @Test func entriesArePrivateFlushedAndSurviveACrashedWrite() throws {
        let document = try document()
        let paidRoot = try root()
        defer { try? FileManager.default.removeItem(at: paidRoot) }
        let project = try journal(document, at: paidRoot)
        let folder = paidRoot.appendingPathComponent(project).appendingPathComponent("takes")
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let newest = try entry(try #require((document["entries"] as? [Any])?[1]))
        let file = folder.appendingPathComponent("\(newest.assetID).json")
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        // A crashed rewrite of the newest entry, a stray file and a foreign name.
        try Data("{\"schema\":".utf8).write(to: folder.appendingPathComponent(".\(newest.assetID).json.partial"))
        try Data("not json".utf8).write(to: folder.appendingPathComponent("0f6a1c2e-9999-4a00-8000-000000000009.json"))
        try VoiceLabTakeJournal.encode(newest).write(to: folder.appendingPathComponent("renamed.json"))
        let entries = VoiceLabTakeJournal.list(projectID: project, paidRoot: paidRoot)
        #expect(entries.count == (document["entries"] as? [Any])?.count && entries.contains(newest))
        #expect(VoiceLabTakeJournal.match(newest.key, projectID: project, paidRoot: paidRoot)?.assetFile == newest.assetFile)
        // The take's recovered timing replaces the entry in place, over the leftover partial.
        let timing = [VoiceLabCharacterTiming(character: "H", start: 0.1, end: 0.4)]
        try VoiceLabTakeJournal.updateTiming(assetFile: newest.assetFile, timing: timing, recovered: true, projectID: project, paidRoot: paidRoot)
        let updated = try #require(VoiceLabTakeJournal.list(projectID: project, paidRoot: paidRoot).first { $0.assetFile == newest.assetFile })
        #expect(updated.alignment == .init(recovered: true, characters: [.init(character: "H", start: 0.1, end: 0.4)]))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".\(newest.assetID).json.partial").path))
        // A word check that failed is written in place too, keeping the timing; the take is then never adopted, and the
        // older take over the same request is, until a later run's passing verdict replaces the failed one.
        let failed = VoiceLabTakeJournalEntry.Checks(speaker: .passed, words: .failed, hardFailures: ["transcript"])
        try VoiceLabTakeJournal.updateChecks(assetFile: newest.assetFile, checks: failed, projectID: project, paidRoot: paidRoot)
        let checked = try #require(VoiceLabTakeJournal.list(projectID: project, paidRoot: paidRoot).first { $0.assetFile == newest.assetFile })
        #expect(checked.checks == failed && !checked.adoptable && checked.alignment == updated.alignment)
        let older = try entry(try #require((document["entries"] as? [Any])?[0]))
        #expect(VoiceLabTakeJournal.match(newest.key, projectID: project, paidRoot: paidRoot)?.assetFile == older.assetFile)
        try VoiceLabTakeJournal.updateChecks(assetFile: newest.assetFile, checks: .init(speaker: .passed, words: .passed, hardFailures: []),
                                             projectID: project, paidRoot: paidRoot)
        #expect(VoiceLabTakeJournal.match(newest.key, projectID: project, paidRoot: paidRoot)?.assetFile == newest.assetFile)
        #expect(throws: (any Error).self) {
            try VoiceLabTakeJournal.updateChecks(assetFile: newest.assetFile, checks: .init(speaker: nil, words: .failed, hardFailures: [""]),
                                                 projectID: project, paidRoot: paidRoot)
        }
        // An asset whose bytes changed is never adopted.
        let asset = paidRoot.appendingPathComponent(newest.assetFile)
        var bytes = try Data(contentsOf: asset); bytes[bytes.count - 1] ^= 0xff
        try bytes.write(to: asset)
        #expect(VoiceLabTakeJournal.match(newest.key, projectID: project, paidRoot: paidRoot)?.assetFile != newest.assetFile)
        VoiceLabTakeJournal.remove(assetID: newest.assetID, projectID: project, paidRoot: paidRoot)
        #expect(!VoiceLabTakeJournal.list(projectID: project, paidRoot: paidRoot).contains { $0.assetFile == newest.assetFile })
        #expect(FileManager.default.fileExists(atPath: asset.path))
    }

    /// Adoption reads the stored PCM back exactly, with the entry's timing and receipt.
    @Test func adoptionRebuildsTheTakeFromItsStoredPCM() throws {
        let document = try document()
        let paidRoot = try root()
        defer { try? FileManager.default.removeItem(at: paidRoot) }
        let project = try journal(document, at: paidRoot)
        let older = try entry(try #require((document["entries"] as? [Any])?[0]))
        let adopted = try VoiceLabTakeJournal.adopt(older, projectID: project, paidRoot: paidRoot)
        #expect(adopted.result.pcm.count == older.frames * 2 && adopted.result.sampleRate == 24_000)
        #expect(adopted.result.pcm.prefix(2) == Data([0xe8, 0x03]))
        #expect(adopted.result.alignment?.map(\.character).joined() == "Hello")
        #expect(adopted.result.receipt.requestID == UUID(uuidString: older.requestID) && adopted.result.receipt.providerRequestID == "req_fixture_older")
        #expect(adopted.result.receipt.voiceID == older.voiceID && adopted.result.receipt.pace == 1)
        #expect(adopted.asset.file == older.assetFile && adopted.asset.sha256 == older.assetSha256 && adopted.asset.durationSeconds == 0.01)
    }
}
