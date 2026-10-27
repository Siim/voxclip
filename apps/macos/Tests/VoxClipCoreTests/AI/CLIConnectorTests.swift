import Foundation
import Testing
@testable import VoxClipCore

@Suite("CLI connector safety and recorded outputs")
struct CLIConnectorTests {
    @Test(arguments: [ConnectorID.claudeCode, .codex])
    func cancellationDuringPreflightIsCancelledNotProviderFailure(_ id: ConnectorID) async throws {
        let catalog = try cliTestCatalog()
        let process = CLIBlockedPreflightRunner()
        let log = CLITestLog()
        let connector = CLIConnector(id: id, runner: process, catalog: catalog, log: log,
            executable: URL(fileURLWithPath: "/bin/sh"), environment: [:], loginShellPATH: "/test")
        let task = Task { try await LLMRunner(keys: CLIReviewKeys(), catalog: catalog, log: log).test(on: connector, model: "default") }
        defer { task.cancel() }
        for _ in 0..<200 {
            if await process.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await process.started)
        task.cancel()
        await #expect(throws: LLMError.cancelled) { try await task.value }
        let entries = await log.entries
        #expect(entries.count == 1)
        #expect(entries.allSatisfy { $0.level == .info && $0.message.contains("code=cancelled") })
    }

    @Test(arguments: [ConnectorID.claudeCode, .codex])
    func statusCachesDetectionAndSendConsumesAuthPreflight(_ id: ConnectorID) async throws {
        let catalog = try cliTestCatalog()
        let process = CLIFakeRunner(id: id, catalog: catalog)
        let connector = cliTestConnector(id, runner: process, catalog: catalog)
        for _ in 0..<2 {
            #expect(await connector.status() == .ready)
            _ = try await connector.send(cliTestRequest(), model: "default")
        }
        let requests = await process.requests
        #expect(await process.versionCount == 1)
        #expect(requests.filter { $0.arguments.contains("--help") }.count == 1)
        #expect(requests.filter { $0.arguments == (id == .codex ? ["login", "status"] : ["auth", "status", "--json"]) }.count == 2)
        _ = try await connector.detection(refresh: true)
        #expect(await process.versionCount == 2)
    }

    @Test func generationMetadataIsRedactedWithoutPromptOrReply() async throws {
        let catalog = try cliTestCatalog()
        let log = CLITestLog()
        await log.register(secret: "private-model-marker")
        let process = CLIFakeRunner(id: .claudeCode, catalog: catalog)
        let connector = CLIConnector(id: .claudeCode, runner: process, catalog: catalog, log: log,
            executable: URL(fileURLWithPath: "/bin/sh"), environment: [:], loginShellPATH: "/test")
        var request = cliTestRequest()
        request.system = "DO_NOT_LOG_SYSTEM"
        request.cachedBlock = "DO_NOT_LOG_TRANSCRIPT"
        request.tag = "private-model-marker\nprivate tag"
        _ = try await connector.send(request, model: "private-model-marker")
        let entries = await log.entries
        #expect(entries.count == 1)
        let message = try #require(entries.first?.message)
        #expect(message.contains("llm connector=claude-code") && message.contains("attempt=1 status=0") && message.contains(" ms="))
        #expect(message.contains("[REDACTED]"))
        #expect(!message.contains("private-model-marker") && !message.contains("DO_NOT_LOG") && !message.contains("structured_output") && !message.contains("\n"))
    }

    @Test func claudeExactArgumentsAndPrivateWorkspace() async throws {
        let catalog = try cliTestCatalog()
        let runner = CLIFakeRunner(id: .claudeCode, catalog: catalog)
        let directory = try CLITestDirectory()
        let connector = cliTestConnector(.claudeCode, runner: runner, catalog: catalog, directory: directory.url)
        var request = cliTestRequest()
        request.system = "JSON only. \"quoted\" \\ path\nTere 世界; $(touch do-not-create)"
        request.cachedBlock = "transcript with 'quotes'"
        let completion = try await connector.send(request, model: "haiku")
        #expect(completion.object == .object(["ok": .bool(true)]))
        let requests = await runner.requests
        let generation = try #require(requests.first { $0.arguments.first == "-p" })
        #expect(generation.arguments == [
            "-p", "--output-format", "json", "--json-schema", "{\"type\":\"object\",\"required\":[\"ok\"],\"properties\":{\"ok\":{\"type\":\"boolean\"}}}",
            "--system-prompt", request.system, "--tools", "", "--no-session-persistence", "--model", "haiku",
            "--fallback-model", "sonnet", "--effort", "low", "--safe-mode", "--strict-mcp-config", "--disable-slash-commands",
        ])
        #expect(generation.stdin == Data("transcript with 'quotes'\n\nReply with {\"ok\":true}".utf8))
        #expect(generation.timeout == request.timeout)
        for process in requests {
            #expect(process.environment == ["PATH": "/test/login/path", "VOXCLIP_TEST_SENTINEL": "inherited"])
            #expect(!FileManager.default.fileExists(atPath: process.workingDirectory.deletingLastPathComponent().path))
        }
        #expect(await runner.allWorkspacesWereEmpty)
        #expect(await runner.allWorkspacesWerePrivate)
    }

    @Test(arguments: ["voice-rewrite", "patch-rewrite"])
    func voiceRewriteNamesNoFallbackModel(_ tag: String) async throws {
        let catalog = try cliTestCatalog()
        let runner = CLIFakeRunner(id: .claudeCode, catalog: catalog)
        let connector = cliTestConnector(.claudeCode, runner: runner, catalog: catalog)
        var request = cliTestRequest()
        request.feature = .voiceRewrite
        request.tag = tag
        _ = try await connector.send(request, model: "haiku")
        let generation = try #require(await runner.requests.first { $0.arguments.first == "-p" })
        // ai.md §12.8: the quoted model answers or the send fails; there is no fallback.
        #expect(generation.arguments.contains("haiku") && !generation.arguments.contains("--fallback-model"))
    }

    @Test func claudeDefaultAndUnsupportedOptionalFlags() async throws {
        let catalog = try cliTestCatalog()
        let runner = CLIFakeRunner(id: .claudeCode, catalog: catalog)
        await runner.omit(["--fallback-model", "--effort", "--strict-mcp-config", "--disable-slash-commands"])
        let connector = cliTestConnector(.claudeCode, runner: runner, catalog: catalog)
        _ = try await connector.send(cliTestRequest(), model: "default")
        let generation = try #require(await runner.requests.last)
        #expect(!generation.arguments.contains("--model"))
        #expect(!generation.arguments.contains("--effort"))
        #expect(!generation.arguments.contains("--fallback-model"))
        #expect(generation.arguments.last == "--safe-mode")
        let forbidden = cliTestProvider(catalog, .claudeCode)["cli"]?.testObject?["forbiddenFlags"]?.testStrings ?? []
        #expect(Set(generation.arguments).isDisjoint(with: forbidden))
    }

    @Test(arguments: [ConnectorID.claudeCode, .codex])
    func missingRequiredFlagPreventsGeneration(_ id: ConnectorID) async throws {
        let catalog = try cliTestCatalog()
        let runner = CLIFakeRunner(id: id, catalog: catalog)
        let flag = id == .claudeCode ? "--safe-mode" : "--ignore-user-config"
        await runner.omit([flag])
        let connector = cliTestConnector(id, runner: runner, catalog: catalog)
        let status = await connector.status()
        #expect(status == .cliTooOld(version: id == .claudeCode ? "2.1.309" : "0.163.0-alpha.10.2", missing: [flag]))
        #expect(await runner.generationCount == 0)
    }

    @Test(arguments: [ConnectorID.claudeCode, .codex])
    func signedOutNeverGenerates(_ id: ConnectorID) async throws {
        let catalog = try cliTestCatalog()
        let runner = CLIFakeRunner(id: id, catalog: catalog)
        await runner.setSignedIn(false)
        let connector = cliTestConnector(id, runner: runner, catalog: catalog)
        await #expect(throws: LLMError.cliSignedOut) { try await connector.send(cliTestRequest(), model: "default") }
        #expect(await runner.generationCount == 0)
        #expect(await connector.status() == .cliSignedOut)
    }

    @Test func codexPreflightIsFreshBeforeEveryGeneration() async throws {
        let catalog = try cliTestCatalog()
        let runner = CLIFakeRunner(id: .codex, catalog: catalog)
        let connector = cliTestConnector(.codex, runner: runner, catalog: catalog)
        _ = try await connector.send(cliTestRequest(), model: "default")
        await runner.setSignedIn(false)
        await #expect(throws: LLMError.cliSignedOut) { try await connector.send(cliTestRequest(), model: "default") }
        let requests = await runner.requests
        #expect(requests.filter { $0.arguments == ["--version"] }.count == 1)
        #expect(requests.filter { $0.arguments == ["login", "status"] }.count == 2)
        #expect(await runner.generationCount == 1)
        #expect(requests.filter { $0.arguments == ["login", "status"] }.allSatisfy { $0.timeout == .seconds(10) })
    }

    @Test(arguments: [ConnectorID.claudeCode, .codex])
    func disabledCatalogEntryDoesNotSpawn(_ id: ConnectorID) async throws {
        var document = try cliTestCatalog().document.testObject ?? [:]
        document["connectors"] = .array((document["connectors"]?.testArray ?? []).map { value in
            guard var provider = value.testObject, provider["id"] == .string(id.rawValue) else { return value }
            provider["enabled"] = .bool(false)
            return .object(provider)
        })
        let catalog = LLMCatalog(document: .object(document))
        let runner = CLIFakeRunner(id: id, catalog: catalog)
        let connector = cliTestConnector(id, runner: runner, catalog: catalog)
        let reason = "\(catalog.connector(id)[ai: "label"].aiString ?? id.rawValue) is not enabled."
        #expect(await connector.status() == .unavailable(reason: reason))
        await #expect(throws: LLMError.unavailable(reason: reason)) { try await connector.models(refresh: true) }
        #expect(await runner.requests.isEmpty)
    }

    @Test func loginShellPATHAndBinaryLookupAreCachedWithoutEnvironmentChanges() async throws {
        var document = try cliTestCatalog().document.testObject ?? [:]
        document["connectors"] = .array((document["connectors"]?.testArray ?? []).map { value in
            guard var provider = value.testObject, provider["id"] == .string("claude-code"),
                  var cli = provider["cli"]?.testObject else { return value }
            cli["searchPaths"] = .object(["macos": .array([])])
            provider["cli"] = .object(cli)
            return .object(provider)
        })
        let catalog = LLMCatalog(document: .object(document))
        let runner = CLIFakeRunner(id: .claudeCode, catalog: catalog)
        let inherited = ["PATH": "/minimal", "VOXCLIP_TEST_SENTINEL": "inherited", "LANG": "et_EE.UTF-8"]
        let connector = CLIConnector(id: .claudeCode, runner: runner, catalog: catalog, log: CLITestLog(), environment: inherited)
        _ = try await connector.send(cliTestRequest(), model: "default")
        _ = try await connector.send(cliTestRequest(), model: "default")
        let requests = await runner.requests
        let shell = requests.filter { $0.arguments == ["-lc", "printf %s \"$PATH\""] }
        #expect(shell.count == 1)
        #expect(shell.first?.environment == inherited)
        #expect(requests.filter { $0.arguments.first != "-lc" }.allSatisfy {
            $0.environment == ["PATH": "/simulated/login/path", "VOXCLIP_TEST_SENTINEL": "inherited", "LANG": "et_EE.UTF-8"]
        })
        #expect(requests.filter { $0.arguments.first == "-p" }.allSatisfy { $0.executable.path == "/bin/sh" })
    }

    @Test func detectionCacheTracksFileSizeAndSettingsRefresh() async throws {
        let directory = try CLITestDirectory()
        let executable = directory.url.appendingPathComponent("fake-cli")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let catalog = try cliTestCatalog()
        let runner = CLIFakeRunner(id: .claudeCode, catalog: catalog)
        let connector = cliTestConnector(.claudeCode, runner: runner, catalog: catalog, executable: executable)
        _ = try await connector.send(cliTestRequest(), model: "default")
        _ = try await connector.send(cliTestRequest(), model: "default")
        #expect(await runner.versionCount == 1)
        try Data("#!/bin/sh\nexit 0\n\n".utf8).write(to: executable)
        _ = try await connector.send(cliTestRequest(), model: "default")
        #expect(await runner.versionCount == 2)
        #expect(await connector.status() == .ready)
        #expect(await runner.versionCount == 2)
        _ = try await connector.detection(refresh: true)
        #expect(await runner.versionCount == 3)
    }

    @Test func binaryReplacementInvalidatesDiscoveredModelsAndEfforts() async throws {
        let directory = try CLITestDirectory()
        let executable = directory.url.appendingPathComponent("fake-cli")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let catalog = try cliTestCatalog()
        let runner = CLIFakeRunner(id: .codex, catalog: catalog)
        let connector = cliTestConnector(.codex, runner: runner, catalog: catalog, executable: executable)
        _ = try await connector.models(refresh: true)
        _ = try await connector.send(cliTestRequest(), model: "listed")
        #expect(await runner.requests.last?.arguments.contains("model_reasoning_effort=\"low\"") == true)
        try Data("#!/bin/sh\nexit 0\n\n".utf8).write(to: executable)
        _ = try await connector.send(cliTestRequest(), model: "listed")
        #expect(await runner.requests.last?.arguments.contains("model_reasoning_effort=\"low\"") == false)
        #expect(try await connector.models(refresh: false).allSatisfy { $0.source == .curated })
    }

    @Test func unknownOptionInvalidatesDetection() async throws {
        let catalog = try cliTestCatalog()
        let runner = CLIFakeRunner(id: .claudeCode, catalog: catalog, generation: { _ in
            ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("unknown option --safe-mode".utf8))
        })
        let connector = cliTestConnector(.claudeCode, runner: runner, catalog: catalog)
        await #expect(throws: LLMError.cliFailed("unknown option --safe-mode")) {
            try await connector.send(cliTestRequest(), model: "default")
        }
        await #expect(throws: LLMError.cliFailed("unknown option --safe-mode")) {
            try await connector.send(cliTestRequest(), model: "default")
        }
        #expect(await runner.versionCount == 2)
    }

    @Test func claudeRecordedEnvelopeUsageAndModel() async throws {
        let catalog = try cliTestCatalog()
        let output = #"{"type":"result","subtype":"success","is_error":false,"result":"not JSON","structured_output":{"ok":true},"stop_reason":"tool_use","terminal_reason":"completed","api_error_status":null,"modelUsage":{"claude-haiku-5-5":{"outputTokens":68},"claude-sonnet-5-5":{"outputTokens":90}},"total_cost_usd":99,"usage":{"input_tokens":2,"output_tokens":68,"cache_read_input_tokens":0,"cache_creation_input_tokens":1048}}"#
        let runner = CLIFakeRunner(id: .claudeCode, catalog: catalog, generation: { _ in cliTestResult(output) })
        let completion = try await cliTestConnector(.claudeCode, runner: runner, catalog: catalog).send(cliTestRequest(), model: "haiku")
        #expect(completion.model == "claude-sonnet-5-5")
        #expect(completion.usage == LLMUsage(input: 2, output: 68, cacheRead: 0, cacheWrite: 1048))
        #expect(completion.stop == .complete)
    }

    /// `cli-replies.json` (ai.md §4.5 and §6.8): each Claude result envelope goes through the connector, then its reply is read
    /// against the case's schema. The envelope is one strict parse of up to 512 levels; the reply, up to 64.
    @Test(.enabled(if: aiSharedFixturesAvailable, aiSharedFixturesSkipReason))
    func sharedClaudeResultEnvelopes() async throws {
        let data = try Data(contentsOf: aiGoldenSharedRoot().appendingPathComponent("fixtures/llm/cli-replies.json"))
        let cases = try JSONDecoder().decode(JSONValue.self, from: data)[ai: "cases"].aiArray
        #expect(cases.count == 35)
        let catalog = try cliTestCatalog()
        for item in cases {
            let id = item[ai: "id"].aiString ?? "?"
            let input = item[ai: "input"], expected = item[ai: "expected"]
            #expect(item[ai: "kind"].aiString == "cli-reply", "\(id): kind")
            let connectorID = try #require(input[ai: "connector"].aiString.flatMap(ConnectorID.init(rawValue:)))
            let stdout = try #require(input[ai: "stdout"].aiString, "\(id): stdout")
            let stderr = input[ai: "stderr"].aiString ?? ""
            let runner = CLIFakeRunner(id: connectorID, catalog: catalog, generation: { _ in
                ProcessResult(exitCode: 0, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
            })
            let connector = cliTestConnector(connectorID, runner: runner, catalog: catalog)
            if input[ai: "mode"].aiString == "app-server" {
                await runner.setProbeResult(["app-server", "--listen", "stdio://"], cliTestResult(stdout))
                let models = try await connector.models(refresh: true)
                #expect(models.map(\.id) == expected[ai: "models"].aiArray.compactMap(\.aiString), "\(id): models")
                continue
            }
            let request = LLMRequest(feature: .voiceRewrite, system: "Rewrite the source.", instruction: "Return the rewrite.",
                                     schemaName: "voice_rewrite_proposal", schema: input[ai: "schema"], maxOutputTokens: 512,
                                     effort: .medium, timeout: .seconds(120), tag: "cli-reply")
            var outcome = "reply"
            do {
                let completion = try await connector.send(request, model: try #require(input[ai: "model"].aiString))
                let parsed = try CanonicalResponseParser.validate(completion, schema: request.schema)
                #expect(parsed.object[ai: "rewrite"].aiString == expected[ai: "rewrite"].aiString, "\(id): rewrite")
                #expect(completion.model == expected[ai: "model"].aiString, "\(id): answering model")
            } catch LLMError.cliFailed(let message) {
                if let expectedMessage = expected[ai: "message"].aiString { #expect(message == expectedMessage, "\(id): stderr") }
                outcome = "cliFailed"
            } catch LLMError.truncated {
                outcome = "truncated"
            } catch LLMError.refused(let category) {
                #expect(category == nil, "\(id): no category")
                outcome = "refused"
            } catch LLMError.invalidOutput {
                outcome = "invalidOutput"
            }
            #expect(outcome == (expected[ai: "error"].aiString ?? "reply"), "\(id)")
        }
    }

    @Test(arguments: [ConnectorID.claudeCode, .codex])
    func malformedSuccessfulReplyReceivesOneCorrectiveRetry(_ id: ConnectorID) async throws {
        let catalog = try cliTestCatalog()
        let request = cliTestRequest()
        let runner = CLIFakeRunner(id: id, catalog: catalog, generation: { process in
            let corrected = String(decoding: process.stdin, as: UTF8.self).contains("Your previous reply was not valid JSON")
            return try cliTestTextResult(id, text: corrected ? #"{"ok":true}"# : "not JSON")
        })
        let connector = cliTestConnector(id, runner: runner, catalog: catalog)
        let result = try await LLMRunner(keys: CLIReviewKeys(), catalog: catalog, log: CLITestLog())
            .run(request, on: connector, model: "default")
        #expect(result.object == .object(["ok": .bool(true)]))
        let generations = await runner.requests.filter {
            $0.arguments.first == "-p" || ($0.arguments.first == "exec" && $0.arguments.contains("--json"))
        }
        #expect(generations.count == 2)
        #expect(generations.last?.stdin == Data((request.instruction +
            "\n\nYour previous reply was not valid JSON for the required schema (not JSON). Reply with only the JSON object.").utf8))
    }

    @Test(arguments: [ConnectorID.claudeCode, .codex])
    func malformedSuccessfulRepliesStopAfterCorrection(_ id: ConnectorID) async throws {
        let catalog = try cliTestCatalog()
        let runner = CLIFakeRunner(id: id, catalog: catalog, generation: { _ in
            try cliTestTextResult(id, text: "not JSON")
        })
        let connector = cliTestConnector(id, runner: runner, catalog: catalog)
        await #expect(throws: LLMError.invalidOutput(reason: "not JSON")) {
            try await LLMRunner(keys: CLIReviewKeys(), catalog: catalog, log: CLITestLog())
                .run(cliTestRequest(), on: connector, model: "default")
        }
        #expect(await runner.generationCount == 2)
    }

    @Test(arguments: ["max_tokens", "refusal"])
    func claudeTerminalStopsNeverReceiveCorrectiveRetry(_ reason: String) async throws {
        let catalog = try cliTestCatalog()
        let runner = CLIFakeRunner(id: .claudeCode, catalog: catalog, generation: { _ in
            try cliTestTextResult(.claudeCode, text: #"{"ok":"#, stop: reason)
        })
        let connector = cliTestConnector(.claudeCode, runner: runner, catalog: catalog)
        let expected: LLMError = reason == "max_tokens" ? .truncated : .refused(category: nil)
        await #expect(throws: expected) {
            try await LLMRunner(keys: CLIReviewKeys(), catalog: catalog, log: CLITestLog())
                .run(cliTestRequest(), on: connector, model: "default")
        }
        #expect(await runner.generationCount == 1)
    }

    @Test func processFailureMessagesAreRedactedAndBounded() async throws {
        let catalog = try cliTestCatalog()
        let logger = CLITestLog()
        let marker = "synthetic-" + UUID().uuidString
        await logger.register(secret: marker)
        let runner = CLIFakeRunner(id: .claudeCode, catalog: catalog, generation: { _ in
            throw LLMError.cliFailed(marker + " " + String(repeating: "x", count: 300))
        })
        let connector = CLIConnector(id: .claudeCode, runner: runner, catalog: catalog, log: logger,
            executable: URL(fileURLWithPath: "/bin/sh"), environment: [:], loginShellPATH: "/test")
        do {
            _ = try await connector.send(cliTestRequest(), model: "default")
            Issue.record("Expected CLI failure")
        } catch LLMError.cliFailed(let message) {
            #expect(message == "[REDACTED] " + String(repeating: "x", count: 189))
        }
        let entries = await logger.entries
        #expect(entries.count == 1)
        #expect(entries.allSatisfy { $0.message.contains("attempt=1 status=-1") && !$0.message.contains(marker) })
    }

    @Test func cancellationDuringFinalWarningDiscardsCompletionAndCleansWorkspace() async throws {
        let catalog = try cliTestCatalog()
        let logger = CLITestLog()
        await logger.cancelWhenWritingWarning()
        let runner = CLIFakeRunner(id: .claudeCode, catalog: catalog, generation: { process in
            try Data("untrusted file".utf8).write(to: process.workingDirectory.appendingPathComponent("unexpected"))
            return cliTestResult(cliClaudeSuccess)
        })
        let connector = CLIConnector(id: .claudeCode, runner: runner, catalog: catalog, log: logger,
            executable: URL(fileURLWithPath: "/bin/sh"), environment: [:], loginShellPATH: "/test")
        let task = Task { try await connector.send(cliTestRequest(), model: "default") }
        await #expect(throws: LLMError.cancelled) { try await task.value }
        let generation = try #require(await runner.requests.last)
        #expect(!FileManager.default.fileExists(atPath: generation.workingDirectory.deletingLastPathComponent().path))
        #expect(await logger.entries.count == 2)
    }

    @Test(arguments: [
        "```json\n{\"ok\":true}\n```",
        "Here is your reply: {\"ok\":true,\"text\":\"a } and \\\"quoted\\\" brace {\"} followed by text",
    ])
    func extractsJSONWithoutParentHelpers(_ reply: String) async throws {
        let catalog = try cliTestCatalog()
        let data = try JSONEncoder().encode(JSONValue.object(["type": .string("result"), "is_error": .bool(false), "result": .string(reply)]))
        let runner = CLIFakeRunner(id: .claudeCode, catalog: catalog, generation: { _ in
            ProcessResult(exitCode: 0, stdout: data, stderr: Data())
        })
        let completion = try await cliTestConnector(.claudeCode, runner: runner, catalog: catalog).send(cliTestRequest(), model: "haiku")
        #expect(completion.object?.testObject?["ok"] == .bool(true))
    }

    @Test(arguments: CLIErrorVector.values)
    fileprivate func errorTaxonomy(_ vector: CLIErrorVector) async throws {
        let catalog = try cliTestCatalog()
        let output: JSONValue
        if vector.id == .claudeCode {
            output = .object(["type": .string("result"), "is_error": .bool(true), "result": .string(vector.message),
                              "api_error_status": vector.status.map { .number(Double($0)) } ?? .null])
        } else {
            output = .object(["type": .string("turn.failed"), "error": .object(["message": .string(vector.message)])])
        }
        let data = try JSONEncoder().encode(output)
        let runner = CLIFakeRunner(id: vector.id, catalog: catalog, generation: { _ in
            ProcessResult(exitCode: 1, stdout: data, stderr: Data("ignored stderr".utf8))
        })
        await #expect(throws: vector.expected) {
            try await cliTestConnector(vector.id, runner: runner, catalog: catalog).send(cliTestRequest(), model: "requested-model")
        }
    }

    @Test func stderrIsRedactedAndBoundedWithoutLoggingBodies() async throws {
        let catalog = try cliTestCatalog()
        let logger = CLITestLog()
        await logger.register(secret: "private-test-marker")
        let runner = CLIFakeRunner(id: .claudeCode, catalog: catalog, generation: { _ in
            ProcessResult(exitCode: 1, stdout: Data("not-json".utf8),
                          stderr: Data(("private-test-marker " + String(repeating: "x", count: 300) + "\nsecond line").utf8))
        })
        let connector = CLIConnector(id: .claudeCode, runner: runner, catalog: catalog, log: logger,
                                     executable: URL(fileURLWithPath: "/bin/sh"), environment: [:], loginShellPATH: "/test")
        do {
            _ = try await connector.send(cliTestRequest(), model: "default")
            Issue.record("Expected CLI failure")
        } catch LLMError.cliFailed(let message) {
            #expect(message.count == 200)
            #expect(message.hasPrefix("[REDACTED] "))
            #expect(!message.contains("private-test-marker"))
        }
        let entries = await logger.entries
        #expect(entries.count == 1)
        #expect(entries.allSatisfy { $0.message.contains("attempt=1 status=1") && !$0.message.contains("private-test-marker") && !$0.message.contains("not-json") })
    }

    @Test func codexExactArgumentsFeaturesAndTOMLEscaping() async throws {
        let catalog = try cliTestCatalog()
        let runner = CLIFakeRunner(id: .codex, catalog: catalog)
        let connector = cliTestConnector(.codex, runner: runner, catalog: catalog)
        var request = cliTestRequest()
        request.system = "\"\\\u{8}\t\n\u{c}\r\u{0}\u{1}\u{1f}\u{7f}Tere 世界"
        let completion = try await connector.send(request, model: "default")
        #expect(completion.usage == LLMUsage(input: 12240, output: 15, cacheRead: 0, cacheWrite: 0))
        let generation = try #require(await runner.requests.last)
        let io = generation.workingDirectory.deletingLastPathComponent().appendingPathComponent("io")
        #expect(generation.arguments == [
            "exec", "--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
            "--sandbox", "read-only", "--cd", generation.workingDirectory.path,
            "-c", "model_reasoning_effort=\"low\"", "-c", "web_search=\"disabled\"", "-c", "approval_policy=\"never\"",
            "-c", "mcp_servers={}", "-c", "developer_instructions=\"\\\"\\\\\\b\\t\\n\\f\\r\\u0000\\u0001\\u001F\\u007FTere 世界\"",
            "--disable", "shell_tool", "--disable", "browser_use",
            "--output-schema", io.appendingPathComponent("schema.json").path,
            "--output-last-message", io.appendingPathComponent("last.json").path, "-",
        ])
        #expect(await runner.schemasWereOutsideCWD)
        #expect(await runner.allWorkspacesWereEmpty)
        #expect(!FileManager.default.fileExists(atPath: io.path))
        let forbidden = cliTestProvider(catalog, .codex)["cli"]?.testObject?["forbiddenFlags"]?.testStrings ?? []
        #expect(Set(generation.arguments).isDisjoint(with: forbidden))
    }

    @Test func codexPrefersLastFileAndIgnoresReconnectingErrors() async throws {
        let catalog = try cliTestCatalog()
        let runner = CLIFakeRunner(id: .codex, catalog: catalog, generation: { request in
            let index = try #require(request.arguments.firstIndex(of: "--output-last-message"))
            try Data("{\"ok\":true,\"file\":true}".utf8).write(to: URL(fileURLWithPath: request.arguments[index + 1]))
            return cliTestResult("not JSON\n{\"type\":\"error\",\"message\":\"Reconnecting... 2/5 (401 Unauthorized)\"}\n" + cliCodexSuccess)
        })
        let completion = try await cliTestConnector(.codex, runner: runner, catalog: catalog).send(cliTestRequest(), model: "default")
        #expect(completion.object?.testObject?["file"] == .bool(true))
    }

    @Test func codexRequiresCompletedTurn() async throws {
        let catalog = try cliTestCatalog()
        let runner = CLIFakeRunner(id: .codex, catalog: catalog, generation: { _ in
            cliTestResult(#"{"type":"item.completed","item":{"type":"agent_message","text":"{\"ok\":true}"}}"#)
        })
        await #expect(throws: LLMError.cliFailed("CLI exited without a result.")) {
            try await cliTestConnector(.codex, runner: runner, catalog: catalog).send(cliTestRequest(), model: "default")
        }
    }

    @Test func malformedClaudeStdoutUsesOnlyFirstStderrLine() async throws {
        let catalog = try cliTestCatalog()
        let runner = CLIFakeRunner(id: .claudeCode, catalog: catalog, generation: { _ in
            ProcessResult(exitCode: 1, stdout: Data("not-json".utf8), stderr: Data("Not logged in\nignored".utf8))
        })
        await #expect(throws: LLMError.cliFailed("Not logged in")) {
            try await cliTestConnector(.claudeCode, runner: runner, catalog: catalog).send(cliTestRequest(), model: "default")
        }
    }

    @Test func codexOutputFileIsCapped() async throws {
        let catalog = try cliTestCatalog()
        let runner = CLIFakeRunner(id: .codex, catalog: catalog, generation: { request in
            let index = try #require(request.arguments.firstIndex(of: "--output-last-message"))
            try Data(repeating: 65, count: 16 * 1024 * 1024 + 1)
                .write(to: URL(fileURLWithPath: request.arguments[index + 1]))
            return cliTestResult(cliCodexSuccess)
        })
        await #expect(throws: LLMError.cliFailed("CLI output exceeded its byte limit.")) {
            try await cliTestConnector(.codex, runner: runner, catalog: catalog).send(cliTestRequest(), model: "default")
        }
        let generation = try #require(await runner.requests.last)
        #expect(!FileManager.default.fileExists(atPath: generation.workingDirectory.deletingLastPathComponent().path))
    }

    @Test func codexModelCatalogAndEffortGate() async throws {
        let catalog = try cliTestCatalog()
        let runner = CLIFakeRunner(id: .codex, catalog: catalog)
        let connector = cliTestConnector(.codex, runner: runner, catalog: catalog)
        let models = try await connector.models(refresh: true)
        #expect(models.map(\.id) == ["default", "listed"])
        #expect(models.last?.source == .discovered)
        let serverRequest = try #require(await runner.requests.first { $0.arguments.first == "app-server" })
        #expect(serverRequest.arguments == ["app-server", "--listen", "stdio://"])
        #expect(serverRequest.timeout == .seconds(15))
        let messages = try String(decoding: serverRequest.stdin, as: UTF8.self).split(separator: "\n").map {
            try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
        }
        #expect(messages.compactMap { $0.testObject?["method"]?.testString } == ["initialize", "initialized", "model/list"])
        _ = try await connector.send(cliTestRequest(), model: "listed")
        #expect(await runner.requests.last?.arguments.contains("model_reasoning_effort=\"low\"") == true)
        _ = try await connector.send(cliTestRequest(), model: "custom")
        #expect(await runner.requests.last?.arguments.contains("model_reasoning_effort=\"low\"") == false)
        await runner.setServerFailure(true)
        #expect(try await connector.models(refresh: true) == models)
        #expect(await connector.refreshWarning?.hasPrefix("Couldn't refresh: ") == true)
        _ = try await connector.send(cliTestRequest(), model: "listed")
        #expect(await runner.requests.last?.arguments.contains("model_reasoning_effort=\"low\"") == true)
    }

    @Test func failedModelRefreshUsesCuratedAndClaudeNeverRefreshes() async throws {
        let catalog = try cliTestCatalog()
        let runner = CLIFakeRunner(id: .codex, catalog: catalog)
        await runner.setServerFailure(true)
        let connector = cliTestConnector(.codex, runner: runner, catalog: catalog)
        #expect(try await connector.models(refresh: true).allSatisfy { $0.source == .curated })
        let claudeRunner = CLIFakeRunner(id: .claudeCode, catalog: catalog)
        let claude = cliTestConnector(.claudeCode, runner: claudeRunner, catalog: catalog)
        #expect(try await claude.models(refresh: true).map(\.id) == ["default", "sonnet", "opus", "haiku"])
        #expect(await claudeRunner.requests.isEmpty)
    }

    @Test func warnsAndCleansWorkspaceOnFailure() async throws {
        let catalog = try cliTestCatalog()
        let logger = CLITestLog()
        let runner = CLIFakeRunner(id: .claudeCode, catalog: catalog, generation: { request in
            try Data("untrusted file".utf8).write(to: request.workingDirectory.appendingPathComponent("unexpected"))
            throw LLMError.timeout
        })
        let connector = CLIConnector(id: .claudeCode, runner: runner, catalog: catalog, log: logger,
            executable: URL(fileURLWithPath: "/bin/sh"), environment: [:], loginShellPATH: "/test")
        await #expect(throws: LLMError.timeout) { try await connector.send(cliTestRequest(), model: "default") }
        let final = try #require(await runner.requests.last)
        #expect(!FileManager.default.fileExists(atPath: final.workingDirectory.deletingLastPathComponent().path))
        let entries = await logger.entries
        #expect(entries.count == 2)
        #expect(entries.last == LogEntry(level: .warn, category: "llm", message: "warning cli-wrote-files"))
        #expect(entries.first?.message.contains("attempt=1 status=-1") == true)
    }

    @Test func outputFileSymlinkIsNeverRead() async throws {
        let catalog = try cliTestCatalog()
        let runner = CLIFakeRunner(id: .codex, catalog: catalog, generation: { request in
            let index = try #require(request.arguments.firstIndex(of: "--output-last-message"))
            try FileManager.default.createSymbolicLink(atPath: request.arguments[index + 1], withDestinationPath: "/dev/null")
            return cliTestResult(cliCodexSuccess)
        })
        await #expect(throws: LLMError.cliFailed("Unable to read CLI result file.")) {
            try await cliTestConnector(.codex, runner: runner, catalog: catalog).send(cliTestRequest(), model: "default")
        }
    }

    @Test func connectorSerializesConcurrentRunsAndCancelsWaiters() async throws {
        let catalog = try cliTestCatalog()
        let runner = CLIFakeRunner(id: .claudeCode, catalog: catalog, generation: { _ in
            try await Task.sleep(for: .milliseconds(150))
            return cliTestResult(cliClaudeSuccess)
        })
        let connector = cliTestConnector(.claudeCode, runner: runner, catalog: catalog)
        let first = Task { try await connector.send(cliTestRequest(), model: "default") }
        for _ in 0..<100 {
            if await runner.generationCount > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let cancelled = Task { try await connector.send(cliTestRequest(), model: "default") }
        cancelled.cancel()
        await #expect(throws: LLMError.cancelled) { try await cancelled.value }
        async let second = connector.send(cliTestRequest(), model: "default")
        async let third = connector.send(cliTestRequest(), model: "default")
        _ = try await (first.value, second, third)
        #expect(await runner.maximumActive == 1)
        #expect(await runner.generationCount == 3)
    }

    @Test(arguments: [ConnectorID.claudeCode, .codex])
    func authStatusExitTwoUsesSectionFiveCopy(_ id: ConnectorID) async throws {
        let catalog = try cliTestCatalog()
        let processes = CLIFakeRunner(id: id, catalog: catalog)
        await processes.setAuthenticationExitCode(2)
        let connector = cliTestConnector(id, runner: processes, catalog: catalog)
        let cli = id == .claudeCode ? "Claude Code" : "Codex"
        let reason = "\(cli) stopped with an error: The CLI could not be started or its output could not be read."
        #expect(await connector.status() == .unavailable(reason: reason))
        #expect(LLMError.unavailable(reason: reason).userMessage(label: cli) == reason + " Your edits are saved.")
    }

    @Test(arguments: [ConnectorID.claudeCode, .codex], [LLMError.timeout, .cliFailed("private-status-marker")])
    func statusFailuresUseRedactedSectionFiveCopy(_ id: ConnectorID, failure: LLMError) async throws {
        let catalog = try cliTestCatalog()
        let processes = CLIFakeRunner(id: id, catalog: catalog)
        await processes.setAuthenticationFailure(failure)
        let log = CLITestLog()
        await log.register(secret: "private-status-marker")
        let connector = CLIConnector(id: id, runner: processes, catalog: catalog, log: log,
                                     executable: URL(fileURLWithPath: "/bin/sh"), environment: [:], loginShellPATH: "/test")
        let label = catalog.connector(id)[ai: "label"].aiString ?? id.rawValue
        let expected = LLMError.cliFailed("The CLI could not be started or its output could not be read.")
            .userMessage(label: label, cli: id == .claudeCode ? "Claude Code" : "Codex", includeEditsSaved: false) ?? ""
        #expect(await connector.status() == .unavailable(reason: expected))
        #expect(!expected.contains("private-status-marker"))
        #expect(!expected.contains("Your edits are saved."))
    }

    @Test(arguments: [ConnectorID.claudeCode, .codex], [false, true])
    func requiredAndOptionalHelpFlagsUseBothStreams(_ id: ConnectorID, stderrOnly: Bool) async throws {
        let catalog = try cliTestCatalog()
        let runner = CLIFakeRunner(id: id, catalog: catalog)
        let help = catalog.connector(id)[ai: "cli"][ai: "detect"][ai: "help"]
        let flags = (help[ai: "requiredFlags"].aiArray + help[ai: "optionalFlags"].aiArray).compactMap(\.aiString)
        let split = stderrOnly ? 0 : flags.count / 2
        let reply = ProcessResult(exitCode: 0, stdout: Data(flags.prefix(split).joined(separator: " ").utf8),
                                  stderr: Data(flags.dropFirst(split).joined(separator: " ").utf8))
        await runner.setProbeResult(help[ai: "args"].aiArray.compactMap(\.aiString), reply)
        let connector = cliTestConnector(id, runner: runner, catalog: catalog)
        let detection = try await connector.detection()
        #expect(detection.supportedFlags == Set(flags))
        #expect(await connector.status() == .ready)
        #expect(await runner.generationCount == 0)
    }

    @Test(arguments: [ConnectorID.claudeCode, .codex])
    func signedOutSignalsTakePrecedenceOverExitTwo(_ id: ConnectorID) async throws {
        let catalog = try cliTestCatalog()
        let runner = CLIFakeRunner(id: id, catalog: catalog)
        await runner.setSignedIn(false)
        await runner.setAuthenticationExitCode(2)
        let connector = cliTestConnector(id, runner: runner, catalog: catalog)
        #expect(await connector.status() == .cliSignedOut)
        await #expect(throws: LLMError.cliSignedOut) { try await connector.send(cliTestRequest(), model: "default") }
        #expect(await runner.generationCount == 0)
    }

    @Test(arguments: [ConnectorID.claudeCode, .codex], ["exit", "stdout", "stderr"])
    func signedOutCatalogSignalsApplyToBothCLIs(_ id: ConnectorID, signal: String) async throws {
        let catalog = try cliTestAuthCatalog(id, changes: ["signedOutExitCode": .number(7), "signedOutText": .string("catalog signed-out marker")])
        let runner = CLIFakeRunner(id: id, catalog: catalog)
        let auth = catalog.connector(id)[ai: "cli"][ai: "detect"][ai: "auth"]
        let marker = "CATALOG SIGNED-OUT MARKER"
        let result = ProcessResult(exitCode: signal == "exit" ? 7 : 2,
            stdout: Data((signal == "stdout" ? marker : "not JSON").utf8),
            stderr: Data((signal == "stderr" ? marker : "").utf8))
        await runner.setProbeResult(auth[ai: "args"].aiArray.compactMap(\.aiString), result)
        let connector = cliTestConnector(id, runner: runner, catalog: catalog)
        #expect(await connector.status() == .cliSignedOut)
        #expect(await runner.generationCount == 0)
    }

    @Test(arguments: ["not JSON", "{}", #"{"loggedIn":true}"#])
    func failedClaudeAuthWithoutSignedOutSignalUsesGenericProbeCopy(_ stdout: String) async throws {
        let catalog = try cliTestCatalog()
        let runner = CLIFakeRunner(id: .claudeCode, catalog: catalog)
        await runner.setProbeResult(["auth", "status", "--json"], cliTestResult(stdout, exit: 2))
        let connector = cliTestConnector(.claudeCode, runner: runner, catalog: catalog)
        let failure = LLMError.cliFailed("The CLI could not be started or its output could not be read.")
        await #expect(throws: failure) { try await connector.detection() }
        #expect(await connector.status() == .unavailable(reason: failure.userMessage(label: "Claude Code", includeEditsSaved: false)!))
    }

    @Test(arguments: [ConnectorID.claudeCode, .codex], [LLMError.timeout, .cliMissing, .cancelled, .cliFailed("CLI output exceeded its byte limit.")])
    func everyProbeFailureUsesGenericCopy(_ id: ConnectorID, failure: LLMError) async throws {
        let catalog = try cliTestCatalog()
        let detect = catalog.connector(id)[ai: "cli"][ai: "detect"]
        for kind in ["version", "help", "features", "auth"] where detect[ai: kind] != .null {
            let runner = CLIFakeRunner(id: id, catalog: catalog)
            await runner.setProbeFailure(detect[ai: kind][ai: "args"].aiArray.compactMap(\.aiString), failure)
            let connector = cliTestConnector(id, runner: runner, catalog: catalog)
            let expected = LLMError.cliFailed("The CLI could not be started or its output could not be read.")
            await #expect(throws: expected) { try await connector.detection() }
            #expect(await connector.status() == .unavailable(reason: expected.userMessage(label: id == .claudeCode ? "Claude Code" : "Codex", includeEditsSaved: false)!))
            #expect(await runner.generationCount == 0)
        }
    }

    @Test(arguments: [ConnectorID.claudeCode, .codex], [false, true])
    func unreadableProbeStreamsUseGenericCopy(_ id: ConnectorID, stderr: Bool) async throws {
        let catalog = try cliTestCatalog()
        let runner = CLIFakeRunner(id: id, catalog: catalog)
        let result = ProcessResult(exitCode: 0, stdout: stderr ? Data("2.1.309".utf8) : Data([0xff]),
                                    stderr: stderr ? Data([0xff]) : Data())
        await runner.setProbeResult(["--version"], result)
        let connector = cliTestConnector(id, runner: runner, catalog: catalog)
        await #expect(throws: LLMError.cliFailed("The CLI could not be started or its output could not be read.")) {
            try await connector.detection()
        }
    }

    @Test func failedProbeRefreshKeepsCuratedOrCachedModelsAndWarning() async throws {
        let catalog = try cliTestCatalog()
        let runner = CLIFakeRunner(id: .codex, catalog: catalog)
        let connector = cliTestConnector(.codex, runner: runner, catalog: catalog)
        await runner.setProbeFailure(["--version"], .timeout)
        #expect(try await connector.models(refresh: true) == catalog.curatedModels(for: .codex))
        #expect(await connector.refreshWarning == "Couldn't refresh: Codex stopped with an error: The CLI could not be started or its output could not be read. Your edits are saved.")
        await runner.clearProbeOverrides()
        let cached = try await connector.models(refresh: true)
        #expect(await connector.refreshWarning == nil)
        await runner.setProbeFailure(["--version"], .cliFailed("CLI output exceeded its byte limit."))
        await #expect(throws: LLMError.cliFailed("The CLI could not be started or its output could not be read.")) {
            try await connector.detection(refresh: true)
        }
        #expect(try await connector.models(refresh: true) == cached)
        #expect(try await connector.models(refresh: false) == cached)
        #expect(await connector.refreshWarning?.hasPrefix("Couldn't refresh: Codex stopped with an error:") == true)
        await runner.clearProbeOverrides()
        #expect(try await connector.models(refresh: true) == cached)
        #expect(await connector.refreshWarning == nil)
    }

    @Test(arguments: [ConnectorID.claudeCode, .codex])
    func incompatibleProbesAreTooOldBeforeAnyAuthOrGeneration(_ id: ConnectorID) async throws {
        let catalog = try cliTestCatalog()
        let detect = catalog.connector(id)[ai: "cli"][ai: "detect"]
        let version = id == .claudeCode ? "2.1.309" : "0.163.0-alpha.10.2"
        let versionReply = id == .claudeCode ? "2.1.309 (Claude Code)" : "codex-cli \(version)"
        let help = detect[ai: "help"]
        let helpFlags = help[ai: "requiredFlags"].aiArray.compactMap(\.aiString)
        var cases: [(String, ProcessResult, String, [String])] = [
            ("version", cliTestResult(versionReply, exit: 2), "unknown", ["version"]),
            ("version", cliTestResult("not a version"), "unknown", ["version"]),
            ("version", cliTestResult(" \n"), "unknown", ["version"]),
            ("help", cliTestResult(helpFlags.joined(separator: " "), exit: 2), version, ["help"]),
            ("help", cliTestResult(helpFlags.dropFirst().joined(separator: " ")), version, [helpFlags[0]])
        ]
        if id == .codex { cases.append(("features", cliTestResult("", exit: 2), version, ["features list"])) }
        for (kind, reply, expectedVersion, missing) in cases {
            let runner = CLIFakeRunner(id: id, catalog: catalog)
            await runner.setProbeResult(detect[ai: kind][ai: "args"].aiArray.compactMap(\.aiString), reply)
            let connector = cliTestConnector(id, runner: runner, catalog: catalog)
            let failure = LLMError.cliTooOld(version: expectedVersion, missing: missing)
            #expect(await connector.status() == .cliTooOld(version: expectedVersion, missing: missing))
            await #expect(throws: failure) { try await connector.detection() }
            if id == .codex {
                #expect(try await connector.models(refresh: true) == catalog.curatedModels(for: id))
                let copy = failure.userMessage(label: "Codex", includeEditsSaved: true)!
                #expect(await connector.refreshWarning == "Couldn't refresh: " + copy)
            }
            let authArguments = detect[ai: "auth"][ai: "args"].aiArray.compactMap(\.aiString)
            #expect(await runner.requests.allSatisfy { $0.arguments != authArguments && $0.arguments.first != "app-server" })
            #expect(await runner.generationCount == 0)
        }
    }

    @Test(arguments: [ConnectorID.claudeCode, .codex], ["", "unknown", " \n\t"])
    func unknownVersionsUseVersionlessTooOldCopy(_ id: ConnectorID, version: String) throws {
        let catalog = try cliTestCatalog()
        let label = try #require(catalog.connector(id)[ai: "label"].aiString)
        let cli = id == .claudeCode ? "Claude Code" : "Codex"
        #expect(LLMError.cliTooOld(version: version, missing: ["version"]).userMessage(label: label, includeEditsSaved: false)
                == "Your \(cli) is too old for VoxClip. Update it, then try again.")
    }

    @Test(arguments: [ConnectorID.claudeCode, .codex])
    func missingCLICopyAndRefreshWarningIncludeCatalogInstallHint(_ id: ConnectorID) async throws {
        var document = try #require(cliTestCatalog().document.aiObject)
        document["connectors"] = .array(document["connectors"]!.aiArray.map { entry in
            guard entry[ai: "id"].aiString == id.rawValue, var fields = entry.aiObject,
                  var cli = fields["cli"]?.aiObject else { return entry }
            cli["searchPaths"] = .object(["macos": .array([])])
            fields["cli"] = .object(cli)
            return .object(fields)
        })
        let catalog = LLMCatalog(document: .object(document))
        let runner = CLIFakeRunner(id: id, catalog: catalog)
        let lookup = catalog.connector(id)[ai: "cli"][ai: "shellLookup"][ai: "macos"].aiArray.compactMap(\.aiString)
        await runner.setProbeResult(Array(lookup.dropFirst()), cliTestResult("", exit: 1))
        let log = CLITestLog()
        let directory = try CLITestDirectory()
        let connector = CLIConnector(id: id, runner: runner, catalog: catalog, log: log, environment: [:],
                                      temporaryDirectory: directory.url, loginShellPATH: "/test")
        let label = try #require(catalog.connector(id)[ai: "label"].aiString)
        let hint = try #require(catalog.connector(id)[ai: "cli"][ai: "installHint"].aiString)
        let cli = id == .claudeCode ? "Claude Code" : "Codex"
        #expect(await connector.status() == .cliMissing)
        #expect(LLMError.cliMissing.userMessage(label: label, installHint: hint, includeEditsSaved: false) == "\(cli) isn't installed. \(hint)")
        await #expect(throws: LLMError.cliMissing) {
            try await LLMRunner(keys: CLIReviewKeys(), catalog: catalog, log: log).test(on: connector, model: "default")
        }
        #expect(await log.entries.contains { $0.message.contains(hint) })
        if id == .codex {
            #expect(try await connector.models(refresh: true) == catalog.curatedModels(for: id))
            #expect(await connector.refreshWarning == "Couldn't refresh: Codex isn't installed. \(hint) Your edits are saved.")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.appendingPathComponent("VoxClip/cli").path).isEmpty)
    }

    @Test(arguments: [ConnectorID.claudeCode, .codex])
    func sectionFiveUsesCatalogLabelsExceptForCLIShortNames(_ id: ConnectorID) throws {
        let catalog = try cliTestCatalog()
        let label = try #require(catalog.connector(id)[ai: "label"].aiString)
        let cli = id == .claudeCode ? "Claude Code" : "Codex"
        let hint = try #require(catalog.connector(id)[ai: "cli"][ai: "signInHint"].aiString)
        #expect(LLMError.network.userMessage(label: label, includeEditsSaved: false) == "Couldn't reach \(label). Check your internet connection.")
        #expect(LLMError.timeout.userMessage(label: label, includeEditsSaved: false) == "\(label) took too long to answer. Try again, or pick a faster model.")
        #expect(LLMError.overloaded.userMessage(label: label, includeEditsSaved: false) == "\(label) is overloaded right now. Try again shortly or pick another model.")
        #expect(LLMError.cliFailed("fixture").userMessage(label: label, includeEditsSaved: false) == "\(cli) stopped with an error: fixture")
        #expect(LLMError.cliSignedOut.userMessage(label: label, signInHint: hint, includeEditsSaved: false) == "\(cli) isn't signed in. \(hint)")
        #expect(LLMError.cliTooOld(version: "1.2.3", missing: ["help"]).userMessage(label: label, includeEditsSaved: false)
                == "Your \(cli) 1.2.3 is too old for VoxClip. Update it, then try again.")
    }

    @Test(arguments: [ConnectorID.claudeCode, .codex], ["start", "timeout", "empty", "nonzero"])
    func loginShellProbeFailuresUseGenericCopy(_ id: ConnectorID, kind: String) async throws {
        let catalog = try cliTestCatalog()
        let runner = CLIFakeRunner(id: id, catalog: catalog)
        let arguments = ["-lc", "printf %s \"$PATH\""]
        if kind == "start" || kind == "timeout" {
            await runner.setProbeFailure(arguments, kind == "start" ? .cliFailed("Unable to start fixture shell") : .timeout)
        } else {
            await runner.setProbeResult(arguments, cliTestResult(kind == "empty" ? "" : "/fixture/bin", exit: kind == "nonzero" ? 2 : 0))
        }
        let connector = CLIConnector(id: id, runner: runner, catalog: catalog, log: CLITestLog(),
                                      executable: URL(fileURLWithPath: "/bin/sh"), environment: [:])
        await #expect(throws: LLMError.cliFailed("The CLI could not be started or its output could not be read.")) {
            try await connector.detection()
        }
        #expect(await runner.requests.allSatisfy { $0.arguments == arguments })
    }

    @Test func cancelledRunCleansDirectories() async throws {
        let catalog = try cliTestCatalog()
        let runner = CLIFakeRunner(id: .claudeCode, catalog: catalog, generation: { _ in
            try await Task.sleep(for: .seconds(60))
            return cliTestResult(cliClaudeSuccess)
        })
        let connector = cliTestConnector(.claudeCode, runner: runner, catalog: catalog)
        let task = Task { try await connector.send(cliTestRequest(), model: "default") }
        for _ in 0..<100 {
            if await runner.generationCount > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        await #expect(throws: LLMError.cancelled) { try await task.value }
        let generation = try #require(await runner.requests.last)
        #expect(!FileManager.default.fileExists(atPath: generation.workingDirectory.deletingLastPathComponent().path))
    }
}

private struct CLIErrorVector: Sendable {
    let id: ConnectorID
    let message: String
    let status: Int?
    let expected: LLMError
    static let values: [CLIErrorVector] = [
        .init(id: .claudeCode, message: "Not logged in · Please run /login", status: nil, expected: .cliSignedOut),
        .init(id: .claudeCode, message: "opaque", status: 403, expected: .cliSignedOut),
        .init(id: .claudeCode, message: "USAGE LIMIT reached", status: nil, expected: .planLimit(message: "USAGE LIMIT reached")),
        .init(id: .claudeCode, message: "opaque", status: 429, expected: .planLimit(message: "opaque")),
        .init(id: .claudeCode, message: "overloaded", status: nil, expected: .overloaded),
        .init(id: .claudeCode, message: "opaque", status: 529, expected: .overloaded),
        .init(id: .claudeCode, message: "Prompt is too long", status: nil, expected: .contextTooLong),
        .init(id: .claudeCode, message: "unknown failure", status: nil, expected: .cliFailed("unknown failure")),
        .init(id: .codex, message: "unexpected status 401 Unauthorized", status: nil, expected: .cliSignedOut),
        .init(id: .codex, message: "usage limit; 429", status: nil, expected: .planLimit(message: "usage limit; 429")),
        .init(id: .codex, message: "model_not_found", status: nil, expected: .modelNotFound("requested-model")),
        .init(id: .codex, message: "context window exceeded", status: nil, expected: .contextTooLong),
        .init(id: .codex, message: "unknown failure", status: nil, expected: .cliFailed("unknown failure")),
    ]
}

private actor CLIBlockedPreflightRunner: ProcessRunner {
    var started = false
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        started = true
        do { try await Task.sleep(for: .seconds(30)) }
        catch { throw LLMError.cancelled }
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
}

private actor CLIFakeRunner: ProcessRunner {
    let id: ConnectorID
    let flags: [String]
    let generation: @Sendable (ProcessRequest) async throws -> ProcessResult
    var requests: [ProcessRequest] = []
    var allWorkspacesWereEmpty = true
    var allWorkspacesWerePrivate = true
    var schemasWereOutsideCWD = true
    var generationCount = 0
    var maximumActive = 0
    private var active = 0
    private var signedIn = true
    private var omittedFlags = Set<String>()
    private var serverFailure = false
    private var authenticationExitCode: Int32?
    private var authenticationFailure: LLMError?
    private var probeResults: [[String]: ProcessResult] = [:]
    private var probeFailures: [[String]: LLMError] = [:]
    var versionCount: Int { requests.filter { $0.arguments == ["--version"] }.count }

    init(id: ConnectorID, catalog: LLMCatalog,
         generation: (@Sendable (ProcessRequest) async throws -> ProcessResult)? = nil) {
        self.id = id
        let help = cliTestProvider(catalog, id)["cli"]?.testObject?["detect"]?.testObject?["help"]?.testObject ?? [:]
        self.flags = (help["requiredFlags"]?.testStrings ?? []) + (help["optionalFlags"]?.testStrings ?? [])
        self.generation = generation ?? { _ in cliTestResult(id == .claudeCode ? cliClaudeSuccess : cliCodexSuccess) }
    }
    func omit(_ flags: Set<String>) { omittedFlags = flags }
    func setSignedIn(_ value: Bool) { signedIn = value }
    func setServerFailure(_ value: Bool) { serverFailure = value }
    func setAuthenticationExitCode(_ value: Int32) { authenticationExitCode = value }
    func setAuthenticationFailure(_ value: LLMError) { authenticationFailure = value }
    func setProbeResult(_ arguments: [String], _ result: ProcessResult) { probeResults[arguments] = result }
    func setProbeFailure(_ arguments: [String], _ failure: LLMError) { probeFailures[arguments] = failure }
    func clearProbeOverrides() { probeResults = [:]; probeFailures = [:] }
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        requests.append(request)
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        let contents = try FileManager.default.contentsOfDirectory(atPath: request.workingDirectory.path)
        allWorkspacesWereEmpty = allWorkspacesWereEmpty && contents.isEmpty
        let attributes = try FileManager.default.attributesOfItem(atPath: request.workingDirectory.path)
        allWorkspacesWerePrivate = allWorkspacesWerePrivate && (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700
        if let failure = probeFailures[request.arguments] { throw failure }
        if let result = probeResults[request.arguments] { return result }
        if request.arguments == ["-lc", "printf %s \"$PATH\""] { return cliTestResult("/simulated/login/path") }
        if request.arguments == ["-lc", "command -v claude"] { return cliTestResult("/bin/sh\nignored second line") }
        if request.arguments == ["--version"] { return cliTestResult(id == .claudeCode ? "2.1.309 (Claude Code)" : "codex-cli 0.163.0-alpha.10.2") }
        if request.arguments.contains("--help") { return cliTestResult(flags.filter { !omittedFlags.contains($0) }.joined(separator: "\n")) }
        if request.arguments == ["features", "list"] {
            return cliTestResult("shell_tool stable false\nplugins removed false\nbrowser_use in development true\nunknown_feature stable true\n")
        }
        if request.arguments == ["auth", "status", "--json"] {
            if let authenticationFailure { throw authenticationFailure }
            return cliTestResult(signedIn ? #"{"loggedIn":true,"authMethod":"api_key","account":"discarded"}"# : #"{"loggedIn":false,"authMethod":"none"}"#, exit: authenticationExitCode ?? (signedIn ? 0 : 1))
        }
        if request.arguments == ["login", "status"] {
            if let authenticationFailure { throw authenticationFailure }
            return cliTestResult(signedIn ? "Logged in using an API key" : "Not logged in", exit: authenticationExitCode ?? (signedIn ? 0 : 1))
        }
        if request.arguments.first == "app-server" {
            if serverFailure { throw LLMError.timeout }
            return cliTestResult(#"{"id":1,"result":{}}"# + "\n" + #"{"id":2,"result":{"data":[{"id":"listed","displayName":"Listed model","isDefault":true,"hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"low"}]},{"id":"hidden","hidden":true},{"id":"listed","displayName":"duplicate"}]}}"# + "\n")
        }
        generationCount += 1
        if let schemaIndex = request.arguments.firstIndex(of: "--output-schema") {
            let schemaPath = request.arguments[schemaIndex + 1]
            schemasWereOutsideCWD = schemasWereOutsideCWD && !schemaPath.hasPrefix(request.workingDirectory.path + "/")
            #expect(FileManager.default.fileExists(atPath: schemaPath))
        }
        return try await generation(request)
    }
}

private actor CLITestLog: Redacting {
    private var redactor = Redactor(homeDirectory: "/test/home")
    private var cancelOnWarning = false
    var entries: [LogEntry] = []
    func cancelWhenWritingWarning() { cancelOnWarning = true }
    func register(secret: String) { redactor.register(secret: secret) }
    func redact(_ message: String) -> String { redactor.redact(message) }
    func write(_ entry: LogEntry) {
        entries.append(LogEntry(level: entry.level, category: entry.category, message: redactor.redact(entry.message)))
        if cancelOnWarning && entry.level == .warn { withUnsafeCurrentTask { $0?.cancel() } }
    }
}

final class CLITestDirectory: Sendable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("VoxClip-CLI-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

private func cliTestCatalog() throws -> LLMCatalog {
    LLMCatalog(document: try FixtureLoader.decode(JSONValue.self, at: "catalog/llm-providers.json"))
}

private func cliTestAuthCatalog(_ id: ConnectorID, changes: [String: JSONValue]) throws -> LLMCatalog {
    var document = try #require(cliTestCatalog().document.aiObject)
    document["connectors"] = .array(document["connectors"]!.aiArray.map { entry in
        guard entry[ai: "id"].aiString == id.rawValue, var fields = entry.aiObject,
              var cli = fields["cli"]?.aiObject, var detect = cli["detect"]?.aiObject,
              var auth = detect["auth"]?.aiObject else { return entry }
        auth.merge(changes) { _, replacement in replacement }
        detect["auth"] = .object(auth)
        cli["detect"] = .object(detect)
        fields["cli"] = .object(cli)
        return .object(fields)
    })
    return LLMCatalog(document: .object(document))
}

private func cliTestProvider(_ catalog: LLMCatalog, _ id: ConnectorID) -> [String: JSONValue] {
    catalog.document.testObject?["connectors"]?.testArray?.compactMap(\.testObject).first {
        $0["id"]?.testString == id.rawValue
    } ?? [:]
}

private func cliTestConnector(_ id: ConnectorID, runner: any ProcessRunner, catalog: LLMCatalog,
                              directory: URL = FileManager.default.temporaryDirectory,
                              executable: URL = URL(fileURLWithPath: "/bin/sh")) -> CLIConnector {
    CLIConnector(id: id, runner: runner, catalog: catalog, log: CLITestLog(), executable: executable,
                 environment: ["PATH": "/test/minimal/path", "VOXCLIP_TEST_SENTINEL": "inherited"],
                 temporaryDirectory: directory, loginShellPATH: "/test/login/path")
}

private func cliTestRequest() -> LLMRequest {
    LLMRequest(feature: .test, system: "You are a JSON API.", instruction: "Reply with {\"ok\":true}",
        schemaName: "test", schema: .object(["type": .string("object"), "required": .array([.string("ok")]),
            "properties": .object(["ok": .object(["type": .string("boolean")])])]),
        maxOutputTokens: 100, effort: .low, timeout: .seconds(120), tag: "test")
}

private func cliTestResult(_ text: String, exit: Int32 = 0) -> ProcessResult {
    ProcessResult(exitCode: exit, stdout: Data(text.utf8), stderr: Data())
}

private struct CLIReviewKeys: KeyProvider {
    func key(for account: String) async throws -> String? {
        Issue.record("CLI execution must not request VoxClip API credentials")
        return nil
    }
}

private func cliTestTextResult(_ id: ConnectorID, text: String, stop: String? = nil) throws -> ProcessResult {
    let value: JSONValue
    if id == .claudeCode {
        value = .object(["type": .string("result"), "is_error": .bool(false), "result": .string(text),
                         "stop_reason": stop.map(JSONValue.string) ?? .string("end_turn")])
    } else {
        value = .object(["type": .string("item.completed"), "item": .object([
            "type": .string("agent_message"), "text": .string(text)])])
    }
    var output = try JSONEncoder().encode(value)
    if id == .codex { output.append(Data("\n{\"type\":\"turn.completed\"}\n".utf8)) }
    return ProcessResult(exitCode: 0, stdout: output, stderr: Data())
}

private let cliClaudeSuccess = #"{"type":"result","is_error":false,"structured_output":{"ok":true},"modelUsage":{"claude-haiku-5-5":{"outputTokens":68}},"usage":{"input_tokens":2,"output_tokens":68,"cache_read_input_tokens":0,"cache_creation_input_tokens":1048}}"#
private let cliCodexSuccess = #"{"type":"thread.started","thread_id":"synthetic-thread"}"# + "\n" +
    #"{"type":"turn.started"}"# + "\n" +
    #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"{\"ok\":true}"}}"# + "\n" +
    #"{"type":"turn.completed","usage":{"input_tokens":12240,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":15,"reasoning_output_tokens":0}}"# + "\n"

private extension JSONValue {
    var testObject: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var testArray: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var testString: String? { if case .string(let value) = self { value } else { nil } }
    var testStrings: [String] { testArray?.compactMap(\.testString) ?? [] }
}
