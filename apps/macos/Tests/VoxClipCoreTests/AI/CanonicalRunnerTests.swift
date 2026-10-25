import Foundation
import Testing
@testable import VoxClipCore

@Test(arguments:["  {\"clips\":[]}  ","```json\n{\"clips\":[]}\n```","Here is JSON: {\"clips\":[],\"extra\":\"brace } and escaped \\\" quote\"} done"])
func aiCanonicalExtraction(text:String) throws {
    let schema = try AIClipTestData.prompt().document[ai:"output"][ai:"schema"]
    let parsed = try CanonicalResponseParser.parse(RawCompletion(text:text,model:"test",stop:.complete),schema:schema)
    #expect(parsed == .object(["clips":.array([])]))
}

@Test("Canonical validation drops malformed items but retains fractional numbers") func aiCanonicalItems() throws {
    let schema = try AIClipTestData.prompt().document[ai:"output"][ai:"schema"]
    let text = #"{"clips":[{"title":"ok","reason":"r","score":7,"start_word":5.5,"end_word":30},{"title":"bad","score":7},{"title":true,"reason":"r","score":7,"start_word":0,"end_word":20}]}"#
    let result = try CanonicalResponseParser.validate(RawCompletion(text:text,model:"test",stop:.complete),schema:schema)
    #expect(result.droppedItems == 2)
    #expect(result.object[ai:"clips"].aiArray.first?[ai:"start_word"].aiDouble == 5.5)
    #expect(throws:LLMError.truncated) { try CanonicalResponseParser.parse(RawCompletion(text:"{}",model:"test",stop:.truncated),schema:schema) }
    #expect(throws:LLMError.refused(category:"safety")) { try CanonicalResponseParser.parse(RawCompletion(text:"{}",model:"test",stop:.refused(category:"safety")),schema:schema) }
}

private struct AIRunnerKeys: KeyProvider { func key(for provider:String) async throws -> String? { nil } }
private struct AIInjectedKeys: KeyProvider {
    let value: String
    func key(for provider: String) async throws -> String? { value }
}
private actor AIRunnerLog: Redacting {
    var messages:[String] = []
    var entries: [LogEntry] = []
    var redactor = Redactor()
    func register(secret:String) { redactor.register(secret:secret) }
    func redact(_ message:String) -> String { redactor.redact(message) }
    func write(_ entry:LogEntry) {
        messages.append(redactor.redact(entry.message))
        entries.append(entry)
    }
}
private actor AIRunnerConnector: LLMConnector {
    nonisolated let id:ConnectorID
    var replies:[Result<RawCompletion,LLMError>]
    var requests:[LLMRequest] = []
    var modelsSeen:[String] = []
    var currentStatus:ConnectorStatus
    init(id:ConnectorID = .openai,replies:[Result<RawCompletion,LLMError>],status:ConnectorStatus = .ready) { self.id=id;self.replies=replies;self.currentStatus=status }
    func status() -> ConnectorStatus { currentStatus }
    func models(refresh:Bool) -> [LLMModel] { [] }
    func contextTokens(model:String) -> Int? { 128000 }
    func send(_ request:LLMRequest,model:String) throws -> RawCompletion {
        requests.append(request);modelsSeen.append(model)
        guard !replies.isEmpty else { throw LLMError.network }
        return try replies.removeFirst().get()
    }
}

private func aiRunnerSetup() throws -> (LLMRunner,LLMRequest) {
    let catalog = try LLMCatalog(shared:SharedResources(root:FixtureLoader.sharedRoot()))
    let runner = LLMRunner(keys:AIRunnerKeys(),catalog:catalog,log:AIRunnerLog())
    return (runner,try catalog.connectionTest(for:.openai))
}
private func aiRunnerSuccess(_ model:String = "chosen") -> RawCompletion { RawCompletion(text:#"{"ok":true,"echo":"voxclip"}"#,model:model,stop:.complete) }

@Test("Injected connector adapters use caller keys before status or model access")
func aiInjectedConnectorConfiguration() async throws {
    let catalog = try LLMCatalog(shared: SharedResources(root: FixtureLoader.sharedRoot()))
    let log = AIRunnerLog()
    let connector = StubLLMConnector(id: .openai, keys: AIInjectedKeys(value: "synthetic-injected-value"), catalog: catalog, log: log, cacheURL: nil)
    #expect(await connector.status() == .ready)
    #expect(try await connector.models(refresh: false) == catalog.curatedModels(for: .openai))
    #expect(await log.redact("synthetic-injected-value") == "[REDACTED]")
}

@Test("Runner logs bounded redacted error cases without transport descriptions")
func aiRunnerErrorLogging() async throws {
    let catalog = try LLMCatalog(shared: SharedResources(root: FixtureLoader.sharedRoot()))
    let log = AIRunnerLog()
    let secret = "synthetic-registered-value"
    let runner = LLMRunner(keys: AIInjectedKeys(value: secret), catalog: catalog, log: log)
    let failure = LLMError.badRequest(status: 400, message: secret + " " + String(repeating: "x", count: 400))
    let connector = AIRunnerConnector(replies: [.failure(failure)])
    await #expect(throws: failure) { try await runner.run(catalog.connectionTest(for: .openai), on: connector, model: "chosen") }
    let message = try #require(await log.messages.last)
    #expect(message.contains("error=badRequest code=providerError"))
    #expect(message.contains("[REDACTED]"))
    #expect(!message.contains(secret))
    #expect(message.components(separatedBy: "message=").last?.utf16.count == 200)
}

@Test("Finder and runner status gates log exactly once through the redactor", arguments: [0, 1, 2], [
    ConnectorStatus.needsKey, .notRunning(url: "http://127.0.0.1:11434"), .unavailable(reason: "private-preflight-marker")
])
func aiFinderPreflightLogging(_ entryPoint: Int, status: ConnectorStatus) async throws {
    let shared = try SharedResources(root: FixtureLoader.sharedRoot())
    let catalog = try LLMCatalog.load(shared: shared)
    let log = AIRunnerLog()
    await log.register(secret: "private-preflight-marker")
    let runner = LLMRunner(keys: AIRunnerKeys(), catalog: catalog, log: log)
    let connector = AIRunnerConnector(id: .ollama, replies: [], status: status)
    let failure: LLMError
    switch status {
    case .needsKey: failure = .missingKey
    case .notRunning(let url): failure = .notRunning(url: url)
    case .unavailable(let reason): failure = .unavailable(reason: reason)
    default: Issue.record("Unexpected fixture status"); return
    }
    let finder = ClipFinder(runner: runner, shared: shared)
    let words = [TimedWord(id: "w0", text: "word", start: 0, end: 1)]
    let transcript = Transcript(words: words, language: "en", durationSeconds: 1,
                                engine: EngineRef(id: .whispercpp, engineVersion: "fixture"), rawKey: "fixture", createdAt: Date())
    let request = ClipFinderRequest(transcript: transcript, preset: try AIClipTestData.preset(.best))
    await #expect(throws: failure) {
        switch entryPoint {
        case 0: _ = try await finder.find(request, connector: connector, model: "chosen")
        case 1: _ = try await finder.prepare(request, connector: connector, model: "chosen")
        default: _ = try await runner.test(on: connector, model: "chosen")
        }
    }
    let entries = await log.entries
    #expect(entries.count == 1)
    let entry = try #require(entries.first)
    #expect(entry.level == .error && entry.category == "llm")
    #expect(entry.message.contains("error=\(failure.caseName) code=\(failure.code.rawValue)"))
    #expect(!entry.message.contains("private-preflight-marker"))
    if case .unavailable = status { #expect(entry.message.contains("[REDACTED]")) }
    #expect(await connector.requests.isEmpty)
}

@Test("Runner corrective retry adds exact schema reason once") func aiRunnerCorrection() async throws {
    let (runner,request) = try aiRunnerSetup()
    let connector = AIRunnerConnector(replies:[.success(RawCompletion(text:"bad",model:"chosen",stop:.complete)),.success(aiRunnerSuccess())])
    let result = try await runner.run(request,on:connector,model:"chosen")
    #expect(result.object[ai:"ok"].aiBool == true)
    let requests = await connector.requests
    #expect(requests.count == 2)
    #expect(requests[1].instruction == request.instruction + "\n\nYour previous reply was not valid JSON for the required schema (not JSON). Reply with only the JSON object.")
}

@Test("Only one corrective retry is allowed") func aiRunnerInvalidTwice() async throws {
    let (runner,request) = try aiRunnerSetup()
    let invalid = RawCompletion(text:"{}",model:"chosen",stop:.complete)
    let connector = AIRunnerConnector(replies:[.success(invalid),.success(invalid)])
    await #expect(throws:LLMError.invalidOutput(reason:"missing \"echo\"")) { try await runner.run(request,on:connector,model:"chosen") }
    #expect(await connector.requests.count == 2)
}

@Test("One same-provider fallback receives a fresh validation pass") func aiRunnerFallback() async throws {
    let (runner,request) = try aiRunnerSetup()
    let connector = AIRunnerConnector(replies:[.failure(.overloaded),.success(aiRunnerSuccess("gpt-5.6-luna"))])
    let result = try await runner.run(request,on:connector,model:"gpt-5.6-terra")
    #expect(result.usedFallback)
    #expect(await connector.modelsSeen == ["gpt-5.6-terra","gpt-5.6-luna"])
}

@Test(arguments:[LLMError.timeout,.unauthorized,.quotaExceeded,.contextTooLong,.refused(category:nil),.truncated,.badRequest(status:400,message:"test")])
func aiRunnerNoFallback(failure:LLMError) async throws {
    let (runner,request) = try aiRunnerSetup()
    let connector = AIRunnerConnector(replies:[.failure(failure),.success(aiRunnerSuccess())])
    await #expect(throws:failure) { try await runner.run(request,on:connector,model:"gpt-5.6-terra") }
    #expect(await connector.requests.count == 1)
}

@Test("Claude fallback is CLI-internal, while Codex may change models once") func aiCLIFallbackPolicy() async throws {
    let (runner,request) = try aiRunnerSetup()
    let claude = AIRunnerConnector(id:.claudeCode,replies:[.failure(.overloaded),.success(aiRunnerSuccess())])
    await #expect(throws:LLMError.overloaded) { try await runner.run(request,on:claude,model:"opus") }
    #expect(await claude.requests.count == 1)
    let codex = AIRunnerConnector(id:.codex,replies:[.failure(.planLimit(message:nil)),.success(aiRunnerSuccess("gpt-5.6-luna"))])
    let result = try await runner.run(request,on:codex,model:"gpt-5.6-terra")
    #expect(result.usedFallback)
    #expect(await codex.modelsSeen == ["gpt-5.6-terra","gpt-5.6-luna"])
}

@Test("Test button trims and casefolds echo") func aiTestRoundTrip() async throws {
    let (runner,_) = try aiRunnerSetup()
    let connector = AIRunnerConnector(replies:[.success(RawCompletion(text:#"{"ok":true,"echo":"  VOXCLIP  "}"#,model:"answer",stop:.complete))])
    let result = try await runner.test(on:connector,model:"chosen")
    #expect(result.passed)
    #expect(result.model == "answer")
}

@Test("Claude native fallback distinguishes aliases from a changed model", arguments: [
    ("opus", "claude-opus-5-5", false),
    ("opus[1m]", "claude-opus-5-5", false),
    ("sonnet", "claude-sonnet-5-5", false),
    ("sonnet", "claude-haiku-4-5", true),
    ("opus", "claude-sonnet-5-5", true),
    ("default", "claude-sonnet-5-5", false),
    ("claude-opus-5-5", "claude-opus-5-5", false),
    ("claude-opus-5-5", "claude-sonnet-5-5", true),
    ("custom-model", "unrecognized-model", false)
])
func aiClaudeNativeFallback(_ selected: String, _ actual: String, _ expected: Bool) async throws {
    let (runner, request) = try aiRunnerSetup()
    let connector = AIRunnerConnector(id: .claudeCode, replies: [.success(aiRunnerSuccess(actual))])
    let result = try await runner.run(request, on: connector, model: selected)
    #expect(result.usedFallback == expected)
    #expect(result.model == actual)
    #expect(await connector.requests.count == 1)
}

@Test("Error codes and saved-edits reassurance are consistent") func aiErrorMessages() {
    #expect(LLMError.missingKey.code == .keyMissing)
    #expect(LLMError.quotaExceeded.code == .providerError)
    #expect(LLMError.cliTooOld(version:"old",missing:[]).code == .cliNotInstalled)
    #expect(LLMError.cancelled.userMessage(label:"test") == nil)
    #expect(LLMError.cliSignedOut.userMessage(label:"Codex",signInHint:"Open Terminal and run codex login.")?.contains("codex login") == true)
    #expect(LLMError.timeout.userMessage(label:"test")?.hasSuffix("Your edits are saved.") == true)
    let secret = "synthetic-value-123"
    let message = LLMError.badRequest(status:400,message:secret).userMessage(label:"test",redactor:Redactor(knownSecrets:[secret]))
    #expect(message?.contains(secret) == false)
    #expect(message?.contains("[REDACTED]") == true)
}
