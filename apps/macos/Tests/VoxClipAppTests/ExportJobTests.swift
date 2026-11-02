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
        let session = RewriteSession(editor: editor, scope: .selection(0...2), envelope: nil, connector: nil)
        editor.rewrite = session
        #expect(shell.panelJob(for: editor) == .rewrite && PanelJob.available(in: editor).contains(.export))
        shell.choosePanelJob(.export, for: editor)
        session.task.show(.running, headline: PanelHeadline(text: "Rewriting"))
        #expect(editor.panelTask == nil && shell.panelJob(for: editor) == .export)
        session.sendApproved = true
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
        // The editor only reads while the banner waits (v5 f24): an export setting is refused, a caption move is not.
        var current = editor.project; current.export.quality = .high; editor.replace(current, name: "Change export quality")
        #expect(editor.project.export.quality != .high)
        var moved = editor.project; moved.captions.position = CaptionPosition(x: 0.5, y: 0.2); editor.replace(moved, name: "Move captions")
        await editor.confirmMediaRelink()
        #expect(editor.project.media.source.absolutePath == url.path && editor.mediaRelinkCandidate == nil)
        #expect(editor.project.captions.position == CaptionPosition(x: 0.5, y: 0.2) && editor.activeClip?.id == "five-2")
    }
    /// While the video is missing (f24c) and while a different-looking file waits for Use It (f24), the editor only reads
    /// (lead decision 7): the clip bar shows Rewrite, Tighten, Hook and the Ask field dimmed, a Rewrite open on the tab
    /// closes and none can start, Export and its entries are refused, and the status bar says why in the task's place.
    /// Use It gives the editor back.
    @Test func theEditorOnlyReadsUntilTheVideoIsConfirmed() async throws {
        let shell = try await shell(exporter: RegressionExporter()), editor = try #require(shell.editor)
        defer { editor.close() }
        shell.choose(.clip("five-1"))
        let bar = ClipBarView(model: editor, shell: shell)
        defer { bar.tearDown() }
        bar.frame = NSRect(x: 0, y: 0, width: 652, height: ShellMetrics.clipBar)
        func lay() { bar.render(); bar.layoutSubtreeIfNeeded() }
        func dimmed() -> Bool {
            let verbs: [NSControl] = [bar.rewrite, bar.tighten, bar.hook, bar.ask]
            return bar.variant == .readOnly("five-1") && verbs.allSatisfy { !$0.isHidden && !$0.isEnabled } && !bar.picker.isHidden
                && bar.isAccessibilityElement() && bar.accessibilityLabel() == "Clip 1 tools"
        }
        func refused() -> Bool {
            !editor.capabilities.edit && !editor.capabilities.ai && !editor.capabilities.export && !editor.mediaExportable
                && editor.mutationEnabled(38) == false && editor.mutationEnabled(45) == false && editor.mutationEnabled(1) == false
        }
        lay()
        #expect(bar.variant == .scope("five-1") && bar.rewrite.isEnabled && editor.statusReadOnly == nil)
        editor.rewrite = RewriteSession(editor: editor, scope: .selection(0...2), envelope: nil, connector: nil)
        // f24c: the video is missing.
        editor.mediaResolved = false; lay()
        #expect(dimmed() && refused() && editor.rewrite == nil)
        #expect(editor.statusReadOnly?.text == "Read-only until you locate the video" && editor.statusReadOnly?.lead == .symbol("exclamationmark.triangle"))
        #expect(StatusBarContent.make(app: editor.app, editor: editor, now: Date())[.task]?.text == "Read-only until you locate the video")
        #expect(bar.rewrite.toolTip == "Read-only until you locate the video" && editor.exportUnavailable == "Locate the video to export.")
        // f24: a different-looking file waits for Use It.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data("different media".utf8).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        editor.mediaResolved = true
        editor.rewrite = RewriteSession(editor: editor, scope: .selection(0...2), envelope: nil, connector: nil)
        await editor.prepareMediaRelink(url: url, probe: MediaProbeResult(durationSeconds: editor.project.media.source.durationSeconds, isPlayable: true))
        lay()
        #expect(editor.mediaRelinkCandidate != nil && dimmed() && refused() && editor.rewrite == nil)
        #expect(editor.statusReadOnly?.text == "Read-only until you confirm the video" && editor.exportUnavailable == "Confirm the video to export.")
        editor.runRewrite(); editor.presentExport()
        #expect(editor.rewrite == nil && !editor.exportJob.isOpen && shell.panelJob(for: editor) == .captions)
        // Use It: the editor edits again.
        await editor.confirmMediaRelink(); lay()
        #expect(editor.mediaRelinkCandidate == nil && editor.capabilities.edit && editor.mediaExportable && editor.statusReadOnly == nil)
        #expect(bar.variant == .scope("five-1") && bar.rewrite.isEnabled && bar.tighten.isEnabled && bar.ask.isEnabled)
    }
    /// A video that is not checked yet is not a missing one: as a project opens, and again as it reverts, Locate… and the
    /// read-only note wait until the video's check answers (on a slow or external volume that takes a while), and the
    /// clip bar and status bar stay as they were before the check.
    @Test func theReadOnlyNoteWaitsForTheVideosCheck() async throws {
        _ = NSApplication.shared
        let app = AppModel(settingsStore: RegressionSettingsStore())
        let editor = EditorModel(document: VoxClipDocument(project: try project()), app: app, preview: DemoPreviewEngine(), exporter: RegressionExporter())
        defer { editor.close() }
        func silent() -> Bool {
            !editor.mediaMissing && editor.mediaReadOnlyNote == nil && editor.statusReadOnly == nil
                && StatusBarContent.make(app: app, editor: editor, now: Date())[.task] == nil
        }
        #expect(!editor.mediaResolved && silent(), "opening: the check has not answered")
        await editor.start()
        // The fixture's video is not on this Mac: the check answers that it is missing.
        #expect(editor.mediaMissing && editor.mediaReadOnlyNote == "Read-only until you locate the video")
        editor.reloadFromDocument(previousProjectID: editor.project.id)
        #expect(!editor.mediaResolved && silent(), "reverting: the check runs again")
        await editor.waitForPendingPreviewForAudit()
        #expect(editor.mediaMissing && editor.mediaReadOnlyNote == "Read-only until you locate the video")
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
    @Test func releasingAPausedExportBeforeItStartsDoesNotLoseTheRelease() async throws {
        let exporter = RegressionExporter()
        await exporter.pauseFirstTarget()
        await exporter.releaseFirstTarget()
        let shell = try await shell(exporter: exporter)
        let editor = try #require(shell.editor)
        defer { editor.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        editor.beginExport(targets: [.clip("five-1")], folder: directory)
        _ = try await TestDeadline.value(editor.exportTask, "previously released export")
        #expect(await exporter.jobs.count == 1)
        #expect(editor.exports.count == 1 && editor.exportError == nil && !editor.exporting)
    }
    @Test func cancellingAPausedExportReleasesItsContinuation() async throws {
        let exporter = RegressionExporter()
        await exporter.pauseFirstTarget()
        let shell = try await shell(exporter: exporter)
        let editor = try #require(shell.editor)
        defer { editor.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        editor.beginExport(targets: [.clip("five-1")], folder: directory)
        try #require(await TestDeadline.until { await !exporter.jobs.isEmpty })
        let task = try #require(editor.exportTask)
        task.cancel()
        _ = try await TestDeadline.value(task, "cancel paused export")
        #expect(editor.exports.isEmpty && editor.exportError == nil && !editor.exporting)
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
        try #require(await TestDeadline.until { await !exporter.jobs.isEmpty })
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
    /// The right panel's one job model (MVP integration): an export renders on while the panel shows another job. A new
    /// Rewrite brings its job forward and its discard question takes the panel while it waits, without touching the
    /// render; answered, Export shows again, and a Rewrite closed under Export leaves Export showing. The status bar's
    /// export item and the percent follow the render throughout, and Done goes back to Captions once Rewrite is gone.
    @Test func anExportRendersOnBehindTheRewriteJobAndItsQuestion() async throws {
        let exporter = RegressionExporter(); await exporter.pauseFirstTarget()
        let shell = try await shell(exporter: exporter), editor = try #require(shell.editor)
        defer { editor.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        shell.choose(.clip("five-1")); editor.presentExport()
        editor.beginExport(targets: [.clip("five-1")], folder: directory)
        await TestDeadline.until { await !exporter.jobs.isEmpty }
        for _ in 0..<2_000 where editor.exportPercent != 25 { await Task.yield() }
        func rendering() -> Bool {
            editor.exporting && editor.exportTask != nil && editor.exportPercent == 25 && editor.statusExport.text == "Exporting 25%"
                && editor.exportJob.isOpen && editor.exportJob.requestedIDs == ["five-1"] && PanelJob.available(in: editor).contains(.export)
        }
        #expect(rendering() && shell.panelJob(for: editor) == .export)
        let session = RewriteSession(editor: editor, scope: .selection(0...2), envelope: nil, connector: nil)
        editor.rewrite = session
        #expect(shell.panelJob(for: editor) == .rewrite && rendering())
        shell.choosePanelJob(.export, for: editor)
        #expect(shell.panelJob(for: editor) == .export && shell.exportReturnJob == .rewrite)
        var answered: [String] = []
        session.task.ask(PanelConfirm(question: "Discard this change?",
                                      cancel: PanelAction(id: "keepWorking", title: "Keep Working") { answered.append("keep"); session.task.dismissConfirm() },
                                      confirm: PanelAction(id: "discardChanges", title: "Discard Changes") { answered.append("discard") }))
        #expect(shell.panelJob(for: editor) == .rewrite && rendering())
        // Done can't end a render, and the question keeps the panel.
        editor.finishExportJob()
        #expect(shell.panelJob(for: editor) == .rewrite && rendering())
        session.task.confirm?.cancel.perform()
        #expect(answered == ["keep"] && shell.panelJob(for: editor) == .export && rendering())
        editor.closeRewrite(returnFocus: false)
        #expect(editor.rewrite == nil && shell.panelJob(for: editor) == .export && rendering())
        await exporter.releaseFirstTarget(); await editor.exportTask?.value
        #expect(!editor.exporting && editor.exports.count == 1 && editor.statusExport.text == "Exported")
        editor.finishExportJob()
        #expect(shell.panelJob(for: editor) == .captions && !PanelJob.available(in: editor).contains(.export))
    }
    /// Every Export entry opens the right panel's Export job on its own target, over an open Rewrite, which stays in
    /// the switcher: the title row's Export (File › Export… calls the same `presentExport`) on the active tab, and an
    /// Explorer EXPORTS row's Export again and Retry on the row's clip, from another tab. Done goes back to Rewrite.
    @Test func everyExportEntryOpensTheJobOnItsTargetOverAnOpenRewrite() async throws {
        let shell = try await shell(exporter: RegressionExporter()), editor = try #require(shell.editor)
        defer { editor.close() }
        shell.choose(.clip("five-1"))
        let session = RewriteSession(editor: editor, scope: .selection(0...2), envelope: nil, connector: nil)
        editor.rewrite = session
        #expect(shell.panelJob(for: editor) == .rewrite)
        let controller = EditorWorkController(model: editor, shell: shell)
        defer { controller.tearDown() }
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1280, height: 800), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = controller.view
        defer { window.contentView = nil; window.close() }
        controller.export.performClick(nil)
        #expect(shell.panelJob(for: editor) == .export && editor.exportJob.requestedIDs == ["five-1"] && shell.viewerShown)
        #expect(PanelJob.available(in: editor) == [.captions, .rewrite, .export, .demo] && window.attachedSheet == nil)
        editor.finishExportJob()
        #expect(shell.panelJob(for: editor) == .rewrite && !editor.exportJob.isOpen)
        let failed = ExportRecord(projectID: editor.project.id, targetID: "five-2", exportedAt: Date(timeIntervalSince1970: 1),
            planFingerprint: "", styleId: editor.project.captions.styleId, aspect: editor.project.export.aspect, outputPath: "",
            failed: true, retryFolder: "/fixture")
        let row = try #require(ExportsListModel(project: editor.project, records: [failed]).rows.first)
        editor.presentExport(row)
        #expect(shell.panelJob(for: editor) == .export && editor.exportJob.requestedIDs == ["five-2"] && editor.exportJobContext == "Clip 2")
        editor.presentExport(row, retry: true)
        #expect(shell.panelJob(for: editor) == .export && editor.exportJob.requestedIDs == ["five-2"] && editor.exportJob.folderOverride?.path == "/fixture")
        #expect(!editor.exporting && editor.activeClip?.id == "five-1" && editor.rewrite === session)
        editor.finishExportJob()
        #expect(shell.panelJob(for: editor) == .rewrite)
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
