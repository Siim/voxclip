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
    private static func editorLayout(in view: NSView) -> Layout? {
        if let split = view as? NSSplitView, split.identifier?.rawValue == "voxclip.editor.split", split.arrangedSubviews.count == 2 {
            return Layout(transcriptWidth: split.arrangedSubviews[0].frame.width, previewWidth: split.arrangedSubviews[1].frame.width)
        }
        return view.subviews.lazy.compactMap { editorLayout(in: $0) }.first
    }
    static func sceneAudit(app: AppModel, destination: URL) async {
        var results: [Result] = []
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for _ in 0..<80 {
                if app.activeHome?.window != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let model = app.activeHome, let window = model.window else { throw CocoaError(.coderInvalidValue) }
            let originalWindow = window.windowNumber
            window.setAccessibilityIdentifier("voxclip.scene.\(originalWindow)")
            results.append(Result(name: "fresh launch opens an empty document workspace", passed: model.isHome && window.isVisible))
            results.append(Result(name: "no separate Welcome window", passed: !NSApp.windows.contains { $0.title.contains("Welcome to VoxClip") }))
            results.append(Result(name: "fresh Home is not an edited document", passed: !window.isDocumentEdited))
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
            results.append(Result(name: "delayed saved connector invalidates readiness", passed: wasDelayed && delayedApp.string("llm.connector") == "openai" && delayedApp.connectorReadinessRevision > initialReadinessRevision))
            window.setContentSize(NSSize(width: 1100, height: 720))
            try await Task.sleep(for: .milliseconds(250))
            try await capture(window: window, name: "live-home", directory: destination)
            guard let root = app.shared?.root else { throw VoxClipError.sharedResourcesMissing }
            let source = root.appendingPathComponent("fixtures/media/fillers-chirp.mp4")
            let cancelled = EditorModel(document: VoxClipDocument(), app: app, preview: DemoPreviewEngine())
            let cancelledImport = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                await cancelled.importVideo(source)
            }
            await cancelledImport.value
            results.append(Result(name: "cancelled import leaves empty Home document", passed: cancelled.isHome && cancelled.importProgress == nil))
            cancelled.close()
            await model.importVideo(source)
            try await Task.sleep(for: .milliseconds(250))
            results.append(Result(name: "video import stays in the same document window", passed: !model.isHome && model.window?.windowNumber == originalWindow && model.location == .transcript))
            results.append(Result(name: "imported video can preview and export without transcript", passed: model.mediaResolved && model.canExport && model.project.transcript == nil))
            results.append(Result(name: "imported document keeps a native untitled title until saved", passed: window.title.contains("Untitled") && model.project.title == "fillers-chirp"))
            let importedID = model.project.id
            await model.importVideo(source)
            results.append(Result(name: "import cannot replace an open project", passed: model.project.id == importedID))
            try await capture(window: window, name: "live-imported", directory: destination)
            let fixture = try DemoEditing.loadFixture(root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
            var transcribed = model.project
            transcribed.transcript = fixture.transcript
            model.document.replaceProject(transcribed)
            model.refresh()
            await model.updatePreview(load: false)
            results.append(Result(name: "demo transcript exposes clip finding", passed: !model.words.isEmpty && model.editingAvailable))
            model.location = .clips
            try await capture(window: window, name: "live-finder-missing", directory: destination)
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
            app.set("llm.connector", .string("openai"))
            results.append(Result(name: "missing key is shown in the Clips workspace", passed: await hasInspectorStatus("Add your OpenAI key", in: window)))
            results.append(Result(name: "Find Clips remains actionable for current preflight with missing key", passed: inspectorElement("findClipsAction", in: window)?.enabled == true))
            try await app.saveProviderKey("offline-test-key", for: "openai")
            results.append(Result(name: "saving a key refreshes Clips readiness without reselecting", passed: await hasInspectorStatus("Ready to find clips", in: window)))
            try await app.saveProviderKey("", for: "openai")
            results.append(Result(name: "forgetting a key refreshes Clips readiness without reselecting", passed: await hasInspectorStatus("Add your OpenAI key", in: window)))
            app.set("llm.connector", .string("ollama"))
            results.append(Result(name: "stopped local service is shown in Clips", passed: await hasInspectorStatus("Start Ollama", in: window)))
            results.append(Result(name: "stopped local service keeps Find Clips actionable", passed: inspectorElement("findClipsAction", in: window)?.enabled == true))
            results.append(Result(name: "stopped local service exposes Check Again", passed: inspectorElement("checkConnectorAgain", in: window)?.enabled == true))
            try await capture(window: window, name: "live-finder-stopped", directory: destination)
            await localConnector.setStatus(.ready)
            let pressedCheckAgain = inspectorElement("checkConnectorAgain", in: window).map { AXUIElementPerformAction($0.element, kAXPressAction as CFString) == .success } == true
            let refreshedLocalStatus = await hasInspectorStatus("Ready to find clips", in: window)
            results.append(Result(name: "Check Again refreshes local readiness without reselecting", passed: pressedCheckAgain && refreshedLocalStatus))
            await localConnector.setStatus(.unavailable(reason: "Local service unavailable."))
            app.set("llm.baseUrl.ollama", .string("http://127.0.0.1:11435"))
            results.append(Result(name: "changing the selected server URL refreshes unavailable status", passed: await hasInspectorStatus("Local service unavailable", in: window)))
            await localConnector.setStatus(.ready)
            let pressedUnavailableCheck = inspectorElement("checkConnectorAgain", in: window).map { AXUIElementPerformAction($0.element, kAXPressAction as CFString) == .success } == true
            let recoveredUnavailable = await hasInspectorStatus("Ready to find clips", in: window)
            results.append(Result(name: "unavailable connector recovers through Check Again", passed: pressedUnavailableCheck && recoveredUnavailable))
            try await capture(window: window, name: "live-finder-ready", directory: destination)
            await localConnector.delayNextStatus()
            app.refreshConnectorReadiness()
            for _ in 0..<20 {
                if await localConnector.hasPendingStatus { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let previousStatusPending = await localConnector.hasPendingStatus
            app.set("llm.connector", .string("lmstudio"))
            let otherReady = await hasInspectorStatus("Ready to find clips", in: window)
            await localConnector.finishDelayedStatus(.needsKey)
            try await Task.sleep(for: .milliseconds(100))
            results.append(Result(name: "late previous connector status cannot replace current readiness", passed: previousStatusPending && otherReady && inspectorElement("clipConnectorStatus", in: window)?.label?.contains("Ready to find clips") == true))
            try await capture(window: window, name: "live-finder-recovered", directory: destination)
            app.set("llm.connector", .string(""))
            app.connectorOverride = nil
            app.providerKeyStoreOverride = nil
            model.location = .transcript
            let ids = model.words.prefix(3).map(\.id)
            model.selectedWordIDs = Set(ids)
            model.makeClip()
            try await Task.sleep(for: .milliseconds(250))
            results.append(Result(name: "manual clip enters Clips workspace", passed: model.location == .clips && model.sortedClips.count == 1))
            results.append(Result(name: "manual clip registers document undo", passed: model.undoManager?.canUndo == true))
            results.append(Result(name: "document window is backed by NSDocument", passed: window.windowController?.document != nil))
            results.append(Result(name: "native document records unsaved changes", passed: window.windowController?.document?.isDocumentEdited == true))
            results.append(Result(name: "edited document is marked for close protection", passed: window.isDocumentEdited))
            try await capture(window: window, name: "live-clips", directory: destination)
            if let clip = model.sortedClips.first {
                model.activate(clip)
                try await Task.sleep(for: .milliseconds(250))
                if let button = exportButton(in: window) {
                    results.append(Result(name: "toolbar has an accessible export label", passed: button.exportTitle == "Export…" && button.accessibilityLabel() == "Export…" && button.isEnabled))
                    button.performClick(nil)
                } else {
                    results.append(Result(name: "native export toolbar button is discoverable", passed: false))
                }
                try await Task.sleep(for: .milliseconds(250))
                results.append(Result(name: "toolbar click opens export for previewed clip", passed: model.showExport && model.activeClip?.id == clip.id && model.exportClipIDs == [clip.id]))
                if let sheet = window.attachedSheet {
                    try await capture(window: sheet, name: "live-export-clip", directory: destination)
                    results.append(Result(name: "clip export opens a native attached sheet", passed: sheet.isVisible))
                } else {
                    results.append(Result(name: "clip export opens a native attached sheet", passed: false))
                }
                model.showExport = false
                let full = try await model.renderRequest(target: .fullEdit)
                let selected = try await model.renderRequest(target: .clip(clip.id))
                results.append(Result(name: "full video and clip render scopes differ", passed: full.plan.outputSamples > selected.plan.outputSamples))
                try await capture(window: window, name: "live-clip-preview", directory: destination)
                model.activate(nil)
                model.setStyle("off")
                results.append(Result(name: "caption switch keeps project and preview", passed: model.project.captions.styleId == "off" && model.activeClip == nil && model.mediaResolved))
                window.setContentSize(NSSize(width: 900, height: 650))
                try await Task.sleep(for: .milliseconds(250))
                results.append(Result(name: "workspace resizes to laptop split view", passed: window.frame.width >= 890 && model.location == .clips))
                try await capture(window: window, name: "live-compact", directory: destination)
                app.set("general.appearance", .string("light"))
                try await Task.sleep(for: .milliseconds(250))
                try await capture(window: window, name: "live-compact-light", directory: destination)
            }
            if let native = window.windowController?.document as? NSDocument {
                let registered = native.windowControllers.contains { $0 === window.windowController }
                results.append(Result(name: "document owns its workspace window controller", passed: registered))
                window.performClose(nil)
                try await Task.sleep(for: .milliseconds(300))
                if let sheet = window.attachedSheet {
                    try await capture(window: sheet, name: "live-dirty-close", directory: destination)
                    results.append(Result(name: "unsaved project close asks before discarding edits", passed: sheet.isVisible && window.isVisible))
                    sheet.cancelOperation(nil)
                    try await Task.sleep(for: .milliseconds(500))
                    results.append(Result(name: "cancel keeps the unsaved document open", passed: window.attachedSheet == nil && window.isVisible && native.isDocumentEdited))
                } else {
                    results.append(Result(name: "unsaved project close asks before discarding edits", passed: false))
                    results.append(Result(name: "cancel keeps the unsaved document open", passed: false))
                }
                let saved = destination.appendingPathComponent("native-save.voxclip")
                try await save(native, to: saved)
                try await Task.sleep(for: .milliseconds(150))
                try await save(native, to: saved, operation: .saveOperation)
                try await Task.sleep(for: .milliseconds(400))
                results.append(Result(name: "native Save As writes and clears dirty state", passed: FileManager.default.fileExists(atPath: saved.path) && !native.isDocumentEdited && !window.isDocumentEdited))
                let reopened = try VoxClipDocument(data: Data(contentsOf: saved)).project
                results.append(Result(name: "native saved project retains transcript and clip", passed: reopened.transcript == model.project.transcript && reopened.edits.clips == model.project.edits.clips))
                model.setStyle("vox-highlight")
                results.append(Result(name: "edit after Save marks this document dirty", passed: native.isDocumentEdited))
                model.undoManager?.undo()
                try await Task.sleep(for: .milliseconds(400))
                results.append(Result(name: "undo back to saved content clears dirty state", passed: model.project.captions.styleId == "off" && !native.isDocumentEdited && !window.isDocumentEdited))
                let second = destination.appendingPathComponent("finder-open.voxclip")
                try FileManager.default.copyItem(at: saved, to: second)
                let initialCount = NSDocumentController.shared.documents.count
                NSDocumentController.shared.newDocument(nil)
                for _ in 0..<30 {
                    if let home = app.activeHome, home !== model, home.window != nil { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                if let emptyHome = app.activeHome, emptyHome !== model, let emptyWindow = emptyHome.window {
                    results.append(Result(name: "New Project opens a normal empty document", passed: emptyHome.isHome && emptyWindow.isVisible && NSDocumentController.shared.documents.count == initialCount + 1))
                    app.fileRouter.receive([second])
                    for _ in 0..<30 {
                        if NSDocumentController.shared.document(for: second) != nil && !emptyWindow.isVisible { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    results.append(Result(name: "opening a saved project from Home closes only that empty Home", passed: NSDocumentController.shared.document(for: second) != nil && !emptyWindow.isVisible && window.isVisible && NSDocumentController.shared.documents.count == initialCount + 1))
                    window.makeKeyAndOrderFront(nil)
                    try await Task.sleep(for: .milliseconds(150))
                    let third = destination.appendingPathComponent("another-project.voxclip")
                    try FileManager.default.copyItem(at: saved, to: third)
                    app.fileRouter.receive([third])
                    for _ in 0..<30 {
                        if NSDocumentController.shared.document(for: third) != nil { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    results.append(Result(name: "opening from an occupied project keeps both project windows", passed: NSDocumentController.shared.document(for: third) != nil && window.isVisible && NSDocumentController.shared.documents.count == initialCount + 2))
                } else {
                    results.append(Result(name: "New Project opens a normal empty document", passed: false))
                    results.append(Result(name: "opening a saved project from Home closes only that empty Home", passed: false))
                    results.append(Result(name: "opening from an occupied project keeps both project windows", passed: false))
                }
            }
        } catch {
            results.append(Result(name: "scene audit: \(error.localizedDescription)", passed: false))
        }
        if let data = try? JSONEncoder().encode(results) { try? data.write(to: destination.appendingPathComponent("scene-results.json"), options: .atomic) }
        exit(results.allSatisfy(\.passed) ? 0 : 1)
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
        return nil
    }
    private static func hasInspectorStatus(_ expected: String, in window: NSWindow) async -> Bool {
        for _ in 0..<30 {
            if inspectorElement("clipConnectorStatus", in: window)?.label?.contains(expected) == true { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return false
    }
    private static func save(_ document: NSDocument, to url: URL, operation: NSDocument.SaveOperationType = .saveAsOperation) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.save(to: url, ofType: UTType.voxclipProject.identifier, for: operation) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
    private static func capture(window: NSWindow, name: String, directory: URL) async throws {
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
            let detail = "capture=\(name) appActive=\(NSApp.isActive) processActive=\(NSRunningApplication.current.isActive) key=\(window.isKeyWindow) visible=\(window.isVisible) policy=\(NSApp.activationPolicy().rawValue)"
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
            let document = VoxClipDocument(project: project, demo: true)
            try await snapshot(EditorView(document: document, app: app).environment(app), name: "demo-editor", size: NSSize(width: 1440, height: 820), appearance: .aqua, directory: destination)
            let clipsModel = EditorModel(document: document, app: app, preview: DemoPreviewEngine())
            clipsModel.mediaResolved = true; clipsModel.refresh(); clipsModel.location = .clips
            try await snapshot(EditorView(model: clipsModel).environment(app), name: "demo-clips", size: NSSize(width: 1100, height: 720), appearance: .aqua, directory: destination)
            try await snapshot(EditorView(document: VoxClipDocument(), app: app).environment(app), name: "demo-home", size: NSSize(width: 1100, height: 720), appearance: .aqua, directory: destination)
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
            results += try await DebugPersistence.run(app: app, fixture: project, directory: destination)
            results += try await DebugExport.run(app: app, fixture: project, directory: destination)
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
                undo.beginUndoGrouping(); model.cutSelection(); undo.endUndoGrouping()
                check("cutting an already-cut pause restores it", !model.project.edits.cutPauseIds.contains(pause.id))
                undo.undo()
                model.selectedPauseIDs = []
            } else { check("cutting an already-cut pause restores it", false) }
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
            check("share URL host and encoding", ShareText.url("x", caption: "A & B + C?")?.absoluteString == "https://x.com/intent/post?text=A%20%26%20B%20%2B%20C%3F")
            check("share weighted URL and emoji", ShareText.weight("Hi 👩🏽‍💻 https://example.com/a") == 29)
            let intent = ShareText.url("x", caption: String(repeating: "word ", count: 100))!
            let truncated = URLComponents(url: intent, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "text" }?.value ?? ""
            check("share over limit truncates", ShareText.weight(truncated) <= 280 && truncated.hasSuffix("…"))
            check("secrets use isolated account names", SecretStore.account(for: "elevenlabs") == "elevenlabs-api-key" && SecretStore.account(for: "openai") == "llm-api-key-openai")
            let outside = destination.appendingPathComponent("outside.voxclip")
            try FileManager.default.copyItem(at: fixture, to: outside)
            do { _ = try DemoEditing.loadFixture(outside); check("demo path is restricted", false) } catch { check("demo path is restricted", true) }
            try FileManager.default.removeItem(at: outside)
            let unavailable = await app.safeError(VoxClipError.notImplemented("mac-media"))
            check("unimplemented service is truthful", unavailable.contains("not available") && unavailable.contains("Your video and edits are still here."))
            try await snapshot(EditorView(document: VoxClipDocument(), app: app).environment(app), name: "home-light", size: NSSize(width: 1100, height: 720), appearance: .aqua, directory: destination)
            try await snapshot(EditorView(document: VoxClipDocument(), app: app).environment(app), name: "home-dark", size: NSSize(width: 1100, height: 720), appearance: .darkAqua, directory: destination)
            let visualDocument = VoxClipDocument(project: project, demo: true)
            try await snapshot(EditorView(document: visualDocument, app: app).environment(app), name: "editor-light", size: NSSize(width: 1440, height: 850), appearance: .aqua, directory: destination)
            try await snapshot(EditorView(document: visualDocument, app: app).environment(app), name: "editor-dark", size: NSSize(width: 1440, height: 850), appearance: .darkAqua, directory: destination)
            let clipsModel = EditorModel(document: visualDocument, app: app, preview: DemoPreviewEngine())
            clipsModel.mediaResolved = true; clipsModel.refresh(); clipsModel.location = .clips
            try await snapshot(EditorView(model: clipsModel).environment(app), name: "clips-light", size: NSSize(width: 1100, height: 720), appearance: .aqua, directory: destination)
            try await snapshot(EditorView(model: clipsModel).environment(app), name: "clips-dark", size: NSSize(width: 1100, height: 720), appearance: .darkAqua, directory: destination)
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
        if let data = try? JSONEncoder().encode(results) { try? data.write(to: destination.appendingPathComponent("results.json"), options: .atomic) }
        exit(results.contains { !$0.passed } ? 1 : 0)
    }
    static func snapshot<Content: View>(_ content: Content, name: String, size: NSSize, appearance: NSAppearance.Name, directory: URL, active: Bool = false) async throws {
        ExportToolbarButton.offscreenActive = active
        defer { ExportToolbarButton.offscreenActive = nil }
        let controller = NSHostingController(rootView: content.background(DesignValues.color("bg.window")).preferredColorScheme(appearance == .darkAqua ? .dark : .light).environment(\.controlActiveState, active ? .key : .inactive))
        let hosting = controller.view
        let window = OffscreenSnapshotWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.rendersActive = active
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        if name.contains("settings") { window.toolbarStyle = .expanded }
        window.title = name.contains("editor") || name.contains("clips") ? "interview-take" : name.contains("settings") ? "VoxClip Settings" : name.hasPrefix("export") ? "Export" : name.hasPrefix("toolbar") ? "Toolbar contrast" : "Home"
        window.contentViewController = controller
        hosting.frame = NSRect(origin: .zero, size: size)
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(600))
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
        let surface = hosting.superview ?? hosting
        guard let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) else { throw CocoaError(.fileWriteUnknown) }
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: directory.appendingPathComponent(name).appendingPathExtension("jpg"), options: .atomic)
        window.close()
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
