#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// What paid voice work is made from (`Project.voiceTakeIdentity`, voice-lab.md "What counts as an edit"), replayed from
/// shared/fixtures/voice-lab/voice-take-identity-cases.json: a save, the tab, music, captions, clip controls, motion,
/// export, share and VoxClip's own rate samples leave it as it is; the clip's words, cuts, pauses and corrections, the
/// transcript, the pause threshold, the source and clean audio change it. The Windows Core replays the same file
/// (`ProjectVoiceTakeIdentity`).
@Suite("Rewrite take currency", .offlineFixtures)
struct RewriteTakeCurrencyTests {
    struct Cases: Decodable {
        struct Set: Decodable { let path: String }
        struct Scope: Decodable { let kind: String; let clipId: String?; let first: Int?; let last: Int?; let enclosingClipId: String? }
        struct Case: Decodable { let id: String; let scope: Scope; let set: [Set]; let sameIdentity: Bool; let sameRewriteInputs: Bool; let why: String }
        let schema: String; let caseCount: Int; let project: String; let base: [Set]; let cases: [Case]
    }
    private static let file = "fixtures/voice-lab/voice-take-identity-cases.json"
    private let raw: [String: Any]
    private let cases: Cases
    private let shared: URL
    init() throws {
        shared = try SharedResources.locate().root
        let data = try Data(contentsOf: shared.appendingPathComponent(Self.file))
        raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        cases = try JSONDecoder().decode(Cases.self, from: data)
    }

    @Test func casesHaveTheirSchemaAndCount() {
        #expect(Swift.Set(raw.keys) == ["schema", "caseCount", "project", "base", "cases"])
        #expect(cases.schema == "voxclip-voice-take-identity/1" && cases.caseCount == 36 && cases.cases.count == cases.caseCount)
        #expect(Swift.Set(cases.cases.map(\.id)).count == cases.caseCount)
    }

    @Test func everyCaseKeepsOrChangesWhatTakesAreMadeFrom() throws {
        let base = try project(applying: try #require(raw["base"] as? [[String: Any]]))
        let rows = try #require(raw["cases"] as? [[String: Any]])
        for (row, item) in zip(rows, cases.cases) {
            let sets = try #require(row["set"] as? [[String: Any]])
            let changed: Project
            do { changed = try project(applying: (raw["base"] as? [[String: Any]] ?? []) + sets) } catch {
                Issue.record("\(item.id) does not decode: \(error)"); continue
            }
            let (scope, enclosing) = try Self.scope(item.scope)
            let same = base.voiceTakeIdentity(scope: scope, enclosingClipID: enclosing) == changed.voiceTakeIdentity(scope: scope, enclosingClipID: enclosing)
            #expect(same == item.sameIdentity, "\(item.id): \(item.why)")
            let inputs = base.rewriteInputs(scope: scope, enclosingClipID: enclosing) == changed.rewriteInputs(scope: scope, enclosingClipID: enclosing)
            #expect(inputs == item.sameRewriteInputs, "\(item.id) (rewrite inputs): \(item.why)")
            #expect(changed != base, "\(item.id) changes nothing")
        }
    }

    /// The brief's own list, on the Rewrite fixture project: what a save, the tab, music, captions, clip controls, the
    /// clip style and rate samples change is not part of the identity; a cut or correction inside the clip, a transcript
    /// change and clean audio are.
    @Test func editsOutsideWhatTakesAreMadeFromKeepTheIdentity() throws {
        let base = try project(applying: try #require(raw["base"] as? [[String: Any]]))
        func identity(_ project: Project) -> Project { project.voiceTakeIdentity(scope: .clip("clip-main"), enclosingClipID: nil) }
        var same = base
        same.modifiedAt = base.modifiedAt.addingTimeInterval(5)
        same.savedBy = ProjectWriter(version: "9.9")
        same.media.source.relativePath = "elsewhere.mov"
        same.title = "Another title"
        same.edits.activeClipId = nil
        same.music = []
        same.captions.position = CaptionPosition(x: 0.5, y: 0.2)
        same.clipControls = []
        same.clipStyle = ClipStyle(preset: .punchy, captions: .init(raw: "auto"), music: .auto, maxLengthSec: 60, shapes: [.portrait],
                                   rewording: .fixOnly)
        same.voiceLab.speakingRateSamples = ["eleven_v4": [VoiceLabRateSample(id: "take", ratio: 1.1)]]
        #expect(identity(same) == identity(base))
        var cut = base; cut.edits.cutWordIds.append("w4")
        var corrected = base; corrected.edits.corrections["w6"] = "and"
        var transcript = base; transcript.transcript?.words[4].text = "shipped"
        var clean = base; clean.voiceLab.cleanAudio = VoiceLabCleanAudio(mode: .on, assetId: nil, mix: 1)
        for changed in [cut, corrected, transcript, clean] { #expect(identity(changed) != identity(base)) }
    }

    private func project(applying sets: [[String: Any]]) throws -> Project {
        let data = try Data(contentsOf: shared.appendingPathComponent(cases.project))
        var root: Any = try JSONSerialization.jsonObject(with: data)
        for set in sets {
            let path = try #require(set["path"] as? String)
            root = try Self.setting(root, at: path.split(separator: "/", omittingEmptySubsequences: true).map(String.init), to: set["value"] ?? NSNull())
        }
        return try JSONProjectStore.decode(JSONSerialization.data(withJSONObject: root))
    }
    /// `value` at the JSON pointer `path` (no escapes) in `node`.
    private static func setting(_ node: Any, at path: [String], to value: Any) throws -> Any {
        guard let key = path.first else { return value }
        let rest = Array(path.dropFirst())
        if var object = node as? [String: Any] {
            object[key] = try setting(object[key] ?? NSNull(), at: rest, to: value)
            return object
        }
        var array = try #require(node as? [Any], "\(key) is not in an object or array")
        let index = try #require(Int(key))
        array[index] = try setting(array[index], at: rest, to: value)
        return array
    }
    private static func scope(_ scope: Cases.Scope) throws -> (RewriteScope, String?) {
        switch scope.kind {
        case "clip": return (.clip(try #require(scope.clipId)), nil)
        case "fullTake": return (.fullTake, nil)
        case "selection": return (.selection(try #require(scope.first)...(try #require(scope.last))), scope.enclosingClipId)
        default: throw CocoaError(.coderInvalidValue)
        }
    }
}
#endif
