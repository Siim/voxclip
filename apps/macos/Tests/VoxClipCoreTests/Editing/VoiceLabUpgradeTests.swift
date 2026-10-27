import Foundation
import Testing
@testable import VoxClipCore

@Suite struct VoiceLabUpgradeTests {
    private func project(_ path: String) throws -> Project { try JSONProjectStore.decode(FixtureLoader.data(path)) }
    private func extendedV1() throws -> Project {
        var v1 = try project("fixtures/projects/interview-take.voxclip")
        v1.extensions = ["org.example.fork": .object(["nested": .array([.number(7), .bool(true)]), "text": .string("õäöü")])]
        return v1
    }
    private func segmentFreeV2() throws -> Project {
        var v2 = try project("fixtures/voice-lab/passage-project.voxclip")
        v2.voiceLab.segments = []
        v2.voiceLab.assets = [v2.voiceLab.assets![0]]
        return v2
    }
    /// The shared voice-lab source with an empty v1 Voice Lab layer.
    private func voiceLabV1() throws -> Project {
        var v1 = try project("fixtures/voice-lab/passage-render-v3.voxclip")
        v1.schemaVersion = 1
        v1.voiceLab = ProjectVoiceLab()
        return v1
    }
    private func take(_ name: String) throws -> (segment: VoiceLabSegment, assets: [VoiceLabAsset]) {
        let source = try project("fixtures/voice-lab/\(name).voxclip")
        return (source.voiceLab.segments[0], source.voiceLab.assets ?? [])
    }
    private func voice(_ id: String = "voice-fixture", provider: String = "elevenlabs", voiceId: String = "fixture-voice",
                       consent: String = "consent-fixture", name: String = "Fixture voice", status: VoiceLabVoiceStatus = .active) -> VoiceLabVoiceReference {
        VoiceLabVoiceReference(id: id, provider: provider, voiceId: voiceId, consentRecordId: consent, displayName: name, status: status)
    }
    private func upgradeCases() throws -> FixtureValue {
        FixtureValue(try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/voice-lab/upgrade-cases.json")))
    }
    private func encoded(_ value: FixtureValue) throws -> Data { try JSONEncoder().encode(value.value) }
    /// Sorted-key JSON whose numbers are binary64 values, the comparison form in upgrade-README.md. `rewritingTimestamps`
    /// writes stored timestamps as a save does (editing §10.1): expected projects keep their source fixtures' whole seconds.
    private func canonical(_ data: Data, rewritingTimestamps: Bool = false) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        return String(decoding: try encoder.encode(rewritingTimestamps ? TimestampWireRule.canonicalTimestamps(value) : value), as: UTF8.self)
    }
    /// The `videoRecipes` entry for one mode in upgrade-cases.json; the fields a mode does not use stay nil.
    private func video(_ mode: VoiceLabVideoMode, outputSamples: Int64 = 48_000, retimeFactor: Double? = nil, zoom: Double? = nil,
                       faceX: Double? = nil, faceY: Double? = nil, assetId: String? = nil, provider: String? = nil, model: String? = nil,
                       requestId: String? = nil, windowStartSample: Int64? = nil, windowEndSample: Int64? = nil, syncMode: String? = nil) -> VoiceLabVideoRecipe {
        VoiceLabVideoRecipe(mode: mode, sourceStartSample: 48_000, sourceEndSample: 96_000, outputSamples: outputSamples, retimeFactor: retimeFactor,
                            zoom: zoom, faceX: faceX, faceY: faceY, assetId: assetId, provider: provider, model: model, requestId: requestId,
                            windowStartSample: windowStartSample, windowEndSample: windowEndSample, syncMode: syncMode)
    }
    /// `value` with `edit` applied to the `video` object of every candidate recipe.
    private func withRecipeVideos(_ value: JSONValue, _ edit: ([String: JSONValue]) -> [String: JSONValue]) -> JSONValue {
        switch value {
        case .object(var object):
            if case .object(var recipe)? = object["recipe"], case .object(let video)? = recipe["video"] {
                recipe["video"] = .object(edit(video))
                object["recipe"] = .object(recipe)
            }
            return .object(object.mapValues { withRecipeVideos($0, edit) })
        case .array(let array): return .array(array.map { withRecipeVideos($0, edit) })
        default: return value
        }
    }
    /// Replays one shared case and returns the saved project JSON, or the name of the error its last step threw.
    /// A case without steps returns the error that loading its input threw.
    private func replay(_ item: FixtureValue, in cases: FixtureValue) throws -> (json: Data?, error: String?) {
        let steps = item["steps"].array
        var value: Project
        do { value = try JSONProjectStore.decode(encoded(cases["projects"][item["input"].string])) }
        catch let error as VoiceLabProjectError {
            #expect(steps.isEmpty, "\(item["id"].string) refused its input")
            return (nil, String(describing: error))
        }
        for (index, step) in steps.enumerated() {
            do {
                switch step["op"].string {
                case "upgradeToV3": value = try VoiceLabProject.upgradeToV3(value)
                case "addVoiceReference":
                    value = try VoiceLabProject.addVoiceReference(ProjectJSON.decoder().decode(VoiceLabVoiceReference.self, from: encoded(step["voice"])), to: value)
                case "markVoiceDeleted": value = try VoiceLabProject.markVoiceDeleted(id: step["id"].string, in: value)
                case "accept":
                    let take = cases["takes"][step["take"].string]
                    value = try VoiceLabProject.accept(ProjectJSON.decoder().decode(VoiceLabSegment.self, from: encoded(take["segment"])),
                                                       assets: ProjectJSON.decoder().decode([VoiceLabAsset].self, from: encoded(take["assets"])), into: value)
                default: Issue.record("Unknown upgrade step \(step["op"].string)")
                }
            } catch let error as VoiceLabProjectError {
                #expect(index == steps.count - 1, "\(item["id"].string) refused before its last step")
                return (nil, String(describing: error))
            }
        }
        return (try JSONProjectStore.encode(value), nil)
    }
    private func saveAndReload(_ value: Project) async throws -> Project {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-v3-upgrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("take.voxclip")
        let store = JSONProjectStore()
        try await store.save(value, to: path)
        return try await store.load(from: path)
    }

    @Test func v1UpgradeKeepsTheDocumentThroughSaveAndReload() async throws {
        let original = try extendedV1()
        let upgraded = try VoiceLabProject.upgradeToV3(original)
        #expect(original.schemaVersion == 1 && original.voiceLab == ProjectVoiceLab())
        #expect(upgraded.schemaVersion == 3)
        #expect(upgraded.voiceLab == ProjectVoiceLab(segments: [], assets: [], cleanAudio: VoiceLabCleanAudio(mode: .off), voices: [], videoAssets: []))
        var rest = upgraded
        rest.schemaVersion = original.schemaVersion
        rest.voiceLab = original.voiceLab
        #expect(rest == original)
        let reopened = try await saveAndReload(upgraded)
        #expect(reopened.schemaVersion == 3 && reopened.voiceLab == upgraded.voiceLab)
        #expect(reopened.transcript == original.transcript && reopened.edits == original.edits)
        #expect(reopened.captions == original.captions && reopened.share == original.share && reopened.export == original.export)
        #expect(reopened.extensions == original.extensions && reopened.ai == original.ai)
        #expect(reopened.id == original.id && reopened.title == original.title && reopened.createdAt == original.createdAt)
        try VoiceLabProject.validate(reopened)
    }

    @Test func segmentFreeV2KeepsAssetsAndV3IsUnchanged() throws {
        let v2 = try segmentFreeV2()
        let upgraded = try VoiceLabProject.upgradeToV3(v2)
        #expect(upgraded.schemaVersion == 3 && v2.schemaVersion == 2)
        #expect(upgraded.voiceLab == ProjectVoiceLab(segments: [], assets: v2.voiceLab.assets, cleanAudio: VoiceLabCleanAudio(mode: .off), voices: [], videoAssets: []))
        #expect(upgraded.transcript == v2.transcript && upgraded.edits == v2.edits && upgraded.media == v2.media)
        let v3 = try project("fixtures/voice-lab/passage-render-v3.voxclip")
        #expect(try VoiceLabProject.upgradeToV3(v3) == v3)
    }

    @Test func legacySegmentsAndInvalidInputsAreNotPromoted() throws {
        let legacy = try project("fixtures/voice-lab/passage-project.voxclip")
        #expect(throws: VoiceLabProjectError.legacySegmentsNeedReview) { try VoiceLabProject.upgradeToV3(legacy) }
        let disabled = try VoiceLabProject.setEnabled(false, id: "vl-passage", in: legacy)
        #expect(throws: VoiceLabProjectError.legacySegmentsNeedReview) { try VoiceLabProject.upgradeToV3(disabled) }
        #expect(legacy.schemaVersion == 2 && legacy.voiceLab.segments.count == 1)
        var invalid = try extendedV1()
        invalid.voiceLab.assets = []
        #expect(throws: VoiceLabProjectError.invalidSegment) { try VoiceLabProject.upgradeToV3(invalid) }
        var future = try extendedV1()
        future.schemaVersion = 4
        #expect(throws: VoiceLabProjectError.invalidSegment) { try VoiceLabProject.upgradeToV3(future) }
    }

    @Test func loadingAndSavingNeverUpgrade() async throws {
        let v1 = try extendedV1()
        let reopenedV1 = try await saveAndReload(v1)
        #expect(reopenedV1.schemaVersion == 1 && reopenedV1.voiceLab == ProjectVoiceLab() && reopenedV1.extensions == v1.extensions)
        let v2 = try segmentFreeV2()
        let reopenedV2 = try await saveAndReload(v2)
        #expect(reopenedV2.schemaVersion == 2 && reopenedV2.voiceLab == v2.voiceLab)
    }

    @Test func acceptUpgradesV1AndSegmentFreeV2AndNeverWritesV2() throws {
        let changer = try take("voice-changer-half-render-v3")
        let v1 = try voiceLabV1()
        let accepted = try VoiceLabProject.accept(changer.segment, assets: changer.assets, into: v1)
        #expect(v1.schemaVersion == 1 && accepted.schemaVersion == 3)
        #expect(accepted.voiceLab == ProjectVoiceLab(segments: [changer.segment], assets: changer.assets,
                                                     cleanAudio: VoiceLabCleanAudio(mode: .off), voices: [], videoAssets: []))
        #expect(try VoiceLabRenderContract.prepare(accepted, scope: .full, labelPosition: .topRight).selectedSegmentRecipes.count == 1)
        var v2 = try project("fixtures/voice-lab/passage-project.voxclip")
        #expect(throws: VoiceLabProjectError.legacySegmentsNeedReview) { try VoiceLabProject.accept(changer.segment, assets: changer.assets, into: v2) }
        v2.voiceLab.segments = []
        v2.voiceLab.assets = []
        #expect(try VoiceLabProject.accept(changer.segment, assets: changer.assets, into: v2) == accepted)
        // An upgraded v1 has no voice reference yet, so an own-voice take still needs active consent.
        let own = try take("passage-render-v3")
        #expect(throws: VoiceLabProjectError.consentUnverified) { try VoiceLabProject.accept(own.segment, assets: own.assets, into: v1) }
    }

    /// JSON cannot hold a non-finite number, so accept refuses one in any stored recipe rather than return a project that cannot be saved.
    @Test func acceptRefusesNonFiniteNumbersInRejectedRecipes() throws {
        let changer = try take("voice-changer-half-render-v3")
        let v1 = try voiceLabV1()
        var segment = changer.segment
        segment.candidates[1].rejected = "Rejected in review"
        #expect(try !JSONProjectStore.encode(VoiceLabProject.accept(segment, assets: changer.assets, into: v1)).isEmpty)
        var silent = segment
        silent.candidates[1].recipe?.qa.peakDbfs = -.infinity
        #expect(throws: VoiceLabProjectError.invalidSegment) { try VoiceLabProject.accept(silent, assets: changer.assets, into: v1) }
        var unbounded = segment
        unbounded.candidates[1].recipe?.video.retimeFactor = .nan
        #expect(throws: VoiceLabProjectError.invalidSegment) { try VoiceLabProject.accept(unbounded, assets: changer.assets, into: v1) }
    }

    @Test func addVoiceReferenceNeedsV3AndAUniqueActiveProviderVoice() throws {
        let v1 = try voiceLabV1()
        #expect(throws: VoiceLabProjectError.requiresVersion3) { try VoiceLabProject.addVoiceReference(voice(), to: v1) }
        #expect(throws: VoiceLabProjectError.requiresVersion3) { try VoiceLabProject.addVoiceReference(voice(), to: segmentFreeV2()) }
        let empty = try VoiceLabProject.upgradeToV3(v1)
        let added = try VoiceLabProject.addVoiceReference(voice(name: " \tFixture voice\n"), to: empty)
        #expect(added.voiceLab.voices == [voice()] && empty.voiceLab.voices == [])
        var rest = added
        rest.voiceLab.voices = empty.voiceLab.voices
        #expect(rest == empty)
        // Each row breaks one rule; "voice-two"/"other-voice" alone is valid, and a duplicate id or active voice ID is not.
        let invalid = [
            voice("../voice", voiceId: "other-voice"), voice("", voiceId: "other-voice"),
            voice(String(repeating: "v", count: 65), voiceId: "other-voice"), voice(voiceId: "other-voice"),
            voice("voice-two", voiceId: "other-voice", consent: ""), voice("voice-two", voiceId: "other-voice", consent: "consent record"),
            voice("voice-two", provider: "ElevenLabs", voiceId: "other-voice"), voice("voice-two", provider: "stock", voiceId: "other-voice"),
            voice("voice-two", voiceId: "../voices"), voice("voice-two", voiceId: "voice/other"), voice("voice-two", voiceId: "voice\n"),
            voice("voice-two", voiceId: ""), voice("voice-two", voiceId: String(repeating: "a", count: 129)),
            voice("voice-two", voiceId: "other-voice", status: .deleted), voice("voice-two", voiceId: "other-voice", name: " \n "),
            voice("voice-two"),
        ]
        for reference in invalid {
            #expect(throws: VoiceLabProjectError.invalidVoice, "\(reference)") { try VoiceLabProject.addVoiceReference(reference, to: added) }
        }
        // Names count Unicode scalars, not UTF-16 units or grapheme clusters.
        let astral = try VoiceLabProject.addVoiceReference(voice("voice-two", voiceId: "other-voice", name: String(repeating: "\u{1D11E}", count: 60)), to: added)
        #expect(astral.voiceLab.voices?.last?.displayName.unicodeScalars.count == 60)
        #expect(throws: VoiceLabProjectError.invalidVoice) {
            try VoiceLabProject.addVoiceReference(voice("voice-two", voiceId: "other-voice", name: String(repeating: "o\u{303}", count: 31)), to: added)
        }
        let longest = try VoiceLabProject.addVoiceReference(voice("voice-two", voiceId: String(repeating: "a", count: 128)), to: added)
        #expect(longest.voiceLab.voices?.count == 2)
    }

    @Test func deletedVoiceKeepsAcceptedTakesRenderableAndRefusesNewOwnVoiceTakes() throws {
        let fixture = try project("fixtures/voice-lab/passage-render-v3.voxclip")
        var active = fixture
        active.voiceLab.voices![0].status = .active
        let deleted = try VoiceLabProject.markVoiceDeleted(id: "voice-fixture", in: active)
        #expect(deleted.voiceLab.voices?.map(\.status) == [.deleted] && active.voiceLab.voices?.map(\.status) == [.active])
        #expect(deleted.voiceLab.segments == active.voiceLab.segments && deleted.voiceLab.assets == active.voiceLab.assets)
        #expect(deleted == fixture)
        // Rendering uses the stored consent evidence, not the reference's current status (§10.5).
        #expect(try VoiceLabRenderContract.prepare(deleted, scope: .full, labelPosition: .topRight).selectedSegmentRecipes.count == 1)
        #expect(try VoiceLabProject.markVoiceDeleted(id: "voice-fixture", in: deleted) == deleted)
        #expect(throws: VoiceLabProjectError.missingVoice) { try VoiceLabProject.markVoiceDeleted(id: "voice-missing", in: deleted) }
        #expect(throws: VoiceLabProjectError.requiresVersion3) { try VoiceLabProject.markVoiceDeleted(id: "voice-fixture", in: voiceLabV1()) }
        // Without the earlier take, the same own-voice take is a new accept: refused once deleted, allowed while active.
        let own = try take("passage-render-v3")
        var cleared = try VoiceLabProject.delete(id: "vl-passage", in: deleted)
        cleared.voiceLab.assets = []
        #expect(throws: VoiceLabProjectError.consentUnverified) { try VoiceLabProject.accept(own.segment, assets: own.assets, into: cleared) }
        cleared.voiceLab.voices![0].status = .active
        #expect(try VoiceLabProject.accept(own.segment, assets: own.assets, into: cleared) == active)
    }

    /// Accept checks consent for every unrejected own-voice candidate; selecting one after deletion relies on its stored evidence (§10.5).
    @Test func ownVoiceAlternativeNeedsActiveConsentOnlyWhenAccepted() throws {
        let cases = try upgradeCases()
        let take = cases["takes"]["changer-own-alternative"]
        let segment = try ProjectJSON.decoder().decode(VoiceLabSegment.self, from: encoded(take["segment"]))
        let assets = try ProjectJSON.decoder().decode([VoiceLabAsset].self, from: encoded(take["assets"]))
        let active = try JSONProjectStore.decode(encoded(cases["projects"]["voice-lab-v3-active-voice"]))
        let deletedFirst = try VoiceLabProject.markVoiceDeleted(id: "voice-fixture", in: active)
        #expect(throws: VoiceLabProjectError.consentUnverified) { try VoiceLabProject.accept(segment, assets: assets, into: deletedFirst) }
        let deleted = try VoiceLabProject.markVoiceDeleted(id: "voice-fixture", in: VoiceLabProject.accept(segment, assets: assets, into: active))
        let selected = try VoiceLabProject.selectCandidate(1, id: segment.id, in: deleted)
        #expect(selected.voiceLab.segments[0].selectedCandidateIndex == 1 && selected.voiceLab.segments[0].provenance.voiceId == "fixture-voice")
    }

    /// Transitions are values without I/O or undo registration (§10.3), so App undo restores an earlier value it holds.
    @Test func restoredTransitionValuesKeepByteIdenticalJSON() throws {
        let original = try voiceLabV1()
        let render = try project("fixtures/voice-lab/passage-render-v3.voxclip")
        let own = try take("passage-render-v3")
        var history = [(project: original, json: try JSONProjectStore.encode(original))]
        func apply(_ transition: (Project) throws -> Project) throws {
            let next = try transition(history[history.count - 1].project)
            history.append((next, try JSONProjectStore.encode(next)))
        }
        try apply(VoiceLabProject.upgradeToV3)
        try apply { try VoiceLabProject.addVoiceReference(voice(), to: $0) }
        try apply { try VoiceLabProject.accept(own.segment, assets: own.assets, into: $0) }
        try apply { try VoiceLabProject.markVoiceDeleted(id: "voice-fixture", in: $0) }
        #expect(history.count == 5 && history[4].project == render)
        while let entry = history.popLast() {
            #expect(try JSONProjectStore.encode(entry.project) == entry.json)
        }
        let snapshot = try JSONProjectStore.encode(original)
        #expect(try JSONProjectStore.decode(snapshot) == original)
        #expect(try JSONProjectStore.encode(JSONProjectStore.decode(snapshot)) == snapshot)
    }

    @Test func sharedUpgradeCasesReplay() throws {
        let cases = try upgradeCases()
        #expect(cases["schema"].string == "voxclip-voice-lab-upgrade-cases/1")
        #expect(!cases["cases"].array.isEmpty)
        for item in cases["cases"].array {
            let outcome = try replay(item, in: cases)
            let expected = try item["error"].isNull ? canonical(encoded(cases["projects"][item["expected"].string]), rewritingTimestamps: true) : item["error"].string
            let actual: String
            if let json = outcome.json {
                actual = try canonical(json)
                _ = try JSONProjectStore.decode(json)
            } else {
                actual = outcome.error ?? ""
            }
            #expect(actual == expected, "\(item["id"].string)")
        }
    }

    /// Windows requires every video key, so the Mac encoder must write the shared `videoRecipes` exactly, nulls included.
    @Test func videoRecipesWriteEveryKeyInEveryMode() throws {
        let fixture = try upgradeCases()["videoRecipes"]
        let recipes = [
            video(.source), video(.retimed, outputSamples: 40_000, retimeFactor: 1.2),
            video(.zoomCover, outputSamples: 40_000, retimeFactor: 1.2, zoom: 1.5, faceX: 0.25, faceY: 0.75),
            video(.lipsync, assetId: "lipsync-take", provider: "sync", model: "lipsync-2", requestId: "lipsync-request-1",
                  windowStartSample: 24_000, windowEndSample: 120_000, syncMode: "remap"),
        ]
        #expect(fixture.object.keys.sorted() == recipes.map(\.mode.rawValue).sorted())
        for recipe in recipes {
            let data = try ProjectJSON.encoder().encode(recipe)
            #expect(try canonical(data) == canonical(encoded(fixture[recipe.mode.rawValue])), "\(recipe.mode)")
            #expect(try ProjectJSON.decoder().decode(VoiceLabVideoRecipe.self, from: data) == recipe)
        }
    }

    /// Every video key is required, explicit null included (architecture §2.1 rule 8), as on Windows and in the schema.
    /// Development builds before 2026-10-26 left out the null keys, so such files are unreadable.
    @Test func recipeVideoMissingAKeyIsUnreadable() throws {
        let cases = try upgradeCases()
        let project = cases["projects"]["passage-render-v3"].value
        #expect(try JSONProjectStore.decode(JSONEncoder().encode(project)).schemaVersion == 3)
        let keys = cases["videoRecipes"]["source"].object.keys.sorted()
        #expect(keys.count == 15)
        let partials = [withRecipeVideos(project) { video in video.filter { $0.value != .null } }]
            + keys.map { key in withRecipeVideos(project) { video in video.filter { $0.key != key } } }
        for partial in partials {
            #expect(partial != project)
            let data = try JSONEncoder().encode(partial)
            #expect(throws: VoxClipError.projectUnreadable("Unknown or missing project field")) { try JSONProjectStore.decode(data) }
            #expect(throws: VoxClipError.projectUnreadable("Incomplete Voice Lab render recipe")) { try ProjectJSON.decode(data) }
        }
    }

    @Test(.enabled(if: SchemaPython.enabled, SchemaPython.skipReason))
    func upgradedFilesMatchTheProjectSchema() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-v3-schema-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONProjectStore()
        var files: [URL] = []
        for (name, value) in [("v1-extension", try extendedV1()), ("v2-asset", try segmentFreeV2())] {
            let url = directory.appendingPathComponent(name + ".voxclip")
            try await store.save(VoiceLabProject.upgradeToV3(value), to: url)
            files.append(url)
        }
        let cases = try upgradeCases()
        for item in cases["cases"].array {
            guard let json = try replay(item, in: cases).json else { continue }
            let url = directory.appendingPathComponent("case-" + item["id"].string + ".voxclip")
            try json.write(to: url)
            files.append(url)
        }
        try SchemaPython.validate(files)
    }
}

/// Runs tools/schemas/validate.py with the Windows Core helper's interpreter rule (AGENTS.md).
enum SchemaPython {
    static let interpreter: String? = {
        let configured = ProcessInfo.processInfo.environment["VOXCLIP_SCHEMA_PYTHON"].flatMap { $0.isEmpty ? nil : $0 }
        return (configured.map { [$0] } ?? ["python3", "python"]).first { (try? run($0, ["-c", "import sys; assert sys.version_info.major == 3; import jsonschema, referencing"]).status) == 0 }
    }()
    static var required: Bool { ProcessInfo.processInfo.environment["VOXCLIP_REQUIRE_SCHEMA_PYTHON"] == "1" }
    static var enabled: Bool { required || interpreter != nil }
    static let skipReason: Comment = "Schema check skipped: set VOXCLIP_SCHEMA_PYTHON to a Python 3 interpreter with jsonschema>=4.18,<5"

    static func validate(_ files: [URL]) throws {
        let python = try #require(interpreter, "VOXCLIP_REQUIRE_SCHEMA_PYTHON=1 needs a Python 3 interpreter with jsonschema and referencing")
        let validator = try FixtureLoader.sharedRoot().deletingLastPathComponent().appendingPathComponent("tools/schemas/validate.py")
        let result = try run(python, [validator.path] + files.map(\.path))
        #expect(result.status == 0, "Schema validation failed:\n\(result.output)")
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.standardOutput = output; process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, text)
    }
}
