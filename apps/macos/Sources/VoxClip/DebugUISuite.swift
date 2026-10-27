#if DEBUG
import SwiftUI
import VoxClipCore
import UniformTypeIdentifiers
import Darwin
import ApplicationServices

@MainActor enum DebugUISuite {
    private static var ran = false
    private static var toolbarEvidence: [Result] = []
    struct Result: Codable {
        let name: String
        let passed: Bool
        var skipped: String? = nil
    }
    struct Layout: Codable { let transcriptWidth: Double; let previewWidth: Double }
    struct ToolbarExtent: Codable { let label: String; let width: Double; let attached: Bool }
    private struct BoundaryCheckpoint: Codable {
        let phase: String
        let modelStyle: String
        let modelID: String
        let modelRelativePath: String?
        let diskStyle: String?
        let diskID: String?
        let diskRelativePath: String?
        let expectedRelativePath: String?
        let nativeURL: String?
        let windowURL: String?
        let appURL: String?
        let nativeEdited: Bool
        let windowEdited: Bool
        let nativeHasUnautosavedChanges: Bool
        let undoGroupingLevel: Int
        let undoCanUndo: Bool
        let undoCanRedo: Bool
        let undoActionName: String
    }
    static func settingsAudit(app: AppModel, destination: URL) async {
        var results: [Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(Result(name: name, passed: passed)) }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            guard let delegate = NSApp.delegate as? AppDelegate,
                  let command = NSApp.mainMenu?.item(withTitle: "VoxClip")?.submenu?.item(withTitle: "Settings…") else {
                throw CocoaError(.coderInvalidValue)
            }
            func openFromCommand() -> NSWindow? {
                guard let action = command.action, NSApp.sendAction(action, to: command.target, from: command) else { return nil }
                return delegate.settingsWindowForTests
            }
            func appearance(_ window: NSWindow) -> NSAppearance.Name? {
                window.contentViewController?.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            }
            func settleAppearance(_ expected: NSAppearance.Name, in window: NSWindow) async -> Bool {
                for _ in 0..<50 {
                    if appearance(window) == expected { return true }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                return false
            }
            let library = app.modelLibrary
            let libraryTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
            library.task = libraryTask
            defer { libraryTask.cancel(); library.task = nil }
            app.set("general.appearance", .string("light"))
            guard let window = openFromCommand() else { throw CocoaError(.coderInvalidValue) }
            check("Settings command opens a retained app-owned window", window.isVisible && !window.isReleasedWhenClosed && delegate.settingsWindowForTests === window)
            check("open Settings applies Light appearance", await settleAppearance(.aqua, in: window))
            app.set("general.appearance", .string("dark"))
            check("open Settings reacts to Dark appearance", await settleAppearance(.darkAqua, in: window))
            app.set("general.appearance", .string("light"))
            check("open Settings reacts back to Light appearance", await settleAppearance(.aqua, in: window))
            window.close()
            check("first close preserves library, task and window owner", !window.isVisible && delegate.settingsWindowForTests === window && app.modelLibrary === library && library.task != nil && !libraryTask.isCancelled)
            guard openFromCommand() === window else { throw CocoaError(.coderInvalidValue) }
            check("first reopen uses the real Settings command and same window", window.isVisible && delegate.settingsWindowForTests === window)
            check("reopened Settings retains Light appearance", await settleAppearance(.aqua, in: window))
            app.set("general.appearance", .string("system"))
            let systemAppearance = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
            check("open Settings follows System appearance", await settleAppearance(systemAppearance, in: window))
            app.set("export.fileNamePattern", .string("r7-accepted-{project}"))
            check("accepted Settings text remains in app model", app.string("export.fileNamePattern") == "r7-accepted-{project}")
            window.close()
            guard openFromCommand() === window else { throw CocoaError(.coderInvalidValue) }
            check("second close and reopen preserves accepted text and task", window.isVisible && app.string("export.fileNamePattern") == "r7-accepted-{project}" && app.modelLibrary === library && library.task != nil && !libraryTask.isCancelled)
            check("reopened Settings still follows System appearance", await settleAppearance(systemAppearance, in: window))
            var tabs: NSSegmentedControl?
            for _ in 0..<50 {
                tabs = settingsControl(in: window) { (control: NSSegmentedControl) in
                    (0..<control.segmentCount).contains { control.label(forSegment: $0) == "Export" }
                }
                if tabs != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            var selectedExport = false
            if let tabs, let segment = (0..<tabs.segmentCount).first(where: { tabs.label(forSegment: $0) == "Export" }), let action = tabs.action {
                tabs.selectedSegment = segment
                selectedExport = tabs.sendAction(action, to: tabs.target)
            }
            check("real Settings Export tab can be selected", selectedExport)
            var patternField: NSTextField?
            for _ in 0..<50 {
                patternField = settingsControl(in: window) { (field: NSTextField) in field.isEditable && field.stringValue == "r7-accepted-{project}" }
                if patternField != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            func fieldValue(_ field: NSTextField?) -> String? { (field?.currentEditor() as? NSTextView)?.string ?? field?.stringValue }
            check("reopened real Settings field shows accepted text", fieldValue(patternField) == "r7-accepted-{project}")
            let pending = "r7-pending-{clip}"
            if let patternField { window.makeFirstResponder(patternField) }
            var fieldEditor: NSTextView?
            for _ in 0..<50 {
                fieldEditor = window.firstResponder as? NSTextView
                if fieldEditor?.isFieldEditor == true { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            if let fieldEditor, fieldEditor.isFieldEditor {
                fieldEditor.selectAll(nil)
                fieldEditor.insertText(pending, replacementRange: fieldEditor.selectedRange())
            }
            for _ in 0..<50 {
                if fieldValue(patternField) == pending { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            check("real Settings text field accepts pending input", fieldEditor?.isFieldEditor == true && fieldValue(patternField) == pending && app.string("export.fileNamePattern") == "r7-accepted-{project}")
            window.close()
            guard openFromCommand() === window else { throw CocoaError(.coderInvalidValue) }
            let reopenedField: NSTextField? = settingsControl(in: window) { $0.isEditable && fieldValue($0) == pending }
            check("pending Settings text survives close and reopen", fieldValue(reopenedField) == pending)
            check("third reopen retains library and active task", app.modelLibrary === library && library.task != nil && !libraryTask.isCancelled)
            window.close()
        } catch { results.append(Result(name: "Settings audit: \(error.localizedDescription)", passed: false)) }
        if let data = try? JSONEncoder().encode(results) { try? data.write(to: destination.appendingPathComponent("settings-results.json"), options: .atomic) }
        exit(results.allSatisfy(\.passed) ? 0 : 1)
    }
    static func saveBoundaryAudit(app: AppModel, destination: URL) async {
        var results: [Result] = []
        var checkpoints: [BoundaryCheckpoint] = []
        func check(_ name: String, _ passed: Bool) { results.append(Result(name: name, passed: passed)) }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for _ in 0..<80 {
                if app.shell.windowController?.window?.isVisible == true { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard let window = app.shell.windowController?.window, let shared = app.shared?.root else { throw CocoaError(.coderInvalidValue) }
            let source = destination.appendingPathComponent("source.mp4")
            try FileManager.default.copyItem(at: shared.appendingPathComponent("fixtures/media/fillers-chirp.mp4"), to: source)
            // The movie imports as a new untitled project attached to the main window.
            await app.shell.importVideo(source)
            guard let model = app.shell.editor, let native = window.windowController?.document as? NSDocument,
                  native === model.document else { throw CocoaError(.coderInvalidValue) }
            try await Task.sleep(for: .milliseconds(1200))
            check("an untranscribed import keeps asking for transcript focus until its transcript arrives", model.wantsTranscriptFocus)
            model.setStyle("off")
            let firstFolder = destination.appendingPathComponent("first", isDirectory: true)
            let secondFolder = destination.appendingPathComponent("second/deeper", isDirectory: true)
            try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
            let first = firstFolder.appendingPathComponent("saved.voxclip")
            let second = secondFolder.appendingPathComponent("moved.voxclip")
            func checkpoint(_ phase: String, diskURL: URL? = nil) {
                let disk = diskURL.flatMap { try? VoxClipDocument(data: Data(contentsOf: $0)).project }
                let expected = diskURL.flatMap { JSONProjectStore.relativePath(source: source, projectURL: $0) }
                checkpoints.append(BoundaryCheckpoint(
                    phase: phase, modelStyle: model.project.captions.styleId, modelID: model.project.id,
                    modelRelativePath: model.project.media.source.relativePath,
                    diskStyle: disk?.captions.styleId, diskID: disk?.id,
                    diskRelativePath: disk?.media.source.relativePath, expectedRelativePath: expected,
                    nativeURL: native.fileURL?.path, windowURL: window.representedURL?.path,
                    appURL: model.document.fileURL?.path, nativeEdited: native.isDocumentEdited,
                    windowEdited: window.isDocumentEdited, nativeHasUnautosavedChanges: native.hasUnautosavedChanges,
                    undoGroupingLevel: model.undoManager?.groupingLevel ?? -1,
                    undoCanUndo: model.undoManager?.canUndo ?? false,
                    undoCanRedo: model.undoManager?.canRedo ?? false,
                    undoActionName: model.undoManager?.undoActionName ?? ""))
                if let data = try? JSONEncoder().encode(checkpoints) {
                    try? data.write(to: destination.appendingPathComponent("save-boundary-checkpoints.json"), options: .atomic)
                }
                if let data = try? JSONEncoder().encode(model.document.saveBoundaryEvents()) {
                    try? data.write(to: destination.appendingPathComponent("save-boundary-events.json"), options: .atomic)
                }
            }
            func settledURL(_ url: URL) async throws {
                for _ in 0..<50 {
                    if native.fileURL == url && window.representedURL == url && model.document.fileURL == url && model.undoManager?.groupingLevel == 0 { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            // The Home card's title, once Recent has read the project file. The read runs at
            // utility priority and draws two caption cards, so a busy Mac needs a while.
            func homeCardTitle(_ url: URL, _ expected: String) async throws -> String? {
                for _ in 0..<200 where app.recentProjects.items[url]?.title != expected {
                    app.recentProjects.refresh(app.recent)
                    try await Task.sleep(for: .milliseconds(50))
                }
                return app.recentProjects.items[url]?.title
            }
            func settledEdited(_ edited: Bool) async throws {
                for _ in 0..<50 {
                    if native.isDocumentEdited == edited && window.isDocumentEdited == edited && native.hasUnautosavedChanges == edited && model.undoManager?.groupingLevel == 0 { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            checkpoint("before-first-save", diskURL: first)
            try await save(native, to: first)
            try await settledURL(first)
            checkpoint("first-save-as", diskURL: first)
            let firstDisk = try VoxClipDocument(data: Data(contentsOf: first)).project
            check("first Save As adopts the destination", native.fileURL == first && window.representedURL == first && model.document.fileURL == first)
            check("first Save As updates the native title", window.title == "saved" && model.project.title == "saved" && firstDisk.title == "saved")
            check("first Save As writes the accepted project", firstDisk.id == model.project.id && firstDisk.captions.styleId == "off")
            check("first Save As writes destination-relative media", firstDisk.media.source.relativePath == JSONProjectStore.relativePath(source: source, projectURL: first))
            check("first Save As settles clean", !native.isDocumentEdited && !window.isDocumentEdited && !native.hasUnautosavedChanges)
            model.setStyle("vox-highlight")
            try await settledEdited(true)
            checkpoint("immediate-edit", diskURL: first)
            check("immediate edit after Save As stays dirty", model.project.captions.styleId == "vox-highlight" && native.isDocumentEdited && window.isDocumentEdited)
            model.undoManager?.undo()
            checkpoint("undo-to-first-save", diskURL: first)
            check("Undo to first Save As content settles clean", model.project.captions.styleId == "off" && !native.isDocumentEdited && !window.isDocumentEdited)
            try await save(native, to: first, operation: .saveOperation)
            try await settledEdited(false)
            checkpoint("normal-save", diskURL: first)
            check("unchanged normal Save remains clean", !native.isDocumentEdited && !window.isDocumentEdited)
            try await save(native, to: second)
            try await settledURL(second)
            try await settledEdited(false)
            checkpoint("moved-save-as", diskURL: second)
            let movedDisk = try VoxClipDocument(data: Data(contentsOf: second)).project
            check("second Save As adopts different folder", native.fileURL == second && window.representedURL == second && model.document.fileURL == second)
            check("second Save As moves the title from the previous file name to the new one", window.title == "moved" && model.project.title == "moved" && movedDisk.title == "moved")
            check("second Save As writes destination-relative media", movedDisk.media.source.relativePath == JSONProjectStore.relativePath(source: source, projectURL: second))
            check("second Save As settles clean", !native.isDocumentEdited && !window.isDocumentEdited && !native.hasUnautosavedChanges)
            for (name, url, project) in [("first", first, firstDisk), ("second", second, movedDisk)] {
                var relativeOnly = project
                relativeOnly.media.source.absolutePath = destination.appendingPathComponent("missing-absolute.mp4").path
                let resolved = try? await app.projectStore.resolveSource(for: relativeOnly, projectURL: url)
                check("\(name) saved project reopens through relative media", resolved?.standardizedFileURL == source.standardizedFileURL)
            }
            let copyURL = destination.appendingPathComponent("saved-copy.voxclip")
            try await save(native, to: copyURL, operation: .saveToOperation)
            let copiedProject = try VoxClipDocument(data: Data(contentsOf: copyURL)).project
            check("Save Copy writes target-relative media without adopting its location", copiedProject.media.source.relativePath == JSONProjectStore.relativePath(source: source, projectURL: copyURL) && native.fileURL == second && model.document.fileURL == second && !native.isDocumentEdited)
            let fileMenu = NSApp.mainMenu?.item(withTitle: "File")?.submenu
            let editMenu = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu
            let recentMenu = fileMenu?.item(withTitle: "Open Recent")?.submenu
            if let recentMenu { (NSApp.delegate as? AppDelegate)?.menuNeedsUpdate(recentMenu) }
            check("native menus retain document and responder commands",
                  ["Save", "Save As…", "Move To…", "Rename…", "Revert to Saved…"].allSatisfy { fileMenu?.item(withTitle: $0) != nil }
                    && ["Cut", "Copy", "Paste", "Select All", "Transcribe Again…"].allSatisfy { editMenu?.item(withTitle: $0) != nil }
                    && NSApp.mainMenu?.item(withTitle: "Window")?.submenu?.item(withTitle: "Toggle Full Screen") != nil)
            check("native document versions remain enabled", type(of: model.document).preservesVersions)
            check("Open Recent refreshes after Save As", recentMenu?.items.contains { ($0.representedObject as? URL) == second } == true)

            let barrier = VoxClipDocument.WriteBarrier()
            model.document.installWriteBarrier(barrier)
            let pendingSave = Task { try await save(native, to: second, operation: .saveOperation) }
            let reachedSnapshot = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                DispatchQueue.global().async { continuation.resume(returning: barrier.arrived.wait(timeout: .now() + 5) == .success) }
            }
            if reachedSnapshot { model.setStyle("vox-highlight") }
            model.document.installWriteBarrier(nil)
            barrier.release.signal()
            try await pendingSave.value
            checkpoint("post-snapshot-edit", diskURL: second)
            let afterSnapshotDisk = try VoxClipDocument(data: Data(contentsOf: second)).project
            check("edit accepted after snapshot remains dirty and undoable", reachedSnapshot && model.project.captions.styleId == "vox-highlight" && native.isDocumentEdited && model.undoManager?.canUndo == true && afterSnapshotDisk.captions.styleId == "off")
            model.undoManager?.undo()
            check("Undo after snapshot returns to clean saved content", model.project.captions.styleId == "off" && !native.isDocumentEdited)
            model.undoManager?.redo()
            check("Redo after snapshot restores unsaved edit", model.project.captions.styleId == "vox-highlight" && native.isDocumentEdited)
            try await save(native, to: second, operation: .saveOperation)
            let laterDisk = try VoxClipDocument(data: Data(contentsOf: second)).project
            check("later Save writes post-snapshot edit", laterDisk.captions.styleId == "vox-highlight" && !native.isDocumentEdited)

            model.setStyle("off")
            let beforeCancellation = try Data(contentsOf: second)
            native.saveAs(nil)
            for _ in 0..<50 {
                if window.attachedSheet != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let presentedSavePanel = window.attachedSheet != nil
            window.attachedSheet?.cancelOperation(nil)
            for _ in 0..<50 {
                if window.attachedSheet == nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            checkpoint("cancelled-save-as", diskURL: second)
            check("cancelled Save As retains edited project, bytes and location", presentedSavePanel && window.attachedSheet == nil && model.project.captions.styleId == "off" && native.isDocumentEdited && native.fileURL == second && model.document.fileURL == second && (try? Data(contentsOf: second)) == beforeCancellation)
            let invalid = destination.appendingPathComponent("missing-folder/project.voxclip")
            let beforeFailure = try Data(contentsOf: second)
            let failed: Bool
            do { try await save(native, to: invalid); failed = false } catch { failed = true }
            checkpoint("failed-save-as", diskURL: second)
            check("failed Save As retains edited project, bytes and location", failed && model.project.captions.styleId == "off" && native.isDocumentEdited && native.fileURL == second && model.document.fileURL == second && (try? Data(contentsOf: second)) == beforeFailure)
            let failedMove: Bool
            do { try await move(native, to: invalid); failedMove = false } catch { failedMove = true }
            check("failed Move retains original bytes, location and edits", failedMove && (try? Data(contentsOf: second)) == beforeFailure && native.fileURL == second && model.project.captions.styleId == "off" && native.isDocumentEdited)
            let rollbackTarget = destination.appendingPathComponent("existing-move-target.voxclip")
            let priorTargetBytes = try Data(contentsOf: first)
            try priorTargetBytes.write(to: rollbackTarget)
            model.document.injectMoveRemovalFailure()
            let rolledBack: Bool
            do { try await move(native, to: rollbackTarget); rolledBack = false } catch { rolledBack = true }
            check("Move rollback restores both files and the edited document", rolledBack && (try? Data(contentsOf: second)) == beforeFailure && (try? Data(contentsOf: rollbackTarget)) == priorTargetBytes && native.fileURL == second && model.project.captions.styleId == "off" && native.isDocumentEdited)
            checkpoint("after-move-rollback", diskURL: second)

            let moved = destination.appendingPathComponent("third/deeper/moved.voxclip")
            try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await move(native, to: moved)
            checkpoint("after-move", diskURL: moved)
            let movedProject = try VoxClipDocument(data: Data(contentsOf: moved)).project
            check("Move removes original and writes destination-relative media", !FileManager.default.fileExists(atPath: second.path) && native.fileURL == moved && window.representedURL == moved && movedProject.media.source.relativePath == JSONProjectStore.relativePath(source: source, projectURL: moved) && movedProject.captions.styleId == "off" && !native.isDocumentEdited && !window.isDocumentEdited)
            let lateMove = destination.appendingPathComponent("late/moved.voxclip")
            try FileManager.default.createDirectory(at: lateMove.deletingLastPathComponent(), withIntermediateDirectories: true)
            let moveBarrier = VoxClipDocument.WriteBarrier()
            model.document.installWriteBarrier(moveBarrier)
            let pendingMove = Task { try await move(native, to: lateMove) }
            let moveReachedSnapshot = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                DispatchQueue.global().async { continuation.resume(returning: moveBarrier.arrived.wait(timeout: .now() + 5) == .success) }
            }
            if moveReachedSnapshot { model.setStyle("vox-highlight") }
            model.document.installWriteBarrier(nil)
            moveBarrier.release.signal()
            try await pendingMove.value
            checkpoint("after-late-edit-move", diskURL: lateMove)
            let lateMoveDisk = try VoxClipDocument(data: Data(contentsOf: lateMove)).project
            check("post-snapshot Move edit remains dirty in document and window", moveReachedSnapshot && lateMoveDisk.captions.styleId == "off" && model.project.captions.styleId == "vox-highlight" && native.isDocumentEdited && window.isDocumentEdited && model.undoManager?.canUndo == true && native.fileURL == lateMove)
            model.undoManager?.undo()
            check("Undo after Move returns both indicators to clean", model.project.captions.styleId == "off" && !native.isDocumentEdited && !window.isDocumentEdited)
            model.undoManager?.redo()
            check("Redo after Move keeps late edit dirty and undoable", model.project.captions.styleId == "vox-highlight" && native.isDocumentEdited && window.isDocumentEdited && model.undoManager?.canUndo == true)
            model.undoManager?.undo()
            try await move(native, to: moved)
            check("moving back preserves clean state and original destination", native.fileURL == moved && !native.isDocumentEdited && !window.isDocumentEdited && !FileManager.default.fileExists(atPath: lateMove.path))
            let renamed = moved.deletingLastPathComponent().appendingPathComponent("renamed.voxclip")
            let stepsBeforeRename = model.undoSteps, undoNameBeforeRename = model.undoManager?.undoActionName ?? ""
            try await move(native, to: renamed)
            let renamedProject = try VoxClipDocument(data: Data(contentsOf: renamed)).project
            check("native Rename moves one file and keeps media portable", !FileManager.default.fileExists(atPath: moved.path) && native.fileURL == renamed && window.representedURL == renamed && renamedProject.media.source.relativePath == movedProject.media.source.relativePath)
            check("native Rename updates the title", window.title == "renamed" && model.project.title == "renamed" && renamedProject.title == "renamed")
            check("the title Rename writes adds no undo step and no edited dot",
                  model.undoSteps == stepsBeforeRename && (model.undoManager?.undoActionName ?? "") == undoNameBeforeRename && !native.isDocumentEdited && !window.isDocumentEdited)
            if let recentMenu { (NSApp.delegate as? AppDelegate)?.menuNeedsUpdate(recentMenu) }
            check("Open Recent replaces moved and renamed locations", recentMenu?.items.contains { ($0.representedObject as? URL) == renamed } == true && recentMenu?.items.contains { ($0.representedObject as? URL) == second || ($0.representedObject as? URL) == moved } == false)
            let renamedCard = try await homeCardTitle(renamed, "renamed")
            let renamedMenuTitle = recentMenu?.items.first { ($0.representedObject as? URL) == renamed }?.title
            check("after Rename the window, the sidebar header, the Home card and Open Recent read \"renamed\" (\(window.title), \(app.shell.projectTitle), \(renamedCard ?? "no card"), \(renamedMenuTitle ?? "no item"))",
                  window.title == "renamed" && app.shell.projectTitle == "renamed" && renamedCard == "renamed" && renamedMenuTitle == "renamed")

            model.setStyle("vox-highlight")
            try native.revert(toContentsOf: renamed, ofType: UTType.voxclipProject.identifier)
            for _ in 0..<50 {
                if model.project.captions.styleId == "off" && model.mediaResolved && !native.isDocumentEdited { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            checkpoint("native-revert", diskURL: renamed)
            check("native Revert updates editor, undo and clean state", model.project.captions.styleId == "off" && model.mediaResolved && model.undoManager?.canUndo == false && !native.isDocumentEdited)

            let alternateSource = shared.appendingPathComponent("fixtures/media/bars-1080p.mp4")
            var alternate = renamedProject
            alternate.media.source = try await VoxClipDocument(importing: alternateSource).project.media.source
            try native.read(from: JSONProjectStore.encode(alternate), ofType: UTType.voxclipProject.identifier)
            for _ in 0..<50 {
                if model.sourceURL == alternateSource && model.mediaResolved { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            check("document read refreshes displayed source identity and derived model", model.sourceURL == alternateSource && model.mediaResolved && model.project.media.source.contentKey == alternate.media.source.contentKey && model.plan != nil)
            try native.revert(toContentsOf: renamed, ofType: UTType.voxclipProject.identifier)
            // The editor reloads on a later turn of the main actor. Until then its state is
            // the one from before the revert, so the wait starts after that turn.
            for _ in 0..<50 {
                try await Task.sleep(for: .milliseconds(20))
                if model.sourceURL == source && model.mediaResolved { break }
            }
            check("Revert restores saved source after identity change", model.sourceURL == source && model.mediaResolved && !native.isDocumentEdited)

            // Save As "A", then Rename "B": the title follows both (design §2). Undoing an
            // edit made before the Save As keeps the new title, and a title that isn't a
            // default stays through Rename.
            let chain = destination.appendingPathComponent("chain", isDirectory: true)
            try FileManager.default.createDirectory(at: chain, withIntermediateDirectories: true)
            let chainA = chain.appendingPathComponent("A.voxclip"), chainB = chain.appendingPathComponent("B.voxclip")
            model.setStyle("vox-highlight")
            try await save(native, to: chainA)
            try await settledURL(chainA)
            model.undoManager?.undo()
            check("Save As \"A\" titles the project A, and undoing an edit made before it keeps that title (window \(window.title), title \(model.project.title ?? "none"), style \(model.project.captions.styleId), media resolved \(model.mediaResolved))",
                  window.title == "A" && model.project.title == "A" && model.project.captions.styleId == "off")
            try await move(native, to: chainB)
            let chainDisk = try VoxClipDocument(data: Data(contentsOf: chainB)).project
            if let recentMenu { (NSApp.delegate as? AppDelegate)?.menuNeedsUpdate(recentMenu) }
            let chainCard = try await homeCardTitle(chainB, "B")
            let chainMenuTitle = recentMenu?.items.first { ($0.representedObject as? URL) == chainB }?.title
            check("a chained Rename to \"B\" after Save As \"A\" shows B in the window, the sidebar header, the Home card and Open Recent (\(window.title), \(app.shell.projectTitle), \(chainCard ?? "no card"), \(chainMenuTitle ?? "no item"))",
                  window.title == "B" && model.project.title == "B" && chainDisk.title == "B" && app.shell.projectTitle == "B" && chainCard == "B" && chainMenuTitle == "B")
            var custom = model.project
            custom.title = "Interview final"
            model.document.replaceProject(custom)
            try await move(native, to: chain.appendingPathComponent("C.voxclip"))
            check("a title that isn't a default stays through Rename", model.project.title == "Interview final" && window.title == "Interview final")

            var following = model.project
            following.title = "C"
            let titleDocument = model.document
            titleDocument.replaceProject(following)
            let chainC = chain.appendingPathComponent("C.voxclip")
            try await save(native, to: chainC)
            titleDocument.injectTitleWriteFailure = true
            let chainD = chain.appendingPathComponent("D.voxclip")
            var failedTitleWrite = false
            do { try await move(native, to: chainD) } catch { failedTitleWrite = true }
            await titleDocument.pendingTitleWrite?.value
            check("a failed deferred Rename title write marks the title edited for retry", failedTitleWrite && titleDocument.isDocumentEdited && titleDocument.project.title == "D")
            let closedAfterTitleRetry = await app.shell.closeProject()
            let titleAfterRetry = try VoxClipDocument(data: Data(contentsOf: chainD)).project.title
            check("the leave boundary retries a failed Rename title write before closing", closedAfterTitleRetry && titleAfterRetry == "D")

        } catch {
            results.append(Result(name: "save boundary audit: \(error.localizedDescription)", passed: false))
        }
        if let data = try? JSONEncoder().encode(results) { try? data.write(to: destination.appendingPathComponent("save-boundary-results.json"), options: .atomic) }
        exit(results.allSatisfy(\.passed) ? 0 : 1)
    }
    private static func editorLayout(in view: NSView) -> Layout? {
        if let split = view as? NSSplitView, split.identifier?.rawValue == "voxclip.editor.split", split.arrangedSubviews.count == 2 {
            return Layout(transcriptWidth: split.arrangedSubviews[0].frame.width, previewWidth: split.arrangedSubviews[1].frame.width)
        }
        return view.subviews.lazy.compactMap { editorLayout(in: $0) }.first
    }
    /// Native checks of the one-window shell (ADR-R29): launch, import, replacing an
    /// untitled or named project, refused replacement, Close Project and reopening.
    /// Captures need an active, unlocked session; while the console is locked they
    /// are recorded as skipped and the window checks still run.
    static func sceneAudit(app: AppModel, destination: URL) async {
        var results: [Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(Result(name: name, passed: passed)) }
        func snapshotWindow(_ window: NSWindow, _ name: String) async {
            do { try await capture(window: window, name: name, directory: destination) }
            catch { results.append(Result(name: "capture \(name)", passed: false, skipped: sessionLocked ? "the console session is locked" : nil)) }
        }
        func waitUntil(_ condition: () -> Bool) async throws {
            for _ in 0..<150 where !condition() { try await Task.sleep(for: .milliseconds(30)) }
        }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let shell = app.shell
            let documents = NSDocumentController.shared
            try await waitUntil { shell.windowController?.window?.isVisible == true }
            guard let window = shell.windowController?.window, let root = app.shared?.root else { throw CocoaError(.coderInvalidValue) }
            func titledWindows() -> [NSWindow] { NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) } }
            check("fresh launch shows one window on Home", titledWindows().count == 1 && shell.isHome && shell.showsHome)
            check("fresh launch titles the window VoxClip", window.title == "VoxClip")
            check("fresh launch opens no document", documents.documents.isEmpty)
            check("no separate Welcome window", !NSApp.windows.contains { $0.title.contains("Welcome to VoxClip") })
            check("Home is not an edited document", !window.isDocumentEdited)
            let menu = NSApp.mainMenu
            check("File menu offers New Project from Video and Close Project", menu?.item(withTitle: "File")?.submenu?.item(withTitle: "New Project from Video…")?.keyEquivalent == "n" && menu?.item(withTitle: "File")?.submenu?.items.contains { $0.keyEquivalent == "w" && $0.title.hasPrefix("Close") } == true)
            check("Window menu brings back the main window", menu?.item(withTitle: "Window")?.submenu?.item(withTitle: "VoxClip") != nil)
            let delayedSettings = DelayedInspectorSettings()
            let delayedApp = AppModel(settingsStore: delayedSettings)
            let initialReadinessRevision = delayedApp.connectorReadinessRevision
            let delayedStartup = Task { await delayedApp.start() }
            for _ in 0..<30 {
                if await delayedSettings.isWaiting { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let wasDelayed = await delayedSettings.isWaiting
            await delayedSettings.finish()
            await delayedStartup.value
            check("delayed saved connector invalidates readiness", wasDelayed && delayedApp.string("llm.connector") == "openai" && delayedApp.connectorReadinessRevision > initialReadinessRevision)
            window.setContentSize(NSSize(width: 1280, height: 800))
            try await Task.sleep(for: .milliseconds(250))
            await snapshotWindow(window, "live-home")

            let source = destination.appendingPathComponent("fillers-chirp.mp4")
            try FileManager.default.copyItem(at: root.appendingPathComponent("fixtures/media/fillers-chirp.mp4"), to: source)
            await shell.importVideo(source)
            guard let imported = shell.document, let editor = shell.editor else { throw CocoaError(.coderInvalidValue) }
            check("import opens the project in the same window", titledWindows().count == 1 && imported.windowControllers.first === shell.windowController && window.windowController?.document === imported)
            check("an untitled import is titled with the movie's name, never Untitled", window.title == "fillers-chirp" && shell.selection == .fullTake)
            check("the keep/delete prompt and Save panel name the import after the movie (\(imported.displayName ?? "none"))", imported.displayName == "fillers-chirp")
            check("an untitled import is protected as an edited document", imported.isDocumentEdited && window.isDocumentEdited)
            check("imported video can preview and export without transcript", editor.mediaResolved && editor.canExport && editor.project.transcript == nil)
            try await waitUntil { subtitleField(in: window)?.accessibilityHelp() == editor.summaryDetail }
            let subtitle = subtitleField(in: window)
            check("VoiceOver reads the edit summary's detail after the subtitle (\(editor.summaryDetail); window subtitle \"\(window.subtitle)\", field \(subtitle == nil ? "not found" : "help \(subtitle?.accessibilityHelp() ?? "none")"))",
                  subtitle?.accessibilityHelp() == editor.summaryDetail)
            await snapshotWindow(window, "live-imported")

            // The editor's flows in the new layout: Find Clips readiness in its popover,
            // Make Clip, Transcribe Again's warning, Export from the toolbar and 1024 wide.
            let transcript = try DemoEditing.loadFixture(root.appendingPathComponent("fixtures/projects/interview-take.voxclip")).transcript
            var transcribed = editor.project
            transcribed.transcript = transcript
            imported.replaceProject(transcribed)
            editor.refresh()
            await editor.updatePreview(load: false)
            check("a transcript enables Find Clips and editing", !editor.words.isEmpty && editor.editingAvailable)
            try await waitUntil { window.firstResponder is TranscriptNSTextView }
            check("the transcript takes keyboard focus when it arrives after an untranscribed import (first responder \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"))", window.firstResponder is TranscriptNSTextView)
            results += await findClipsReadiness(app: app, editor: editor, window: window, snapshot: snapshotWindow)
            let ids = editor.words.prefix(3).map(\.id)
            editor.selectedWordIDs = Set(ids)
            editor.makeClip()
            let made = editor.sortedClips.first
            check("Make Clip selects the new clip's row and registers one undo step", made != nil && shell.selection == made.map { SidebarItem.clip($0.id) } && editor.undoManager?.undoActionName == "Make clip from selection")
            await snapshotWindow(window, "live-clips")
            shell.selection = .fullTake
            editor.apply(.cutSelection(ids: [ids[0]]), name: "Cut word")
            editor.apply(.correct(id: ids[1], text: "corrected"), name: "Correct word")
            let transcribeItem = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu?.item(withTitle: "Transcribe Again…")
            let dispatched = transcribeItem.flatMap { item in item.action.map { NSApp.sendAction($0, to: item.target, from: item) } } ?? false
            try await waitUntil { window.attachedSheet != nil }
            let warning = AppDelegate.retranscriptionWarning(for: editor.project)
            // Editor menu commands need the main window to be key, so an inactive app
            // (a locked console) can't reach them.
            let inactive = NSApp.keyWindow !== window ? "the app isn't active, so the main window isn't key and editor menu commands are off" : nil
            let warned = dispatched && window.attachedSheet != nil && !editor.showTranscribe && warning.contains("1 cuts") && warning.contains("1 corrections") && warning.contains("1 clips")
            results.append(Result(name: "Transcribe Again warns about lost cuts, corrections and clips", passed: warned, skipped: warned ? nil : inactive))
            if let sheet = window.attachedSheet {
                if let cancel = button(titled: "Cancel", in: sheet.contentView) { cancel.performClick(nil) } else { sheet.cancelOperation(nil) }
            }
            try await waitUntil { window.attachedSheet == nil }
            let kept = window.attachedSheet == nil && !editor.showTranscribe && editor.project.edits.cutWordIds.count == 1 && editor.project.edits.corrections.count == 1 && editor.project.edits.clips.count == 1
            results.append(Result(name: "cancelling Transcribe Again keeps the edits", passed: kept && warned, skipped: kept && !warned ? inactive : nil))
            if let clip = made {
                shell.selection = .clip(clip.id)
                // While the console is locked the window isn't redrawn, and its toolbar
                // keeps showing what it last drew.
                let stale = sessionLocked ? "the console session is locked, so the toolbar isn't redrawn" : nil
                func toolbarCheck(_ name: String, _ passed: Bool) { results.append(Result(name: name, passed: passed, skipped: passed ? nil : stale)) }
                try await waitUntil {
                    window.toolbar?.validateVisibleItems()
                    window.displayIfNeeded()
                    return exportButton(in: window)?.exportTitle == "Export Clip…"
                }
                check("the editor's Export reads Export Clip… for the selected clip", editor.exportTitle == "Export Clip…" && editor.exportUnavailable == nil && editor.canExport)
                if let export = exportButton(in: window) {
                    toolbarCheck("the toolbar's Export reads Export Clip… for the selected clip, also to VoiceOver (title \(export.exportTitle), label \(export.accessibilityLabel() ?? "none"), enabled \(export.isEnabled))",
                                 export.exportTitle == "Export Clip…" && export.accessibilityLabel() == "Export Clip…" && export.isEnabled)
                    export.performClick(nil)
                } else { check("the toolbar's Export button is discoverable", false) }
                try await waitUntil { window.attachedSheet != nil }
                toolbarCheck("Export from the toolbar opens Export for the selected clip", editor.showExport && editor.activeClip?.id == clip.id && editor.exportClipIDs == [clip.id])
                if let sheet = window.attachedSheet {
                    await snapshotWindow(sheet, "live-export-clip")
                    check("clip export opens an attached sheet", sheet.isVisible)
                } else { toolbarCheck("clip export opens an attached sheet", false) }
                editor.showExport = false
                try await waitUntil { window.attachedSheet == nil }
                check("the export sheet closes before the editor changes", window.attachedSheet == nil && !editor.showExport)
                await snapshotWindow(window, "live-clip-preview")
                shell.selection = .fullTake
            }
            let appearance = app.string("general.appearance", fallback: "system")
            window.setContentSize(NSSize(width: 1024, height: 700))
            try await waitUntil { abs(shell.windowWidth - 1024) < 1 && !shell.viewerVisible }
            check("1024 wide collapses the viewer and keeps the sidebar", abs(shell.windowWidth - 1024) < 1 && !shell.viewerVisible && shell.columnVisibility == .all)
            await snapshotWindow(window, "live-compact")
            app.set("general.appearance", .string("light"))
            try await Task.sleep(for: .milliseconds(250))
            await snapshotWindow(window, "live-compact-light")
            app.set("general.appearance", .string(appearance))
            window.setContentSize(NSSize(width: 1280, height: 800))
            try await waitUntil { abs(shell.windowWidth - 1280) < 1 }

            var other = editor.project
            other.id = UUID().uuidString.lowercased()
            other.title = "Project B"
            let otherURL = destination.appendingPathComponent("project-b.voxclip")
            try JSONProjectStore.encode(other).write(to: otherURL)
            app.fileRouter.receive([otherURL])
            try await waitUntil { window.attachedSheet != nil }
            let sheet = window.attachedSheet
            check("opening a project over an untitled one asks to keep or delete it", sheet != nil)
            if let sheet {
                await snapshotWindow(sheet, "live-dirty-close")
                if let cancel = button(titled: "Cancel", in: sheet.contentView) { cancel.performClick(nil) } else { sheet.cancelOperation(nil) }
            }
            try await waitUntil { window.attachedSheet == nil && documents.documents.count == 1 }
            editor.setStyle("off")
            check("Cancel keeps the untitled project open and editable", shell.document === imported && !editor.isLeaving && shell.notice == nil && documents.documents.count == 1 && editor.project.captions.styleId == "off")

            let importedURL = destination.appendingPathComponent("project-a.voxclip")
            try await save(imported, to: importedURL)
            try await waitUntil { imported.fileURL == importedURL && !imported.isDocumentEdited }
            let savedAt = try importedURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantFuture
            try await Task.sleep(for: .milliseconds(100))
            editor.setStyle("vox-highlight")
            app.fileRouter.receive([otherURL])
            try await waitUntil { shell.document?.fileURL == otherURL && shell.editor?.mediaResolved == true && documents.documents.count == 1 }
            let replacedAt = try importedURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let replacedOnDisk = try JSONProjectStore.decode(Data(contentsOf: importedURL))
            check("opening another project keeps one window", titledWindows().count == 1 && window.windowController === shell.windowController)
            check("the open project saves before it is replaced", replacedAt > savedAt && replacedOnDisk.id == imported.project.id && replacedOnDisk.captions.styleId == "vox-highlight")
            check("the replaced project closes and the opened one shows, titled by Project.title", documents.documents.count == 1 && shell.document?.fileURL == otherURL && window.title == "Project B" && shell.selection == .fullTake)

            guard let opened = shell.document, let openedEditor = shell.editor else { throw CocoaError(.coderInvalidValue) }
            openedEditor.setStyle("off")
            shell.injectSaveFailure = true
            app.fileRouter.receive([importedURL])
            try await waitUntil { shell.notice != nil && documents.documents.count == 1 }
            openedEditor.setStyle("vox-highlight")
            check("a failed save keeps the open project editable with a notice", shell.document === opened && !openedEditor.isLeaving && shell.notice?.contains("stays open") == true && openedEditor.project.captions.styleId == "vox-highlight" && documents.documents.count == 1)
            openedEditor.exporting = true
            app.fileRouter.receive([importedURL])
            try await waitUntil { shell.notice == WorkspaceShell.busyCopy && documents.documents.count == 1 }
            check("a running export refuses opening another project", shell.notice == WorkspaceShell.busyCopy && shell.document === opened)
            openedEditor.exporting = false

            let closed = await shell.closeProject()
            check("Close Project shows Home in the same window", closed && shell.isHome && shell.selection == .home && window.isVisible && window.title == "VoxClip" && documents.documents.isEmpty)
            window.performClose(nil)
            try await waitUntil { !window.isVisible }
            check("closing the window on Home keeps the app running", !window.isVisible && NSApp.isRunning)
            app.fileRouter.receive([otherURL])
            try await waitUntil { window.isVisible && shell.document?.fileURL == otherURL && window.firstResponder is TranscriptNSTextView }
            check("opening a project from Finder while the window is closed brings the window back", window.isVisible && shell.document?.fileURL == otherURL)
            check("opening a project puts keyboard focus in the transcript", window.firstResponder is TranscriptNSTextView)
            _ = await shell.closeProject()
            window.performClose(nil)
            try await waitUntil { !window.isVisible }
            _ = (NSApp.delegate as? AppDelegate)?.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            check("the Dock reopens the main window on Home", window.isVisible && shell.windowController?.window === window && shell.showsHome)
            openVoxClipSettings()
            let settings = (NSApp.delegate as? AppDelegate)?.settingsWindowForTests
            window.performClose(nil)
            try await waitUntil { !window.isVisible }
            _ = (NSApp.delegate as? AppDelegate)?.applicationShouldHandleReopen(NSApp, hasVisibleWindows: settings?.isVisible == true)
            check("the Dock brings the main window back while Settings is open", window.isVisible && settings?.isVisible == true)
            settings?.close()
            app.fileRouter.receive([otherURL])
            try await waitUntil { shell.document?.fileURL == otherURL && shell.editor?.mediaResolved == true }
            shell.editor?.setStyle("off")
            window.performClose(nil)
            try await waitUntil { !window.isVisible && documents.documents.isEmpty }
            let closedOnDisk = try JSONProjectStore.decode(Data(contentsOf: otherURL))
            check("the close button saves the project and closes the window", shell.isHome && !window.isVisible && documents.documents.isEmpty && closedOnDisk.captions.styleId == "off")
            MainWindowController.shared.show()
        } catch {
            results.append(Result(name: "scene audit: \(error.localizedDescription)", passed: false))
        }
        for document in NSDocumentController.shared.documents { document.updateChangeCount(.changeCleared); document.close() }
        if let data = try? JSONEncoder().encode(results) { try? data.write(to: destination.appendingPathComponent("scene-results.json"), options: .atomic) }
        exit(results.allSatisfy { $0.passed || $0.skipped != nil } ? 0 : 1)
    }
    static var sessionLocked: Bool { (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true }
    /// The titlebar text field that draws the window subtitle.
    private static func subtitleField(in window: NSWindow) -> NSTextField? {
        guard !window.subtitle.isEmpty, let frame = window.contentView?.superview else { return nil }
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.stringValue == window.subtitle { return field }
            return view.subviews.lazy.compactMap(find).first
        }
        return frame.subviews.lazy.filter { $0 !== window.contentView }.compactMap(find).first
    }
    /// Find Clips readiness in the popover (design §6.2), as main's Clips inspector
    /// checked it: a missing key, saving and forgetting it, a stopped local service, a
    /// changed server URL and a late status from the previous connector. The popover's
    /// accessibility needs this process to be a trusted accessibility client.
    private static func findClipsReadiness(app: AppModel, editor: EditorModel, window: NSWindow, snapshot: (NSWindow, String) async -> Void) async -> [Result] {
        var results: [Result] = []
        let trusted = AXIsProcessTrusted()
        func check(_ name: String, _ passed: Bool) {
            results.append(Result(name: name, passed: passed, skipped: !passed && !trusted ? "this process is not a trusted accessibility client" : nil))
        }
        let keys = InspectorTestKeys()
        let keyConnector = InspectorKeyConnector(keys: keys)
        let localConnector = InspectorStatusConnector(id: .ollama, status: .notRunning(url: "http://127.0.0.1:11434"))
        let otherConnector = InspectorStatusConnector(id: .lmstudio, status: .ready)
        app.providerKeyStoreOverride = keys
        app.connectorOverride = { id in
            switch id {
            case "openai": keyConnector
            case "ollama": localConnector
            default: otherConnector
            }
        }
        defer {
            editor.showFindClips = false
            app.set("llm.connector", .string(""))
            app.connectorOverride = nil
            app.providerKeyStoreOverride = nil
        }
        app.set("llm.connector", .string("openai"))
        editor.requestFindClips(from: .toolbar)
        check("Find Clips shows a missing key in its popover", await hasInspectorStatus("Key missing", in: window))
        check("Find Clips stays actionable with a missing key", inspectorElement("findClipsAction", in: window)?.enabled == true)
        await snapshot(window, "live-finder-missing")
        do {
            try await app.saveProviderKey("offline-test-key", for: "openai")
            check("saving a key refreshes the popover's readiness without reselecting", await hasInspectorStatus("Ready", in: window))
            try await app.saveProviderKey("", for: "openai")
            check("forgetting a key refreshes the popover's readiness without reselecting", await hasInspectorStatus("Key missing", in: window))
        } catch { results.append(Result(name: "saving a test key: \(error.localizedDescription)", passed: false)) }
        app.set("llm.connector", .string("ollama"))
        check("a stopped local service shows in the popover", await hasInspectorStatus("Not running", in: window))
        check("a stopped local service keeps Find Clips actionable", inspectorElement("findClipsAction", in: window)?.enabled == true)
        await snapshot(window, "live-finder-stopped")
        await localConnector.setStatus(.unavailable(reason: "Local service unavailable."))
        app.set("llm.baseUrl.ollama", .string("http://127.0.0.1:11435"))
        check("changing the server URL refreshes the popover's status", await hasInspectorStatus("Unavailable", in: window))
        await localConnector.setStatus(.ready)
        app.refreshConnectorReadiness()
        check("a recovered service reads Ready", await hasInspectorStatus("Ready", in: window))
        await snapshot(window, "live-finder-ready")
        await localConnector.delayNextStatus()
        app.refreshConnectorReadiness()
        for _ in 0..<20 {
            if await localConnector.hasPendingStatus { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let previousPending = await localConnector.hasPendingStatus
        app.set("llm.connector", .string("lmstudio"))
        let otherReady = await hasInspectorStatus("Ready", in: window)
        await localConnector.finishDelayedStatus(.needsKey)
        try? await Task.sleep(for: .milliseconds(100))
        check("a late status from the previous connector cannot replace the current one", previousPending && otherReady && inspectorElement("clipConnectorStatus", in: window)?.label?.contains("Ready") == true)
        await snapshot(window, "live-finder-recovered")
        app.settings.values["llm.baseUrl.ollama"] = nil
        return results
    }
    private static func button(titled title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { button(titled: title, in: $0) }.first
    }
    private static func exportButton(in window: NSWindow) -> ExportToolbarButton? {
        func find(in view: NSView) -> ExportToolbarButton? {
            if let button = view as? ExportToolbarButton { return button }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        return window.toolbar?.visibleItems?.lazy.compactMap { $0.view.flatMap { find(in: $0) } }.first
            ?? window.contentView.flatMap { find(in: $0) }
    }
    private struct InspectorElement { let element: AXUIElement; let label: String?; let enabled: Bool }
    /// Drive the public AppKit controls in the real Settings window. The tab
    /// strip belongs to its toolbar, outside the hosted content view.
    private static func settingsControl<T: NSView>(in window: NSWindow, matching predicate: (T) -> Bool) -> T? {
        func find(_ view: NSView) -> T? {
            if let control = view as? T, predicate(control) { return control }
            for child in view.subviews {
                if let found = find(child) { return found }
            }
            return nil
        }
        for view in (window.toolbar?.items.compactMap(\.view) ?? []) + [window.contentView].compactMap({ $0 }) {
            if let found = find(view) { return found }
        }
        return nil
    }
    private static func inspectorElement(_ identifier: String, in window: NSWindow) -> InspectorElement? {
        func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
            return value
        }
        var seen = 0
        func find(_ element: AXUIElement, depth: Int) -> InspectorElement? {
            guard depth < 40, seen < 5000 else { return nil }
            seen += 1
            if (attribute(element, kAXIdentifierAttribute as CFString) as? String) == identifier {
                return InspectorElement(element: element, label: attribute(element, kAXDescriptionAttribute as CFString) as? String ?? attribute(element, kAXTitleAttribute as CFString) as? String ?? attribute(element, kAXValueAttribute as CFString) as? String,
                                        enabled: attribute(element, kAXEnabledAttribute as CFString) as? Bool ?? true)
            }
            let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
            for child in children {
                if let found = find(child, depth: depth + 1) { return found }
            }
            return nil
        }
        let application = AXUIElementCreateApplication(getpid())
        let windows = attribute(application, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []
        for candidate in windows where (attribute(candidate, kAXIdentifierAttribute as CFString) as? String) == window.accessibilityIdentifier() {
            if let found = find(candidate, depth: 0) { return found }
        }
        // A popover may be an accessibility window of its own.
        for candidate in windows where (attribute(candidate, kAXIdentifierAttribute as CFString) as? String) != window.accessibilityIdentifier() {
            seen = 0
            if let found = find(candidate, depth: 0) { return found }
        }
        return nil
    }
    private static func hasInspectorStatus(_ expected: String, in window: NSWindow) async -> Bool {
        for _ in 0..<30 {
            if inspectorElement("clipConnectorStatus", in: window)?.label?.contains(expected) == true { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return false
    }
    /// An error with its underlying cause, for check names.
    static func describe(_ error: any Error) -> String {
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        return [error.localizedDescription, underlying.map { "\($0.domain) \($0.code): \($0.localizedDescription)" }].compactMap { $0 }.joined(separator: " — ")
    }
    static func save(_ document: NSDocument, to url: URL, operation: NSDocument.SaveOperationType = .saveAsOperation) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.save(to: url, ofType: UTType.voxclipProject.identifier, for: operation) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
    static func move(_ document: NSDocument, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.move(to: url) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
    static func capture(window: NSWindow, name: String, directory: URL) async throws {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<20 {
            if NSApp.isActive && window.isKeyWindow { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(100))
        guard NSApp.isActive, window.isKeyWindow else {
            let key = NSApp.keyWindow
            let main = NSApp.mainWindow
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            let locked = session?["CGSSessionScreenIsLocked"] ?? "unknown"
            let detail = "capture=\(name) appActive=\(NSApp.isActive) processActive=\(NSRunningApplication.current.isActive) key=\(window.isKeyWindow) visible=\(window.isVisible) policy=\(NSApp.activationPolicy().rawValue) targetNumber=\(window.windowNumber) targetIsSheet=\(window.sheetParent != nil) targetAttachedSheet=\(window.attachedSheet?.windowNumber.description ?? "nil") keyNumber=\(key?.windowNumber.description ?? "nil") mainNumber=\(main?.windowNumber.description ?? "nil") keyIsTargetSheetParent=\(key != nil && key === window.sheetParent) sessionLocked=\(locked)"
            try? Data(detail.utf8).write(to: directory.appendingPathComponent("activation.txt"))
            throw CocoaError(.userCancelled)
        }
        for attempt in 0..<3 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-l", String(window.windowNumber), directory.appendingPathComponent(name).appendingPathExtension("png").path]
            try process.run(); process.waitUntilExit()
            if process.terminationStatus == 0 { return }
            if attempt < 2 { try await Task.sleep(for: .milliseconds(150)) }
        }
        throw CocoaError(.fileWriteUnknown)
    }
    static func captureDemo(app: AppModel, destination: URL) async {
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            guard let index = CommandLine.arguments.firstIndex(of: "-demoProject"), index + 1 < CommandLine.arguments.count else { throw CocoaError(.coderInvalidValue) }
            let project = try DemoEditing.loadFixture(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            let shell = WorkspaceShell(app: app)
            await shell.attachForTesting(VoxClipDocument(project: project, demo: true))
            try await snapshot(WorkspaceView(shell: shell).environment(app), name: "demo-editor", size: NSSize(width: 1440, height: 820), appearance: .aqua, directory: destination, mainWindow: true)
            if let clip = project.edits.clips.first { shell.selection = .clip(clip.id) }
            try await snapshot(WorkspaceView(shell: shell).environment(app), name: "demo-clips", size: NSSize(width: 1100, height: 720), appearance: .aqua, directory: destination, mainWindow: true)
            try await snapshot(WorkspaceView(shell: WorkspaceShell(app: app)).environment(app), name: "demo-home", size: NSSize(width: 1100, height: 720), appearance: .aqua, directory: destination, mainWindow: true)
            try await snapshot(SettingsView().environment(app), name: "demo-settings", size: NSSize(width: 900, height: 560), appearance: .aqua, directory: destination)
            try await snapshot(SettingsView().environment(app), name: "settings-minimum", size: NSSize(width: 600, height: 480), appearance: .aqua, directory: destination)
        } catch {
            try? Data("Demo capture failed".utf8).write(to: destination.appendingPathComponent("failure.txt"))
        }
        exit(FileManager.default.fileExists(atPath: destination.appendingPathComponent("failure.txt").path) ? 1 : 0)
    }
    static func performance(app: AppModel, destination: URL) {
        var passed = false
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            guard let root = app.shared?.root else { throw VoxClipError.sharedResourcesMissing }
            let project = try DemoEditing.loadFixture(root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
            let results = try DebugTranscriptPerformance.run(app: app, fixture: project, directory: destination)
            try JSONEncoder().encode(results).write(to: destination.appendingPathComponent("results.json"), options: .atomic)
            passed = results.allSatisfy { $0.passed }
        } catch { try? Data("Performance fixture failed".utf8).write(to: destination.appendingPathComponent("failure.txt")) }
        exit(passed ? 0 : 1)
    }
    static func run(app: AppModel) async {
        guard !ran else { return }
        ran = true
        guard let argument = CommandLine.arguments.firstIndex(of: "-uiSelfTest"), argument + 1 < CommandLine.arguments.count else { return }
        let destination = URL(fileURLWithPath: CommandLine.arguments[argument + 1], isDirectory: true)
        var results: [Result] = await DebugRegressions.startup()
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            results.append(Result(name: name, passed: condition()))
        }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            results += try await DebugSettings.run(directory: destination)
            results += try await DebugDownloads.run(app: app, directory: destination)
            results += try await DebugRegressions.media(app: app, directory: destination)
            guard let root = app.shared?.root else { throw VoxClipError.sharedResourcesMissing }
            let fixture = root.appendingPathComponent("fixtures/projects/interview-take.voxclip")
            let project = try DemoEditing.loadFixture(fixture)
            results += try DebugTranscriptPixels.run(app: app, fixture: project, directory: destination)
            results += try await DebugSelectionBar.run(app: app, fixture: project, directory: destination)
            results += try await DebugViewer.run(app: app, fixture: project, directory: destination)
            results += try await DebugCaptionsSection.run(app: app, fixture: project, directory: destination)
            results += try await DebugTimeline.run(app: app, fixture: project, directory: destination)
            try JSONEncoder().encode(results).write(to: destination.appendingPathComponent("results-progress.json"), options: .atomic)
            results += try DebugProbes.colorReadbackChecks(directory: destination)
            results += try await DebugPersistence.run(app: app, fixture: project, directory: destination)
            results += try await DebugExport.run(app: app, fixture: project, directory: destination)
            results += try await DebugMenus.run(app: app, fixture: project, directory: destination)
            try JSONEncoder().encode(results).write(to: destination.appendingPathComponent("results-progress.json"), options: .atomic)
            results += try await DebugRegressions.editor(app: app, project: project)
            results += try await DebugIntegratedFlow.run(app: app, directory: destination)
            let document = VoxClipDocument(project: project, demo: false)
            let preview = DemoPreviewEngine()
            let model = EditorModel(document: document, app: app, preview: preview)
            let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
            model.mediaResolved = true
            model.refresh()
            check("fixture contains words", !model.words.isEmpty)
            check("transcribed project enables editing and Export", model.editingAvailable && model.canExport)
            let render = try await model.renderRequest()
            check("fixture captions render through the preview request", render.captionLayout != nil && !render.captions.pages.isEmpty)
            let first = model.words[0].id
            model.selectedWordIDs = [first]
            undo.beginUndoGrouping(); model.cutSelection(); undo.endUndoGrouping()
            check("delete cuts selected word", model.project.edits.cutWordIds.contains(first))
            undo.undo()
            check("undo restores snapshot", model.project.edits.cutWordIds == project.edits.cutWordIds)
            undo.redo()
            check("redo reapplies snapshot", model.project.edits.cutWordIds.contains(first))
            undo.beginUndoGrouping(); model.cutSelection(restore: true); undo.endUndoGrouping()
            check("restore selection", !model.project.edits.cutWordIds.contains(first))
            if let pause = model.pauses.first(where: { !model.cutPauseIDs.contains($0.id) }) {
                model.selectedWordIDs = []; model.selectedPauseIDs = [pause.id]
                undo.beginUndoGrouping(); model.cutSelection(); undo.endUndoGrouping()
                check("pause-only selection cuts", model.project.edits.cutPauseIds.contains(pause.id))
                undo.undo()
                model.selectedPauseIDs = []
            } else { check("pause-only selection cuts", false) }
            if let pause = model.pauses.first(where: { model.cutPauseIDs.contains($0.id) }) {
                model.selectedWordIDs = []; model.selectedPauseIDs = [pause.id]
                model.cutSelection()
                check("named Cut does not restore an already-cut pause", model.project.edits.cutPauseIds.contains(pause.id))
                undo.beginUndoGrouping(); model.toggleSelectionCut(); undo.endUndoGrouping()
                check("Delete toggles an already-cut pause back to restored", !model.project.edits.cutPauseIds.contains(pause.id))
                undo.undo()
                model.selectedPauseIDs = []
            } else { check("Delete toggles an already-cut pause back to restored", false) }
            var tuning = CaptionSettings(styleId: "vox-highlight")
            CaptionFineTuning.size(&tuning, scale: 1.45)
            check("XL stores normative scale", CaptionFineTuning.value(tuning, group: "font", key: "sizeScale") == .number(1.45))
            CaptionFineTuning.size(&tuning, scale: 1)
            check("M deletes empty override object", tuning.overrides["font"] == nil)
            CaptionFineTuning.words(&tuning, count: 16)
            check("Line stores maxWords and maxLines", CaptionFineTuning.value(tuning, group: "layout", key: "maxWords") == .number(16) && CaptionFineTuning.value(tuning, group: "layout", key: "maxLines") == .number(1))
            CaptionFineTuning.words(&tuning, count: 0)
            check("Phrase deletes layout overrides", tuning.overrides["layout"] == nil)
            CaptionFineTuning.position(&tuning, aspect: .portrait, point: CaptionPosition(x: 0.5, y: 0.2))
            check("positions are per preset", tuning.position == nil && tuning.positionByAspect["9:16"]?.y == 0.2)
            CaptionFineTuning.reset(&tuning)
            check("reset clears every override", tuning.overrides.isEmpty && tuning.position == nil && tuning.positionByAspect.isEmpty)
            let second = model.words[min(3, model.words.count - 1)].id
            model.select(first); model.select(second, extend: true)
            check("word selection extends", model.selectedWordIDs.count == min(4, model.words.count))
            let count = model.project.edits.clips.count
            undo.beginUndoGrouping(); model.makeClip(); undo.endUndoGrouping()
            check("manual clip without key", model.project.edits.clips.count == count + 1)
            undo.beginUndoGrouping(); model.makeClip(); undo.endUndoGrouping()
            check("manual clip deduplicates", model.project.edits.clips.count == count + 1)
            if let clip = model.project.edits.clips.last {
                undo.beginUndoGrouping(); model.nudge(clip, start: true, offset: 10000); undo.endUndoGrouping()
                check("nudge clamps to inclusive end", model.project.edits.clips.last?.startWordId == clip.endWordId)
                undo.beginUndoGrouping(); model.apply(.cutSelection(ids: [first]), name: "Cut before removing clip"); undo.endUndoGrouping()
                let cutsBeforeRemove = model.project.edits.cutWordIds
                undo.beginUndoGrouping(); model.removeClip(clip.id); undo.endUndoGrouping()
                check("remove clip preserves cuts", model.project.edits.clips.count == count && model.project.edits.cutWordIds == cutsBeforeRemove)
            } else { check("nudge clamps to inclusive end", false); check("remove clip preserves cuts", false) }
            model.beginCorrection(); model.correctionText = "Corrected"
            undo.beginUndoGrouping(); model.saveCorrection(); undo.endUndoGrouping()
            check("correction preserves timings", model.words[0].start == project.transcript?.words[0].start && model.project.edits.corrections[first] == "Corrected")
            undo.beginUndoGrouping(); model.apply(.cutSelection(ids: model.words.map(\.id)), name: "Cut all"); undo.endUndoGrouping()
            check("everything cut disables export", !model.canExport)
            undo.undo()
            check("undo restores export", model.canExport)
            let encoded = try ShareText.url("x", caption: "A & B + C?")
            check("share URL host and encoding", encoded?.absoluteString == "https://x.com/intent/post?text=A%20%26%20B%20%2B%20C%3F")
            check("share weighted URL and emoji", ShareText.weight("Hi 👩🏽‍💻 https://example.com/a") == 29)
            let intent = try ShareText.url("x", caption: String(repeating: "word ", count: 100))!
            let truncated = URLComponents(url: intent, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "text" }?.value ?? ""
            check("share over limit truncates", (ShareText.weight(truncated) ?? .max) <= 280 && truncated.hasSuffix("…"))
            check("secrets use isolated account names", SecretStore.account(for: "elevenlabs") == "elevenlabs-api-key" && SecretStore.account(for: "openai") == "llm-api-key-openai")
            let outside = destination.appendingPathComponent("outside.voxclip")
            try FileManager.default.copyItem(at: fixture, to: outside)
            do { _ = try DemoEditing.loadFixture(outside); check("demo path is restricted", false) } catch { check("demo path is restricted", true) }
            try FileManager.default.removeItem(at: outside)
            let unavailable = await app.safeError(VoxClipError.notImplemented("mac-media"))
            check("unimplemented service is truthful", unavailable.contains("not available") && unavailable.contains("Your video and edits are still here."))
            results += try await DebugHome.run(app: app, fixture: project, directory: destination)
            results += try await DebugSidebar.run(app: app, fixture: project, directory: destination)
            let editorShell = WorkspaceShell(app: app)
            await editorShell.attachForTesting(VoxClipDocument(project: project, demo: true))
            check("an attached project shows its editor scoped to Full take", !editorShell.showsHome && editorShell.selection == .fullTake && editorShell.title == project.title)
            try await snapshot(WorkspaceView(shell: editorShell).environment(app), name: "editor-light", size: NSSize(width: 1440, height: 850), appearance: .aqua, directory: destination, mainWindow: true)
            try await snapshot(WorkspaceView(shell: editorShell).environment(app), name: "editor-dark", size: NSSize(width: 1440, height: 850), appearance: .darkAqua, directory: destination, mainWindow: true)
            var clipped = project
            if let words = clipped.transcript?.words, words.count > 4 {
                clipped.edits.clips = [ClipRange(id: "snapshot-clip", startWordId: words[1].id, endWordId: words[4].id, title: "Snapshot clip")]
            }
            let clipShell = WorkspaceShell(app: app)
            await clipShell.attachForTesting(VoxClipDocument(project: clipped, demo: true), selection: .clip("snapshot-clip"))
            check("a clip row scopes the editor through setActiveClip", clipShell.editor?.project.edits.activeClipId == "snapshot-clip")
            clipShell.editor?.undoManager?.undo()
            check("undo of a row change returns the selection to Full take", clipShell.selection == .fullTake && clipShell.editor?.project.edits.activeClipId == nil)
            clipShell.selection = .clip("snapshot-clip")
            try await snapshot(WorkspaceView(shell: clipShell).environment(app), name: "clips-light", size: NSSize(width: 1100, height: 720), appearance: .aqua, directory: destination, mainWindow: true)
            try await snapshot(WorkspaceView(shell: clipShell).environment(app), name: "clips-dark", size: NSSize(width: 1100, height: 720), appearance: .darkAqua, directory: destination, mainWindow: true)
            clipShell.selection = .home
            check("Home keeps the project open and titles the window VoxClip", clipShell.showsHome && !clipShell.isHome && clipShell.title == "VoxClip" && clipShell.editor?.project.edits.activeClipId == "snapshot-clip")
            let library = app.modelLibrary
            let downloadTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
            defer { downloadTask.cancel(); library.task = nil }
            library.task = downloadTask
            try await snapshot(SettingsView().environment(app), name: "settings-light", size: NSSize(width: 800, height: 560), appearance: .aqua, directory: destination)
            check("closing Settings preserves AppModel library and download task", app.modelLibrary === library && library.task != nil && !downloadTask.isCancelled)
            try await snapshot(OnboardingView().environment(app), name: "onboarding-light", size: NSSize(width: 616, height: 536), appearance: .aqua, directory: destination)
            try await snapshot(ExportSheet(model: model).environment(app), name: "export-light", size: NSSize(width: 668, height: 500), appearance: .aqua, directory: destination)
            try await snapshot(ExportSheet(model: model).environment(app), name: "export-dark", size: NSSize(width: 668, height: 500), appearance: .darkAqua, directory: destination)
            try await snapshot(OnboardingView().environment(app), name: "onboarding-dark", size: NSSize(width: 616, height: 536), appearance: .darkAqua, directory: destination)
            for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
                for active in [false, true] {
                    let name = "toolbar-\(appearance == .darkAqua ? "dark" : "light")-\(active ? "key" : "inactive")"
                    try await snapshot(toolbarContrast, name: name, size: NSSize(width: 560, height: 180), appearance: appearance, directory: destination, active: active)
                }
                let prefix = "toolbar-\(appearance == .darkAqua ? "dark" : "light")"
                let key = try Data(contentsOf: destination.appendingPathComponent("\(prefix)-key.jpg"))
                let inactive = try Data(contentsOf: destination.appendingPathComponent("\(prefix)-inactive.jpg"))
                check("\(prefix) key and inactive captures differ", key != inactive)
            }
            results += toolbarEvidence
            model.close()
        } catch { results.append(Result(name: "suite: \(error.localizedDescription)", passed: false)) }
        let fallbacks = cachedMainWindowCaptures
        // Only a capable host fails: one that may record the screen and whose
        // screencapture ran cleanly but still gave no usable image.
        let skip: String? = fallbacks.isEmpty ? nil
            : sessionLocked ? "the console session is locked"
            : !CGPreflightScreenCaptureAccess() ? "this process may not record the screen (Screen Recording permission)"
            : windowServerRefusals.first.map { "screencapture could not capture (\($0))" }
        results.append(Result(name: "main-window captures come from the window server, which draws the sidebar\(fallbacks.isEmpty ? "" : " (\(fallbacks.count) fell back to cacheDisplay; first: \(windowServerGaps.first ?? "none"))")",
                              passed: fallbacks.isEmpty, skipped: skip))
        if let data = try? JSONEncoder().encode(results) { try? data.write(to: destination.appendingPathComponent("results.json"), options: .atomic) }
        exit(results.contains { !$0.passed && $0.skipped == nil } ? 1 : 0)
    }
    /// Draws `content` in an offscreen window. `mainWindow` matches the app's main
    /// window: full-size content under a unified toolbar, as WorkspaceView expects.
    static func snapshot<Content: View>(_ content: Content, name: String, size: NSSize, appearance: NSAppearance.Name, directory: URL, active: Bool = false, mainWindow: Bool = false) async throws {
        ExportToolbarButton.offscreenActive = active
        defer { ExportToolbarButton.offscreenActive = nil }
        let controller = NSHostingController(rootView: content.background(DesignValues.color("bg.window")).sceneAccent().preferredColorScheme(appearance == .darkAqua ? .dark : .light).environment(\.controlActiveState, active ? .key : .inactive))
        // A fixed size from the start: a hosting controller that sizes its window
        // leaves split views laid out for the wrong height in the first frames.
        controller.sizingOptions = []
        let hosting = controller.view
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = OffscreenSnapshotWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size), styleMask: mainWindow ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.titled, .closable, .resizable], backing: .buffered, defer: false)
        if mainWindow { window.toolbarStyle = .unified }
        window.rendersActive = active
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        if name.contains("settings") { window.toolbarStyle = .expanded }
        window.title = name.contains("editor") || name.contains("clips") ? "interview-take" : name.contains("settings") ? "VoxClip Settings" : name.hasPrefix("export") ? "Export" : name.hasPrefix("toolbar") ? "Toolbar contrast" : "Home"
        window.contentViewController = controller
        hosting.frame = NSRect(origin: .zero, size: size)
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(600))
        window.setContentSize(size)
        hosting.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<20 {
            hosting.layoutSubtreeIfNeeded()
            if !["editor-light", "editor-dark", "demo-editor"].contains(name) || editorLayout(in: hosting) != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        // Let SwiftUI commit the layout for the final size before drawing.
        try await Task.sleep(for: .milliseconds(150))
        hosting.layoutSubtreeIfNeeded()
        func prepare(_ view: NSView) {
            if let text = view as? NSTextView {
                if let manager = text.textLayoutManager, let range = manager.textContentManager?.documentRange { manager.ensureLayout(for: range); manager.textViewportLayoutController.layoutViewport() }
                text.displayIfNeeded()
            }
            view.subviews.forEach(prepare)
        }
        prepare(hosting)
        if name == "settings-minimum" {
            let toolbar = window.toolbar?.visibleItems?.compactMap { item -> ToolbarExtent? in
                guard let view = item.view else { return nil }
                return ToolbarExtent(label: item.label, width: view.bounds.width, attached: view.window === window && !view.isHiddenOrHasHiddenAncestor)
            } ?? []
            try JSONEncoder().encode(toolbar).write(to: directory.appendingPathComponent("settings-minimum-toolbar.json"))
        }
        if name.hasPrefix("toolbar-") { toolbarEvidence += try DebugToolbarPixels.measure(window: window, name: name, directory: directory, active: active) }
        if name == "editor-light" || name == "editor-dark" || name == "demo-editor" {
            guard let layout = editorLayout(in: hosting), layout.transcriptWidth >= 439, layout.previewWidth >= 299 else { throw CocoaError(.coderInvalidValue) }
            if name == "demo-editor" { try JSONEncoder().encode(layout).write(to: directory.appendingPathComponent("editor-layout.json"), options: .atomic) }
        }
        // cacheDisplay cannot draw materials: the sidebar comes out blank and its selected
        // row black. The window server composites the offscreen window as a real one.
        let bitmap: NSBitmapImageRep
        if mainWindow, let composited = await windowServerImage(window, directory: directory, name: name) {
            bitmap = composited
        } else {
            if mainWindow { cachedMainWindowCaptures.append(name) }
            let surface = hosting.superview ?? hosting
            guard let cached = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) else { throw CocoaError(.fileWriteUnknown) }
            surface.cacheDisplay(in: surface.bounds, to: cached)
            bitmap = cached
        }
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: directory.appendingPathComponent(name).appendingPathExtension("jpg"), options: .atomic)
        window.close()
    }
    /// Main-window captures that fell back to cacheDisplay because the window server
    /// gave no image (it gives none while the console session is locked).
    static var cachedMainWindowCaptures: [String] = []
    /// Why screencapture gave nothing: it could not start or exited non-zero.
    static var windowServerRefusals: [String] = []
    /// Captures that exited cleanly but gave no usable image.
    static var windowServerGaps: [String] = []
    /// The window as the window server draws it, without activating the app.
    private static func windowServerImage(_ window: NSWindow, directory: URL, name: String) async -> NSBitmapImageRep? {
        // screencapture refuses a file name that starts with a dot, and still exits 0.
        let file = directory.appendingPathComponent("\(name)-window-server.png")
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        let errors = Pipe()
        process.standardError = errors
        guard (try? process.run()) != nil else { windowServerRefusals.append("it did not start"); return nil }
        while process.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
        let message = String(decoding: errors.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus != 0 { windowServerRefusals.append("exit \(process.terminationStatus)\(message.isEmpty ? "" : ": \(message)")") }
        guard process.terminationStatus == 0 else { return nil }
        guard let data = try? Data(contentsOf: file), let image = NSBitmapImageRep(data: data) else {
            let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
            windowServerGaps.append("\(name): no image (\(bytes.map { "\($0) bytes" } ?? "no file")\(message.isEmpty ? "" : ", \(message)"))")
            return nil
        }
        guard image.pixelsWide >= Int(window.frame.width) else { windowServerGaps.append("\(name): \(image.pixelsWide) px for a \(Int(window.frame.width)) pt window"); return nil }
        return image
    }
    private static var toolbarContrast: some View {
        VStack(spacing: 12) {
            Text("Toolbar probe · left enabled · right disabled")
            Text("Key state is simulated; the app stays inactive.").font(.caption).foregroundStyle(.secondary)
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { EditorExportControl {} }
                ToolbarItem(placement: .primaryAction) { EditorExportControl {}.disabled(true) }
            }
    }
}

private actor InspectorTestKeys: ProviderKeyStore {
    private var present = false
    func hasKey(for provider: String) -> Bool { provider == "openai" && present }
    func save(_ value: String, for provider: String) {
        if provider == "openai" { present = !value.isEmpty }
    }
}

private actor DelayedInspectorSettings: SettingsStore {
    private var pending: CheckedContinuation<SettingsDocument, Never>?
    private var released = false
    var isWaiting: Bool { pending != nil }
    func load() async throws -> SettingsDocument {
        if released { return SettingsDocument(values: ["llm.connector": .string("openai")]) }
        return await withCheckedContinuation { pending = $0 }
    }
    func finish() {
        released = true
        pending?.resume(returning: SettingsDocument(values: ["llm.connector": .string("openai")]))
        pending = nil
    }
    func save(_ settings: SettingsDocument) async throws {}
    func flush() async throws {}
}

private actor InspectorKeyConnector: LLMConnector {
    nonisolated let id: ConnectorID = .openai
    let keys: InspectorTestKeys
    init(keys: InspectorTestKeys) { self.keys = keys }
    func status() async -> ConnectorStatus { await keys.hasKey(for: "openai") ? .ready : .needsKey }
    func models(refresh: Bool) -> [LLMModel] { [] }
    func contextTokens(model: String) -> Int? { nil }
    func send(_ request: LLMRequest, model: String) throws -> RawCompletion { throw LLMError.unavailable(reason: "Offline UI fixture") }
}

private actor InspectorStatusConnector: LLMConnector {
    nonisolated let id: ConnectorID
    private var current: ConnectorStatus
    private var delayNext = false
    private var pending: CheckedContinuation<ConnectorStatus, Never>?
    init(id: ConnectorID, status: ConnectorStatus) { self.id = id; current = status }
    func setStatus(_ value: ConnectorStatus) { current = value }
    func delayNextStatus() { delayNext = true }
    var hasPendingStatus: Bool { pending != nil }
    func finishDelayedStatus(_ value: ConnectorStatus) { pending?.resume(returning: value); pending = nil }
    func status() async -> ConnectorStatus {
        if delayNext {
            delayNext = false
            return await withCheckedContinuation { pending = $0 }
        }
        return current
    }
    func models(refresh: Bool) -> [LLMModel] { [] }
    func contextTokens(model: String) -> Int? { nil }
    func send(_ request: LLMRequest, model: String) throws -> RawCompletion { throw LLMError.unavailable(reason: "Offline UI fixture") }
}

@MainActor private final class OffscreenSnapshotWindow: NSWindow {
    var rendersActive = false
    override var isKeyWindow: Bool { rendersActive }
    override var isMainWindow: Bool { rendersActive }
}
#endif
