import Foundation
import Testing
@testable import VoxClipCore

@Test func sharedFixturesResolveFromSource() throws {
    let root = try FixtureLoader.sharedRoot(environment: [:])
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("schemas/project.schema.json").path))
    let override = try FixtureLoader.sharedRoot(environment: ["VOXCLIP_SHARED_DIR": root.path])
    #expect(override == root)
}

@Test(arguments: ["interview-take.voxclip", "clip-from-long-take.voxclip"])
func portableProjectRoundTrip(name: String) throws {
    let data = try FixtureLoader.data("fixtures/projects/" + name)
    let document = try ProjectJSON.decode(data)
    let encoded = try ProjectJSON.encode(document)
    #expect(try ProjectJSON.decode(encoded) == document)
    // The examples store whole seconds, which a save writes once in canonical form (editing §10.1).
    let stored = try JSONEncoder().encode(TimestampWireRule.canonicalTimestamps(JSONDecoder().decode(JSONValue.self, from: data)))
    let original = try JSONSerialization.jsonObject(with: stored) as? NSDictionary
    let result = try JSONSerialization.jsonObject(with: encoded) as? NSDictionary
    #expect(original == result)
}

@Test func allCaptionStylesDecodeAndRetainDefaults() throws {
    let root = try FixtureLoader.sharedRoot()
    let directory = root.appendingPathComponent("caption-styles/styles", isDirectory: true)
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
    #expect(files.count == 19)
    for url in files {
        let data = try Data(contentsOf: url)
        let style = try JSONDecoder().decode(CaptionStyle.self, from: data)
        #expect(style.schemaVersion == 1)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let font = object?["font"] as? [String: Any]
        let features = font?["features"] as? [String: Any]
        #expect(style.font.features.kern == (features?["kern"] as? Bool ?? true))
        #expect(try JSONDecoder().decode(CaptionStyle.self, from: JSONEncoder().encode(style)) == style)
    }
}

@Test func errorsExposeEveryArchitectureCode() {
    #expect(VoxClipErrorCode.allCases.count == 32)
    #expect(VoxClipError.cancelled.exitCode == 6)
    #expect(VoxClipError.modelMissing("model").exitCode == 7)
    #expect(VoxClipError.everythingCut.exitCode == 5)
    #expect(VoxClipError.notImplemented("mac-ai").errorDescription?.contains("mac-ai") == true)
}

@Test func versionsUseNumericComponentsAndPrereleases() {
    #expect(compareVersions("1.2", "1.2.0") == .orderedSame)
    #expect(compareVersions("1.10", "1.9") == .orderedDescending)
    #expect(compareVersions("v1.2.0-beta", "1.2") == .orderedAscending)
}

@Test func redactorSanitizesWithoutMutatingSafeDiagnostics() {
    var redactor = Redactor(homeDirectory: "/Users/example")
    let known = String(repeating: "session", count: 3)
    redactor.register(secret: known)
    #expect(redactor.redact(known) == "[REDACTED]")
    #expect(redactor.redact("Authorization: Bearer abc.def.ghi") == "Authorization: Bearer [REDACTED]")
    #expect(redactor.redact("GET https://example.com/?key=placeholder&alt=json") == "GET https://example.com/?key=[REDACTED]&alt=json")
    #expect(redactor.redact("{\"client_secret\":\"placeholder\"}") == "{\"client_secret\":\"[REDACTED]\"}")
    #expect(redactor.redact("/Users/example/Movies/take.mov failed") == "~/Movies/take.mov failed")
    #expect(redactor.redact("status 401 from api.elevenlabs.io") == "status 401 from api.elevenlabs.io")
}

@Test func redactorFollowsSharedFixture() throws {
    let document = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/redaction/cases.json")) as? [String: Any])
    #expect(document["schema"] as? String == "voxclip-redaction-fixture/1")
    // Windows Core checks the same list, so both platforms run identical patterns in the same order.
    let rules = try #require(document["rules"] as? [[String: String]])
    #expect(rules.map { [$0["pattern"] ?? "", $0["template"] ?? ""] } == Redactor.rules.map { [$0.pattern, $0.template] })
    let cases = try #require(document["cases"] as? [[String: String]])
    #expect(cases.count == 124)
    for row in cases {
        let input = try #require(row["input"]), output = try #require(row["output"])
        #expect(Redactor(homeDirectory: row["home"] ?? "").redact(input) == output, "\(input)")
    }
}

/// Rule 5 tries a JWT only at the start of a base64url run, so 1 MB of "eyJ" is scanned once; the bound is generous.
@Test func redactionStaysLinearOnDenseJWTPrefixes() {
    let input = String(repeating: "eyJ", count: 350_000)
    var output = ""
    let elapsed = ContinuousClock().measure { output = Redactor().redact(input) }
    let unchanged = output == input
    #expect(unchanged)
    #expect(elapsed < .seconds(10), "\(elapsed)")
}

/// Label chains, nested labels, scheme repeats and quoted values full of labels, 1 MB each, are scanned in linear time
/// and never fail closed; the bound is generous.
@Test func redactionStaysLinearOnLabelRuns() {
    for (head, unit) in [("", "token:"), ("", "password: token: secret: "), ("token: ", "Bearer "), ("", "token=a=\""), ("token: a=\"", "password x ")] {
        let input = head + String(repeating: unit, count: 1_000_000 / unit.count)
        var output = ""
        let elapsed = ContinuousClock().measure { output = Redactor().redact(input) }
        #expect(output != "[REDACTED]", "\(unit) failed closed")
        #expect(elapsed < .seconds(10), "\(unit) \(elapsed)")
    }
}

/// Rule 5's open-ended key shapes are a bounded lookahead and a `+` loop, so a 1,000,000-character key does not stop ICU
/// and the key after it is still redacted.
@Test func keyShapesRedactMillionCharacterRuns() {
    for prefix in ["sk-ant-", "sk-", "sk-proj-", "xai-", "sk_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_"] {
        let input = prefix + String(repeating: "a", count: 1_000_000) + " " + prefix + String(repeating: "b", count: 40)
        #expect(Redactor().redact(input) == "[REDACTED] [REDACTED]", "\(prefix)")
    }
    // A JWT segment holds at most 8,192 characters: a longer header is no JWT, and a longer signature is replaced up
    // to its first 8,192 characters.
    let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJl", long = "eyJ" + String(repeating: "a", count: 1_000_000) + ".x.y"
    #expect(Redactor().redact(long + " " + jwt) == long + " [REDACTED]")
    #expect(Redactor().redact("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0." + String(repeating: "s", count: 10_000))
        == "[REDACTED]" + String(repeating: "s", count: 1_808))
    // Rule 6 replaces a JWT glued after a signature that filled its 8,192 characters.
    #expect(Redactor().redact("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0." + String(repeating: "s", count: 8_192) + jwt) == "[REDACTED][REDACTED]")
}

/// On an open counted loop, ICU stops with an internal error once the loop's backtracking stack overflows: from about
/// 125,000 to 500,000 characters, depending on the rest of the pattern (153,863 for main's rule 5). stringByReplacingMatches
/// then returns the text unchanged, both keys included. Redactor.apply reports the error, so redact fails closed.
@Test func icuInternalErrorFailsClosed() throws {
    let input = "sk-" + String(repeating: "a", count: 1_000_000) + " sk-" + String(repeating: "b", count: 24)
    let openLoop = try NSRegularExpression(pattern: "sk-[A-Za-z0-9_-]{20,}")
    let range = NSRange(location: 0, length: (input as NSString).length)
    #expect(openLoop.stringByReplacingMatches(in: input, range: range, withTemplate: "[REDACTED]") == input)
    #expect(Redactor.apply([(openLoop, "[REDACTED]")], to: input) == nil)
    #expect(Redactor.apply([(openLoop, "[REDACTED]")], to: "sk-" + String(repeating: "b", count: 24)) == "[REDACTED]")
}

@Test func providerKeysRedactWhetherOrNotRegistered() {
    let fal = "6f1c2d3e-4a5b-4c6d-8e7f-90a1b2c3d4e5:0f1e2d3c4b5a69788796a5b4c3d2e1f0", sync = "3f9a1c0e-7b2d-4e8f-a6c5-1d2e3f4a5b6c"
    let registered = Redactor(knownSecrets: [fal, sync])
    for redactor in [Redactor(), registered] {
        #expect(redactor.redact("Authorization: Key \(fal)") == "Authorization: Key [REDACTED]")
        #expect(redactor.redact("authorization: key \(fal) next") == "authorization: key [REDACTED] next")
        #expect(redactor.redact("{\"authorization\":\"Key \(fal)\"}") == "{\"authorization\":\"Key [REDACTED]\"}")
        #expect(redactor.redact("x-api-key: \(sync)") == "x-api-key: [REDACTED]")
    }
}

@Test func voiceLabCannotBeWrittenIntoSchemaOne() throws {
    var project = try ProjectJSON.decode(FixtureLoader.data("fixtures/projects/interview-take.voxclip"))
    project.voiceLab.segments = [try ProjectJSON.decode(FixtureLoader.data("fixtures/voice-lab/passage-project.voxclip")).voiceLab.segments[0]]
    #expect(throws: VoiceLabProjectError.invalidSegment) { try ProjectJSON.encode(project) }
}

@Test func isolatedPathsDoNotTouchUserData() {
    let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": "/tmp/voxclip-contract-test"], home: URL(fileURLWithPath: "/Users/example"))
    #expect(locations.logs.path == "/tmp/voxclip-contract-test/Logs")
    #expect(locations.settings.path == "/tmp/voxclip-contract-test/settings.json")
}

@Test func projectStoreRejectsMissingInput() async {
    let store: any ProjectStore = JSONProjectStore()
    await #expect(throws: VoxClipError.projectUnreadable("Invalid project document")) {
        _ = try await store.load(from: URL(fileURLWithPath: "/tmp/not-a-project.voxclip"))
    }
}

@Test func settingsPreserveUnknownRootKeys() throws {
    let data = Data(#"{"schema":"voxclip-settings/1","future.setting":{"enabled":true}}"#.utf8)
    let settings = try JSONDecoder().decode(SettingsDocument.self, from: data)
    let encoded = try JSONEncoder().encode(settings)
    #expect(try JSONSerialization.jsonObject(with: data) as? NSDictionary == JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
}

@Test func nullableCaptionDefaultsRemainDistinctFromOmission() throws {
    let explicitNull = Data(#"{"maxWords":3,"maxLines":2,"maxLineWidthW":0.8,"breakOnGapSec":null}"#.utf8)
    let absent = Data(#"{"maxWords":3,"maxLines":2,"maxLineWidthW":0.8}"#.utf8)
    #expect(try JSONDecoder().decode(CaptionLayout.self, from: explicitNull).breakOnGapSec == nil)
    #expect(try JSONDecoder().decode(CaptionLayout.self, from: absent).breakOnGapSec == 0.6)
}

@Test func canonicalCandidatesKeepFractionalIndicesForFinalizer() throws {
    let data = Data(#"{"title":"Example","reason":"Test","score":7.5,"start_word":1.5,"end_word":4}"#.utf8)
    let candidate = try JSONDecoder().decode(ClipCandidate.self, from: data)
    #expect(candidate.startWord == 1.5)
    #expect(candidate.score == 7.5)
}

@Test func missingRequiredNullableWordFieldIsRejected() throws {
    let data = Data(#"{"id":"w1","text":"word","kind":"word","start":0,"end":1,"rawStart":null,"rawEnd":null,"conf":null,"timing":"native"}"#.utf8)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(TimedWord.self, from: data) }
}

@Test func canonicalEngineAndTimingVocabularyMatchSharedSchemas() throws {
    let engine = EngineRef(id: .whispercpp, modelId: "small", modelSha256: String(repeating: "0", count: 64), engineVersion: "whisper.cpp 1.9.5 (b5454)")
    let data = try JSONEncoder().encode(engine)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == Set(["id", "modelId", "modelSha256", "engineVersion", "locale"]))
    #expect(object["modelId"] as? String == "small")
    #expect(object["locale"] is NSNull)
    #expect(try JSONDecoder().decode(EngineRef.self, from: data) == engine)
    let schema = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("schemas/timed-word.schema.json")) as? [String: Any])
    let properties = try #require(schema["properties"] as? [String: Any])
    let timing = try #require(properties["timing"] as? [String: Any])
    let values = try #require(timing["enum"] as? [String])
    #expect(Set(TimingSource.allCases.map(\.rawValue)) == Set(values))
    #expect(PIPELINE_VERSION == 1)
}
