import Foundation
import Testing
import VoxClipCore

@Suite struct PostingHelpTests {
    private let clips = [PostingClip(id: "quiet", title: "Second thought", words: "A quieter ending.", duration: 20),
                         PostingClip(id: "strong", title: "First thought", words: "A strong opening.", duration: 25)]

    @Test func oneSendKeepsTheOrderedNetworkDraftsForReopening() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let connector = PostingConnector(reply: Self.answer)
        let service = try service(root)
        let plan = try await service.ask(projectID: "project", clips: clips, connector: connector, model: "claude")
        #expect(plan.entries.map(\.clip) == [2, 1])
        #expect(plan.entries.first?.when == "Tuesday morning, local time")
        #expect(plan.entries.first?.posts.x.copyText == "Start here.\n\n#Editing")
        #expect(plan.entries.first?.posts.linkedin.text == "The practical takeaway.")
        #expect(plan.entries.first?.posts.voxconvo.text == "Here is the first clip.")
        #expect(try await self.service(root).restore(projectID: "project", clips: clips) == plan)
        _ = try await service.ask(projectID: "project", clips: clips, connector: connector, model: "claude")
        let requests = await connector.requests
        #expect(requests.count == 1)
        #expect(requests.first?.feature == .postingHelp)
        #expect(requests.first?.instruction.contains("A strong opening.") == true)
        #expect(requests.first?.instruction.contains("\"strong\"") == false)
    }

    @Test func anInvalidReplyIsKeptWithoutASecondPaidRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let connector = PostingConnector(reply: "This is not a posting plan.")
        await #expect(throws: LLMError.self) {
            _ = try await self.service(root).ask(projectID: "project", clips: clips, connector: connector, model: "claude")
        }
        #expect(await connector.requests.count == 1)
        let folder = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let reply = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        #expect(try String(contentsOf: reply, encoding: .utf8).contains("This is not a posting plan."))
    }

    private func service(_ root: URL) throws -> PostingHelpService {
        let shared = try SharedResources.locate()
        let catalog = try LLMCatalog(shared: shared)
        return try PostingHelpService(shared: shared, catalog: catalog, runner: LLMRunner(keys: PostingKeys(), catalog: catalog, log: PostingLog()),
            archive: PostingHelpArchive(root: root))
    }

    private static let answer = """
    {"entries":[
      {"clip":2,"when":"Tuesday morning, local time","posts":{
        "x":{"text":"Start here.","hashtags":["#Editing"]},
        "linkedin":{"text":"The practical takeaway.","hashtags":["#Storytelling"]},
        "voxconvo":{"text":"Here is the first clip.","hashtags":["#Clips"]}}},
      {"clip":1,"when":"Two days later, local time","posts":{
        "x":{"text":"The follow-up.","hashtags":[]},
        "linkedin":{"text":"A second perspective.","hashtags":[]},
        "voxconvo":{"text":"Here is part two.","hashtags":[]}}}
    ]}
    """
}

private struct PostingKeys: KeyProvider { func key(for provider: String) async throws -> String? { nil } }
private actor PostingLog: Redacting {
    func register(secret: String) {}
    func redact(_ message: String) -> String { message }
    func write(_ entry: LogEntry) {}
}
private actor PostingConnector: LLMConnector {
    nonisolated let id: ConnectorID = .claudeCode
    let reply: String
    var requests: [LLMRequest] = []
    init(reply: String) { self.reply = reply }
    func status() -> ConnectorStatus { .ready }
    func models(refresh: Bool) -> [LLMModel] { [] }
    func contextTokens(model: String) -> Int? { 200_000 }
    func send(_ request: LLMRequest, model: String) -> RawCompletion {
        requests.append(request)
        return RawCompletion(text: reply, model: model, stop: .complete)
    }
}
