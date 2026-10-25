#if DEBUG
import SwiftUI
import VoxClipCore
import Darwin

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
    static func captureDemo(app: AppModel, destination: URL) async {
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            guard let index = CommandLine.arguments.firstIndex(of: "-demoProject"), index + 1 < CommandLine.arguments.count else { throw CocoaError(.coderInvalidValue) }
            let project = try DemoEditing.loadFixture(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            let document = VoxClipDocument(project: project, demo: true)
            try await snapshot(EditorView(document: document, app: app).environment(app), name: "demo-editor", size: NSSize(width: 1440, height: 820), appearance: .aqua, directory: destination)
            try await snapshot(WelcomeView().environment(app), name: "demo-welcome", size: NSSize(width: 720, height: 500), appearance: .aqua, directory: destination)
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
            try await snapshot(WelcomeView().environment(app), name: "welcome-light", size: NSSize(width: 720, height: 500), appearance: .aqua, directory: destination)
            let visualDocument = VoxClipDocument(project: project, demo: true)
            try await snapshot(EditorView(document: visualDocument, app: app).environment(app), name: "editor-light", size: NSSize(width: 1440, height: 850), appearance: .aqua, directory: destination)
            try await snapshot(EditorView(document: visualDocument, app: app).environment(app), name: "editor-dark", size: NSSize(width: 1440, height: 850), appearance: .darkAqua, directory: destination)
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
        window.title = name.contains("editor") ? "interview-take · VoxClip" : name.contains("settings") ? "VoxClip Settings" : name.hasPrefix("export") ? "Export" : name.hasPrefix("toolbar") ? "Toolbar contrast" : "Welcome to VoxClip"
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
        if name.hasPrefix("editor") || name == "demo-editor" {
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

@MainActor private final class OffscreenSnapshotWindow: NSWindow {
    var rendersActive = false
    override var isKeyWindow: Bool { rendersActive }
    override var isMainWindow: Bool { rendersActive }
}
#endif
