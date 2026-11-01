#if DEBUG
import AppKit
import SwiftUI
import Testing
@testable import VoxClipCore
@testable import VoxClip

@Suite("Export job", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR"))
@MainActor struct ExportJobTests {
    private func project() throws -> Project {
        let shared = try SharedResources.locate()
        let base = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        var project = try DebugExplorer.fiveQuestions(from: base)
        project.id = UUID().uuidString.lowercased()
        return project
    }
    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/VoxClip/" + name), encoding: .utf8)
    }
    @Test(arguments: [false, true])
    func exportEntryRetargetsAnOpenIdleJobWithoutDone(finished: Bool) async throws {
        let shell = try await shell(exporter: RegressionExporter()), editor = try #require(shell.editor)
        defer { editor.close() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        shell.choose(.clip("five-1")); editor.presentExport()
        if finished { editor.beginExport(targets: [.clip("five-1")], folder: folder); await editor.exportTask?.value; #expect(editor.exports.count == 1) }
        shell.choose(.clip("five-2")); editor.presentExport()
        #expect(editor.exportJob.requestedIDs == ["five-2"] && editor.exportClipIDs == ["five-2"])
        #expect(editor.exportJobContext == "Clip 2" && editor.exports.isEmpty)
        shell.choose(.fullTake); editor.presentExport()
        #expect(editor.exportJob.requestedIDs.isEmpty && editor.exportJobContext == "Full Edit")
    }
    @Test func aNewRewriteAndANewTurnBringTheirJobForwardWhileExportStaysAvailable() async throws {
        let shell = try await shell(exporter: RegressionExporter()), editor = try #require(shell.editor)
        defer { editor.close() }
        editor.app.set("voiceLab.enabled", .bool(true)); editor.app.set("voiceLab.betaNoticeAccepted", .bool(true))
        editor.presentExport()
        let session = RewriteSession(editor: editor, range: 0...2, envelope: nil, connector: nil)
        editor.rewrite = session
        #expect(shell.panelJob(for: editor) == .rewrite && PanelJob.available(in: editor).contains(.export))
        shell.choosePanelJob(.export, for: editor)
        session.task.show(.running, headline: PanelHeadline(text: "Rewriting"))
        #expect(shell.panelJob(for: editor) == .rewrite)
        shell.choosePanelJob(.export, for: editor)
        editor.finishExportJob()
        #expect(shell.panelJob(for: editor) == .rewrite)
    }
    @Test func confirmingDifferentMediaRelinksTheCurrentScopeAndKeepsEdits() async throws {
        let shell = try await shell(exporter: RegressionExporter()), editor = try #require(shell.editor)
        defer { editor.close() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data("different media".utf8).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        await editor.prepareMediaRelink(url: url, probe: MediaProbeResult(durationSeconds: editor.project.media.source.durationSeconds, isPlayable: true))
        #expect(editor.mediaRelinkCandidate != nil)
        #expect(editor.announcements.contains("This file looks different. Use it anyway? \(url.lastPathComponent)"))
        shell.choose(.clip("five-2"))
        var current = editor.project; current.export.quality = .high; editor.replace(current, name: "Change export quality")
        await editor.confirmMediaRelink()
        #expect(editor.project.media.source.absolutePath == url.path && editor.mediaRelinkCandidate == nil)
        #expect(editor.project.export.quality == .high && editor.activeClip?.id == "five-2")
    }
    @Test func aRefusedRelinkKeepsTheBannerAndExplainsWhy() async throws {
        let shell = try await shell(exporter: RegressionExporter()), editor = try #require(shell.editor)
        defer { editor.close() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data("different media".utf8).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        await editor.prepareMediaRelink(url: url, probe: MediaProbeResult(durationSeconds: editor.project.media.source.durationSeconds, isPlayable: true))
        editor.isLeaving = true
        await editor.confirmMediaRelink()
        #expect(editor.mediaRelinkCandidate != nil && editor.previewError?.isEmpty == false)
    }
    @Test func choosingThisClipCapturesItsTargetForTheHeaderAndExport() async throws {
        let shell = try await shell(exporter: RegressionExporter()), editor = try #require(shell.editor)
        defer { editor.close() }
        editor.presentExport()
        shell.choose(.clip("five-2"))
        editor.exportJob.selectScope(.thisClip, model: editor)
        #expect(editor.exportJob.requestedIDs == ["five-2"])
        #expect(editor.exportJobContext == "Clip 2")
        #expect(editor.exportTargets(editor.exportJob.scope, requestedIDs: editor.exportJob.requestedIDs) == [.clip("five-2")])
    }
    @Test func copyFeedbackResetsAndRestartsItsTimer() throws {
        let job = ExportJobState()
        job.captionCopied(); #expect(job.copied)
        let timer = try #require(job.captionCopyTimer)
        job.captionCopied(); #expect(!timer.isValid)
        let next = try #require(job.captionCopyTimer)
        next.fire(); #expect(!job.copied && job.captionCopyTimer == nil)
    }
    @Test func shareOpeningRequiresHTTPS() throws {
        for host in ["x.com", "www.linkedin.com"] {
            #expect(ShareText.allowsOpening(try #require(URL(string: "https://\(host)/"))))
            #expect(!ShareText.allowsOpening(try #require(URL(string: "http://\(host)/"))))
        }
        #expect(!ShareText.allowsOpening(try #require(URL(string: "https://example.com/"))))
    }

    @Test func exportEntryShowsTheRightPanelForItsRequestedClip() async throws {
        _ = NSApplication.shared
        let shell = WorkspaceShell(app: AppModel(settingsStore: RegressionSettingsStore()))
        await shell.attachForTesting(VoxClipDocument(project: try project()), selection: .fullTake, preview: DemoPreviewEngine())
        let editor = try #require(shell.editor)
        defer { editor.close() }
        editor.mediaResolved = true; editor.mediaUnreadable = false; editor.refresh()
        shell.choose(.clip("five-1"))
        editor.presentExport()
        #expect(shell.panelJob(for: editor).rawValue == "export")
        #expect(editor.exportClipIDs == ["five-1"] && shell.viewerShown)
    }
    @Test func exportAndDifferentMediaConfirmationHaveNoModalPath() throws {
        let model = try source("EditorModel.swift")
        let view = try source("EditorView.swift")
        #expect(!model.contains("var showExport"))
        #expect(!view.contains("editorFlag(\\.showExport)"))
        let relink = try #require(model.range(of: "func locateMedia()"))
        let end = try #require(model.range(of: "func apply(", range: relink.upperBound..<model.endIndex))
        #expect(!model[relink.lowerBound..<end.lowerBound].contains("NSAlert"))
    }
    private func shell(exporter: RegressionExporter) async throws -> WorkspaceShell {
        _ = NSApplication.shared
        let shell = WorkspaceShell(app: AppModel(settingsStore: RegressionSettingsStore()))
        await shell.attachForTesting(VoxClipDocument(project: try project()), selection: .fullTake, preview: DemoPreviewEngine(), exporter: exporter)
        let editor = try #require(shell.editor)
        editor.mediaResolved = true; editor.mediaUnreadable = false; editor.refresh()
        return shell
    }
    @Test func jobRunsAcrossPanelAndTabSwitchesThenDoneReturnsToPreviousJob() async throws {
        let exporter = RegressionExporter(); await exporter.pauseFirstTarget()
        let shell = try await shell(exporter: exporter), editor = try #require(shell.editor)
        defer { editor.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        shell.choose(.clip("five-1")); editor.presentExport()
        #expect(editor.exportJob.scope == .thisClip && editor.exportPrimaryTitle([.clip("five-1")]) == "Export Clip 1")
        editor.exportJob.fileNamePattern = "custom-{clip}"
        editor.beginExport(targets: [.clip("five-1")], folder: directory)
        while await exporter.jobs.isEmpty { await Task.yield() }
        #expect(editor.exporting)
        shell.choosePanelJob(.captions, for: editor); shell.choose(.clip("five-2"))
        editor.presentExport()
        #expect(editor.exporting && editor.exportJob.requestedIDs == ["five-1"])
        shell.choosePanelJob(.export, for: editor)
        #expect(editor.exportJobContext == "Clip 1" && editor.exportJob.fileNamePattern == "custom-{clip}")
        await exporter.releaseFirstTarget(); await editor.exportTask?.value
        #expect(!editor.exporting && editor.exports.count == 1 && editor.exportError == nil)
        #expect(editor.exports.first?.outputURL.lastPathComponent.hasPrefix("custom-") == true)
        editor.exportJob.selectShareTarget("five-1", model: editor)
        editor.exportJob.draft.edit("Keep this caption across a new render")
        editor.exportJob.draft.setDisclosure(true)
        editor.beginExport(targets: [.clip("five-1")], folder: directory); await editor.exportTask?.value
        #expect(editor.project.share.captions["five-1"] == "Keep this caption across a new render")
        #expect(editor.exportJob.draft.draftTarget == nil && !editor.exportJob.draft.addDisclosure)
        editor.finishExportJob()
        #expect(shell.panelJob(for: editor) == .captions && !editor.exportJob.isOpen)
    }
    @Test func failedExportOffersTryAgainAndExplorerRetryOpensSetupWithTargetAndFolder() async throws {
        let exporter = RegressionExporter(failure: .exportFailed("Fixture failure"))
        let shell = try await shell(exporter: exporter), editor = try #require(shell.editor)
        defer { editor.close() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        editor.presentExport(clipIDs: ["five-1"])
        editor.beginExport(targets: [.clip("five-1")], folder: folder); await editor.exportTask?.value
        #expect(editor.exportError != nil && editor.exportPrimaryTitle([.clip("five-1")]) == "Try again")
        shell.choose(.clip("five-2")); editor.retryExport("five-1")
        #expect(!editor.exporting && editor.exportJob.requestedIDs == ["five-1"] && editor.exportJob.folderOverride == folder)
        #expect(shell.panelJob(for: editor) == .export)
        #expect(await exporter.jobs.count == 1)
    }
    @Test func relinkWaitsForExplicitUseAndCancelLeavesTheProjectUnchanged() async throws {
        let shell = try await shell(exporter: RegressionExporter()), editor = try #require(shell.editor)
        defer { editor.close() }
        let base = editor.project
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data("different media".utf8).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let probe = MediaProbeResult(durationSeconds: base.media.source.durationSeconds, isPlayable: true)
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        await editor.prepareMediaRelink(url: url, probe: probe)
        #expect(editor.mediaRelinkCandidate != nil && editor.project == base && !undo.canUndo)
        editor.cancelMediaRelink(); await editor.confirmMediaRelink()
        #expect(editor.project == base && editor.mediaRelinkCandidate == nil && !undo.canUndo)
        // Choosing Another clears the candidate before its system picker; cancellation is the same no-op.
        await editor.prepareMediaRelink(url: url, probe: probe); editor.cancelMediaRelink()
        #expect(editor.project == base)
        await editor.prepareMediaRelink(url: url, probe: probe)
        undo.beginUndoGrouping(); await editor.confirmMediaRelink(); undo.endUndoGrouping()
        #expect(editor.project.media.source.absolutePath == url.path && undo.canUndo)
        undo.undo(); #expect(editor.project == base && !undo.canUndo)
    }
    @Test func relinkRejectsDurationMismatchAndStaleBanner() async throws {
        let shell = try await shell(exporter: RegressionExporter()), editor = try #require(shell.editor)
        defer { editor.close() }
        let base = editor.project
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data("different media".utf8).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        await editor.prepareMediaRelink(url: url, probe: MediaProbeResult(durationSeconds: base.media.source.durationSeconds + 1, isPlayable: true))
        #expect(editor.mediaRelinkCandidate == nil && editor.project == base && editor.previewError?.contains("0.05") == true)
        await editor.prepareMediaRelink(url: url, probe: MediaProbeResult(durationSeconds: base.media.source.durationSeconds, isPlayable: true))
        #expect(editor.mediaRelinkCandidate != nil && editor.previewError == nil)
        editor.isLeaving = true; await editor.confirmMediaRelink()
        #expect(editor.project == base)
    }

    @Test func titleRowAndMenuShareThePanelEntryAndNeverAttachASheet() async throws {
        let shell = try await shell(exporter: RegressionExporter()), editor = try #require(shell.editor)
        defer { editor.close() }
        shell.choose(.clip("five-2"))
        shell.toggleViewer()
        let controller = EditorWorkController(model: editor, shell: shell)
        defer { controller.tearDown() }
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1280, height: 800), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = controller.view
        controller.export.performClick(nil)
        #expect(shell.panelJob(for: editor) == .export && editor.exportClipIDs == ["five-2"] && shell.viewerShown)
        #expect(window.attachedSheet == nil)
        // The existing File > Export… selector calls this same entry with the same captured active scope.
        let menu = try source("VoxClipApp.swift")
        #expect(menu.contains("@objc private func exportProject(_ sender: Any?) { editor?.presentExport() }"))
        #expect(menu.contains("add(file, \"Export…\", #selector(exportProject(_:)), \"e\", target: self)"))
        editor.finishExportJob(); editor.presentExport()
        #expect(editor.exportClipIDs == ["five-2"] && shell.panelJob(for: editor) == .export)
        window.contentView = nil; window.close()
    }
    @Test func exportControlsKeepAUsableScrollAndFooterAtTheMinimumColumn() async throws {
        let shell = try await shell(exporter: RegressionExporter()), editor = try #require(shell.editor)
        defer { editor.close() }; editor.presentExport(clipIDs: ["five-1"])
        let size = CGSize(width: 324, height: 322)
        let host = NSHostingView(rootView: PanelHost(model: editor, shell: shell, width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        for _ in 0..<100 { host.layoutSubtreeIfNeeded(); if !DebugRightColumn.scrollViews(in: host).isEmpty { break }; await Task.yield() }
        let scroll = try #require(DebugRightColumn.scrollViews(in: host).first)
        #expect(scroll.contentView.bounds.height >= 24)
        #expect(host.fittingSize.width <= size.width + 1)
    }

    @Test func existingExportEngineAndLedgerChecksStillPassInTheJob() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let results = try await DebugExport.run(app: AppModel(settingsStore: RegressionSettingsStore()), fixture: project(), directory: directory, captures: false)
        for result in results { #expect(result.passed, Comment(rawValue: result.name)) }
    }


    @Test func optionalShareSectionIsRememberedAcrossJobsAndDoneNeverRequiresSharing() async throws {
        let shell = try await shell(exporter: RegressionExporter()), editor = try #require(shell.editor)
        defer { editor.close() }
        #expect(!shell.app.bool("ui.export.shareExpanded"))
        editor.presentExport(); editor.finishExportJob()
        #expect(!editor.exportJob.isOpen && shell.panelJob(for: editor) == .captions)
        #expect(shell.app.boolBinding("ui.export.shareExpanded").wrappedValue == false)
        shell.app.boolBinding("ui.export.shareExpanded").wrappedValue = true
        editor.presentExport(); editor.finishExportJob(); editor.presentExport()
        #expect(shell.app.bool("ui.export.shareExpanded"))
        #expect(!editor.exportJob.draft.addDisclosure)
    }

}
#endif
