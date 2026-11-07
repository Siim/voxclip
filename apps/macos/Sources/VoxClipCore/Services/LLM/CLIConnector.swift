import Foundation

public actor CLIConnector: LLMConnector {
    public struct Detection: Sendable, Equatable {
        public let executable: URL
        public let version: String
        public let supportedFlags: Set<String>
        public let features: Set<String>
        public let authMethod: String?
    }

    public nonisolated let id: ConnectorID
    private let runner: any ProcessRunner
    private let catalog: LLMCatalog
    private let log: any Redacting
    private let executableOverride: URL?
    private let inheritedEnvironment: [String: String]
    private let temporaryDirectory: URL
    private let appVersion: String
    private let loginShellPATH: String?
    private var environment: [String: String]?
    private var capabilities: CLICapabilities?
    private var discoveredModels: [LLMModel]?
    private var modelEfforts: [String: Set<String>] = [:]
    /// The `isDefault` model's supportedReasoningEfforts from the last model/list; nil when it reported none.
    private var defaultModelEfforts: Set<String>?
    private var occupied = false
    private var authenticatedPreflight: (fingerprint: CLIFingerprint, at: ContinuousClock.Instant)?
    public internal(set) var refreshWarning: String?
    public private(set) var lastAuthMethod: String?

    private var probeFailure: LLMError {
        .cliFailed("The CLI could not be started or its output could not be read.")
    }

    public init(id: ConnectorID, runner: any ProcessRunner = FoundationProcessRunner(), catalog: LLMCatalog,
                log: any Redacting, executable: URL? = nil, environment: [String: String]? = nil,
                temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                appVersion: String = AppVersion.current, loginShellPATH: String? = nil) {
        self.id = id
        self.runner = runner
        self.catalog = catalog
        self.log = log
        self.executableOverride = executable
        self.inheritedEnvironment = environment ?? ProcessInfo.processInfo.environment
        self.temporaryDirectory = temporaryDirectory
        self.appVersion = appVersion
        self.loginShellPATH = loginShellPATH
    }

    public func status() async -> ConnectorStatus {
        do {
            _ = try await detection(refresh: false)
            return .ready
        } catch LLMError.cliMissing { return .cliMissing }
        catch LLMError.cliSignedOut { return .cliSignedOut }
        catch LLMError.cliTooOld(let version, let missing) { return .cliTooOld(version: version, missing: missing) }
        catch LLMError.cancelled { return .unavailable(reason: "") }
        catch is CancellationError { return .unavailable(reason: "") }
        catch let failure as LLMError {
            if case .unavailable(let reason) = failure { return .unavailable(reason: reason) }
            return await unavailableStatus(failure)
        }
        catch { return await unavailableStatus(probeFailure) }
    }
    public func knownCLIAuthMethod() async -> String? { lastAuthMethod }

    private func unavailableStatus(_ failure: LLMError) async -> ConnectorStatus {
        .unavailable(reason: await failureMessage(failure, includeEditsSaved: false))
    }

    private func failureMessage(_ failure: LLMError, includeEditsSaved: Bool) async -> String {
        let label = catalog.connector(id)[ai: "label"].aiString ?? id.rawValue
        let cli = catalog.connector(id)[ai: "cli"]
        let message = failure.userMessage(label: label, installHint: cli[ai: "installHint"].aiString ?? "",
            signInHint: cli[ai: "signInHint"].aiString ?? "", cli: id == .claudeCode ? "Claude Code" : "Codex",
            includeEditsSaved: includeEditsSaved) ?? ""
        return await log.redact(message)
    }

    public func detection(refresh: Bool = false) async throws -> Detection {
        try await acquire()
        defer { occupied = false }
        authenticatedPreflight = nil
        let configuration = try configuration()
        let detected = try await detect(configuration, refresh: refresh)
        let method = try await authenticate(detected, configuration: configuration)
        lastAuthMethod = method
        authenticatedPreflight = (detected.fingerprint, .now)
        return Detection(executable: detected.fingerprint.url, version: detected.version,
                         supportedFlags: detected.flags, features: detected.features, authMethod: method)
    }

    public func models(refresh: Bool) async throws -> [LLMModel] {
        try await acquire()
        defer { occupied = false }
        let configuration = try configuration()
        if id == .claudeCode { return curatedModels(configuration) }
        if !refresh { return discoveredModels ?? curatedModels(configuration) }
        let previousModels = discoveredModels
        let previousEfforts = modelEfforts
        let previousDefaultEfforts = defaultModelEfforts
        do {
            let detected = try await detect(configuration, refresh: false)
            let models = try await refreshCodexModels(detected, configuration: configuration)
            discoveredModels = models
            refreshWarning = nil
            return models
        } catch LLMError.cancelled { throw LLMError.cancelled }
        catch is CancellationError { throw LLMError.cancelled }
        catch {
            discoveredModels = previousModels
            modelEfforts = previousEfforts
            defaultModelEfforts = previousDefaultEfforts
            let failure = error as? LLMError ?? probeFailure
            refreshWarning = "Couldn't refresh: " + (await failureMessage(failure, includeEditsSaved: true))
            return previousModels ?? curatedModels(configuration)
        }
    }

    public func contextTokens(model: String) async -> Int? {
        guard let configuration = try? configuration() else { return nil }
        return (discoveredModels ?? curatedModels(configuration)).first { $0.id == model }?.contextTokens
    }

    public func send(_ request: LLMRequest, model: String) async throws -> RawCompletion {
        try await acquire()
        defer { occupied = false }
        let configuration = try configuration()
        guard !model.isEmpty, !model.hasPrefix("-"), !model.contains("\0") else {
            throw LLMError.badRequest(status: 0, message: "Invalid CLI model id.")
        }
        let detected = try await detect(configuration, refresh: false)
        let preflight = authenticatedPreflight
        authenticatedPreflight = nil
        if preflight?.fingerprint != detected.fingerprint || preflight.map({ ContinuousClock.now - $0.at >= .seconds(5) }) != false {
            _ = try await authenticate(detected, configuration: configuration)
        }
        let images = sendableImages(request, detected: detected)
        return try await workspace { directories in
            let schema = try aiCompactCanonicalSchema(request.schema)
            let arguments: [String]
            let text = (request.cachedBlock.map { $0 + "\n\n" } ?? "") + request.instruction
            var stdin = Data(text.utf8)
            if id == .claudeCode {
                arguments = claudeArguments(request, model: model, schema: schema, detected: detected,
                                            configuration: configuration, streamsImages: !images.isEmpty)
                if !images.isEmpty { stdin = try claudeImageMessage(text: text, images: images) }
            } else {
                do { try Data(schema.utf8).write(to: directories.io.appendingPathComponent("schema.json"), options: .atomic) }
                catch { throw LLMError.cliFailed("Unable to write CLI schema file.") }
                let files = try writeImages(images, to: directories.io)
                arguments = codexArguments(request, model: model, directories: directories, detected: detected,
                                           configuration: configuration, images: files)
                if !images.isEmpty { stdin = Data(codexImagePrompt(text: text, images: images).utf8) }
            }
            let started = ContinuousClock.now
            var exitCode: Int32 = -1
            do {
                var processRequest = ProcessRequest(
                executable: detected.fingerprint.url, arguments: arguments, workingDirectory: directories.cwd,
                environment: try await resolvedEnvironment(),
                stdin: stdin,
                timeout: request.timeout)
                processRequest.cliCapturesTimeoutOutput = true
                var result = try await execute(processRequest)
                if id == .claudeCode, !images.isEmpty { result = claudeStreamResult(result) }
                exitCode = result.exitCode
                let raw: RawCompletion
                if id == .claudeCode { raw = try await parseClaude(result, requestedModel: model, configuration: configuration) }
                else { raw = try await parseCodex(result, file: directories.io.appendingPathComponent("last.json"), requestedModel: model, configuration: configuration) }
                await recordAttempt(request, model: raw.model, status: exitCode, started: started, usage: raw.usage)
                return raw
            } catch let timeout as CLIProcessTimeout {
                await recordAttempt(request, model: model, status: exitCode, started: started)
                if Task.isCancelled { throw LLMError.cancelled }
                let output = timeoutClassificationText(timeout)
                if networkFailure(output, configuration: configuration) {
                    throw await classify(output, status: nil, model: model, configuration: configuration)
                }
                throw LLMError.timeout
            } catch {
                await recordAttempt(request, model: model, status: exitCode, started: started)
                throw error
            }
        }
    }

    private func recordAttempt(_ request: LLMRequest, model: String, status: Int32, started: ContinuousClock.Instant, usage: LLMUsage? = nil) async {
        func safe(_ value: String) -> String { String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(128)) }
        var message = "llm connector=\(id.rawValue) model=\(safe(model)) feature=\(request.feature.rawValue) tag=\"\(safe(request.tag))\" attempt=1 status=\(status) ms=\(Int(aiDurationSeconds(started.duration(to: .now)) * 1000))"
        if let input = usage?.input { message += " in=\(input)" }
        if let output = usage?.output { message += " out=\(output)" }
        if let cacheRead = usage?.cacheRead { message += " cacheRead=\(cacheRead)" }
        if let cacheWrite = usage?.cacheWrite { message += " cacheWrite=\(cacheWrite)" }
        await log.write(LogEntry(level: .info, category: "llm", message: await log.redact(message)))
    }

    private func acquire() async throws {
        do {
            while occupied { try await Task.sleep(for: .milliseconds(20)) }
            try Task.checkCancellation()
            occupied = true
        } catch { throw LLMError.cancelled }
    }

    private func configuration() throws -> [String: JSONValue] {
        try catalog.validateKeylessAuth(for: id)
        guard id == .claudeCode || id == .codex,
              let configuration = catalog.document.cliObject?["connectors"]?.cliArray?.compactMap(\.cliObject)
                .first(where: { $0["id"]?.cliString == id.rawValue }),
              configuration["cli"]?.cliObject != nil else {
            throw LLMError.unavailable(reason: "VoxClip is missing its AI configuration. Reinstall VoxClip.")
        }
        guard configuration["enabled"]?.cliBool == true else {
            throw LLMError.unavailable(reason: "\(configuration["label"]?.cliString ?? id.rawValue) is not enabled.")
        }
        return configuration
    }

    private func resolvedEnvironment() async throws -> [String: String] {
        if let environment { return environment }
        var inherited = inheritedEnvironment
        if let loginShellPATH { inherited["PATH"] = loginShellPATH }
        else {
            let result = try await runProbe(URL(fileURLWithPath: "/bin/zsh"), arguments: ["-lc", "printf %s \"$PATH\""],
                                            environment: inheritedEnvironment)
            let path = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.exitCode == 0, !path.isEmpty, !path.contains("\n"), !path.contains("\0") else { throw probeFailure }
            inherited["PATH"] = path
        }
        environment = inherited
        return inherited
    }

    private func locate(_ configuration: [String: JSONValue]) async throws -> URL {
        let manager = FileManager.default
        if let executableOverride, manager.isExecutableFile(atPath: executableOverride.path) { return executableOverride }
        let cli = configuration["cli"]?.cliObject ?? [:]
        for candidate in cli["searchPaths"]?.cliObject?["macos"]?.cliStrings ?? [] {
            let expanded = (candidate as NSString).expandingTildeInPath
            if manager.isExecutableFile(atPath: expanded) { return URL(fileURLWithPath: expanded) }
        }
        let lookup = cli["shellLookup"]?.cliObject?["macos"]?.cliStrings ?? []
        guard lookup == ["/bin/zsh", "-lc", "command -v \(id == .claudeCode ? "claude" : "codex")"] else {
            throw LLMError.cliMissing
        }
        let inherited = try await resolvedEnvironment()
        let result = try await runProbe(URL(fileURLWithPath: lookup[0]), arguments: Array(lookup.dropFirst()), environment: inherited)
        guard result.exitCode == 0,
              let first = String(data: result.stdout, encoding: .utf8)?.components(separatedBy: .newlines).first,
              first.hasPrefix("/"), !first.contains("\0"), manager.isExecutableFile(atPath: first) else {
            throw LLMError.cliMissing
        }
        return URL(fileURLWithPath: first)
    }

    private func detect(_ configuration: [String: JSONValue], refresh: Bool) async throws -> CLICapabilities {
        let executable = try await locate(configuration)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: executable.resolvingSymlinksInPath().path) else {
            throw LLMError.cliMissing
        }
        let fingerprint = CLIFingerprint(url: executable, size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                                         modified: attributes[.modificationDate] as? Date ?? .distantPast)
        if !refresh, let capabilities, capabilities.fingerprint == fingerprint { return capabilities }
        if capabilities?.fingerprint != fingerprint {
            discoveredModels = nil
            modelEfforts = [:]
            defaultModelEfforts = nil
        }
        capabilities = nil
        let detect = configuration["cli"]?.cliObject?["detect"]?.cliObject ?? [:]
        let versionConfiguration = detect["version"]?.cliObject ?? [:]
        let versionResult = try await probe(executable, arguments: versionConfiguration["args"]?.cliStrings ?? ["--version"])
        let versionText = String(decoding: versionResult.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let version = cliRegexGroups(versionConfiguration["regex"]?.cliString ?? "^(.+)$", in: versionText)?.first
        guard versionResult.exitCode == 0, let version, !AIText.trim(version).isEmpty else {
            throw LLMError.cliTooOld(version: "unknown", missing: ["version"])
        }
        let helpConfiguration = detect["help"]?.cliObject ?? [:]
        let helpResult = try await probe(executable, arguments: helpConfiguration["args"]?.cliStrings ?? ["--help"])
        let help = String(decoding: helpResult.stdout, as: UTF8.self) + "\n" + String(decoding: helpResult.stderr, as: UTF8.self)
        let flags = Set(cliAllRegexMatches("--[A-Za-z][A-Za-z0-9-]*", in: help))
        let required = helpConfiguration["requiredFlags"]?.cliStrings ?? []
        var missing = required.filter { !flags.contains($0) }
        if helpResult.exitCode != 0 && missing.isEmpty { missing.append("help") }
        guard missing.isEmpty else { throw LLMError.cliTooOld(version: version, missing: missing) }
        var features = Set<String>()
        if id == .codex {
            let featureConfiguration = detect["features"]?.cliObject ?? [:]
            let result = try await probe(executable, arguments: featureConfiguration["args"]?.cliStrings ?? ["features", "list"])
            guard result.exitCode == 0 else { throw LLMError.cliTooOld(version: version, missing: ["features list"]) }
            let pattern = featureConfiguration["lineRegex"]?.cliString ?? "^(\\S+)\\s+(.+?)\\s+(true|false)\\s*$"
            for line in String(decoding: result.stdout, as: UTF8.self).components(separatedBy: .newlines) {
                if let groups = cliRegexGroups(pattern, in: line), groups.count == 3,
                   groups[1] != (featureConfiguration["skipStage"]?.cliString ?? "removed") {
                    features.insert(groups[0])
                }
            }
        }
        let value = CLICapabilities(fingerprint: fingerprint, version: version, flags: flags, features: features)
        capabilities = value
        return value
    }

    private func authenticate(_ detected: CLICapabilities, configuration: [String: JSONValue]) async throws -> String? {
        let auth = configuration["cli"]?.cliObject?["detect"]?.cliObject?["auth"]?.cliObject ?? [:]
        let result = try await probe(detected.fingerprint.url, arguments: auth["args"]?.cliStrings ?? [])
        let text = String(decoding: result.stdout, as: UTF8.self) + "\n" + String(decoding: result.stderr, as: UTF8.self)
        let signedOutText = auth["signedOutText"]?.cliString ?? ""
        if Int(result.exitCode) == (auth["signedOutExitCode"]?.cliInt ?? 1) ||
            (!signedOutText.isEmpty && text.localizedCaseInsensitiveContains(signedOutText)) {
            throw LLMError.cliSignedOut
        }
        if id == .claudeCode {
            let status = CanonicalResponseParser.envelope(result.stdout)?.cliObject
            if status?["loggedIn"]?.cliBool == false { throw LLMError.cliSignedOut }
            guard result.exitCode == 0, status?["loggedIn"]?.cliBool == true else { throw probeFailure }
            return status?["authMethod"]?.cliString
        }
        guard result.exitCode == 0 else { throw probeFailure }
        if text.localizedCaseInsensitiveContains(auth["apiKeyText"]?.cliString ?? "API key") { return "api_key" }
        if text.localizedCaseInsensitiveContains("ChatGPT") { return "chatgpt" }
        return nil
    }

    private func probe(_ executable: URL, arguments: [String]) async throws -> ProcessResult {
        let inherited = try await resolvedEnvironment()
        return try await runProbe(executable, arguments: arguments, environment: inherited)
    }

    private func runProbe(_ executable: URL, arguments: [String], environment: [String: String]) async throws -> ProcessResult {
        do {
            return try await workspace { directories in
                try await executeProbe(ProcessRequest(executable: executable, arguments: arguments, workingDirectory: directories.cwd,
                    environment: environment, timeout: policyTimeout("cliDetect", default: 10)))
            }
        } catch {
            if Task.isCancelled { throw LLMError.cancelled }
            throw probeFailure
        }
    }

    private func executeProbe(_ request: ProcessRequest) async throws -> ProcessResult {
        do {
            let result = try await execute(request)
            guard result.stdout.count <= request.maxOutputBytes, result.stderr.count <= request.maxOutputBytes,
                  String(data: result.stdout, encoding: .utf8) != nil, String(data: result.stderr, encoding: .utf8) != nil else {
                throw probeFailure
            }
            return result
        } catch {
            if Task.isCancelled { throw LLMError.cancelled }
            throw probeFailure
        }
    }

    private func execute(_ request: ProcessRequest) async throws -> ProcessResult {
        do {
            try Task.checkCancellation()
            let result = try await runner.run(request)
            try Task.checkCancellation()
            let text = String(decoding: result.stdout + result.stderr, as: UTF8.self).lowercased()
            if text.contains("unknown option") || text.contains("unrecognized option") {
                capabilities = nil
                discoveredModels = nil
                modelEfforts = [:]
                defaultModelEfforts = nil
            }
            return result
        } catch is CancellationError { throw LLMError.cancelled }
        catch let timeout as CLIProcessTimeout { throw timeout }
        catch LLMError.cliFailed(let message) { throw LLMError.cliFailed(await safeMessage(message)) }
        catch let error as LLMError { throw error }
        catch { throw LLMError.cliFailed("Unable to run CLI process.") }
    }

    public func supportsImages() async -> Bool { catalog.supportsImages(for: id) }

    /// The images a send passes on (ai.md §19.3): the catalogue's, and for Claude Code only when the CLI lists the
    /// stream-json input flags (`images.requiredFlags`). Otherwise none, and the request goes as text.
    private func sendableImages(_ request: LLMRequest, detected: CLICapabilities) -> [LLMImage] {
        let images = catalog.images(request, for: id)
        guard !images.isEmpty else { return [] }
        let required = catalog.connector(id)[ai: "images"][ai: "requiredFlags"].aiArray.compactMap(\.aiString)
        guard required.allSatisfy(detected.flags.contains) else { return [] }
        return images
    }

    /// Claude Code's one stream-json user message: each image after its label, then the request's text.
    private func claudeImageMessage(text: String, images: [LLMImage]) throws -> Data {
        var content: [JSONValue] = []
        for image in images {
            content.append(.object(["type": .string("text"), "text": .string(image.label)]))
            content.append(.object(["type": .string("image"), "source": .object([
                "type": .string("base64"), "media_type": .string(image.mediaType), "data": .string(image.data.base64EncodedString())])]))
        }
        content.append(.object(["type": .string("text"), "text": .string(text)]))
        let message: JSONValue = .object(["type": .string("user"), "message": .object(["role": .string("user"), "content": .array(content)])])
        do { return Data((try cliEncode(message) + "\n").utf8) }
        catch { throw LLMError.cliFailed("Unable to encode the CLI request.") }
    }

    /// The stream-json output's last `result` event as the `json` output's single object, so one parser reads both.
    private func claudeStreamResult(_ result: ProcessResult) -> ProcessResult {
        let last = cliLines(result.stdout).last { line in
            CanonicalResponseParser.envelope(line)?.cliObject?["type"]?.cliString == "result"
        }
        return ProcessResult(exitCode: result.exitCode, stdout: last.map { Data($0.utf8) } ?? Data(), stderr: result.stderr)
    }

    /// Codex reads each image from a file in the private io folder, named by its order.
    private func writeImages(_ images: [LLMImage], to directory: URL) throws -> [URL] {
        try images.enumerated().map { index, image in
            let name = String(format: "frame-%02d.%@", index + 1, image.mediaType == "image/png" ? "png" : "jpg")
            let url = directory.appendingPathComponent(name)
            do { try image.data.write(to: url, options: .atomic) }
            catch { throw LLMError.cliFailed("Unable to write a CLI image file.") }
            return url
        }
    }

    /// Codex attaches the images in order before the prompt, so the prompt names them first: "Image 1: Frame 1 at 3.20 s".
    private func codexImagePrompt(text: String, images: [LLMImage]) -> String {
        let labels = images.enumerated().map { "Image \($0.offset + 1): \($0.element.label)" }
        return "The attached images, in order:\n" + labels.joined(separator: "\n") + "\n\n" + text
    }

    private func claudeArguments(_ request: LLMRequest, model: String, schema: String, detected: CLICapabilities,
                                 configuration: [String: JSONValue], streamsImages: Bool) -> [String] {
        // ai.md §19.3: images go as one stream-json user message, which the CLI takes only with stream-json output and
        // --verbose; its last `result` event is the json output's object.
        let output = streamsImages ? ["--input-format", "stream-json", "--output-format", "stream-json", "--verbose"] : ["--output-format", "json"]
        var arguments = ["-p"] + output + ["--json-schema", schema, "--system-prompt", request.system,
                         "--tools", "", "--no-session-persistence"]
        if model != "default" { arguments += ["--model", model] }
        // A Voice Lab rewrite is billed for the quoted model only, so it never names a fallback (ai.md §12.8).
        if request.feature != .voiceRewrite, detected.flags.contains("--fallback-model"),
           let fallback = configuration["fallbackOrder"]?.cliStrings.first(where: { $0 != model }) {
            arguments += ["--fallback-model", fallback]
        }
        if detected.flags.contains("--effort"),
           let effort = Effort.resolved(request.effort, supported: catalog.effortLevels(for: id)) { arguments += ["--effort", effort.rawValue] }
        arguments.append("--safe-mode")
        for flag in ["--strict-mcp-config", "--disable-slash-commands"] where detected.flags.contains(flag) {
            arguments.append(flag)
        }
        return arguments
    }

    private func codexArguments(_ request: LLMRequest, model: String, directories: CLIWorkspace,
                                detected: CLICapabilities, configuration: [String: JSONValue], images: [URL]) -> [String] {
        var arguments = ["exec", "--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config"]
        if detected.flags.contains("--ignore-rules") { arguments.append("--ignore-rules") }
        arguments += ["--sandbox", "read-only", "--cd", directories.cwd.path]
        if model != "default" { arguments += ["--model", model] }
        // A named model sends only a level its supportedReasoningEfforts lists; the CLI default uses the isDefault
        // model's list, or the catalog's levels when model/list reported none (ai.md §6.9).
        let supported = model == "default" ? Array(defaultModelEfforts ?? Set(catalog.effortLevels(for: id))) : Array(modelEfforts[model] ?? [])
        if let effort = Effort.resolved(request.effort, supported: supported) {
            arguments += ["-c", "model_reasoning_effort=\"\(effort.rawValue)\""]
        }
        arguments += ["-c", "web_search=\"disabled\"", "-c", "approval_policy=\"never\"", "-c", "mcp_servers={}",
                      "-c", "developer_instructions=" + cliTOMLString(request.system)]
        for feature in configuration["cli"]?.cliObject?["disableFeatures"]?.cliStrings ?? [] where detected.features.contains(feature) {
            arguments += ["--disable", feature]
        }
        // ai.md §19.3: `--image` takes one or more files; a flag follows the last one, so none is read as the prompt.
        if !images.isEmpty { arguments += ["--image"] + images.map(\.path) }
        arguments += ["--output-schema", directories.io.appendingPathComponent("schema.json").path,
                      "--output-last-message", directories.io.appendingPathComponent("last.json").path, "-"]
        return arguments
    }

    private func parseClaude(_ result: ProcessResult, requestedModel: String,
                             configuration: [String: JSONValue]) async throws -> RawCompletion {
        guard let object = CanonicalResponseParser.envelope(result.stdout)?.cliObject,
              object["type"]?.cliString == "result", let isError = object["is_error"]?.cliBool else {
            throw await classifyStderr(result.stderr, model: requestedModel, configuration: configuration)
        }
        if !isError && result.exitCode != 0 {
            throw await classifyStderr(result.stderr, model: requestedModel, configuration: configuration)
        }
        if isError {
            throw await classify(object["result"]?.cliString ?? cliFirstLine(result.stderr),
                                 status: object["api_error_status"]?.cliInt, model: requestedModel, configuration: configuration)
        }
        let modelUsage = object["modelUsage"]?.cliObject ?? [:]
        let actualModel = modelUsage.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.max { first, second in
            let firstUsage = modelUsage[first]?.cliObject ?? [:]
            let secondUsage = modelUsage[second]?.cliObject ?? [:]
            return (firstUsage["outputTokens"]?.cliInt ?? firstUsage["output_tokens"]?.cliInt ?? 0) <
                   (secondUsage["outputTokens"]?.cliInt ?? secondUsage["output_tokens"]?.cliInt ?? 0)
        } ?? requestedModel
        let usage = object["usage"]?.cliObject
        let text = object["result"]?.cliString
        // ai.md §6.8: the stop reason, before the reply is read.
        let stop: StopKind
        switch object["stop_reason"]?.cliString {
        case "max_tokens": stop = .truncated
        case "refusal": stop = .refused(category: nil)
        default: stop = .complete
        }
        let structured = object["structured_output"].flatMap { $0.cliObject == nil ? nil : $0 }
        let extracted = structured ?? text.flatMap(cliExtractJSON)
        return RawCompletion(text: text, object: extracted, model: actualModel, stop: stop,
            usage: usage.map { LLMUsage(input: $0["input_tokens"]?.cliInt, output: $0["output_tokens"]?.cliInt,
                                        cacheRead: $0["cache_read_input_tokens"]?.cliInt,
                                        cacheWrite: $0["cache_creation_input_tokens"]?.cliInt) })
    }

    private func parseCodex(_ result: ProcessResult, file: URL, requestedModel: String,
                            configuration: [String: JSONValue]) async throws -> RawCompletion {
        var completed: [String: JSONValue]?
        var agentMessage: String?
        var failure: String?
        var sawFailure = false
        var lastError: String?
        for line in cliLines(result.stdout) {
            guard let event = CanonicalResponseParser.envelope(line)?.cliObject else { continue }
            switch event["type"]?.cliString {
            case "turn.completed": completed = event
            case "turn.failed":
                sawFailure = true
                failure = event["error"]?.cliObject?["message"]?.cliString
            case "error":
                if let message = event["message"]?.cliString, !message.hasPrefix("Reconnecting...") { lastError = message }
            case "item.completed":
                if let item = event["item"]?.cliObject, item["type"]?.cliString == "agent_message" {
                    agentMessage = item["text"]?.cliString
                }
            default: break
            }
        }
        guard result.exitCode == 0, let completed, !sawFailure else {
            if let message = failure ?? lastError {
                throw await classify(message, status: nil, model: requestedModel, configuration: configuration)
            }
            throw await classifyStderr(result.stderr, model: requestedModel, configuration: configuration)
        }
        let fileText = try cliReadOutput(file)
        let text = fileText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? fileText : agentMessage
        let usage = completed["usage"]?.cliObject
        return RawCompletion(text: text, object: text.flatMap(cliExtractJSON), model: requestedModel, stop: .complete,
            usage: usage.map { LLMUsage(input: $0["input_tokens"]?.cliInt, output: $0["output_tokens"]?.cliInt,
                                        cacheRead: $0["cached_input_tokens"]?.cliInt,
                                        cacheWrite: nil) })
    }

    // Partial JSONL includes model prose, IDs and usage. Only transport error messages are evidence.
    private func timeoutClassificationText(_ timeout: CLIProcessTimeout) -> String {
        var messages = [String(decoding: timeout.stderr, as: UTF8.self)]
        if id == .codex {
            for line in cliLines(timeout.stdout) {
                guard let event = CanonicalResponseParser.envelope(line)?.cliObject else { continue }
                switch event["type"]?.cliString {
                case "error":
                    // Includes Codex's "Reconnecting..." progress message and its reason.
                    if let message = event["message"]?.cliString { messages.append(message) }
                case "turn.failed":
                    if let message = event["error"]?.cliObject?["message"]?.cliString { messages.append(message) }
                default: break
                }
            }
        }
        return messages.joined(separator: "\n")
    }

    // Select before classifying, so later help text cannot change the first diagnostic's category.
    private func classifyStderr(_ stderr: Data, model: String,
                                configuration: [String: JSONValue]) async -> LLMError {
        let first = cliFirstLine(stderr)
        let error = await classify(first, status: nil, model: model, configuration: configuration)
        if case .cliFailed = error,
           let networkLine = cliLines(stderr).map(AIText.trim).first(where: { networkFailure($0, configuration: configuration) }) {
            return await classify(networkLine, status: nil, model: model, configuration: configuration)
        }
        return error
    }

    private func classify(_ message: String, status: Int?, model: String,
                          configuration: [String: JSONValue]) async -> LLMError {
        let cli = configuration["cli"]?.cliObject ?? [:]
        func matches(_ key: String) -> Bool {
            (cli[key]?.cliStrings ?? []).contains { message.localizedCaseInsensitiveContains($0) }
        }
        let redacted = await safeMessage(message)
        if matches("authErrorMarkers") || (id == .claudeCode && [401, 403].contains(status ?? 0)) { return .cliSignedOut }
        if matches("limitMarkers") || (id == .claudeCode && status == 429) { return .planLimit(message: redacted) }
        if id == .claudeCode {
            if matches("overloadMarkers") || status == 529 { return .overloaded }
            if message.localizedCaseInsensitiveContains("prompt is too long") { return .contextTooLong }
        } else {
            if matches("overloadMarkers") { return .overloaded }
            if matches("modelErrorMarkers") { return .modelNotFound(model) }
            let lower = message.lowercased()
            if lower.contains("context") && (lower.contains("length") || lower.contains("window")) { return .contextTooLong }
        }
        if networkFailure(message, configuration: configuration) {
            return .cliNetworkUnreachable(detail: await safeMessage(cliFirstLine(Data(message.utf8))))
        }
        return .cliFailed(redacted)
    }

    static let defaultNetworkErrorMarkers = [
        "ECONNREFUSED", "ENETUNREACH", "EHOSTUNREACH", "Connection refused",
        "connect ETIMEDOUT", "getaddrinfo ENOTFOUND", "fetch failed",
        "error sending request for url", "dns error", "failed to lookup address information",
        "No route to host", "Network is unreachable", "os error 61", "os error 65", "tcp connect error",
    ]

    private func networkFailure(_ message: String, configuration: [String: JSONValue]) -> Bool {
        let markers = configuration["cli"]?.cliObject?["networkErrorMarkers"]?.cliStrings ?? Self.defaultNetworkErrorMarkers
        return markers.contains { message.localizedCaseInsensitiveContains($0) }
    }

    private func safeMessage(_ message: String) async -> String {
        String((await log.redact(message.isEmpty ? cliNoResultMessage : message)).prefix(200))
    }

    private func policyTimeout(_ key: String, default seconds: Int) -> Duration {
        let configured = catalog.document.cliObject?["policy"]?.cliObject?["timeoutsSeconds"]?.cliObject?[key]?.cliInt
        return .seconds(configured.flatMap { $0 > 0 ? $0 : nil } ?? seconds)
    }

    private func curatedModels(_ configuration: [String: JSONValue]) -> [LLMModel] {
        (configuration["models"]?.cliArray ?? []).compactMap { value in
            guard let model = value.cliObject, let id = model["id"]?.cliString else { return nil }
            return LLMModel(id: id, name: model["name"]?.cliString ?? id, tier: model["tier"]?.cliString,
                            contextTokens: model["contextTokens"]?.cliInt, source: .curated)
        }
    }

    private func refreshCodexModels(_ detected: CLICapabilities,
                                    configuration: [String: JSONValue]) async throws -> [LLMModel] {
        let inherited = try await resolvedEnvironment()
        return try await workspace { directories in
            let messages: [JSONValue] = [
                .object(["id": .number(1), "method": .string("initialize"), "params": .object([
                    "clientInfo": .object(["name": .string("voxclip"), "title": .string("VoxClip"), "version": .string(appVersion)])])]),
                .object(["method": .string("initialized")]),
                .object(["id": .number(2), "method": .string("model/list"), "params": .object(["limit": .number(100)])]),
            ]
            var request = ProcessRequest(executable: detected.fingerprint.url, arguments: ["app-server", "--listen", "stdio://"],
                workingDirectory: directories.cwd, environment: inherited,
                stdin: Data((try messages.map(cliEncode).joined(separator: "\n") + "\n").utf8),
                timeout: policyTimeout("modelList", default: 15))
            request.cliCompletionResponseID = 2
            request.cliInitializationResponseID = 1
            let result = try await executeProbe(request)
            var entries: [JSONValue]?
            for line in cliLines(result.stdout) {
                if let response = CanonicalResponseParser.envelope(line)?.cliObject,
                   response["id"]?.cliInt == 2 {
                    entries = response["result"]?.cliObject?["data"]?.cliArray
                    break
                }
            }
            guard let entries else { throw probeFailure }
            var efforts: [String: Set<String>] = [:]
            var defaultEfforts: Set<String>?
            var seen = Set<String>()
            let models = entries.compactMap { value -> LLMModel? in
                guard let item = value.cliObject, item["hidden"]?.cliBool != true,
                      let id = item["id"]?.cliString, seen.insert(id).inserted else { return nil }
                efforts[id] = Set((item["supportedReasoningEfforts"]?.cliArray ?? []).compactMap {
                    $0.cliObject?["reasoningEffort"]?.cliString
                })
                if item["isDefault"]?.cliBool == true, defaultEfforts == nil, efforts[id]?.isEmpty == false { defaultEfforts = efforts[id] }
                return LLMModel(id: id, name: item["displayName"]?.cliString ?? id, source: .discovered)
            }
            guard !models.isEmpty else { throw LLMError.noModels }
            modelEfforts = efforts
            defaultModelEfforts = defaultEfforts
            return [LLMModel(id: "default", name: "CLI default", source: .curated)] + models.filter { $0.id != "default" }
        }
    }

    private func workspace<Value: Sendable>(_ operation: (CLIWorkspace) async throws -> Value) async throws -> Value {
        let manager = FileManager.default
        let root = temporaryDirectory.appendingPathComponent("VoxClip/cli", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directories = CLIWorkspace(cwd: root.appendingPathComponent("cwd", isDirectory: true),
                                       io: root.appendingPathComponent("io", isDirectory: true))
        do {
            try manager.createDirectory(at: directories.cwd, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.createDirectory(at: directories.io, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        } catch {
            try? manager.removeItem(at: root)
            throw LLMError.cliFailed("Unable to create a private CLI working directory.")
        }
        defer { try? manager.removeItem(at: root) }
        let value: Value
        do { value = try await operation(directories) }
        catch {
            await warnIfFiles(directories.cwd)
            throw error
        }
        await warnIfFiles(directories.cwd)
        guard !Task.isCancelled else { throw LLMError.cancelled }
        return value
    }

    private func warnIfFiles(_ cwd: URL) async {
        if let files = try? FileManager.default.contentsOfDirectory(atPath: cwd.path), !files.isEmpty {
            await log.write(LogEntry(level: .warn, category: "llm", message: await log.redact("warning cli-wrote-files")))
        }
    }
}

private struct CLIFingerprint: Equatable, Sendable { let url: URL; let size: UInt64; let modified: Date }
private struct CLICapabilities: Sendable {
    let fingerprint: CLIFingerprint
    let version: String
    let flags: Set<String>
    let features: Set<String>
}
private struct CLIWorkspace: Sendable { let cwd: URL; let io: URL }

private extension JSONValue {
    var cliObject: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var cliArray: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var cliString: String? { if case .string(let value) = self { value } else { nil } }
    var cliBool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var cliStrings: [String] { cliArray?.compactMap(\.cliString) ?? [] }
}

extension JSONValue {
    var cliInt: Int? {
        guard case .number(let value) = self, let integer = Int64(exactly: value) else { return nil }
        return Int(exactly: integer)
    }
}

private func cliEncode(_ value: JSONValue) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func cliRegexGroups(_ pattern: String, in text: String) -> [String]? {
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
    return (1..<match.numberOfRanges).compactMap { index in
        Range(match.range(at: index), in: text).map { String(text[$0]) }
    }
}

private func cliAllRegexMatches(_ pattern: String, in text: String) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
        Range($0.range, in: text).map { String(text[$0]) }
    }
}

private let cliNoResultMessage = "The CLI exited without a result."

private func cliFirstLine(_ data: Data) -> String {
    cliLines(data).lazy.map(AIText.trim).first { !$0.isEmpty } ?? cliNoResultMessage
}

private func cliTOMLString(_ text: String) -> String {
    var encoded = "\""
    for scalar in text.unicodeScalars {
        switch scalar.value {
        case 0x22: encoded += "\\\""
        case 0x5c: encoded += "\\\\"
        case 0x08: encoded += "\\b"
        case 0x09: encoded += "\\t"
        case 0x0a: encoded += "\\n"
        case 0x0c: encoded += "\\f"
        case 0x0d: encoded += "\\r"
        case 0x00...0x1f, 0x7f: encoded += String(format: "\\u%04X", scalar.value)
        default: encoded.unicodeScalars.append(scalar)
        }
    }
    return encoded + "\""
}

/// The lines of a CLI's JSON Lines output, split at LF only, so a raw U+2028 inside a string stays in its line; each line is
/// then read as an envelope (ai.md §4.5), whose jsTrim drops a CR.
private func cliLines(_ data: Data) -> [String] {
    String(decoding: data, as: UTF8.self).unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}

/// The reply object of a CLI's text, read as every reply is (ai.md §4.5).
private func cliExtractJSON(_ text: String) -> JSONValue? {
    guard let value = try? CanonicalResponseParser.extract(text), value.cliObject != nil else { return nil }
    return value
}

private func cliReadOutput(_ url: URL) throws -> String? {
    let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard directory >= 0 else { throw LLMError.cliFailed("Unable to read CLI result directory.") }
    defer { _ = close(directory) }
    let descriptor = openat(directory, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    if descriptor < 0 {
        if errno == ENOENT { return nil }
        throw LLMError.cliFailed("Unable to read CLI result file.")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var information = stat()
    guard fstat(descriptor, &information) == 0, information.st_mode & S_IFMT == S_IFREG else {
        throw LLMError.cliFailed("CLI result is not a regular file.")
    }
    let limit = 16 * 1024 * 1024
    let data = try handle.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else { throw LLMError.cliFailed("CLI output exceeded its byte limit.") }
    guard let text = String(data: data, encoding: .utf8) else { throw LLMError.invalidOutput(reason: "CLI output is not UTF-8.") }
    return text
}
