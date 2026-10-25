import Foundation
import Testing
import VoxClipCore

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
    let original = try JSONSerialization.jsonObject(with: data) as? NSDictionary
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

@Test func voiceLabCannotBeWrittenIntoSchemaOne() throws {
    var project = try ProjectJSON.decode(FixtureLoader.data("fixtures/projects/interview-take.voxclip"))
    project.voiceLab.segments = [.object([:])]
    #expect(throws: VoxClipError.self) { try ProjectJSON.encode(project) }
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
