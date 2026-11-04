import CryptoKit
import Foundation
import Testing
@testable import VoxClipCore

/// shared/fixtures/clip-style/caption-pick.json: the clip style contract (design.md §6.9) and the caption pick request (AI §15).
@Suite struct CaptionPickTests {
    private struct Clip: Decodable { var id: String; var title: String?; var seconds: Double; var text: String }

    private static func fixture() throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/clip-style/caption-pick.json")) }
    private static func shared() throws -> SharedResources { SharedResources(root: try FixtureLoader.sharedRoot()) }
    private static func library() throws -> [CaptionStyle] { try CaptionStyleLibrary(shared: shared()).styles }
    private static func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T { try JSONDecoder().decode(type, from: value.aiEncoded()) }
    private static func clips(_ value: JSONValue) throws -> [CaptionPickClip] {
        try decode([Clip].self, value).map { CaptionPickClip(id: $0.id, title: $0.title, seconds: $0.seconds, text: $0.text) }
    }
    private static func sha(_ relative: String) throws -> String {
        SHA256.hash(data: try FixtureLoader.data(relative)).map { String(format: "%02x", $0) }.joined()
    }

    @Test("The fixture is current for the prompt, the presets and the style library")
    func fixtureIsCurrent() throws {
        let fixture = try Self.fixture()
        #expect(fixture[ai: "fixture"].aiString == "voxclip-caption-pick/1")
        #expect(fixture[ai: "promptSha256"].aiString == (try Self.sha("prompts/caption-pick.json")))
        #expect(fixture[ai: "clipStylesSha256"].aiString == (try Self.sha("data/clip-styles.json")))
        #expect(fixture[ai: "libraryStyles"].aiArray.compactMap(\.aiString) == (try Self.library()).map(\.id))
        #expect(fixture[ai: "requests"].aiArray.count == 4 && fixture[ai: "replies"].aiArray.count == 4 && fixture[ai: "clipStyles"].aiArray.count == 14)
    }

    @Test("Every request renders byte for byte, with the preset's candidates and extra high effort")
    func requests() throws {
        let prompt = try CaptionPickPrompt.load(shared: Self.shared()), styles = try ClipStyleCatalog.load(shared: Self.shared()), library = try Self.library()
        for item in try Self.fixture()[ai: "requests"].aiArray {
            let id = item[ai: "id"].aiString ?? "", expected = item[ai: "expected"]
            let preset = try #require(item[ai: "preset"].aiString.flatMap(ClipStylePresetID.init(rawValue:)))
            let candidates = styles.captionCandidates(library, for: styles.preset(preset).style)
            #expect(candidates.map(\.id) == expected[ai: "candidates"].aiArray.compactMap(\.aiString), "\(id) candidates")
            let request = prompt.request(clips: try Self.clips(item[ai: "clips"]), candidates: candidates, presetLabel: styles.preset(preset).label, timeout: .seconds(60), language: "en")
            #expect(request.feature == .captionPick)
            #expect(request.system == expected[ai: "system"].aiString, "\(id) system")
            #expect(request.instruction == expected[ai: "instruction"].aiString, "\(id) instruction")
            #expect(request.schemaName == expected[ai: "schemaName"].aiString && request.maxOutputTokens == expected[ai: "maxOutputTokens"].aiInt)
            #expect(request.effort?.rawValue == expected[ai: "effort"].aiString && request.effort == .decision)
            #expect(request.tag == expected[ai: "tag"].aiString, "\(id) tag")
        }
    }

    @Test("Replies keep only known clips, candidate styles and trimmed reasons")
    func replies() throws {
        let prompt = try CaptionPickPrompt.load(shared: Self.shared())
        let clips = try Self.clips(Self.fixture()[ai: "requests"].aiArray[0][ai: "clips"])
        for item in try Self.fixture()[ai: "replies"].aiArray {
            let id = item[ai: "id"].aiString ?? ""
            #expect(clips.map(\.id) == item[ai: "clips"].aiArray.compactMap(\.aiString))
            let parsed = prompt.picks(item[ai: "reply"], clips: clips, candidates: Set(item[ai: "candidates"].aiArray.compactMap(\.aiString)))
            #expect(parsed.picks == (try Self.decode([String: ClipCaptionPick].self, item[ai: "expected"][ai: "picks"])), "\(id) picks")
            #expect(parsed.dropped == item[ai: "expected"][ai: "dropped"].aiInt, "\(id) dropped")
        }
    }

    @Test("Presets, resolution, recording and fixing follow the contract; a fixed style is never overridden")
    func clipStyleContract() throws {
        let styles = try ClipStyleCatalog.load(shared: Self.shared())
        for item in try Self.fixture()[ai: "clipStyles"].aiArray {
            let id = item[ai: "id"].aiString ?? "", expected = item[ai: "expected"]
            switch item[ai: "op"].aiString {
            case "preset":
                let preset = try #require(item[ai: "preset"].aiString.flatMap(ClipStylePresetID.init(rawValue:)))
                let style = styles.preset(preset).style
                #expect(style == (try Self.decode(ClipStyle.self, expected[ai: "style"])), "\(id)")
                #expect(style.summary(presetLabel: styles.preset(preset).label) == expected[ai: "summary"].aiString, "\(id) summary")
            case "resolve":
                let style = try Self.decode(ClipStyle.self, item[ai: "style"])
                for (clip, want) in expected[ai: "resolved"].aiObject ?? [:] {
                    #expect(style.captionStyle(forClip: clip.isEmpty ? nil : clip) == want.aiString, "\(id) \(clip)")
                }
            case "record":
                let style = try Self.decode(ClipStyle.self, item[ai: "style"])
                let picks = try Self.decode([String: ClipCaptionPick].self, item[ai: "picks"])
                #expect(style.recording(picks) == (try Self.decode(ClipStyle.self, expected[ai: "style"])), "\(id)")
            case "fix":
                let style = try Self.decode(ClipStyle.self, item[ai: "style"])
                let choice = ClipCaptionChoice(raw: item[ai: "choice"].aiString ?? "")
                #expect(style.fixingCaptions(choice) == (try Self.decode(ClipStyle.self, expected[ai: "style"])), "\(id)")
            default: Issue.record("Unknown op in \(id)")
            }
        }
    }

    @Test("Auto: a stub reply's picks are recorded with reasons; a fixed style sends nothing and keeps its choice")
    func autoPickWithStubReplyAndFixedStyle() async throws {
        let shared = try Self.shared(), catalog = try LLMCatalog(shared: shared), styles = try ClipStyleCatalog.load(shared: shared)
        let picker = CaptionPicker(runner: LLMRunner(keys: PickKeys(), catalog: catalog, log: PickLog()), prompt: try CaptionPickPrompt.load(shared: shared), catalog: catalog)
        let clips = [CaptionPickClip(id: "clip-a", title: "Hook", seconds: 20, text: "Stop doing this."), CaptionPickClip(id: "clip-b", title: "Story", seconds: 40, text: "When I was a kid.")]
        let reply = #"{"picks":[{"clip":"C1","style":"punch-in","reason":"Punchy hook."},{"clip":"C2","style":"minimal","reason":"Quiet story."}]}"#
        let connector = PickConnector(reply: reply)
        var auto = styles.preset(.auto).style
        auto.captionPicks["gone"] = ClipCaptionPick(styleId: "glow", reason: "A deleted clip.")
        let picked = try await picker.pick(auto, clips: clips, library: try Self.library(), styles: styles, connector: connector, model: "m", language: "en")
        #expect(picked.style.captionPicks == ["clip-a": .init(styleId: "punch-in", reason: "Punchy hook."), "clip-b": .init(styleId: "minimal", reason: "Quiet story.")])
        #expect(picked.style.captionStyle(forClip: "clip-a") == "punch-in" && picked.dropped == 0)
        let sent = await connector.sent
        #expect(sent.count == 1 && sent.first?.effort == .xhigh)

        let fixed = picked.style.fixingCaptions(.style("marker"))
        let silent = PickConnector(reply: reply)
        let unchanged = try await picker.pick(fixed, clips: clips, library: try Self.library(), styles: styles, connector: silent, model: "m", language: "en")
        #expect(unchanged.style == fixed && unchanged.style.captionStyle(forClip: "clip-b") == "marker")
        let unsent = await silent.sent
        #expect(unsent.isEmpty)
        #expect(fixed.recording(["clip-a": .init(styleId: "glow", reason: "Later.")]) == fixed)
    }

    @Test("A project's clip style round-trips, is optional and rejects invalid values")
    func persistence() throws {
        let data = try FixtureLoader.data("fixtures/projects/interview-take.voxclip")
        var project = try ProjectJSON.decoder().decode(Project.self, from: data)
        #expect(project.clipStyle == nil)
        let plain = try ProjectJSON.encoder().encode(project)
        #expect(!String(decoding: plain, as: UTF8.self).contains("clipStyle"))
        let styles = try ClipStyleCatalog.load(shared: Self.shared())
        project.clipStyle = styles.preset(.calm).style.fixingCaptions(.style("glow"))
        project.clipStyle?.captionPicks = [:]
        let encoded = try ProjectJSON.encoder().encode(project)
        let decoded = try ProjectJSON.decoder().decode(Project.self, from: encoded)
        #expect(decoded.clipStyle == project.clipStyle)
        try ProjectValidation.validate(JSONDecoder().decode(JSONValue.self, from: encoded))
        try ProjectValidation.validateModel(decoded)
        func patched(_ change: (inout [String: JSONValue]) -> Void) throws -> Data {
            guard case .object(var root) = try JSONDecoder().decode(JSONValue.self, from: encoded), case .object(var clip)? = root["clipStyle"] else { throw VoxClipError.sharedResourcesMissing }
            change(&clip); root["clipStyle"] = .object(clip)
            return try JSONEncoder().encode(JSONValue.object(root))
        }
        let short = try patched { $0["maxLengthSec"] = .number(2) }
        #expect(throws: (any Error).self) { try ProjectJSON.decoder().decode(Project.self, from: short) }
        let extra = try patched { $0["tone"] = .string("warm") }
        #expect(throws: (any Error).self) { try ProjectValidation.validate(JSONDecoder().decode(JSONValue.self, from: extra)) }
        let pickless = try patched { $0["captionPicks"] = nil }
        #expect(throws: (any Error).self) { try ProjectValidation.validate(JSONDecoder().decode(JSONValue.self, from: pickless)) }
        #expect(styles.initial(saved: nil) == styles.preset(.auto).style)
        #expect(styles.initial(saved: decoded.clipStyle) == decoded.clipStyle?.settingsDefault)
        #expect(styles.style(for: .mine, mine: decoded.clipStyle).captions == .style("glow"))
    }
}

private struct PickKeys: KeyProvider { func key(for provider: String) async throws -> String? { nil } }
private actor PickLog: Redacting {
    func register(secret: String) {}
    func redact(_ message: String) -> String { message }
    func write(_ entry: LogEntry) {}
}
private actor PickConnector: LLMConnector {
    nonisolated let id: ConnectorID = .claudeCode
    let reply: String
    var sent: [LLMRequest] = []
    init(reply: String) { self.reply = reply }
    func status() -> ConnectorStatus { .ready }
    func models(refresh: Bool) -> [LLMModel] { [] }
    func contextTokens(model: String) -> Int? { 200_000 }
    func send(_ request: LLMRequest, model: String) throws -> RawCompletion {
        sent.append(request)
        return RawCompletion(text: reply, model: model, stop: .complete)
    }
}
