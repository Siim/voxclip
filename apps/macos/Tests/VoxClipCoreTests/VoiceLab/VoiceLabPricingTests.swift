import CryptoKit
#if DEBUG
import Foundation
import Synchronization
import Testing
@testable import VoxClipCore
@_spi(Testing) @testable import VoxClipMedia

/// Replays shared/fixtures/voice-lab/pricing-cases.json (voice-lab §3.1 and §3.2, rules in pricing-cases-README.md).
@Suite("Voice Lab pricing, cost presentation and spend ledger", .timeLimit(.minutes(1)))
struct VoiceLabPricingTests {
    static func catalog() throws -> VoiceLabPriceCatalog {
        try VoiceLabPriceCatalog.load(shared: SharedResources(root: FixtureLoader.sharedRoot()))
    }
    /// For the service suites, so they do not depend on `SharedResources.locate()` under the test runner.
    static var catalogIfPresent: VoiceLabPriceCatalog? { try? catalog() }

    private static func document() throws -> [String: Any] {
        let document = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/voice-lab/pricing-cases.json")) as? [String: Any])
        #expect(document["schema"] as? String == "voxclip-voice-lab-pricing-cases/1")
        return document
    }
    private static func rows(_ key: String, in object: [String: Any]? = nil) throws -> [[String: Any]] {
        let rows = try #require((try object ?? document())[key] as? [[String: Any]])
        #expect(!rows.isEmpty)
        return rows
    }
    private static func ledgerSection() throws -> [String: Any] { try #require(document()["ledger"] as? [String: Any]) }
    private static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
    private static func amount(_ value: Any?) -> Decimal? { (value as? String).flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) } }
    private static func operation(_ value: Any?) throws -> VoiceLabPricedOperation {
        let row = try #require(value as? [String: Any])
        return VoiceLabPricedOperation(provider: try #require(row["provider"] as? String), operation: try #require(row["operation"] as? String),
                                       endpoint: row["endpoint"] as? String, unit: try #require(row["unit"] as? String))
    }
    private static func check(_ estimate: CostEstimate, _ expected: [String: Any], _ id: String) {
        #expect(estimate.units == number(expected["units"]), "\(id) units")
        #expect(estimate.unit == expected["unit"] as? String, "\(id) unit")
        #expect(estimate.usd.map(VoiceLabMoney.canonical) == expected["usd"] as? String, "\(id) usd")
        #expect(estimate.credits == expected["credits"] as? Int, "\(id) credits")
        #expect(estimate.basis == expected["basis"] as? String, "\(id) basis")
    }
    private static func kind(_ value: Any?) throws -> VoiceLabCostPresentation.Kind {
        let row = try #require(value as? [String: Any])
        let text = try #require(row["text"] as? String)
        return row["kind"] as? String == "inline" ? .inline(text) : .confirm(text)
    }
    private static func cap(_ value: Any?) throws -> VoiceLabMonthlyCap? {
        guard let row = value as? [String: Any] else { return nil }
        return VoiceLabMonthlyCap(limit: try #require(amount(row["limit"])), spent: try #require(amount(row["spent"])))
    }
    private static func spend(_ row: [String: Any]) throws -> CostEstimate {
        CostEstimate(provider: try #require(row["provider"] as? String), operation: "fixture", units: 1, unit: "call",
                     usd: amount(row["usd"]), basis: "fixture")
    }
    private static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-spend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private static func text(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }
    private static func mode(_ path: String) throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
    }
    private static let utc = TimeZone(secondsFromGMT: 0)!
    /// An EU lab after discovery: `eleven_v3` speaks, `eleven_multilingual_sts_v2` converts, `own123` is the user's clone
    /// and `stock123` a stock voice. Every other request goes to `action`.
    private static func discoveredLab(spend: VoiceLabSpendLedger?, _ action: @escaping SpeechStubHTTP.Handler) async throws -> ElevenLabsVoiceLab {
        try await discoveredLab(spend: spend, streaming: { request in
            let (status, headers, body) = try action(request)
            return SpeechStubHTTP.Reply(status: status, headers: headers, body: body)
        })
    }
    private static func discoveredLab(spend: VoiceLabSpendLedger?,
                                      streaming action: @escaping @Sendable (URLRequest) throws -> SpeechStubHTTP.Reply) async throws -> ElevenLabsVoiceLab {
        let models = Data(#"[{"model_id":"eleven_v3","can_do_text_to_speech":true,"languages":[{"language_id":"en"}]},{"model_id":"eleven_multilingual_sts_v2","can_do_voice_conversion":true,"languages":[{"language_id":"en"}]}]"#.utf8)
        let plan = Data(#"{"tier":"starter","status":"active","character_count":0,"character_limit":10000,"can_use_instant_voice_cloning":true,"voice_slots_used":0,"voice_limit":10}"#.utf8)
        let voices = Data(#"{"voices":[{"voice_id":"own123","name":"Mine","category":"cloned","is_owner":true,"voice_verification":{"requires_verification":false,"is_verified":true}},{"voice_id":"stock123","name":"Stock","category":"premade","is_owner":false}],"has_more":false}"#.utf8)
        let base = SpeechStubHTTP.registerStream { request in
            switch request.url?.path {
            case "/v1/models": return SpeechStubHTTP.Reply(status: 200, headers: [:], body: models)
            case "/v1/user/subscription": return SpeechStubHTTP.Reply(status: 200, headers: [:], body: plan)
            case "/v2/voices": return SpeechStubHTTP.Reply(status: 200, headers: [:], body: voices)
            default: return try action(request)
            }
        }
        let lab = ElevenLabsVoiceLab(keys: SpeechTestKeys(value: "synthetic-voice-lab-key"), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)),
                                     region: .eu, logger: SpeechTestLogger(), prices: try catalog(), spend: spend)
        _ = try await lab.models(); _ = try await lab.plan(); _ = try await lab.voices()
        return lab
    }
    /// A timestamped TTS reply for "Hi" with `audio`.
    private static func speech(_ audio: Data) -> Data {
        let encoded = audio.base64EncodedString()
        return Data(#"{"audio_base64":"\#(encoded)","alignment":{"characters":["H","i"],"character_start_times_seconds":[0,0.02],"character_end_times_seconds":[0.02,0.04]}}"#.utf8)
    }

    @Test func catalogIsTheFixtureInputAndLoads() throws {
        let data = try FixtureLoader.data("catalog/voice-lab.json")
        let inputs = try #require(Self.document()["inputs"] as? [String: String])
        #expect(inputs["shared/catalog/voice-lab.json"] == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        let catalog = try Self.catalog()
        #expect(catalog.entries.count == 18)
        #expect(catalog.entry(for: .elevenLabsDeleteClone, model: nil)?.formula == .zero)
        #expect(catalog.entry(for: .elevenLabsTextToSpeech, model: "eleven_v3")?.checked == "2026-10-25")
        #expect(catalog.entry(for: .falLipsync(endpoint: "fal-ai/sync-lipsync/v3"), model: nil)?.checked == "2026-10-26")
    }

    @Test func catalogDefectsAreRefused() throws {
        let original = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("catalog/voice-lab.json")) as? [String: Any])
        func refused(_ change: (inout [[String: Any]], inout [String: Any]) -> Void) throws -> Bool {
            var root = original
            var entries = try #require(root["entries"] as? [[String: Any]])
            change(&entries, &root)
            root["entries"] = entries
            return (try? VoiceLabPriceCatalog(data: JSONSerialization.data(withJSONObject: root))) == nil
        }
        #expect(try !refused { _, _ in })
        #expect(try refused { _, root in root["schema"] = "voxclip-voice-lab-prices/2" })
        #expect(try refused { entries, _ in entries[0]["usdParameters"] = ["perHour": 0.22] })
        #expect(try refused { entries, _ in entries[0]["usdParameters"] = ["perHour": "-0.22"] })
        #expect(try refused { entries, _ in entries[0]["unit"] = "character" })
        #expect(try refused { entries, _ in entries[0]["formula"] = "perDay" })
        #expect(try refused { entries, _ in entries[0]["creditsParameters"] = ["perMinute": "1000"] })
        #expect(try refused { entries, _ in entries[1].removeValue(forKey: "source") })
        #expect(try refused { entries, _ in entries[1]["note"] = "extra" })
        #expect(try refused { entries, _ in entries[9]["usdParameters"] = ["perCall": "1"] })
        // Two entries that could price one request: an exact duplicate, and a model-less entry beside model entries.
        #expect(try refused { entries, _ in entries.append(entries[4]) })
        #expect(try refused { entries, _ in var row = entries[4]; row.removeValue(forKey: "model"); entries.append(row) })
    }

    @Test func estimatesReplayEveryCase() throws {
        let catalog = try Self.catalog()
        for row in try Self.rows("estimates") {
            let id = row["id"] as? String ?? "?"
            let expected = try #require(row["expected"] as? [String: Any])
            let operation = try Self.operation(row["operation"])
            let estimate = { try VoiceLabPricing.estimate(operation: operation, model: row["model"] as? String, units: try #require(Self.number(row["units"])),
                                                          candidates: try #require(row["candidates"] as? Int),
                                                          characterMultiplier: Self.number(row["characterMultiplier"]), catalog: catalog) }
            if expected["error"] as? String == "invalidInput" {
                #expect(throws: VoiceLabError.invalidInput, "\(id)") { try estimate() }
                continue
            }
            let result = try estimate()
            #expect(result.provider == operation.provider && result.operation == operation.operation, "\(id)")
            Self.check(result, expected, id)
        }
    }

    @Test func providerPricesReplaceTheAmountThroughTheTypedHook() throws {
        for row in try Self.rows("providerPrices") {
            let id = row["id"] as? String ?? "?"
            let base = try #require(row["estimate"] as? [String: Any]), price = try #require(row["price"] as? [String: Any])
            let estimate = CostEstimate(provider: try #require(base["provider"] as? String), operation: try #require(base["operation"] as? String),
                                        units: try #require(Self.number(base["units"])), unit: try #require(base["unit"] as? String),
                                        usd: Self.amount(base["usd"]), credits: base["credits"] as? Int, basis: try #require(base["basis"] as? String))
            let live = VoiceLabProviderPrice(usd: try #require(Self.amount(price["usd"])), credits: price["credits"] as? Int,
                                             basis: try #require((price["basis"] as? String).flatMap(VoiceLabProviderPriceBasis.init(rawValue:))))
            let expected = try #require(row["expected"] as? [String: Any])
            if expected["error"] != nil {
                #expect(throws: VoiceLabError.invalidInput, "\(id)") { try VoiceLabPricing.applying(live, to: estimate) }
                continue
            }
            let result = try VoiceLabPricing.applying(live, to: estimate)
            #expect(result.provider == expected["provider"] as? String && result.operation == expected["operation"] as? String, "\(id)")
            Self.check(result, expected, id)
        }
    }

    @Test func formatsPresentationsAndButtonsReplay() throws {
        for row in try Self.rows("formats") {
            let usd = try #require(Self.amount(row["usd"]))
            #expect(VoiceLabCostPresentation.format(usd) == row["text"] as? String, "\(usd)")
            let estimate = CostEstimate(provider: "elevenlabs", operation: "textToSpeech", units: 1, unit: "character", usd: usd, basis: "list-2026-10-25")
            #expect(VoiceLabCostPresentation.kind(estimate, isLipSync: false, providerName: "ElevenLabs") == (try Self.kind(row["presentation"])), "\(usd)")
        }
        for row in try Self.rows("presentations") {
            let estimate = CostEstimate(provider: "fixture", operation: "fixture", units: 1, unit: "call", usd: Self.amount(row["usd"]), basis: "fixture")
            let lipSync = try #require(row["isLipSync"] as? Bool), provider = try #require(row["providerName"] as? String)
            let kind = VoiceLabCostPresentation.kind(estimate, isLipSync: lipSync, providerName: provider, cap: try Self.cap(row["cap"]))
            #expect(kind == (try Self.kind(row["expected"])), "\(row)")
        }
        for row in try Self.rows("buttons") {
            let estimate = CostEstimate(provider: "elevenlabs", operation: "fixture", units: 1, unit: "call", usd: Self.amount(row["usd"]), basis: "fixture")
            let lipSync = try #require(row["isLipSync"] as? Bool)
            let kind = VoiceLabCostPresentation.kind(estimate, isLipSync: lipSync, providerName: "ElevenLabs", cap: try Self.cap(row["cap"]))
            let action = try #require(row["action"] as? String)
            #expect(VoiceLabCostPresentation.buttonTitle(action, takes: row["takes"] as? Int, kind: kind) == row["text"] as? String)
        }
    }

    @Test func elevenLabsQuotesCarryCatalogEstimates() async throws {
        let models = Data(#"[{"model_id":"eleven_v3","can_do_text_to_speech":true,"languages":[{"language_id":"en"}],"model_rates":{"character_cost_multiplier":0.5}},{"model_id":"new_speech_model","can_do_text_to_speech":true,"languages":[{"language_id":"en"}]},{"model_id":"eleven_multilingual_sts_v2","can_do_voice_conversion":true,"languages":[{"language_id":"en"}],"model_rates":null}]"#.utf8)
        let plan = Data(#"{"tier":"starter","status":"active","character_count":0,"character_limit":10000,"can_use_instant_voice_cloning":true,"voice_slots_used":0,"voice_limit":10}"#.utf8)
        let voices = Data(#"{"voices":[{"voice_id":"own123","name":"Mine","category":"cloned","is_owner":true,"voice_verification":{"requires_verification":false,"is_verified":true}},{"voice_id":"stock123","name":"Stock","category":"premade","is_owner":false}],"has_more":false}"#.utf8)
        let sends = Mutex(0)
        let base = SpeechStubHTTP.register { request in
            switch request.url?.path {
            case "/v1/models": return (200, [:], models)
            case "/v1/user/subscription": return (200, [:], plan)
            case "/v2/voices": return (200, [:], voices)
            default: sends.withLock { $0 += 1 }; throw URLError(.badURL)
            }
        }
        let lab = ElevenLabsVoiceLab(keys: SpeechTestKeys(value: "synthetic-voice-lab-key"), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)),
                                     region: .eu, logger: SpeechTestLogger(), prices: try Self.catalog())
        _ = try await lab.models(); _ = try await lab.plan(); _ = try await lab.voices()
        let policy = OwnVoicePolicy(recordID: "record-1", cloneVoiceID: "own123", recordActive: true, providerConsentGranted: true, statementVerified: true, speakerMatched: true)
        let createPolicy = OwnVoicePolicy(recordID: "record-1", recordActive: true, providerConsentGranted: true, statementVerified: true, speakerMatched: true)
        let clone = VoiceLabCloneRequest(displayName: "My voice", language: "en", samples: [
            VoiceLabCloneSample(role: .consentStatement, wav: VoiceLabRequestFixtures.wav(rate: 8_000, frames: 40_000)),
            VoiceLabCloneSample(role: .training, wav: VoiceLabRequestFixtures.wav(rate: 8_000, frames: 40_000, fill: 1))
        ], createdAt: Date(timeIntervalSince1970: 1_793_000_000), removeBackgroundNoise: false)
        for row in try Self.rows("quotes") {
            let id = row["id"] as? String ?? "?", model = row["model"] as? String ?? ""
            let quote: VoiceLabQuote
            switch row["operation"] as? String {
            case "textToSpeech":
                quote = try await lab.prepareSynthesis(text: try #require(row["text"] as? String), modelID: model, voice: .stock(voiceID: "stock123"),
                                                       language: "en", options: VoiceLabSpeechOptions(seed: 7), requestID: UUID())
            case "voiceChange":
                let wav = try #require(row["wav"] as? [String: Any])
                quote = try await lab.prepareConversion(audio: VoiceLabRequestFixtures.wav(rate: try #require(wav["rate"] as? Int), frames: try #require(wav["frames"] as? Int)),
                                                        modelID: model, voice: .stock(voiceID: "stock123"), language: "en", seed: 7, cleanAudioOn: false, requestID: UUID())
            case "createClone": quote = try await lab.prepareClone(clone, policy: createPolicy, requestID: UUID())
            default: quote = try await lab.prepareDelete(voiceID: "own123", policy: policy, requestID: UUID())
            }
            let expected = try #require(row["expected"] as? [String: Any])
            #expect(quote.estimate.provider == expected["provider"] as? String && quote.estimate.operation == expected["operation"] as? String, "\(id)")
            Self.check(quote.estimate, expected, id)
        }
        // A run of takes uses the same discovered multiplier, for credits only; preparation and estimates send nothing billable.
        let run = try await lab.estimate(.textToSpeech, modelID: "eleven_v3", units: 60, candidates: 3)
        #expect(run.usd.map(VoiceLabMoney.canonical) == "0.0144" && run.credits == 90 && run.units == 180)
        #expect(sends.withLock { $0 } == 0)
    }

    @Test(arguments: ["0", "-1", "0.0099", "100.5", "\"0.5\"", "true", "null", "1e400"])
    func discoveryRefusesAMalformedCharacterMultiplier(_ value: String) async throws {
        let models = Data("[{\"model_id\":\"eleven_v3\",\"can_do_text_to_speech\":true,\"model_rates\":{\"character_cost_multiplier\":\(value)}}]".utf8)
        let base = SpeechStubHTTP.register { _ in (200, [:], models) }
        let lab = ElevenLabsVoiceLab(keys: SpeechTestKeys(value: "synthetic-voice-lab-key"), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)),
                                     region: .eu, logger: SpeechTestLogger(), prices: try Self.catalog())
        await #expect(throws: (any Error).self) { try await lab.models() }
    }

    @Test func rolloversUseTheLocalCalendarMonthAtTheStart() async throws {
        let ledger = try Self.ledgerSection()
        #expect(String(decoding: VoiceLabSpendDocument().encoded(), as: UTF8.self) == ledger["emptyFile"] as? String)
        for row in try Self.rows("rollovers", in: ledger) {
            let root = try Self.directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let offset = try #require(row["timeZoneOffsetSeconds"] as? Int)
            let zone = try #require(TimeZone(secondsFromGMT: offset))
            let spend = VoiceLabSpendLedger(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]), timeZone: zone)
            #expect(spend.url.path == root.appendingPathComponent("VoiceLab/spend.json").path)
            for step in try Self.rows("records", in: row) {
                let at = try VoiceLabRequestFixtures.date(try #require(step["at"] as? String))
                #expect(spend.month(of: at) == step["month"] as? String, "\(step)")
                let warning = await spend.record(try Self.spend(step), at: at)
                #expect(warning == nil)
            }
            #expect(try Self.text(spend.url) == row["ledger"] as? String, "\(row["id"] ?? "")")
            // Only VoiceLab itself is created, 0700 like the asset store's paid root; the ledger and its lock are 0600.
            let paid = spend.url.deletingLastPathComponent()
            #expect(try Self.mode(paid.path) == 0o700)
            #expect(try Self.mode(spend.url.path) == 0o600 && Self.mode(spend.url.path + ".lock") == 0o600)
            let names = try FileManager.default.contentsOfDirectory(atPath: paid.path).sorted()
            #expect(names == ["spend.json", "spend.json.lock"])
        }
    }

    @Test func freeActionsAreNeverRecorded() async throws {
        let free = try #require(Self.ledgerSection()["freeOnly"] as? [String: Any])
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let spend = VoiceLabSpendLedger(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]), timeZone: Self.utc)
        for step in try Self.rows("records", in: free) {
            let at = try VoiceLabRequestFixtures.date(try #require(step["at"] as? String))
            let warning = await spend.record(try Self.spend(step), at: at)
            #expect(warning == nil)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("VoiceLab").path))
        let document = await spend.read()
        #expect(document == VoiceLabSpendDocument())
    }

    @Test func twoConcurrentRecordersLoseNoUpdate() async throws {
        let concurrent = try #require(Self.ledgerSection()["concurrent"] as? [String: Any])
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("VoiceLab/spend.json")
        let at = try VoiceLabRequestFixtures.date(try #require(concurrent["at"] as? String))
        let count = try #require(concurrent["recordsPerWriter"] as? Int)
        let estimates = try Self.rows("writers", in: concurrent).map(Self.spend)
        let writers = estimates.count
        let shared = ConcurrentRecorders()
        await withTaskGroup(of: Void.self) { group in
            for estimate in estimates {
                // Separate ledger values open separate lock descriptors, as the App and the CLI would.
                let ledger = VoiceLabSpendLedger(url: url, timeZone: Self.utc)
                group.addTask {
                    // A barrier: no writer starts until every writer is running.
                    shared.arrived.withLock { $0 += 1 }
                    while shared.arrived.withLock({ $0 }) < writers { await Task.yield() }
                    for _ in 0..<count {
                        if let warning = await ledger.record(estimate, at: at) { shared.warnings.withLock { $0.append(warning) } }
                    }
                }
            }
        }
        #expect(shared.warnings.withLock { $0 }.isEmpty)
        #expect(try Self.text(url) == concurrent["ledger"] as? String)
    }

    /// Writers in one process try the lock in the order they asked for it. Before the line, a writer that recorded again
    /// at once took the lock straight back, and the other writer of `twoConcurrentRecordersLoseNoUpdate` sometimes timed
    /// out on a slow disk and lost its record. Here no process holds the lock, yet a later writer waits for an earlier
    /// one, then records once that one is done.
    @Test func aLaterWriterWaitsForEveryEarlierOne() async throws {
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("VoiceLab/spend.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("spend.json.lock")
        let turns = VoiceLabSpendTurns.shared(lock: lock)
        let earlier = turns.join(), later = turns.join()
        #expect(turns.isFirst(earlier) && !turns.isFirst(later))
        let estimate = try Self.spend(["provider": "elevenlabs", "usd": "0.01"])
        let at = try VoiceLabRequestFixtures.date("2026-10-27T12:00:00Z")
        let ledger = VoiceLabSpendLedger(url: url, timeZone: Self.utc, lockTimeout: .milliseconds(50))
        #expect(await ledger.record(estimate, at: at) == .lockTimedOut)
        turns.leave(earlier)
        #expect(turns.isFirst(later))
        #expect(await ledger.record(estimate, at: at) == .lockTimedOut)
        turns.leave(later)
        #expect(await ledger.record(estimate, at: at) == nil)
        #expect(await ledger.total(provider: "elevenlabs", at: at)?.usd == Self.amount("0.01"))
    }

    @Test func corruptLedgersAreMovedAsideAndAFreshLedgerStarts() async throws {
        let ledger = try Self.ledgerSection()
        let recovery = try #require(ledger["recoveryRecord"] as? [String: Any])
        let at = try VoiceLabRequestFixtures.date(try #require(recovery["at"] as? String))
        for row in try Self.rows("existing", in: ledger) {
            let id = row["id"] as? String ?? "?"
            let root = try Self.directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("spend.json")
            let bytes: Data
            if let encoded = row["contentBase64"] as? String {
                bytes = try #require(Data(base64Encoded: encoded))
            } else {
                bytes = Data(try #require(row["content"] as? String).utf8)
            }
            try bytes.write(to: url)
            let warning = await VoiceLabSpendLedger(url: url, timeZone: Self.utc).record(try Self.spend(recovery), at: at)
            let backups = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("spend.corrupt-") }
            if try #require(row["corrupt"] as? Bool) {
                let backup = try #require(backups.first)
                #expect(backups.count == 1 && backup.range(of: #"\Aspend\.corrupt-[0-9]{13}\.json\z"#, options: .regularExpression) != nil, "\(id)")
                #expect(warning == .replacedCorruptLedger(backupFileName: backup), "\(id)")
                #expect(try Data(contentsOf: root.appendingPathComponent(backup)) == bytes, "\(id)")
            } else {
                #expect(warning == nil && backups.isEmpty, "\(id)")
            }
            #expect(try Self.text(url) == row["ledger"] as? String, "\(id)")
        }
    }

    @Test func failuresReturnTypedWarningsAndRecordNothing() async throws {
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("spend.json")
        let ledger = VoiceLabSpendLedger(url: url, timeZone: Self.utc, lockTimeout: .milliseconds(50))
        let estimate = CostEstimate(provider: "elevenlabs", operation: "audioIsolation", units: 180, unit: "second", usd: Decimal(string: "0.36"), credits: 3_000, basis: "list-2026-10-25")
        // Another holder of the lock: a writer gives up after lockTimeout, a reader after readTimeout, and nothing changes.
        let holder = open(url.path + ".lock", O_RDWR | O_CREAT, 0o600)
        #expect(holder >= 0 && flock(holder, LOCK_EX | LOCK_NB) == 0)
        let timedOut = await ledger.record(estimate, at: Date())
        #expect(timedOut == .lockTimedOut)
        let unread = await ledger.read()
        #expect(unread == nil)
        let blindCheck = await ledger.wouldCross(cap: 0, provider: "elevenlabs", estimate: estimate, at: Date())
        #expect(!blindCheck)
        // Cancelling the task ends the wait at once instead of after a long timeout.
        let patient = VoiceLabSpendLedger(url: url, timeZone: Self.utc, lockTimeout: .seconds(60))
        let waiting = Task { await patient.record(estimate, at: Date()) }
        try await Task.sleep(for: .milliseconds(50))
        let cancelledAt = ContinuousClock.now
        waiting.cancel()
        let cancelled = await waiting.value
        #expect(cancelled == .cancelled)
        #expect(ContinuousClock.now - cancelledAt < .seconds(5))
        close(holder)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        var invalid = estimate
        invalid.provider = "Eleven Labs"
        let badProvider = await ledger.record(invalid, at: Date())
        #expect(badProvider == .invalidEstimate)
        invalid = estimate
        invalid.usd = -1
        let negative = await ledger.record(invalid, at: Date())
        #expect(negative == .invalidEstimate)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // A file where the paid root belongs, and a missing data folder, which the ledger never creates.
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        let notDirectory = await VoiceLabSpendLedger(url: blocked.appendingPathComponent("spend.json")).record(estimate, at: Date())
        #expect(notDirectory == .writeFailed)
        let missing = root.appendingPathComponent("missing-data")
        let orphan = VoiceLabSpendLedger(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": missing.path]))
        let noData = await orphan.record(estimate, at: Date())
        #expect(noData == .writeFailed)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        let recorded = await ledger.record(estimate, at: Date())
        #expect(recorded == nil)
        let total = await ledger.total(provider: "elevenlabs", at: Date())
        #expect(total == VoiceLabSpendTotal(usd: Decimal(string: "0.36")!, unknownCount: 0))
    }

    @Test func readOnlyFoldersFailAtOnce() async throws {
        let root = try Self.directory()
        let paid = root.appendingPathComponent("VoiceLab")
        defer {
            chmod(paid.path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: paid, withIntermediateDirectories: false)
        let ledger = VoiceLabSpendLedger(url: paid.appendingPathComponent("spend.json"), timeZone: Self.utc, lockTimeout: .seconds(60))
        let estimate = CostEstimate(provider: "elevenlabs", operation: "audioIsolation", units: 180, unit: "second", usd: Decimal(string: "0.36"), credits: 3_000, basis: "list-2026-10-25")
        // Without a lock file the lock cannot be created; with one, the temporary file cannot. Neither waits for the lock.
        let started = ContinuousClock.now
        #expect(chmod(paid.path, 0o500) == 0)
        let noLock = await ledger.record(estimate, at: Date())
        #expect(noLock == .writeFailed)
        #expect(chmod(paid.path, 0o700) == 0)
        #expect(FileManager.default.createFile(atPath: paid.appendingPathComponent("spend.json.lock").path, contents: nil))
        #expect(chmod(paid.path, 0o500) == 0)
        let noTemporary = await ledger.record(estimate, at: Date())
        #expect(noTemporary == .writeFailed)
        #expect(ContinuousClock.now - started < .seconds(5))
        let names = try FileManager.default.contentsOfDirectory(atPath: paid.path)
        #expect(names == ["spend.json.lock"])
    }

    @Test func theServiceRecordsEachAcceptedActionOnce() async throws {
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = VoiceLabSpendLedger(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]), timeZone: Self.utc)
        let audio = Data(repeating: 0, count: 4_800), speech = Self.speech(audio)
        let status = Mutex(200), sends = Mutex(0), slow = Mutex(false), entered = Mutex(false), released = Mutex(false)
        let lab = try await Self.discoveredLab(spend: ledger) { request in
            sends.withLock { $0 += 1 }
            let code = status.withLock { $0 }
            switch request.url?.path {
            case "/v1/voices/add": return (200, [:], Data(#"{"voice_id":"new123","requires_verification":false}"#.utf8))
            case "/v1/voices/own123": return (200, [:], Data(#"{"status":"ok"}"#.utf8))
            case "/v1/text-to-speech/stock123/with-timestamps":
                if slow.withLock({ $0 }) {
                    entered.withLock { $0 = true }
                    // Hold the reply until the test has cancelled, so a slow runner cannot deliver the status line first.
                    let deadline = Date().addingTimeInterval(10)
                    while !released.withLock({ $0 }), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                }
                return (code, [:], code == 200 ? speech : Data(#"{"detail":"busy"}"#.utf8))
            case "/v1/voice-changer/stock123": return (code, ["Content-Type": "audio/pcm"], code == 200 ? audio : Data("busy".utf8))
            default: throw URLError(.badURL)
            }
        }
        let voice = VoiceLabVoiceChoice.stock(voiceID: "stock123"), options = VoiceLabSpeechOptions(seed: 7)
        let input = VoiceLabRequestFixtures.wav(rate: 24_000, frames: 24_000)
        @Sendable func speak(_ id: UUID, approved: Bool = true) async throws -> VoiceLabAudioResult {
            let quote = try await lab.prepareSynthesis(text: "Hi", modelID: "eleven_v3", voice: voice, language: "en", options: options, requestID: id)
            return try await lab.synthesize(text: "Hi", modelID: "eleven_v3", voice: voice, language: "en", options: options, requestID: id,
                                            authorization: VoiceLabAuthorization(quote: quote, approved: approved))
        }
        @Sendable func change(_ id: UUID) async throws -> VoiceLabAudioResult {
            let quote = try await lab.prepareConversion(audio: input, modelID: "eleven_multilingual_sts_v2", voice: voice, language: "en", seed: 7,
                                                        cleanAudioOn: false, requestID: id)
            return try await lab.convert(audio: input, modelID: "eleven_multilingual_sts_v2", voice: voice, language: "en", seed: 7, cleanAudioOn: false,
                                         requestID: id, authorization: VoiceLabAuthorization(quote: quote, approved: true))
        }

        // Creating and deleting a voice are accepted but free, so they touch nothing.
        let createPolicy = OwnVoicePolicy(recordID: "record-1", recordActive: true, providerConsentGranted: true, statementVerified: true, speakerMatched: true)
        let ownPolicy = OwnVoicePolicy(recordID: "record-1", cloneVoiceID: "own123", recordActive: true, providerConsentGranted: true, statementVerified: true, speakerMatched: true)
        let clone = VoiceLabCloneRequest(displayName: "My voice", language: "en", samples: [
            VoiceLabCloneSample(role: .consentStatement, wav: VoiceLabRequestFixtures.wav(rate: 8_000, frames: 40_000)),
            VoiceLabCloneSample(role: .training, wav: VoiceLabRequestFixtures.wav(rate: 8_000, frames: 40_000, fill: 1))
        ], createdAt: Date(timeIntervalSince1970: 1_793_000_000), removeBackgroundNoise: false)
        let cloneID = UUID(), deleteID = UUID()
        let cloneQuote = try await lab.prepareClone(clone, policy: createPolicy, requestID: cloneID)
        let created = try await lab.createOwnClone(clone, policy: createPolicy, requestID: cloneID, authorization: VoiceLabAuthorization(quote: cloneQuote, approved: true))
        let deleteQuote = try await lab.prepareDelete(voiceID: "own123", policy: ownPolicy, requestID: deleteID)
        let deleted = try await lab.deleteOwnClone(voiceID: "own123", policy: ownPolicy, requestID: deleteID, authorization: VoiceLabAuthorization(quote: deleteQuote, approved: true))
        #expect(cloneQuote.estimate.usd == 0 && deleteQuote.estimate.usd == 0)
        #expect(created.spendWarning == nil && deleted.spendWarning == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("VoiceLab").path))

        // A TTS take and a voice change are each recorded once, at the approved quote's estimate.
        let spoken = try await speak(UUID()), changed = try await change(UUID())
        #expect(spoken.spendWarning == nil && changed.spendWarning == nil)
        let ttsEstimate = try await lab.estimate(.textToSpeech, modelID: "eleven_v3", units: 2)
        let conversionEstimate = try await lab.estimate(.voiceChange, modelID: "eleven_multilingual_sts_v2", units: 1)
        let tts = try #require(ttsEstimate.usd), conversion = try #require(conversionEstimate.usd)
        let read = await ledger.read()
        let recorded = try #require(read)
        #expect(recorded.months.count == 1)
        #expect(recorded.months.values.first == ["elevenlabs": VoiceLabSpendTotal(usd: tts + conversion)])

        // A refused authorization sends nothing; a 4xx or 5xx reply and a cancellation before the reply record nothing.
        let sent = sends.withLock { $0 }
        await #expect(throws: VoiceLabError.consentRequired) { try await speak(UUID(), approved: false) }
        #expect(sends.withLock { $0 } == sent)
        for code in [401, 429, 500] {
            status.withLock { $0 = code }
            await #expect(throws: VoiceLabError.self) { try await speak(UUID()) }
            await #expect(throws: VoiceLabError.self) { try await change(UUID()) }
        }
        status.withLock { $0 = 200 }
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await speak(UUID())
        }
        do { _ = try await early.value; Issue.record("Expected cancellation") }
        catch VoiceLabError.cancelled {}
        catch is CancellationError {}
        slow.withLock { $0 = true }
        let late = Task { try await speak(UUID()) }
        let deadline = ContinuousClock.now + .seconds(10)
        while !entered.withLock({ $0 }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        late.cancel()
        await #expect(throws: VoiceLabError.cancelled) { try await late.value }
        released.withLock { $0 = true }
        #expect(sends.withLock { $0 } == sent + 7)
        let after = await ledger.read()
        #expect(after == recorded)
    }

    @Test func theTwoHundredStatusLineIsRecordedOnceWhateverTheBodyDoes() async throws {
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = VoiceLabSpendLedger(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]), timeZone: Self.utc)
        let audio = Data(repeating: 0, count: 4_800), speech = Self.speech(audio)
        // Every TTS reply is a 200: whole, stalled after its first 64 bytes, or declaring more than the 32 MiB limit. The
        // content type keeps URLSession from holding the head back to sniff the first 512 bytes.
        let stall = Mutex(false), oversized = Mutex(false)
        let lab = try await Self.discoveredLab(spend: ledger, streaming: { request in
            guard request.url?.path == "/v1/text-to-speech/stock123/with-timestamps" else { throw URLError(.badURL) }
            let json = ["Content-Type": "application/json"]
            if oversized.withLock({ $0 }) {
                return SpeechStubHTTP.Reply(status: 200, headers: json.merging(["Content-Length": String(32 * 1_024 * 1_024 + 1)]) { $1 }, body: speech)
            }
            if stall.withLock({ $0 }) { return SpeechStubHTTP.Reply(status: 200, headers: json, body: speech.prefix(64), stalls: true) }
            return SpeechStubHTTP.Reply(status: 200, headers: json, body: speech)
        })
        let voice = VoiceLabVoiceChoice.stock(voiceID: "stock123"), options = VoiceLabSpeechOptions(seed: 7)
        @Sendable func speak() async throws -> VoiceLabAudioResult {
            let id = UUID()
            let quote = try await lab.prepareSynthesis(text: "Hi", modelID: "eleven_v3", voice: voice, language: "en", options: options, requestID: id)
            return try await lab.synthesize(text: "Hi", modelID: "eleven_v3", voice: voice, language: "en", options: options, requestID: id,
                                            authorization: VoiceLabAuthorization(quote: quote, approved: true))
        }
        let estimate = try await lab.estimate(.textToSpeech, modelID: "eleven_v3", units: 2)
        let take = try #require(estimate.usd)
        func total() async -> Decimal { await ledger.read()?.months.values.first?["elevenlabs"]?.usd ?? 0 }
        func awaitTotal(_ takes: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while await total() != take * Decimal(takes), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        }

        // Cancelled after the 200 head and the first 64 bytes, while the rest never comes: the record started with the
        // status line and stands.
        stall.withLock { $0 = true }
        let cancelled = Task { try await speak() }
        try await awaitTotal(1)
        cancelled.cancel()
        await #expect(throws: VoiceLabError.cancelled) { try await cancelled.value }
        #expect(await total() == take)

        // A Content-Length over the limit.
        stall.withLock { $0 = false }
        oversized.withLock { $0 = true }
        await #expect(throws: VoiceLabError.responseTooLarge) { try await speak() }
        #expect(await total() == take * 2)

        // Cancelled after the last byte: the reply is kept and recorded once.
        oversized.withLock { $0 = false }
        await lab.runAfterLastByte { withUnsafeCurrentTask { $0?.cancel() } }
        let late = Task { try await speak() }
        let kept = try await late.value
        await lab.runAfterLastByte(nil)
        #expect(late.isCancelled)
        #expect(kept.pcm == audio && kept.spendWarning == nil)
        #expect(await total() == take * 3)
    }

    @Test func aLedgerThatCannotWriteKeepsTheResultAndCarriesTheWarning() async throws {
        let root = try Self.directory()
        defer {
            chmod(root.path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }
        let ledger = VoiceLabSpendLedger(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]), timeZone: Self.utc)
        let audio = Data(repeating: 0, count: 4_800), speech = Self.speech(audio)
        let lab = try await Self.discoveredLab(spend: ledger) { request in
            guard request.url?.path == "/v1/text-to-speech/stock123/with-timestamps" else { throw URLError(.badURL) }
            return (200, [:], speech)
        }
        let voice = VoiceLabVoiceChoice.stock(voiceID: "stock123"), options = VoiceLabSpeechOptions(seed: 7), id = UUID()
        let quote = try await lab.prepareSynthesis(text: "Hi", modelID: "eleven_v3", voice: voice, language: "en", options: options, requestID: id)
        // A read-only data folder: VoiceLab cannot be created.
        #expect(chmod(root.path, 0o500) == 0)
        let spoken = try await lab.synthesize(text: "Hi", modelID: "eleven_v3", voice: voice, language: "en", options: options, requestID: id,
                                              authorization: VoiceLabAuthorization(quote: quote, approved: true))
        #expect(spoken.pcm == audio)
        #expect(spoken.spendWarning == .writeFailed && spoken.receipt.spendWarning == .writeFailed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func capCrossingAndTheCapSentence() async throws {
        let cap = try #require(Self.ledgerSection()["cap"] as? [String: Any])
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let offset = try #require(cap["timeZoneOffsetSeconds"] as? Int)
        let zone = try #require(TimeZone(secondsFromGMT: offset))
        let ledger = VoiceLabSpendLedger(url: root.appendingPathComponent("spend.json"), timeZone: zone)
        for row in try Self.rows("existing", in: cap) {
            let at = try VoiceLabRequestFixtures.date(try #require(row["at"] as? String))
            let warning = await ledger.record(try Self.spend(row), at: at)
            #expect(warning == nil)
        }
        for row in try Self.rows("checks", in: cap) {
            let limit = try #require(Self.amount(row["cap"])), provider = try #require(row["provider"] as? String)
            let at = try VoiceLabRequestFixtures.date(try #require(row["at"] as? String))
            let crosses = await ledger.wouldCross(cap: limit, provider: provider, estimate: try Self.spend(row), at: at)
            #expect(crosses == row["wouldCross"] as? Bool, "\(row)")
        }
        for row in try Self.rows("sentences", in: cap) {
            let amount = try #require(Self.amount(row["cap"])), provider = try #require(row["providerName"] as? String)
            #expect(VoiceLabCostPresentation.capWarning(cap: amount, providerName: provider) == row["text"] as? String)
        }
    }

    @Test func monthlyCapSettingValidatesAndRoundTrips() throws {
        for row in try Self.rows("settings") {
            let key = try #require(row["key"] as? String)
            let value: JSONValue = switch row["value"] {
            case let text as String: .string(text)
            case let number as NSNumber: .number(number.doubleValue)
            default: .null
            }
            #expect(SettingsDocument.isKnownKey(key))
            let settings = SettingsDocument(values: [key: value])
            if try #require(row["valid"] as? Bool) { try settings.validate() } else { #expect(throws: VoxClipError.self, "\(row)") { try settings.validate() } }
        }
        var settings = SettingsDocument()
        try settings.setVoiceLabMonthlyCap(Decimal(string: "12.50"), for: "elevenlabs")
        #expect(settings.values["voiceLab.monthlyCapUsd.elevenlabs"] == .string("12.5"))
        #expect(settings.voiceLabMonthlyCap(for: "elevenlabs") == Decimal(string: "12.5") && settings.voiceLabMonthlyCap(for: "fal") == nil)
        let decoded = try JSONDecoder().decode(SettingsDocument.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        try decoded.validate()
        #expect(throws: VoiceLabError.invalidInput) { try settings.setVoiceLabMonthlyCap(Decimal(string: "12.345"), for: "elevenlabs") }
        #expect(throws: VoiceLabError.invalidInput) { try settings.setVoiceLabMonthlyCap(-1, for: "elevenlabs") }
        #expect(throws: VoiceLabError.invalidInput) { try settings.setVoiceLabMonthlyCap(1, for: "Eleven Labs") }
        try settings.setVoiceLabMonthlyCap(nil, for: "elevenlabs")
        #expect(settings.values.isEmpty)
    }
}

/// The concurrent recorders' barrier and warnings, shared by reference. Hosted Xcode 26 refuses to send a task-group
/// closure that captures a local `Mutex`.
private final class ConcurrentRecorders: Sendable {
    let arrived = Mutex(0)
    let warnings = Mutex<[VoiceLabSpendWarning]>([])
}
#endif
