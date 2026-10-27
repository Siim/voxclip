import Foundation
import Testing
@testable import VoxClipCore

@Suite struct EditingPersistence {
    struct WriterVersionCase: Decodable, Sendable {
        let runtime: String?
        let writer: String
    }

    @Test func runtimeWriterVersionsSaveAndReload() async throws {
        let cases = try FixtureLoader.decode([WriterVersionCase].self, at: "fixtures/projects/writer-versions.json")
        let original = try project()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("writer.voxclip")
        for entry in cases {
            let store = JSONProjectStore(appVersion: entry.runtime)
            try await store.save(original, to: destination)
            let loaded = try await store.load(from: destination)
            #expect(loaded.savedBy.version == entry.writer)
            #expect(loaded.transcript == original.transcript)
            #expect(loaded.edits == original.edits)
        }
    }

    static var projectFixtureNames: [String] {
        guard let root = try? FixtureLoader.sharedRoot(), let files = try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("fixtures/projects"), includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "voxclip" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }
    func temporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../.build/mac-editing-tests/\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    func project(_ name: String = "interview-take") throws -> Project {
        try JSONProjectStore.decode(FixtureLoader.data("fixtures/projects/\(name).voxclip"))
    }

    @Test(arguments: projectFixtureNames) func roundTrip(_ name: String) async throws {
        let original = try project(name)
        let data = try JSONProjectStore.encode(original)
        #expect(try JSONProjectStore.decode(data) == original)
        #expect(try JSONProjectStore.encode(original) == data)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name + ".voxclip")
        let store = JSONProjectStore(appVersion: "9.8.7")
        try await store.save(original, to: url)
        let loaded = try await store.load(from: url)
        #expect(loaded.transcript == original.transcript)
        #expect(loaded.edits == original.edits)
        #expect(loaded.savedBy == ProjectWriter(version: "9.8.7"))
        #expect(loaded.modifiedAt != original.modifiedAt)
        #expect(loaded.media.source.relativePath == JSONProjectStore.relativePath(source: URL(fileURLWithPath: original.media.source.absolutePath), projectURL: url))
        let raw = try Data(contentsOf: url)
        #expect(raw.last == 10)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
        let output = directory.deletingLastPathComponent().appendingPathComponent("schema-outputs")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try raw.write(to: output.appendingPathComponent(name + ".voxclip"), options: .atomic)
    }

    @Test func invalidDocumentsAreRejectedStrictly() throws {
        let original = try project()
        let encoded = try JSONProjectStore.encode(original)
        let raw = try JSONDecoder().decode(JSONValue.self, from: encoded)
        guard case .object(let root) = raw else { Issue.record("Expected object"); return }
        func rejected(_ object: [String: JSONValue], error: VoxClipError? = nil) throws {
            let data = try JSONEncoder().encode(JSONValue.object(object))
            if let error { #expect(throws: error) { try JSONProjectStore.decode(data) } }
            else { #expect(throws: VoxClipError.self) { try JSONProjectStore.decode(data) } }
        }
        var changed = root; changed["unexpected"] = .bool(true); try rejected(changed)
        changed = root; changed["schemaVersion"] = .number(4); try rejected(changed, error: .projectTooNew)
        changed = root; changed["schemaVersion"] = .number(0); try rejected(changed)
        changed = root; changed["format"] = .string("another"); try rejected(changed)
        changed = root; changed["id"] = .string("not-uuid"); try rejected(changed)
        changed = root; changed["title"] = .null; try rejected(changed)
        changed = root; changed["createdAt"] = .string("2026-10-25T00:00:00+00:00"); try rejected(changed)
        for key in ["transcript", "media", "edits", "captions", "export", "share", "ai", "voiceLab", "savedBy"] {
            guard case .object(var object) = root[key] else { continue }
            object["unknown"] = .bool(true)
            changed = root; changed[key] = .object(object); try rejected(changed)
            object.removeValue(forKey: "unknown")
            if let first = object.keys.sorted().first { object.removeValue(forKey: first) }
            changed = root; changed[key] = .object(object); try rejected(changed)
        }
        var invalid = original
        invalid.transcript!.words[0].end = invalid.transcript!.words[0].start
        #expect(throws: VoxClipError.self) { try JSONProjectStore.encode(invalid) }
        invalid = original; invalid.edits.pauseKeepSeconds = 2
        #expect(throws: VoxClipError.self) { try JSONProjectStore.encode(invalid) }
        invalid = original; invalid.transcript!.words[0].conf = 1.1
        #expect(throws: VoxClipError.self) { try JSONProjectStore.encode(invalid) }
        invalid = original; invalid.transcript!.words[0].text = "o\u{303}"
        #expect(throws: VoxClipError.self) { try JSONProjectStore.encode(invalid) }
    }

    @Test func referenceCleanupAndProjectOperations() throws {
        var original = try project("clip-from-long-take")
        original.edits.cutWordIds.append("missing")
        original.edits.cutPauseIds.append("pause-after-missing")
        original.edits.corrections["missing"] = "text"
        let word = original.transcript!.words[0]
        original.edits.corrections[word.id] = word.text
        original.edits.clips.append(ClipRange(id: "invalid", startWordId: "missing", endWordId: word.id))
        original.edits.clips[0].aiResultId = "missing"
        original.edits.activeClipId = "invalid"
        original.share.captions["invalid"] = "drop"
        original.extensions = ["test.extension": .object(["kept": .number(1)])]
        let cleaned = JSONProjectStore.cleanReferences(original)
        let raw = try ProjectJSON.encode(original)
        let (decoded, warnings) = try JSONProjectStore.decodeReportingWarnings(raw)
        #expect(decoded == cleaned.project)
        #expect(warnings == cleaned.warnings)
        #expect(try JSONProjectStore.decode(raw) == cleaned.project)
        #expect(try ProjectJSON.decode(JSONProjectStore.encode(original)) == cleaned.project)
        #expect(cleaned.warnings.count == 7)
        #expect(!cleaned.project.edits.cutWordIds.contains("missing"))
        #expect(cleaned.project.edits.activeClipId == nil)
        #expect(cleaned.project.edits.clips[0].aiResultId == nil)
        #expect(cleaned.project.edits.clips[0].aiClipIndex == nil)
        #expect(cleaned.project.extensions == original.extensions)
        var project = cleaned.project
        let id = project.edits.clips[0].id
        project.share.captions[id] = "to remove"
        try project.applyEditing(.removeClip(id: id))
        #expect(project.share.captions[id] == nil && !project.ai.results.isEmpty)
        let transcript = project.transcript!
        project.edits.pauseKeepSeconds = 0.42
        project.replaceTranscript(transcript)
        #expect(project.edits.cutWordIds.isEmpty && project.edits.corrections.isEmpty && project.edits.clips.isEmpty)
        #expect(project.share.captions.isEmpty && project.ai.results.isEmpty && project.edits.pauseThresholdSeconds == 0.8)
        #expect(project.edits.pauseKeepSeconds == 0.42)
        var unrefined = transcript
        unrefined.refined = false
        project.replaceTranscript(unrefined)
        #expect(project.edits.pauseThresholdSeconds == 1 && project.edits.pauseKeepSeconds == 0.42)
    }

    @Test func sourceResolutionChecksSizeAndHashAndRelativeFallback() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.bin"), wrong = directory.appendingPathComponent("wrong.bin")
        try Data([1, 2, 3, 4]).write(to: source)
        try Data([4, 3, 2, 1]).write(to: wrong)
        var project = try project()
        project.media.source.absolutePath = wrong.path
        project.media.source.relativePath = "source.bin"
        project.media.source.sizeBytes = 4
        project.media.source.contentKey = try JSONProjectStore.contentKey(for: source)
        let store = JSONProjectStore(appVersion: "9.8.7"), projectURL = directory.appendingPathComponent("test.voxclip")
        #expect(try await store.resolveSource(for: project, projectURL: projectURL) == source)
        try await store.save(project, to: projectURL)
        #expect(try await store.load(from: projectURL).media.source.absolutePath == source.path)
        project.media.source.relativePath = "wrong.bin"
        await #expect(throws: VoxClipError.self) { try await store.resolveSource(for: project, projectURL: projectURL) }
        project.media.source.absolutePath = source.path
        #expect(try await store.resolveSource(for: project, projectURL: projectURL) == source)
        #expect(JSONProjectStore.relativePath(source: source, projectURL: directory.appendingPathComponent("child/test.voxclip")) == "../source.bin")
    }

    @Test func failedProjectSavePreservesExistingBytes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("test.voxclip")
        let existing = Data("previous document".utf8)
        try existing.write(to: destination)
        var invalid = try project(); invalid.media.source.durationSeconds = -.infinity
        await #expect(throws: (any Error).self) { try await JSONProjectStore(appVersion: "9.8.7").save(invalid, to: destination) }
        #expect(try Data(contentsOf: destination) == existing)
    }

    @Test func relinkingDifferentMediaRequiresConfirmationAndDurationTolerance() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.bin")
        try Data([1, 2, 3]).write(to: source)
        let original = try project(), store = JSONProjectStore(appVersion: "9.8.7")
        let probe = MediaProbeResult(durationSeconds: original.media.source.durationSeconds + 0.04, isPlayable: true)
        await #expect(throws: VoxClipError.self) { try await store.relink(original, to: source, probe: probe) }
        let linked = try await store.relink(original, to: source, probe: probe, confirmedDifferent: true)
        #expect(linked.media.source.sizeBytes == 3 && linked.media.source.absolutePath == source.path)
        #expect(linked.transcript == original.transcript && linked.edits == original.edits)
        #expect(linked.media.source.durationSeconds == original.media.source.durationSeconds)
        let wrongDuration = MediaProbeResult(durationSeconds: original.media.source.durationSeconds + 0.06, isPlayable: true)
        await #expect(throws: VoxClipError.self) { try await store.relink(original, to: source, probe: wrongDuration, confirmedDifferent: true) }
        #expect(try await store.relink(linked, to: source, probe: wrongDuration) == linked)
    }

    @Test func orderedCutIDsAndCorrectionsRetainNumbers() throws {
        var project = try project("clip-from-long-take")
        let ids = project.transcript!.words.map(\.id)
        project.edits.cutWordIds = [ids[10], ids[1]]
        project.edits.corrections = [ids[10]: "line\ntext", ids[1]: "brace } and quote \""]
        project.captions.overrides["corrections"] = .object(["do-not-touch": .bool(true)])
        project.media.source.sizeBytes = 9_007_199_254_740_993
        let encoded = try JSONProjectStore.encode(project), decoded = try JSONProjectStore.decode(encoded)
        #expect(decoded.media.source.sizeBytes == project.media.source.sizeBytes)
        #expect(decoded.edits.cutWordIds == [ids[1], ids[10]])
        #expect(decoded.edits.corrections == project.edits.corrections)
        #expect(decoded.captions.overrides == project.captions.overrides)
        let text = String(decoding: encoded, as: UTF8.self)
        let first = try #require(text.range(of: "\"\(ids[1])\" : \"brace")), last = try #require(text.range(of: "\"\(ids[10])\" : \"line"))
        #expect(first.lowerBound < last.lowerBound)
    }

    @Test func settingsDebounceAndFlushPreserveUnknownKeysAndModels() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": directory.path])
        let store = JSONSettingsStore(locations: locations)
        var settings = try await store.load()
        #expect(settings["editing.pauseBreath"] == .string("natural"))
        settings.values["future.setting"] = .object(["keep": .bool(true)])
        settings.setModelID("claude", for: "anthropic")
        settings.setModelID("gpt", for: "openai")
        try await store.save(settings)
        #expect(!FileManager.default.fileExists(atPath: locations.settings.path))
        try await Task.sleep(for: .milliseconds(280))
        settings.values["general.appearance"] = .string("dark")
        try await store.save(settings)
        try await Task.sleep(for: .milliseconds(280))
        #expect(!FileManager.default.fileExists(atPath: locations.settings.path))
        try await Task.sleep(for: .milliseconds(350))
        #expect(FileManager.default.fileExists(atPath: locations.settings.path))
        let disk = try JSONDecoder().decode(SettingsDocument.self, from: Data(contentsOf: locations.settings))
        #expect(disk.modelID(for: "anthropic") == "claude" && disk.modelID(for: "openai") == "gpt")
        #expect(disk["general.appearance"] == .string("dark"))
        try await store.save(SettingsDocument(values: ["cache.limitGB": .number(10)]))
        try await store.flush()
        let loaded = try await JSONSettingsStore(locations: locations).load()
        #expect(loaded.values["future.setting"] == disk.values["future.setting"])
        #expect(loaded["cache.limitGB"] == .number(10))
        #expect(loaded["general.appearance"] == .string("system"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["settings.json"])
        let outputs = directory.deletingLastPathComponent().appendingPathComponent("schema-outputs")
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        try Data(contentsOf: locations.settings).write(to: outputs.appendingPathComponent("settings.json"), options: .atomic)
    }

    @Test func settingsInvalidAndFailedWritesLeaveOldFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": directory.path])
        let store = JSONSettingsStore(locations: locations)
        try await store.save(SettingsDocument(values: ["cache.limitGB": .number(5)])); try await store.flush()
        let existing = try Data(contentsOf: locations.settings)
        for settings in [SettingsDocument(schema: "future"), SettingsDocument(values: ["cache.limitGB": .number(3)]),
                         SettingsDocument(values: ["llm.model.openai": .string("")]), SettingsDocument(values: ["update.autoCheck": .number(1)])] {
            await #expect(throws: VoxClipError.self) { try await store.save(settings) }
        }
        #expect(try Data(contentsOf: locations.settings) == existing)
        let blocker = directory.appendingPathComponent("blocker")
        try existing.write(to: blocker)
        let blocked = JSONSettingsStore(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": blocker.path]))
        try await blocked.save(SettingsDocument())
        await #expect(throws: (any Error).self) { try await blocked.flush() }
        #expect(try Data(contentsOf: blocker) == existing)
    }

    @Test func cacheEvictsLRUButProtectsOpenEntriesAndModels() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": directory.path])
        let store = CacheStore(locations: locations)
        let keys = [String(repeating: "a", count: 64), String(repeating: "b", count: 64), String(repeating: "c", count: 64)]
        for (index, key) in keys.enumerated() {
            let entry = CacheEntry(contentKey: key, createdAt: Date(timeIntervalSince1970: 0), lastAccessAt: Date(timeIntervalSince1970: Double(index)), bytes: 1000)
            try await store.record(entry)
        }
        try FileManager.default.createDirectory(at: locations.models, withIntermediateDirectories: true)
        let model = locations.models.appendingPathComponent("model.bin")
        try Data([1]).write(to: model)
        try await store.evict(limitBytes: 2000, protectedKeys: [keys[0]])
        #expect(FileManager.default.fileExists(atPath: locations.cache.appendingPathComponent(keys[0]).path))
        #expect(!FileManager.default.fileExists(atPath: locations.cache.appendingPathComponent(keys[1]).path))
        #expect(FileManager.default.fileExists(atPath: locations.cache.appendingPathComponent(keys[2]).path))
        #expect(try await store.entry(contentKey: "../Models") == nil)
        #expect(try await store.entry(contentKey: keys[2]) != nil)
        try await store.evict(limitBytes: 0, protectedKeys: [keys[0]])
        #expect(FileManager.default.fileExists(atPath: locations.cache.appendingPathComponent(keys[0]).path))
        #expect(FileManager.default.fileExists(atPath: model.path))
    }

    @Test func cacheCorruptionIsAMissAndSymlinksAreNotEvicted() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": directory.path])
        let store = CacheStore(locations: locations)
        let key = String(repeating: "d", count: 64), symbolicKey = String(repeating: "e", count: 64)
        let entry = locations.cache.appendingPathComponent(key)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: entry.appendingPathComponent("meta.json"))
        #expect(try await store.entry(contentKey: key) == nil)
        try FileManager.default.createDirectory(at: locations.models, withIntermediateDirectories: true)
        let model = locations.models.appendingPathComponent("model.bin")
        try Data([1, 2, 3]).write(to: model)
        try FileManager.default.createSymbolicLink(at: locations.cache.appendingPathComponent(symbolicKey), withDestinationURL: locations.models)
        try await store.evict(limitBytes: 0, protectedKeys: [])
        #expect(!FileManager.default.fileExists(atPath: entry.path))
        #expect(try Data(contentsOf: model) == Data([1, 2, 3]))
        #expect(try await store.entry(contentKey: symbolicKey) == nil)
    }

    @Test(arguments: [false, true]) func pruningKeepsReferencedResultsAndNewestTen(referencedIsOld: Bool) async throws {
        var project = try project("clip-from-long-take")
        project.ai.results[0].createdAt = Date(timeIntervalSince1970: referencedIsOld ? -1 : 20)
        let referenced = project.ai.results[0]
        for index in 0..<14 {
            var result = referenced
            result.id = "result-\(index)"
            result.createdAt = Date(timeIntervalSince1970: Double(index / 2))
            project.ai.results.append(result)
        }
        let first = referencedIsOld ? 4 : 5
        let expectedIDs = [referenced.id] + (first..<14).map { "result-\($0)" }
        let encoded = try JSONProjectStore.encode(project)
        #expect(try ProjectJSON.decode(encoded).ai.results.map(\.id) == expectedIDs)
        #expect(try JSONProjectStore.decode(encoded).ai.results.map(\.id) == expectedIDs)
        #expect(JSONProjectStore.pruneAIResults(project).ai.results.map(\.id) == expectedIDs)
        #expect(project.ai.results.count == 15)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("retained.voxclip"), store = JSONProjectStore(appVersion: "9.8.7")
        try await store.save(project, to: url)
        let loaded = try await store.load(from: url)
        #expect(loaded.ai.results.map(\.id) == expectedIDs)
    }

    @Test func loadWarningsAreLoggedAndReturnedPerDocument() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var first = try project(), second = try project()
        first.edits.cutWordIds.append("missing-word")
        second.edits.cutPauseIds += ["pause-after-missing-one", "pause-after-missing-two"]
        let firstURL = directory.appendingPathComponent("first.voxclip"), secondURL = directory.appendingPathComponent("second.voxclip")
        try ProjectJSON.encode(first).write(to: firstURL)
        try ProjectJSON.encode(second).write(to: secondURL)
        let logger = EditingTestLogger(), store = JSONProjectStore(logger: logger)
        async let firstResult = store.loadReportingWarnings(from: firstURL)
        async let secondResult = store.loadReportingWarnings(from: secondURL)
        let (firstReport, secondReport) = try await (firstResult, secondResult)
        #expect(firstReport.1 == ["Dropped 1 invalid cut word reference(s)"])
        #expect(secondReport.1 == ["Dropped 2 invalid cut pause reference(s)"])
        #expect(!firstReport.0.edits.cutWordIds.contains("missing-word"))
        #expect(!secondReport.0.edits.cutPauseIds.contains("pause-after-missing-one"))
        _ = try await store.load(from: firstURL)
        let entries = await logger.entries
        #expect(entries.count == 3)
        #expect(entries.allSatisfy { $0.level == .warn && $0.category == "import" })
        #expect(entries.filter { $0.message == firstReport.1[0] }.count == 2)
        #expect(entries.filter { $0.message == secondReport.1[0] }.count == 1)
    }
}

actor EditingTestLogger: Logger {
    private(set) var entries: [LogEntry] = []
    func write(_ entry: LogEntry) async {
        entries.append(entry)
        await Task.yield()
    }
}
