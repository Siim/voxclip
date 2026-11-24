#if DEBUG
import AppKit
import Foundation
import Testing
import VoxClipCore
@testable import VoxClip

@MainActor @Suite(.serialized) struct CardImportTests {
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
