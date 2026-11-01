#if DEBUG
import AppKit
import SwiftUI
import Testing
@testable import VoxClipCore
@testable import VoxClip

@Suite("Explorer library", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR"))
@MainActor struct ExplorerLibraryTests {
    private func project() throws -> Project {
        let shared = try SharedResources.locate()
        let base = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        var project = try DebugExplorer.fiveQuestions(from: base)
        project.id = UUID().uuidString.lowercased()
        return project
    }
    private func shell(exporter: any Exporter = RegressionExporter()) async throws -> WorkspaceShell {
        _ = NSApplication.shared
        let shell = WorkspaceShell(app: AppModel(settingsStore: RegressionSettingsStore()))
        await shell.attachForTesting(VoxClipDocument(project: try project()), selection: .fullTake, preview: DemoPreviewEngine(), exporter: exporter)
        let editor = try #require(shell.editor)
        editor.mediaResolved = true; editor.refresh()
        return shell
    }
    private func record(_ project: Project, target: String = "five-1", aspect: AspectRatio = .landscape, time: Double = 1, failed: Bool = false) throws -> ExportRecord {
        var snapshot = project; snapshot.export.aspect = aspect
        let exportTarget: ExportTarget = target == "full" ? .fullEdit : .clip(target)
        return ExportRecord(projectID: project.id, targetID: target, exportedAt: Date(timeIntervalSince1970: time),
            planFingerprint: try ExportFingerprint.value(snapshot, target: exportTarget), styleId: project.captions.styleId, aspect: aspect,
            outputPath: failed ? "" : "/fixture/clip.mp4", targetName: "Saved clip", durationSeconds: 38, width: 1920, height: 1080,
            byteSize: 21_000_000, failed: failed, retryFolder: failed ? "/fixture" : nil)
    }
    @Test func rowsMatchOnlyThisProjectsLedgerNewestFirstIncludingFailedAndEdited() throws {
        var project = try project()
        let exported = try record(project, target: "five-1", aspect: .portrait, time: 3)
        let edited = try record(project, target: "five-2", time: 1)
        let failed = try record(project, target: "full", time: 2, failed: true)
        let other = try record(try self.project(), time: 10)
        let word = try #require(project.transcript?.words.first { $0.id == project.edits.clips[1].startWordId })
        project.edits.corrections[word.id] = "Changed since export"
        let model = ExportsListModel(project: project, records: [edited, other, exported, failed])
        #expect(model.rows.map(\.record) == [exported, failed, edited])
        #expect(model.rows.map(\.status) == [.exported, .failed, .edited])
        #expect(model.rows.map(\.targetName) == ["Clip 1", "Full Take", "Clip 2"])
        #expect(model.rows.first?.title == "Clip 1 · 9:16")
        #expect(model.rows.first?.duration == "0:38" && model.rows.first?.resolution == "1080p")
        #expect(model.rows.first?.size.contains("21") == true)
        #expect(model.rows[1].outputURL == nil && model.rows[1].retryFolder?.path == "/fixture")
        #expect(model.rows.map { $0.status.warning } == [false, true, true])
    }
    @Test func ledgerAdditionsRoundTripAndOldRecordsStillLoadWithoutInventingOutputFacts() throws {
        let project = try project(), entry = try record(project)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("ledger.json")
        try ExportLedger(file: file).record(entry)
        #expect(ExportLedger(file: file).records == [entry])
        let object = try #require(JSONSerialization.jsonObject(with: ProjectJSON.encoder().encode(entry)) as? [String: Any])
        let legacy = object.filter { !["targetName", "durationSeconds", "width", "height", "byteSize", "failed", "retryFolder"].contains($0.key) }
        try JSONSerialization.data(withJSONObject: [legacy]).write(to: file)
        let records = ExportLedger(file: file).records
        #expect(records.count == 1)
        let row = try #require(ExportsListModel(project: project, records: records).rows.first)
        #expect(row.status == .exported && row.duration == "—" && row.resolution == "—" && row.size == "—")
    }
    @Test func successAndFailureAreRecordedByTheActualExportPath() async throws {
        for failed in [false, true] {
            let exporter: any Exporter = failed ? RegressionExporter(failure: .exportFailed("fixture")) : LibraryFileExporter()
            let shell = try await shell(exporter: exporter)
            let editor = try #require(shell.editor)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { editor.close(); try? FileManager.default.removeItem(at: folder) }
            shell.choose(.clip("five-1"))
            editor.presentExport(); editor.beginExport(targets: [.clip("five-1")], folder: folder)
            await editor.exportTask?.value
            let rows = editor.exportsList.rows
            #expect(rows.count == 1)
            let row = try #require(rows.first)
            #expect(row.status == (failed ? .failed : .exported))
            if failed {
                #expect(row.retryFolder?.path == folder.path && row.outputURL == nil)
                editor.failedExports = [:]
                #expect(editor.exportRowStatus("five-1") == .failed)
                editor.finishExportJob(); editor.retryExport("five-1")
                #expect(editor.exportJob.isOpen && editor.exportJob.folderOverride?.path == folder.path)
            } else {
                #expect(row.record.byteSize == 21_000)
                #expect(row.record.durationSeconds == editor.exports.first?.durationSeconds)
                #expect(row.record.width == editor.exports.first?.width && row.record.height == editor.exports.first?.height)
            }
            let reloaded = ExportLedger(file: editor.app.exportLedger.file)
            let persisted = try ProjectJSON.decoder().decode(ExportRecord.self, from: ProjectJSON.encoder().encode(row.record))
            #expect(reloaded.records.contains(persisted))
        }
    }
    @Test(arguments: [false, true])
    func aLaterFailureOrCancelKeepsTheSuccessfulOutput(cancelled: Bool) async throws {
        let exporter = LibraryAttemptExporter()
        let shell = try await shell(exporter: exporter), editor = try #require(shell.editor)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { editor.close(); try? FileManager.default.removeItem(at: folder) }
        editor.beginExport(targets: [.clip("five-1")], folder: folder)
        await editor.exportTask?.value
        let saved = try #require(editor.exportsList.rows.first?.record)
        await exporter.set(cancelled ? .cancel : .fail)
        editor.select(editor.words[0].id); editor.cutSelection() // Output facts must stay attached to the earlier successful snapshot.
        editor.beginExport(targets: [.clip("five-1")], folder: folder)
        await editor.exportTask?.value
        let row = try #require(editor.exportsList.rows.first)
        #expect(row.status == .failed && row.outputURL?.path == saved.outputPath)
        #expect(row.record.outputPath == saved.outputPath && row.record.planFingerprint == saved.planFingerprint)
        #expect(row.record.durationSeconds == saved.durationSeconds && row.record.width == saved.width && row.record.byteSize == saved.byteSize)
        #expect(row.retryFolder?.path == folder.path)
    }
    @Test func cancellationBetweenTargetsLeavesTheNextTargetUnattempted() async throws {
        let exporter = LibraryAttemptExporter(); await exporter.set(.cancelAfterSuccess)
        let shell = try await shell(exporter: exporter), editor = try #require(shell.editor)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { editor.close(); try? FileManager.default.removeItem(at: folder) }
        editor.beginExport(targets: [.clip("five-1"), .clip("five-2")], folder: folder)
        await editor.exportTask?.value
        #expect(editor.exportsList.rows.map(\.record.targetID) == ["five-1"])
        #expect(editor.exportsList.rows.first?.status == .exported)
        #expect(editor.failedExports.isEmpty)
    }

    @Test func aDestinationFailureBeforeRenderingStillMakesAFailedLedgerRow() async throws {
        let exporter = RegressionExporter()
        let shell = try await shell(exporter: exporter), editor = try #require(shell.editor)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { editor.close(); try? FileManager.default.removeItem(at: file) }
        try Data([0]).write(to: file)
        editor.presentExport(clipIDs: ["five-1"])
        editor.beginExport(targets: [.clip("five-1")], folder: file)
        await editor.exportTask?.value
        #expect(await exporter.jobs.isEmpty)
        #expect(editor.exportsList.rows.count == 1 && editor.exportsList.rows.first?.status == .failed)
        #expect(editor.exportsList.rows.first?.record.planFingerprint == "")
        #expect(editor.exportsList.rows.first?.retryFolder?.path == file.path)
    }
    @Test(arguments: ["five-1", "full"])
    func exportAgainAndRetryOpenThatRowsTargetAndAspectFromAnotherTab(target: String) async throws {
        let shell = try await shell(), editor = try #require(shell.editor)
        defer { editor.close() }
        let entry = try record(editor.project, target: target, aspect: .portrait, failed: true)
        let row = try #require(ExportsListModel(project: editor.project, records: [entry]).rows.first)
        shell.choose(.clip("five-2")); editor.presentExport()
        editor.presentExport(row)
        #expect(editor.exportJob.isOpen && editor.exportJob.requestedIDs == (target == "full" ? [] : [target]))
        #expect(editor.exportJob.scope == (target == "full" ? .fullVideo : .thisClip))
        #expect(editor.project.export.aspect == .portrait)
        #expect(!editor.exporting && editor.exports.isEmpty)
        editor.presentExport(row, retry: true)
        #expect(editor.exportJob.folderOverride?.path == "/fixture")
    }
    @Test func runningExportsKeepTheirTargetWhenALibraryActionArrives() async throws {
        let exporter = RegressionExporter(); await exporter.pauseFirstTarget()
        let shell = try await shell(exporter: exporter), editor = try #require(shell.editor)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { editor.close(); try? FileManager.default.removeItem(at: folder) }
        editor.setAspect(.landscape)
        shell.choose(.clip("five-2")); editor.presentExport()
        editor.beginExport(targets: [.clip("five-2")], folder: folder)
        while await exporter.jobs.isEmpty { await Task.yield() }
        let row = try #require(ExportsListModel(project: editor.project, records: [try record(editor.project, aspect: .portrait)]).rows.first)
        editor.presentExport(row)
        #expect(editor.exporting && editor.exportJob.requestedIDs == ["five-2"] && editor.project.export.aspect == .landscape)
        await exporter.releaseFirstTarget(); await editor.exportTask?.value
    }
    @Test func productionLibraryHidesVoicesAndDrawsExportRowsAtTheNotesHeight() async throws {
        let shell = try await shell(), editor = try #require(shell.editor)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { editor.close(); try? FileManager.default.removeItem(at: folder) }
        editor.app.exportLedger = ExportLedger(file: folder.appendingPathComponent("exports.json"))
        try editor.app.exportLedger.record(record(editor.project))
        let shared = try SharedResources.locate()
        editor.app.voiceLabSession.records = [try JSONDecoder().decode(VoiceConsentRecord.self,
            from: Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record.json")))]
        shell.setExplorerExpanded(.exports, true); shell.setExplorerExpanded(.voices, true)
        func drawn() -> ([String: String], [String: CGRect]) {
            let host = NSHostingView(rootView: ExplorerLibrarySections(shell: shell, editor: editor).frame(width: 224))
            host.frame = NSRect(x: 0, y: 0, width: 224, height: 200); host.layoutSubtreeIfNeeded()
            return (DebugRightColumn.texts(in: host), DebugRightColumn.markers(in: host))
        }
        editor.app.settings.values["voiceLab.enabled"] = .bool(false)
        var (texts, frames) = drawn()
        #expect(texts["explorer.header.voices"] == nil && texts["explorer.voice"] == nil)
        #expect(texts["explorer.header.exports"] == "Exports, 1 item")
        #expect(texts["explorer.export"] == editor.exportsList.rows.first?.accessibilityLabel)
        #expect(frames["explorer.export"]?.height == 28)
        editor.app.settings.values["voiceLab.enabled"] = .bool(true)
        (texts, frames) = drawn()
        #expect(texts["explorer.header.voices"] == "Voices, 1 item")
        #expect(texts["explorer.voice"] == shell.explorerVoices.first?.accessibilityLabel)
        #expect(frames["explorer.voice"]?.height == 28 && texts["explorer.voice.state"] == "Ready")
        editor.app.voiceLabSession.records[0].status = .verificationRequired
        (texts, frames) = drawn()
        #expect(texts["explorer.voice.state"] == "Needs attention")
        shell.setExplorerExpanded(.exports, false); shell.setExplorerExpanded(.voices, false)
        (texts, frames) = drawn()
        #expect(texts["explorer.export"] == nil && texts["explorer.voice"] == nil)
        #expect(texts["explorer.header.voices"] == "Voices, 1 item" && texts["explorer.header.exports"] == "Exports, 1 item")
    }
    @Test func removedTargetsStayVisibleButCannotRetargetAJob() async throws {
        let shell = try await shell(), editor = try #require(shell.editor)
        defer { editor.close() }
        let entry = try record(editor.project)
        let stale = try #require(ExportsListModel(project: editor.project, records: [entry]).rows.first)
        let otherProject = try project()
        let foreign = try #require(ExportsListModel(project: otherProject, records: [try record(otherProject)]).rows.first)
        editor.presentExport(foreign)
        #expect(!editor.exportJob.isOpen)
        var changed = editor.project; changed.edits.clips.removeAll { $0.id == entry.targetID }
        editor.document.replaceProject(changed); editor.refresh()
        let row = try #require(ExportsListModel(project: changed, records: [entry]).rows.first)
        #expect(!row.targetExists && row.targetName == "Saved clip" && row.status == .edited)
        editor.presentExport(row); editor.presentExport(stale)
        #expect(!editor.exportJob.isOpen)
    }
    @Test func voiceRowsUseVisibleRecordsAndVanishWithTheBetaSettingOff() async throws {
        let shell = try await shell(), editor = try #require(shell.editor)
        defer { editor.close() }
        let shared = try SharedResources.locate()
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record.json")))
        var deleted = record; deleted.status = .deleted
        editor.app.voiceLabSession.records = [record, deleted]
        editor.app.settings.values["voiceLab.enabled"] = .bool(false)
        #expect(!shell.explorerShowsVoices && shell.explorerVoices.isEmpty)
        editor.app.settings.values["voiceLab.enabled"] = .bool(true)
        #expect(shell.explorerShowsVoices && shell.explorerVoices.count == 1)
        let row = try #require(shell.explorerVoices.first)
        #expect(row.name == record.voiceName && row.made.hasPrefix("made ") && row.made.hasSuffix("from a read-aloud") && row.state == "Ready")
        var attention = record; attention.status = .verificationRequired
        editor.app.voiceLabSession.records = [attention]
        #expect(shell.explorerVoices.first?.state == "Needs attention")
        editor.app.settings.values["voiceLab.enabled"] = .bool(false)
        #expect(shell.explorerVoices.isEmpty && !shell.explorerShowsVoices)
    }
    @Test func libraryGroupsSpeakCountsAndDisclosuresPersistWithoutEditing() async throws {
        let shell = try await shell(), editor = try #require(shell.editor)
        defer { editor.close() }
        for section in [ExplorerSection.voices, .exports] {
            editor.app.settings.values[section.key] = nil
            #expect(!shell.explorerExpanded(section))
            #expect(ExplorerHeader(shell: shell, section: section, count: 1).accessibilityName == "\(section.title), 1 item")
            #expect(ExplorerHeader(shell: shell, section: section, count: 2).accessibilityName == "\(section.title), 2 items")
            shell.setExplorerExpanded(section, true)
            #expect(editor.app.bool("ui.explorer.\(section.rawValue)"))
            shell.setExplorerExpanded(section, false)
        }
        #expect(!editor.document.isDocumentEdited && !editor.document.hasUnautosavedChanges)
    }
    @Test func warningsBelongToExportRowsAndManagementStaysInSettings() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/VoxClip/ExplorerView.swift"), encoding: .utf8)
        let clipRow = try #require(source.components(separatedBy: "@MainActor struct ClipRow: View {").last)
        let body = try #require(clipRow.components(separatedBy: "@MainActor private struct ExplorerClipMenu").first)
        #expect(!body.contains("explorer.exportWarning") && !body.contains("exclamationmark.triangle"))
        let library = try String(contentsOf: root.appendingPathComponent("Sources/VoxClip/ExplorerLibrary.swift"), encoding: .utf8)
        #expect(library.contains("explorer.exportWarning") && library.contains("row.status.warning"))
        #expect(library.contains("openVoxClipSettings(pane: \"voiceLab\")"))
        for forbidden in [".sheet(", ".alert(", ".confirmationDialog(", "NSAlert"] { #expect(!library.contains(forbidden)) }
    }
}

private actor LibraryAttemptExporter: Exporter {
    enum Outcome { case success, fail, cancel, cancelAfterSuccess }
    private var outcome = Outcome.success
    func set(_ value: Outcome) { outcome = value }
    func export(_ job: ExportJob, progress: @escaping @Sendable (ExportProgress) -> Void) async throws -> ExportResult {
        if outcome == .fail { throw VoxClipError.exportFailed("fixture") }
        if outcome == .cancel { throw CancellationError() }
        try Data(repeating: 0, count: 21_000).write(to: job.outputURL)
        let result = try await RegressionExporter().export(job, progress: progress)
        if outcome == .cancelAfterSuccess { withUnsafeCurrentTask { $0?.cancel() } }
        return result
    }
}

/// A real local file lets the production ledger path read actual byte size.
private actor LibraryFileExporter: Exporter {
    func export(_ job: ExportJob, progress: @escaping @Sendable (ExportProgress) -> Void) async throws -> ExportResult {
        try Data(repeating: 0, count: 21_000).write(to: job.outputURL)
        return try await RegressionExporter().export(job, progress: progress)
    }
}
#endif
