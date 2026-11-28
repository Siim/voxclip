#if DEBUG
import AppKit
import Foundation
import Testing
import VoxClipCore
@testable import VoxClip

private actor CardConnectorSpy: LLMConnector {
    nonisolated let id = ConnectorID.openai
    private(set) var requests = 0
    private(set) var frameLabels: [String] = []

    func status() -> ConnectorStatus { .ready }
    func models(refresh: Bool) -> [LLMModel] { [] }
    func contextTokens(model: String) -> Int? { 128_000 }
    func supportsImages() -> Bool { true }

    func send(_ request: LLMRequest, model: String) -> RawCompletion {
        requests += 1
        frameLabels = request.images.map(\.label)
        return RawCompletion(text: """
        {"clips":[{"title":"Superscribe","reason":"The origin and payoff.","score":9,"parts":[
          {"start_line":1,"end_line":1,"take_reason":"0010 says “a dictation tool that supports time tracking”"},
          {"start_line":5,"end_line":5},{"start_line":7,"end_line":7},
          {"start_line":3,"end_line":3,"take_reason":"Only 0010 says “It’s a reporting tool”"},
          {"start_line":8,"end_line":8}],"not_in_take":""}]}
        """, model: model, stop: .complete)
    }
}

@MainActor @Suite(.serialized) struct CardImportTests {
    @Test(.timeLimit(.minutes(1))) func bestVersionsSavesAllProjectsAndShowsFivePartsAfterInlineApproval() async throws {
        let (app, importer, spy) = try await openThreeRecordings(connector: true)
        defer { cleanUp(app, importer) }
        importer.start(app, mode: .bestVersions)
        try await waitUntil { importer.combinedEditor?.sendConfirmation.isPresented == true || !importer.running }
        let editor = try #require(importer.combinedEditor, Comment(rawValue: importer.notice ?? "No combined project"))
        let url = try #require(importer.combinedURL)
        let prompt = try #require(editor.sendConfirmation.prompt, Comment(rawValue: editor.clipError ?? "No approval"))
        #expect(prompt.billed)
        #expect(await spy.requests == 0)
        try await verifySavedProjects(importer)
        let before = try await JSONProjectStore().load(from: url)
        #expect(before.edits.clips.isEmpty)
        #expect(ProjectClock.label(before.media.source) == "0010")
        editor.sendConfirmation.approve()
        try await waitUntil { !importer.running }
        #expect(importer.notice == nil)
        #expect(await spy.requests == 1)
        #expect(await spy.frameLabels == ["Recording 0010", "Recording 0007", "Recording 0006"])
        let result = try #require(importer.combinedEditor)
        let clip = try #require(result.suggestedClips.first, Comment(rawValue: importer.notice ?? "No proposal"))
        let details = try #require(result.suggestedCardDetails(clip))
        #expect(details.parts.count == 5)
        #expect(details.parts.compactMap(\.recording) == ["0010", "0010"])
        let after = try await JSONProjectStore().load(from: url)
        #expect(after.edits.clips.first?.parts?.count == 5)
        let clock = ProjectClock.build(after)
        #expect(clock.regions.map(\.label) == ["0007", "0010", "0006"])
        let partLabels = after.edits.clips.first?.playParts.compactMap { clock.region(of: $0.startWordId)?.label }
        #expect(partLabels == ["0010", "0007", "0007", "0010", "0007"])
        #expect(importer.budget?.cap == 1 && importer.budget?.spent == 0)
        #expect((importer.budget?.plannerSpent ?? 0) > 0)
        #expect(after.voiceLab.segments.isEmpty && after.voiceLab.videoAssets?.isEmpty == true)
        result.keep(clip.id)
        let kept = try await JSONProjectStore().load(from: url)
        #expect(kept.edits.clips.first?.selected == true)
    }

    @Test(.timeLimit(.minutes(1))) func zeroCardCapSavesProjectsWithoutSendingAMeteredPlan() async throws {
        let (app, importer, spy) = try await openThreeRecordings(connector: true)
        defer { cleanUp(app, importer) }
        #expect(app.set(ClipsMode.capKey, .number(0)))
        importer.start(app, mode: .bestVersions)
        try await waitUntil { importer.combinedEditor?.sendConfirmation.isPresented == true || !importer.running }
        importer.combinedEditor?.sendConfirmation.approve()
        try await waitUntil { !importer.running }
        try await verifySavedProjects(importer)
        let url = try #require(importer.combinedURL)
        let saved = try await JSONProjectStore().load(from: url)
        #expect(saved.edits.clips.isEmpty)
        #expect(await spy.requests == 0)
        #expect(importer.notice?.contains("card's AI cap") == true)
    }

    @Test(.timeLimit(.minutes(1))) func stopAtInlineApprovalKeepsEveryProjectWithoutSending() async throws {
        let (app, importer, spy) = try await openThreeRecordings(connector: true)
        defer { cleanUp(app, importer) }
        importer.start(app, mode: .bestVersions)
        try await waitUntil { importer.combinedEditor?.sendConfirmation.isPresented == true || !importer.running }
        let editor = try #require(importer.combinedEditor)
        try #require(editor.sendConfirmation.isPresented)
        importer.stop()
        try await waitUntil { !importer.running }
        #expect(!editor.sendConfirmation.isPresented)
        #expect(await spy.requests == 0)
        try await verifySavedProjects(importer)
        let url = try #require(importer.combinedURL)
        let saved = try await JSONProjectStore().load(from: url)
        #expect(saved.edits.clips.isEmpty)
        #expect(ProjectClock.build(saved).regions.count == 3)
        #expect(importer.budget?.spent == 0)
    }

    @Test(.timeLimit(.minutes(1))) func noConnectorOffersFreeCombinedProjectAndOneRecordingExplainsWhyNot() async throws {
        let (app, importer, spy) = try await openThreeRecordings(connector: false)
        defer { cleanUp(app, importer) }
        #expect(importer.combinedBlock(app, findClip: true) == "Choose an AI connector in Settings › AI.")
        let deselected = Array(importer.selected.dropFirst())
        for file in deselected { importer.toggle(file.id) }
        #expect(importer.combinedBlock(app, findClip: true) == "Select two or more recordings to make one clip from them.")
        for file in deselected { importer.toggle(file.id) }
        #expect(importer.combinedBlock(app, findClip: false) == nil)
        importer.start(app, mode: .combinedProject)
        try await waitUntil { !importer.running }
        try await verifySavedProjects(importer)
        let url = try #require(importer.combinedURL)
        let saved = try await JSONProjectStore().load(from: url)
        #expect(ProjectClock.build(saved).regions.map(\.label) == ["0010", "0007", "0006"])
        #expect(saved.edits.clips.isEmpty && importer.budget == nil)
        #expect(await spy.requests == 0)
    }

    private func openThreeRecordings(connector: Bool) async throws -> (AppModel, CardImport, CardConnectorSpy) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-card-\(UUID())", isDirectory: true)
        let folder = root.appendingPathComponent("Card")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let shared = try SharedResources.locate()
        let reference = try await JSONProjectStore().load(from: shared.root.appendingPathComponent("fixtures/recordings/reference-recordings.voxclip"))
        let primary = try #require(reference.transcript)
        let other = try #require(reference.media.spokenSources?.first?.transcript)
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": root.appendingPathComponent("Data").path])
        let takes = [("0010", "0010", other), ("0007", "0007", primary), ("0006", "0007", primary)]
        for (index, take) in takes.enumerated() {
            let (label, fixture, transcript) = take
            let url = folder.appendingPathComponent("recording-\(label).mp4")
            var media = try Data(contentsOf: shared.root.appendingPathComponent("fixtures/media/recording-\(fixture).mp4"))
            if label != fixture { media.append(contentsOf: [0, 0, 0, 8, 102, 114, 101, 101]) }
            try media.write(to: url)
            let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            RecordingTranscriptCache.write(transcript, key: try JSONProjectStore.contentKey(for: url), cache: locations.cache)
        }
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: locations)
        let spy = CardConnectorSpy()
        app.connectorOverride = { _ in spy }
        app.voiceRecoveryForTests = { }
        #expect(app.set("update.autoCheck", .bool(false)))
        #expect(app.set("llm.connector", .string(connector ? "openai" : "")))
        #expect(app.set(ClipsMode.capKey, .number(1)))
        await app.start()
        let importer = CardImport(library: root.appendingPathComponent("Library"))
        importer.offer(folder)
        try await waitUntil { !importer.scanRunning }
        try #require(importer.selected.count == 3)
        return (app, importer, spy)
    }

    private func verifySavedProjects(_ importer: CardImport) async throws {
        let urls = importer.rows.compactMap(\.url)
        #expect(importer.copied == 3 && importer.transcribed == 3)
        try #require(urls.count == 3)
        for url in urls {
            let project = try await JSONProjectStore().load(from: url)
            #expect(project.transcript != nil)
            #expect(project.media.additionalSources.count == 2)
            #expect(project.edits.clips.isEmpty)
        }
    }

    private func cleanUp(_ app: AppModel, _ importer: CardImport) {
        importer.stop()
        importer.combinedEditor?.close()
        for row in importer.rows { row.model?.close() }
        try? FileManager.default.removeItem(at: app.locations.root.deletingLastPathComponent())
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(condition())
    }

    @Test(.timeLimit(.minutes(1))) func copyOnlySavesOneProjectPerRecordingWithCompanionMedia() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-card-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let card = root.appendingPathComponent("Card/DCIM", isDirectory: true)
        let library = root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        let shared = try SharedResources.locate()
        for name in ["counter-1080p.mp4", "bars-1080p.mp4"] {
            try FileManager.default.copyItem(at: shared.root.appendingPathComponent("fixtures/media/\(name)"), to: card.appendingPathComponent(name))
        }
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.appendingPathComponent("Data").path]))
        app.voiceRecoveryForTests = { }
        #expect(app.set("update.autoCheck", .bool(false)))
        #expect(app.set("llm.connector", .string("codex")))
        #expect(app.set(ClipsMode.capKey, .number(1)))
        await app.start()
        let importer = CardImport(library: library)
        importer.offer(card.deletingLastPathComponent())
        for _ in 0..<200 where importer.scanRunning { try await Task.sleep(for: .milliseconds(25)) }
        #expect(importer.selected.count == 2)
        #expect(importer.blocked(app) == nil)
        let batch = CardImport(library: library)
        batch.offer(card.deletingLastPathComponent())
        for _ in 0..<200 where batch.scanRunning { try await Task.sleep(for: .milliseconds(25)) }
        batch.start(app)
        #expect(batch.budget?.cap == 1)
        batch.stop()
        for _ in 0..<200 where batch.running { try await Task.sleep(for: .milliseconds(25)) }
        importer.start(app, copyOnly: true)
        for _ in 0..<400 where importer.running { try await Task.sleep(for: .milliseconds(25)) }
        #expect(importer.stage == .done)
        #expect(importer.copied == 2)
        #expect(importer.transcribed == 0 && importer.budget == nil)
        let projects = importer.rows.compactMap(\.url)
        #expect(projects.count == 2)
        let cards = Set(importer.files.map(\.id))
        for url in projects {
            let project = try await JSONProjectStore().load(from: url)
            let sources = [project.media.source] + project.media.additionalSources
            #expect(project.schemaVersion == 4 && sources.count == 2)
            #expect(Set(sources.compactMap(\.recordingHash)) == cards)
            #expect(sources.allSatisfy { FileManager.default.fileExists(atPath: $0.absolutePath) })
        }
        importer.offer(card.deletingLastPathComponent())
        for _ in 0..<200 where importer.scanRunning { try await Task.sleep(for: .milliseconds(25)) }
        #expect(importer.files.count == 2 && importer.newFiles.isEmpty)
    }
}
#endif
