#if DEBUG
import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import VoxClipCore
@testable import VoxClip

/// A document never puts up an app-modal alert in a test process: nobody dismisses it, and one left up blocks every
/// later AppKit action in the run. On 2026-11-21 an in-place autosave into a test folder that had already been deleted
/// raised "could not be autosaved" and broke the command-field and shell tests that ran after it.
@Suite("Documents in a test process", .serialized, .offlineFixtures)
@MainActor struct DocumentTestProcessTests {
    init() { _ = NSApplication.shared }
    private func document() throws -> VoxClipDocument {
        let shared = try SharedResources.locate()
        let project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        return VoxClipDocument(project: project)
    }

    @Test func aTestProcessIsDetected() { #expect(TestProcess.isRunning) }

    @Test func anUntitledDocumentOnlyAutosavesAfterItHasATestURL() async throws {
        let document = try document()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-autosave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        defer { document.close() }
        document.fileType = UTType.voxclipProject.identifier
        let before = document.project.modifiedAt
        document.updateChangeCount(.changeDone)

        let untitled = await withTestDeadline(returning: false) { continuation in
            document.autosave(withImplicitCancellability: false) { error in
                continuation.resume(returning: error == nil)
            }
        }
        try #require(untitled)
        try #require(document.autosavedContentsFileURL == nil)
        #expect(document.hasUnautosavedChanges)

        let url = folder.appendingPathComponent("Project.voxclip")
        try JSONProjectStore.encode(document.project).write(to: url)
        document.fileURL = url
        let saved = await withTestDeadline(returning: false) { continuation in
            document.autosave(withImplicitCancellability: false) { error in
                continuation.resume(returning: error == nil)
            }
        }

        try #require(saved)
        let project = try JSONProjectStore.decode(Data(contentsOf: url))
        #expect(project.id == document.project.id)
        #expect(project.modifiedAt != before)
        #expect(!document.hasUnautosavedChanges)
    }

    @Test func anErrorIsRecordedNotShownInAnAlert() throws {
        let document = try document()
        let before = VoxClipDocument.errorsPresentedInTests.count
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError,
                            userInfo: [NSLocalizedDescriptionKey: "The document could not be autosaved."])
        #expect(document.presentError(error) == false)
        #expect(NSApp.modalWindow == nil)
        #expect(!NSApp.windows.contains { $0.isVisible && String(describing: type(of: $0)).contains("Alert") })
        #expect(VoxClipDocument.errorsPresentedInTests.count == before + 1)
        #expect(VoxClipDocument.errorsPresentedInTests.last?.contains("could not be autosaved") == true)
    }

    @Test func aTimedAutosaveIntoADeletedTestFolderIsSkipped() async throws {
        let document = try document()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-gone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        document.fileURL = folder.appendingPathComponent("project.voxclip")
        try FileManager.default.removeItem(at: folder)
        document.updateChangeCount(.changeDone)
        let before = VoxClipDocument.errorsPresentedInTests.count
        let failure: String? = await withCheckedContinuation { continuation in
            document.autosave(withImplicitCancellability: false) { error in continuation.resume(returning: error.map { "\($0)" }) }
        }
        #expect(failure == nil)
        #expect(NSApp.modalWindow == nil)
        #expect(VoxClipDocument.errorsPresentedInTests.count == before)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        document.fileURL = nil
    }
}
#endif
