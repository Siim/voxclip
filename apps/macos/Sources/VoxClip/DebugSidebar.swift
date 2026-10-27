#if DEBUG
import AppKit
import SwiftUI
import VoxClipCore

/// The sidebar (step 5) on the "Five questions" fixture from the design mockups: four
/// kept clips and one AI suggestion, with clip numbering, Keep, Keep All, Dismiss,
/// Remove, Rename and row scoping, and light and dark captures.
@MainActor enum DebugSidebar {
    static func run(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        let shell = WorkspaceShell(app: app)
        await shell.attachForTesting(VoxClipDocument(project: try fiveQuestions(from: fixture), demo: true), selection: .fullTake)
        guard let editor = shell.editor else { throw CocoaError(.coderInvalidValue) }
        let kept = editor.keptClips, suggested = editor.suggestedClips
        check("Five questions has four kept clips and one suggestion numbered 5", kept.count == 4 && suggested.count == 1 && suggested.first.flatMap { editor.clipNumber($0.id) } == 5
              && kept.map(\.title) == ["Think in sentences", "It has to work on mute", "And yeah, I mess up a lot", "The best thirty seconds"])
        check("rows show each scope's edited length", editor.editedDuration(nil) > 60 && kept.allSatisfy { editor.editedDuration($0) > 3 && editor.editedDuration($0) < 40 })
        check("each clip's card sets its own first words", editor.cardText(.clip(kept[0].id), wordsVisible: true).words.map(\.text) == ["The", "trick"]
              && editor.cardText(.fullTake, wordsVisible: true).source == .transcript)
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await DebugUISuite.snapshot(WorkspaceView(shell: shell).environment(app), name: "sidebar-editor-\(suffix)", size: NSSize(width: 1440, height: 900), appearance: appearance, directory: directory, active: true, mainWindow: true)
        }

        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await DebugUISuite.snapshot(SidebarRowsPreview(shell: shell).environment(app), name: "sidebar-rows-\(suffix)", size: NSSize(width: 252, height: 640), appearance: appearance, directory: directory, active: true)
        }
        results += try await editorLayout(app: app, shell: shell, directory: directory)
        shell.selection = .clip(kept[0].id)
        check("a clip row scopes the editor to that clip", editor.project.edits.activeClipId == kept[0].id)
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await DebugUISuite.snapshot(WorkspaceView(shell: shell).environment(app), name: "sidebar-clip-\(suffix)", size: NSSize(width: 1440, height: 900), appearance: appearance, directory: directory, active: true, mainWindow: true)
        }
        editor.undoManager?.undo()
        check("undo of the row change returns to Full Take", shell.selection == .fullTake && editor.project.edits.activeClipId == nil)

        guard let suggestion = suggested.first else { throw CocoaError(.coderInvalidValue) }
        editor.keep(suggestion.id)
        check("Keep moves the suggestion into the kept clips as clip 5", editor.suggestedClips.isEmpty && editor.keptClips.count == 5 && editor.clipNumber(suggestion.id) == 5)
        editor.undoManager?.undo()
        check("undo of Keep restores the suggestion", editor.suggestedClips.map(\.id) == [suggestion.id])
        editor.dismiss(suggestion.id)
        check("Dismiss removes the suggestion in one undo step", editor.suggestedClips.isEmpty && editor.keptClips.count == 4)
        editor.undoManager?.undo()
        check("undo of Dismiss restores the suggestion", editor.suggestedClips.map(\.id) == [suggestion.id])
        editor.removeClip(kept[1].id)
        check("Remove takes out a kept clip and renumbers the rest", editor.keptClips.count == 3 && editor.clipNumber(kept[2].id) == 2 && editor.clipNumber(suggestion.id) == 4)
        editor.undoManager?.undo()
        check("undo of Remove restores the clip", editor.keptClips.map(\.id) == kept.map(\.id))
        editor.renameClip(kept[0].id, to: "  Sentences, not videos  ")
        check("Rename trims and sets the clip title", editor.keptClips.first?.title == "Sentences, not videos")
        editor.undoManager?.undo()

        var second = editor.project
        if let source = second.edits.clips.first(where: { $0.id == suggestion.id }) {
            var extra = source
            extra.id = "suggestion-2"
            extra.startWordId = kept[3].startWordId
            extra.endWordId = kept[3].endWordId
            second.edits.clips.append(extra)
        }
        editor.close()
        let keepAllShell = WorkspaceShell(app: app)
        await keepAllShell.attachForTesting(VoxClipDocument(project: second, demo: true), selection: .fullTake)
        guard let both = keepAllShell.editor else { throw CocoaError(.coderInvalidValue) }
        check("two suggestions are listed after the kept clips", both.suggestedClips.count == 2 && both.clipNumber("suggestion-2") == 5 && both.clipNumber(suggestion.id) == 6)
        both.keepAll()
        check("Keep All keeps every suggestion", both.suggestedClips.isEmpty && both.keptClips.count == 6)
        both.undoManager?.undo()
        check("Keep All is one undo step", both.suggestedClips.count == 2)
        both.close()
        results += try await findClips(app: app, fixture: fixture, directory: directory)
        results += try await editorToolbar(app: app, fixture: fixture, directory: directory)
        results += try await reviewFixes(app: app, fixture: fixture, directory: directory)
        return results
    }

    /// The round 1d review fixes: Make Clip as one undo step that selects its row, focus
    /// after Keep, Dismiss and Remove, Export Clip… from a row, Recent rows, the
    /// untranscribed take, Help on Home, a running import, the divider drag, the title
    /// rule, Versions-browser windows, poster folders and the selected-row meta.
    static func reviewFixes(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        var two = try fiveQuestions(from: fixture)
        if var extra = two.edits.clips.first(where: { $0.id == "five-5" }) {
            extra.id = "five-6"
            extra.startWordId = two.edits.clips[3].startWordId
            extra.endWordId = two.edits.clips[3].endWordId
            two.edits.clips.append(extra)
        }
        let shell = WorkspaceShell(app: app)
        await shell.attachForTesting(VoxClipDocument(project: two, demo: true), selection: .fullTake)
        guard let editor = shell.editor else { throw CocoaError(.coderInvalidValue) }
        // One explicit undo group per user action, so "one undo step" means one.
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        func step(_ action: () -> Void) { undo.beginUndoGrouping(); action(); undo.endUndoGrouping() }

        // Make Clip (⌘K): one undo step adds the clip and selects its row.
        let words = editor.words
        guard let start = words.firstIndex(where: { $0.text == "One" }), start + 3 < words.count else { throw CocoaError(.coderInvalidValue) }
        editor.select(words[start].id); editor.select(words[start + 3].id, extend: true)
        let before = editor.project.edits.clips.count, steps = editor.undoSteps
        step { editor.makeClip() }
        let made = editor.project.edits.clips.first { $0.startWordId == words[start].id && $0.endWordId == words[start + 3].id }
        let madeNumber = made.flatMap { editor.clipNumber($0.id) }
        check("Make Clip adds the clip and selects its row in one undo step (\(editor.lastAnnouncement ?? "no announcement"))",
              made != nil && editor.project.edits.clips.count == before + 1 && editor.project.edits.activeClipId == made?.id && shell.selection == made.map { SidebarItem.clip($0.id) }
              && editor.undoSteps == steps + 1 && undo.undoActionName == "Make clip from selection")
        check("Make Clip announces \"Clip N made.\"", madeNumber != nil && editor.lastAnnouncement == "Clip \(madeNumber ?? 0) made.")
        undo.undo()
        check("one undo removes the clip and returns the selection to Full Take", editor.project.edits.clips.count == before && editor.project.edits.activeClipId == nil && shell.selection == .fullTake)
        undo.redo()
        check("redo brings the clip back selected", editor.project.edits.activeClipId == made?.id && shell.selection == made.map { SidebarItem.clip($0.id) })
        step { shell.selection = .fullTake }
        editor.select(words[start].id); editor.select(words[start + 3].id, extend: true)
        let duplicateSteps = editor.undoSteps
        step { editor.makeClip() }
        check("Make Clip on words a clip already covers selects that clip and announces it (\(editor.lastAnnouncement ?? "no announcement"))",
              editor.project.edits.clips.count == before + 1 && editor.project.edits.activeClipId == made?.id && editor.lastAnnouncement == "Clip \(madeNumber ?? 0) already covers these words."
              && editor.undoSteps == duplicateSteps + 1)
        step { if let made { editor.removeClip(made.id) } }

        // Keep, Dismiss and Remove on the selected row move the selection to the next row.
        let suggestions = editor.suggestedClips.map(\.id), kept = editor.keptClips.map(\.id)
        guard suggestions.count == 2, kept.count == 4 else { throw CocoaError(.coderInvalidValue) }
        step { shell.selection = .clip(suggestions[0]) }
        let keepSteps = editor.undoSteps
        step { editor.keep(suggestions[0]) }
        check("Keep on the selected suggestion selects the next suggestion in the same undo step", shell.selection == .clip(suggestions[1]) && editor.project.edits.activeClipId == suggestions[1] && editor.undoSteps == keepSteps + 1)
        undo.undo()
        check("one undo restores the suggestion and its selection", editor.suggestedClips.map(\.id) == suggestions && shell.selection == .clip(suggestions[0]))
        step { shell.selection = .clip(suggestions[1]) }
        step { editor.dismiss(suggestions[1]) }
        check("Dismiss on the last row selects Full Take", shell.selection == .fullTake && editor.suggestedClips.map(\.id) == [suggestions[0]])
        undo.undo()
        step { shell.selection = .clip(kept[1]) }
        step { editor.removeClip(kept[1]) }
        check("Remove on a selected kept clip selects the next clip", shell.selection == .clip(kept[2]) && editor.project.edits.activeClipId == kept[2])
        undo.undo()
        step { shell.selection = .clip(kept[0]) }
        step { editor.keep(suggestions[0]) }
        check("Keep on a row that isn't selected leaves the selection alone", shell.selection == .clip(kept[0]) && editor.project.edits.activeClipId == kept[0])
        undo.undo()

        // Recent rows show Home, and the editor's scope never pulls the selection away.
        let recent = directory.appendingPathComponent("recent-row.voxclip")
        shell.selection = .recent(recent)
        check("a selected Recent row shows Home and titles the window VoxClip", shell.showsHome && shell.title == "VoxClip" && shell.selection == .recent(recent))
        step { shell.selection = .fullTake }

        // The title rule: Project.title, else the file name, else the video's name.
        var titled = two
        titled.title = "Five questions"
        var untitled = two
        untitled.title = nil
        untitled.media.source.absolutePath = "/Movies/Take 3.mov"
        let saved = URL(fileURLWithPath: "/Projects/renamed.voxclip")
        check("the title is Project.title, else the file name, else the video's name",
              WorkspaceShell.projectTitle(titled, fileURL: saved) == "Five questions" && WorkspaceShell.projectTitle(untitled, fileURL: saved) == "renamed"
              && WorkspaceShell.projectTitle(untitled, fileURL: nil) == "Take 3")
        // Save As, Move and Rename give a default title the file's new name (design §2).
        var named = two
        named.media.source.absolutePath = "/Movies/IMG_1234.mov"
        let interview = URL(fileURLWithPath: "/Projects/Interview.voxclip")
        named.title = nil
        let unset = VoxClipDocument.followingTitle(named, previousNames: [], destination: interview)
        named.title = "IMG_1234"
        let video = VoxClipDocument.followingTitle(named, previousNames: [], destination: interview)
        named.title = "Draft"
        let previous = VoxClipDocument.followingTitle(named, previousNames: ["Draft"], destination: interview)
        let custom = VoxClipDocument.followingTitle(named, previousNames: ["Other"], destination: interview)
        check("a default title (unset, the video's name or the previous file name) follows the new file name, and any other title stays",
              unset == "Interview" && video == "Interview" && previous == "Interview" && custom == nil)
        // An untitled project's name is its title, else its video's name, never "Untitled".
        var draft = named
        draft.title = nil
        let fromVideo = VoxClipDocument(project: draft, demo: false).displayName
        draft.title = "Interview final"
        let fromTitle = VoxClipDocument(project: draft, demo: false).displayName
        check("the keep/delete prompt and Save panel name an untitled project by its title, else its video (\(fromVideo ?? "none"), \(fromTitle ?? "none"))",
              fromVideo == "IMG_1234" && fromTitle == "Interview final")
        editor.close()

        // The untranscribed take (C7).
        var bare = two
        bare.transcript = nil
        bare.edits.clips = []
        bare.edits.cutWordIds = []
        bare.edits.cutPauseIds = []
        let untranscribed = WorkspaceShell(app: app)
        await untranscribed.attachForTesting(VoxClipDocument(project: bare, demo: true), selection: .fullTake)
        if let model = untranscribed.editor {
            check("an untranscribed take reads \"Not transcribed\" and its actions say \"Transcribe the video to select words.\"",
                  SidebarStyle.fullTakeMeta(model) == "Not transcribed" && SidebarStyle.untranscribedReason(model) == "Transcribe the video to select words.")
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                try await DebugUISuite.snapshot(SidebarRowsPreview(shell: untranscribed).environment(app), name: "sidebar-untranscribed-\(suffix)", size: NSSize(width: 252, height: 240), appearance: appearance, directory: directory, active: true)
            }
            model.close()
        } else { check("an untranscribed take opens", false) }

        // A running import refuses opening, closing and replacing the open project.
        let busy = WorkspaceShell(app: app)
        await busy.attachForTesting(VoxClipDocument(project: two, demo: true), selection: .fullTake)
        let other = VoxClipDocument(project: two, demo: true)
        let release = busy.holdImportForTesting()
        let opened = await busy.openProject(at: recent)
        let openNotice = busy.notice
        busy.notice = nil
        let replaced = await busy.replaceProject(with: other)
        let closed = await busy.closeProject()
        check("while a video imports, opening, replacing and closing the project are refused with \"Finish the current task first.\"",
              !opened && openNotice == WorkspaceShell.busyCopy && !replaced && !closed && busy.notice == WorkspaceShell.busyCopy && busy.editor != nil)
        release()
        let closedAfter = await busy.closeProject()
        check("after the import, the project can close", closedAfter && busy.editor == nil)
        other.close()

        // A clip title still being typed is kept when the project closes or is replaced.
        // The interview fixture is a project that saves; it gets one kept clip.
        var savable = fixture
        if let words = savable.transcript?.words, words.count > 4 {
            savable.edits.clips = [ClipRange(id: "rename-in-progress", startWordId: words[0].id, endWordId: words[3].id, title: "Old title")]
        }
        for leaving in ["close", "replace"] {
            let file = directory.appendingPathComponent("rename-\(leaving).voxclip")
            try? FileManager.default.removeItem(at: file)
            let named = VoxClipDocument(project: savable, demo: false)
            let renamer = WorkspaceShell(app: app)
            let replacement = VoxClipDocument(project: two, demo: true)
            do {
                try await DebugUISuite.save(named, to: file)
                await renamer.attachForTesting(named, selection: .fullTake)
                guard let model = renamer.editor, let clip = model.keptClips.first else { throw CocoaError(.coderValueNotFound) }
                model.mediaResolved = true
                renamer.beginRename(clip.id)
                renamer.renameDraft = "Typed before \(leaving)"
                let left = leaving == "close" ? await renamer.closeProject() : await renamer.replaceProject(with: replacement)
                let written = try VoxClipDocument(data: Data(contentsOf: file)).project.edits.clips.first { $0.id == clip.id }?.title
                check("a clip title still being typed is saved when the project \(leaving == "close" ? "closes (⌘W)" : "is replaced") (\(written ?? "none"))",
                      left && written == "Typed before \(leaving)" && renamer.renaming == nil)
            } catch {
                check("a clip title still being typed is saved when the project \(leaving == "close" ? "closes" : "is replaced"): \(DebugUISuite.describe(error))", false)
            }
            renamer.editor?.close()
            replacement.close()
            named.close()
        }

        // Crash recovery (design §2): the main window's restorable state records an
        // untitled project's autosave and nothing for a saved one, and the autosave
        // reopens untitled with its edits.
        var cut = savable
        if let word = cut.transcript?.words.first(where: { !cut.edits.cutWordIds.contains($0.id) }) { cut.edits.cutWordIds.append(word.id) }
        let autosave = directory.appendingPathComponent("recovery-autosave.voxclip")
        try JSONProjectStore.encode(cut).write(to: autosave)
        func recorded(_ document: VoxClipDocument) throws -> URL? {
            let archiver = NSKeyedArchiver(requiringSecureCoding: true)
            MainWindowController.encodeRestorableState(document: document, into: archiver)
            archiver.finishEncoding()
            return MainWindowController.restoredAutosave(from: try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData))
        }
        let neverSaved = VoxClipDocument(project: cut, demo: false)
        neverSaved.autosavedContentsFileURL = autosave
        let savedProject = VoxClipDocument(project: cut, demo: false)
        savedProject.updateLocation(directory.appendingPathComponent("recovery-saved.voxclip"))
        savedProject.autosavedContentsFileURL = autosave
        let decoded = try recorded(neverSaved), savedDecoded = try recorded(savedProject)
        check("crash recovery records an untitled project's autosave and reads it back; a saved project records nothing",
              decoded?.standardizedFileURL == autosave.standardizedFileURL && savedDecoded == nil)
        let recovering = WorkspaceShell(app: app)
        let reopened = await recovering.reopenAutosave(autosave)
        let recovered = recovering.document
        let recoveredCuts = Set(recovered?.project.edits.cutWordIds ?? [])
        check("the recorded autosave reopens in the shell untitled and edited, with its cuts (reopened \(reopened), untitled \(recovered?.fileURL == nil), edited \(recovered?.isDocumentEdited == true), cuts \(recoveredCuts == Set(cut.edits.cutWordIds)), notice \(recovering.notice ?? "none"))",
              reopened && recovered?.fileURL == nil && recovered?.isDocumentEdited == true && recoveredCuts == Set(cut.edits.cutWordIds))
        // AppKit's document recovery and the restorable state can both reach the
        // autosave: the second reach keeps the recovered project and opens no copy.
        let again = await recovering.reopenAutosave(autosave)
        let appKitReopen = try await NSDocumentController.shared.reopenDocument(for: nil, withContentsOf: autosave, display: false).0
        let copy = VoxClipDocument(project: cut, demo: false)
        copy.autosavedContentsFileURL = autosave
        NSDocumentController.shared.addDocument(copy)
        let copyClosed = recovering.closesRecoveredCopy(copy) && !NSDocumentController.shared.documents.contains(copy)
        check("a second reach of the same autosave keeps the recovered project and closes a copy (again \(again), AppKit's reopen \(appKitReopen === recovered ? "returns the open project" : "makes a copy"), copy closed \(copyClosed))",
              again && copyClosed && recovering.document === recovered && FileManager.default.fileExists(atPath: autosave.path))
        if appKitReopen !== recovered, let extra = appKitReopen as? VoxClipDocument { _ = recovering.closesRecoveredCopy(extra) }
        recovering.editor?.close()
        recovered?.close()

        // Help works on Home: Keyboard Shortcuts and Workspace Tour need no editor.
        let menuDelegate = NSApp.delegate as? AppDelegate
        let help = NSApp.mainMenu?.item(withTitle: "Help")?.submenu
        let shortcuts = help?.items.first { $0.tag == 35 }, tour = help?.items.first { $0.tag == 36 }
        let enabled = [shortcuts, tour].allSatisfy { item in item.map { menuDelegate?.validateMenuItem($0) == true } ?? false }
        // AppKit sends no menu action while an app-modal session runs (menus are disabled
        // then), so with one open the handler is called directly.
        let modal = NSApp.modalWindow.map { "\(type(of: $0)) \"\($0.title)\"" }
        if let shortcuts, let action = shortcuts.action {
            if modal == nil { NSApp.sendAction(action, to: shortcuts.target, from: shortcuts) } else { _ = menuDelegate?.perform(action, with: shortcuts) }
        }
        let showedShortcuts = app.shell.showShortcuts
        app.shell.showShortcuts = false
        check("Help > Keyboard Shortcuts and Workspace Tour are enabled with no editor", enabled)
        check("Help > Keyboard Shortcuts opens its sheet with no editor, through \(modal.map { "its handler (app-modal \($0) open)" } ?? "the menu action")", showedShortcuts)
        check("the shortcuts sheet lists the current bindings", ShortcutsView.lines.contains("⌘1 / ⌘2|Home / Full Take") && ShortcutsView.lines.contains("⇧⌘K|Find clips")
              && ShortcutsView.lines.contains("⌥⌘I|Show / hide viewer") && ShortcutsView.lines.contains("⌃⌘S|Show / hide sidebar")
              && !ShortcutsView.lines.contains { $0.contains("⌘3") || $0.contains("caption inspector") })

        // The transcript takes keyboard focus when a project opens; returning from Home
        // with the sidebar list focused leaves focus in the list (C4).
        results += try await transcriptFocus(app: app, project: two)

        // Only a drag of the editor split's own divider stores the right column's width.
        results += await dividerDrag(app: app)

        // The sidebar in a window: Export Clip… from a row's context menu, Find Clips'
        // focus and the overlay below 960.
        results += try await sidebarWindow(app: app, project: try fiveQuestions(from: fixture), directory: directory)

        // A Versions-browser version opens read-only in its own window.
        let version = VoxClipDocument(project: two, demo: true)
        version.versionForTesting = true
        let mainDocument = app.shell.document
        version.makeWindowControllers()
        let versionWindow = version.windowControllers.first as? VersionWindowController
        let versionEditor = versionWindow?.shell.editor
        let refused = await app.shell.replaceProject(with: version)
        let projectBefore = version.project
        if let versionEditor, let word = versionEditor.words.first { versionEditor.apply(.cutSelection(ids: [word.id]), name: "Cut selection") }
        check("a Versions-browser version opens in its own read-only window and never replaces the open project",
              versionWindow != nil && versionWindow?.window !== app.shell.windowController?.window && versionEditor != nil && !refused
              && app.shell.document === mainDocument && version.project == projectBefore)
        version.close()
        check("closing a version closes its window and editor", versionWindow?.shell.editor == nil && versionWindow?.window?.isVisible != true)

        // Poster JPEGs are cached only through real folders.
        let cache = directory.appendingPathComponent("poster-cache", isDirectory: true)
        let outside = directory.appendingPathComponent("poster-outside", isDirectory: true)
        try? FileManager.default.removeItem(at: cache)
        try? FileManager.default.removeItem(at: outside)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let realKey = String(repeating: "a", count: 64), linkedKey = String(repeating: "b", count: 64)
        try FileManager.default.createSymbolicLink(at: cache.appendingPathComponent(linkedKey), withDestinationURL: outside)
        let real = ThumbnailCache.posterFolder(in: cache, contentKey: realKey, create: true)
        let linked = ThumbnailCache.posterFolder(in: cache, contentKey: linkedKey, create: true)
        let poster = outside.appendingPathComponent("poster.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: poster)
        let link = cache.appendingPathComponent("poster-link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: poster)
        check("poster folders are made only through real folders: a linked cache entry skips the disk cache",
              real?.path == cache.appendingPathComponent(realKey).appendingPathComponent("thumbs").path && linked == nil
              && (try? FileManager.default.contentsOfDirectory(atPath: outside.path)) == ["poster.jpg"] && ThumbnailCache.readPoster(link) == nil)

        // A focused selected row's meta reads at 4.5:1 on the dark accent selection.
        guard let dark = NSAppearance(named: .darkAqua) else { throw CocoaError(.coderInvalidValue) }
        var contrast = 0.0
        dark.performAsCurrentDrawingAppearance { contrast = DesignValues.contrast(.alternateSelectedControlTextColor, DesignValues.accentFill) }
        check("selected-row meta reads at \(String(format: "%.2f", contrast)):1 on the dark accent selection (at least 4.5)", contrast >= 4.5)
        return results
    }

    /// Keyboard focus in an offscreen main-window layout: the transcript when a project
    /// opens, and the sidebar list when the user returns from Home through it.
    static func transcriptFocus(app: AppModel, project: Project) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        let shell = WorkspaceShell(app: app)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1280, height: 800), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: WorkspaceView(shell: shell).environment(app))
        controller.sizingOptions = []
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.orderBack(nil)
        defer { shell.editor?.close(); window.close() }
        try await Task.sleep(for: .milliseconds(200))
        await shell.attachForTesting(VoxClipDocument(project: project, demo: true), selection: .fullTake)
        for _ in 0..<80 where !(window.firstResponder is TranscriptNSTextView) { try await Task.sleep(for: .milliseconds(25)) }
        check("opening a project puts keyboard focus in the transcript", window.firstResponder is TranscriptNSTextView)
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap(table).first
        }
        guard let root = window.contentView, let list = table(in: root) else {
            check("the sidebar list is in the window", false)
            return results
        }
        shell.selection = .home
        try await Task.sleep(for: .milliseconds(150))
        window.makeFirstResponder(list)
        shell.selection = .fullTake
        try await Task.sleep(for: .milliseconds(1200))
        check("Full Take chosen from the focused sidebar list leaves focus in the list", window.firstResponder === list)
        return results
    }

    /// The sidebar in an offscreen main-window layout: its column width, Export Clip…
    /// through a clip row's own context menu, Find Clips' keyboard focus on its first new
    /// suggestion, and below 960 the overlay sidebar with Escape.
    static func sidebarWindow(app: AppModel, project: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        let keys = ["llm.connector", "llm.model.ollama", "llm.clips.snapToLines"]
        let saved = keys.map { app.settings.values[$0] }
        defer { app.connectorOverride = nil; for (key, value) in zip(keys, saved) { app.settings.values[key] = value } }
        let shell = WorkspaceShell(app: app)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1280, height: 800), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: WorkspaceView(shell: shell).environment(app))
        controller.sizingOptions = []
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.orderBack(nil)
        defer { shell.editor?.close(); window.close() }
        try await Task.sleep(for: .milliseconds(200))
        // A real video, so Export Clip… is enabled.
        var exportable = project
        if let root = app.shared?.root { exportable.media.source = try await VoxClipDocument(importing: root.appendingPathComponent("fixtures/media/fillers-chirp.mp4")).project.media.source }
        await shell.attachForTesting(VoxClipDocument(project: exportable, demo: false), selection: .fullTake)
        guard let editor = shell.editor else { throw CocoaError(.coderInvalidValue) }
        try await Task.sleep(for: .milliseconds(400))
        func tables(in view: NSView) -> [NSTableView] {
            if let table = view as? NSTableView { return [table] }
            return view.subviews.flatMap { tables(in: $0) }
        }
        guard let root = window.contentView, let list = tables(in: root).first else {
            check("the sidebar list is in the window", false)
            return results
        }
        check("the sidebar column keeps its ideal width (\(Int(shell.sidebarWidth)) of \(Int(VCTokens.sizeSidebarIdeal)))", abs(shell.sidebarWidth - Double(VCTokens.sizeSidebarIdeal)) < 24)

        // Export Clip… from the row's own context menu, after an earlier export of another
        // clip left its result and error behind.
        let kept = editor.keptClips.map(\.id)
        guard kept.count >= 3 else { throw CocoaError(.coderInvalidValue) }
        shell.selection = .clip(kept[2])
        try await Task.sleep(for: .milliseconds(200))
        let row = list.selectedRow
        shell.selection = .fullTake
        try await Task.sleep(for: .milliseconds(200))
        editor.exportClipIDs = [kept[0]]
        editor.exports = [ExportResult(outputURL: directory.appendingPathComponent("earlier.mp4"), durationSeconds: 1, width: 1080, height: 1920, fps: 30, frames: 30,
                                       audioSampleRate: 48_000, audioSamples: 48_000, videoCodec: "h264", encoder: "fixture", elapsedSeconds: 1)]
        editor.exportError = "An earlier export failed."
        var menu: NSMenu?
        var source = "none"
        if row >= 0 {
            let rect = list.rect(ofRow: row)
            let point = list.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            if let click = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                menu = list.menu(for: click)
                source = "the list"
                var view = window.contentView?.hitTest(point)
                while menu?.items.contains(where: { $0.title == "Export Clip…" }) != true, let current = view {
                    menu = current.menu(for: click)
                    source = String(describing: type(of: current))
                    view = current.superview
                }
            }
        }
        menu?.update()
        let item = menu?.items.first { $0.title == "Export Clip…" }
        // AppKit runs no menu action while an app-modal session runs, so one left open by
        // an earlier check fails this one instead of passing or failing it by chance.
        func texts(_ view: NSView) -> [String] { ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts) }
        let modal = NSApp.modalWindow.map { "\(type(of: $0)) \"\($0.contentView.map(texts)?.joined(separator: " ") ?? $0.title)\"" }
        if let menu, let item, let index = menu.items.firstIndex(of: item) { menu.performActionForItem(at: index) }
        for _ in 0..<40 where !editor.showExport { try await Task.sleep(for: .milliseconds(50)) }
        let exported = editor.exportClipIDs.map { (id: String) -> String in
            guard let index: Int = editor.keptClips.firstIndex(where: { (clip: ClipRange) -> Bool in clip.id == id }) else { return id }
            let number: Int = index + 1
            return "clip \(number)"
        }.joined(separator: ", ")
        check("Export Clip… in a clip row's context menu opens Export for that clip and clears the earlier result (row \(row), menu from \(source), item enabled \(item?.isEnabled == true), modal \(modal ?? "none"), exportable \(editor.mediaExportable), Export shown \(editor.showExport) for \(exported))",
              modal == nil && editor.showExport && editor.exportClipIDs == [kept[2]] && editor.exports.isEmpty && editor.exportError == nil
              && editor.project.edits.activeClipId == nil && shell.selection == .fullTake)
        editor.showExport = false
        try await Task.sleep(for: .milliseconds(300))

        // Find Clips focuses its first new suggestion; the list takes keyboard focus.
        app.settings.values["llm.connector"] = .string("ollama")
        app.settings.values["llm.model.ollama"] = .string("fixture-local")
        app.settings.values["llm.clips.snapToLines"] = .bool(false)
        app.connectorOverride = { _ in FixtureClipConnector(spans: [(20, 70), (95, 145)]) }
        editor.findClips()
        await editor.findTask?.value
        for _ in 0..<40 where window.firstResponder !== list { try await Task.sleep(for: .milliseconds(25)) }
        check("after Find Clips the sidebar list has keyboard focus for the first new suggestion, which stays unselected (first responder \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"))",
              editor.focusedSuggestion != nil && window.firstResponder === list && shell.selection == .fullTake && editor.project.edits.activeClipId == nil)

        // Below 960 the sidebar shows as the overlay, and Escape hides it (design §3.7).
        window.setContentSize(NSSize(width: 900, height: 800))
        for _ in 0..<40 where shell.windowWidth >= WorkspaceShell.sidebarCollapseWidth { try await Task.sleep(for: .milliseconds(25)) }
        app.settings.values["llm.connector"] = nil
        editor.requestFindClips(from: .toolbar)
        try await Task.sleep(for: .milliseconds(400))
        let overlayList = tables(in: root).first { $0 !== list && !$0.isHiddenOrHasHiddenAncestor }
        check("at 900 Find Clips shows the sidebar as the overlay, with its setup callout, while the column stays collapsed",
              shell.windowWidth < WorkspaceShell.sidebarCollapseWidth && shell.sidebarOverlay && shell.columnVisibility == .detailOnly && editor.showAISetup && overlayList != nil)
        window.setContentSize(NSSize(width: 880, height: 800))
        try await Task.sleep(for: .milliseconds(250))
        check("a resize below 960 keeps the overlay", shell.sidebarOverlay && shell.columnVisibility == .detailOnly)
        if let overlayList { window.makeFirstResponder(overlayList) }
        let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        let escape = String(UnicodeScalar(UInt8(27)))
        if let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                      context: nil, characters: escape, charactersIgnoringModifiers: escape, isARepeat: false, keyCode: 53) { window.sendEvent(key) }
        try await Task.sleep(for: .milliseconds(250))
        check("Escape in the overlay sidebar hides it (first responder \(responder))", !shell.sidebarOverlay)
        window.setContentSize(NSSize(width: 1280, height: 800))
        try await Task.sleep(for: .milliseconds(250))
        check("back at 1280 the sidebar column returns and no overlay shows", shell.columnVisibility == .all && !shell.sidebarOverlay)
        return results
    }

    /// A drag of the editor split's divider, posted as events in an offscreen window,
    /// stores the dragged width; showing and hiding the viewer and resizing do not.
    static func dividerDrag(app: AppModel) async -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        let saved = app.settings.values["ui.rightColumnWidth"]
        defer { app.settings.values["ui.rightColumnWidth"] = saved }
        app.settings.values["ui.rightColumnWidth"] = nil
        let shell = WorkspaceShell(app: app)
        shell.toggleViewer(); shell.toggleViewer()
        shell.windowWidth = 1100; shell.windowWidth = 1440
        check("showing, hiding and resizing never store ui.rightColumnWidth", app.settings.values["ui.rightColumnWidth"] == nil)

        let controller = NSSplitViewController()
        let split = EditorSplit()
        controller.splitView = split
        split.isVertical = true
        split.dividerStyle = .thin
        let left = NSViewController(), right = NSViewController()
        left.view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        right.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let leftItem = NSSplitViewItem(viewController: left), rightItem = NSSplitViewItem(viewController: right)
        leftItem.minimumThickness = 300
        rightItem.minimumThickness = 300
        rightItem.maximumThickness = 560
        controller.addSplitViewItem(leftItem)
        controller.addSplitViewItem(rightItem)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1101, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1101, height: 400))
        split.setPosition(700, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        split.onDividerDrag = { shell.rememberRightWidth($0) }
        let start = right.view.frame.width
        let point = split.convert(NSPoint(x: left.view.frame.maxX + split.dividerThickness / 2, y: 200), to: nil)
        func event(_ type: NSEvent.EventType, _ x: Double) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: point.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        guard let down = event(.leftMouseDown, point.x), let drag = event(.leftMouseDragged, point.x + 40), let up = event(.leftMouseUp, point.x + 40) else {
            check("a divider drag stores the dragged width", false)
            return results
        }
        // If the split view never reads the posted events, a late mouse-up ends its loop.
        let windowNumber = window.windowNumber, end = NSPoint(x: point.x + 40, y: point.y)
        let fallback = Timer(timeInterval: 2, repeats: false) { _ in
            MainActor.assumeIsolated {
                if let late = NSEvent.mouseEvent(with: .leftMouseUp, location: end, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) { NSApp.postEvent(late, atStart: true) }
            }
        }
        RunLoop.main.add(fallback, forMode: .common)
        NSApp.postEvent(drag, atStart: false)
        NSApp.postEvent(up, atStart: false)
        split.mouseDown(with: down)
        fallback.invalidate()
        let stored = app.settings.values["ui.rightColumnWidth"]
        let expected = (start - 40).rounded()
        check("a drag of the divider stores the dragged width (\(start) → \(right.view.frame.width))", abs(right.view.frame.width - (start - 40)) < 1.5 && stored == .number(expected))
        window.close()
        return results
    }

    /// The toolbar and edit summary (step 8): the summary grammar and cut count for each
    /// scope, Export's title and reasons, the Find Clips shortcut, and the accent and
    /// selection colours.
    static func editorToolbar(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        let five = try fiveQuestions(from: fixture)
        let shell = WorkspaceShell(app: app)
        await shell.attachForTesting(VoxClipDocument(project: five, demo: true), selection: .fullTake)
        guard let editor = shell.editor else { throw CocoaError(.coderInvalidValue) }
        let kept = editor.keptClips
        let full = editor.summaryLine
        check("the full take reads \"2:10 after cuts · 8 cuts\" (\(full))", editor.cutCount == 8 && full == "2:10 after cuts · 8 cuts" && editor.subtitle == full)
        let detail = editor.summaryDetail
        check("the edit summary's detail reads \"2:23 source · 19 words cut in 5 places · 3 pauses cut\" (\(detail))", detail == "2:23 source · 19 words cut in 5 places · 3 pauses cut")
        check("Export reads Export Video… for the full take and gives the demo reason", editor.exportTitle == "Export Video…" && editor.exportUnavailable == "Demo projects have no video to export.")
        shell.selection = .clip(kept[1].id)
        let second = editor.summaryLine, secondDetail = editor.summaryDetail
        check("a clip reads \"Clip 2 · 0:20 after cuts · 2 cuts\" (\(second))", second == "Clip 2 · 0:20 after cuts · 2 cuts" && editor.exportTitle == "Export Clip…")
        check("a clip's detail reads \"0:21 source · 2 words cut in 2 places · 0 pauses cut\" (\(secondDetail))", secondDetail == "0:21 source · 2 words cut in 2 places · 0 pauses cut")
        shell.selection = .clip(kept[3].id)
        let fourth = editor.summaryLine
        check("a clip with no cuts reads \"Clip 4 · 0:11 · No cuts yet\" (\(fourth))", fourth == "Clip 4 · 0:11 · No cuts yet")
        if let bounds = editor.scopeBounds, bounds.count > 2 {
            let pair = [editor.words[bounds.lowerBound + 1].id, editor.words[bounds.lowerBound + 2].id]
            editor.apply(.cutSelection(ids: pair), name: "Cut selection")
            let one = editor.summaryLine
            editor.apply(.restoreSelection(ids: pair), name: "Restore selection")
            check("two adjacent cut words are one cut: \"Clip 4 · {edited} after cuts · 1 cut\" (\(one))", one.hasPrefix("Clip 4 · ") && one.hasSuffix(" after cuts · 1 cut"))
        } else { check("clip 4 has words to cut", false) }
        shell.selection = .fullTake
        if let pause = editor.pauses.first(where: { !editor.cutPauseIDs.contains($0.id) }) {
            editor.apply(.cutSelection(ids: [pause.id]), name: "Cut selection")
            let withPause = editor.cutCount
            editor.apply(.restoreSelection(ids: [pause.id]), name: "Restore selection")
            check("a cut pause counts as a cut: the full take's eight become nine", withPause == 9 && editor.cutCount == 8)
        } else { check("the full take has a pause to cut", false) }
        editor.close()

        var moved = five
        moved.media.source.absolutePath = directory.appendingPathComponent("moved-away.mp4").path
        moved.media.source.relativePath = nil
        let real = WorkspaceShell(app: app)
        await real.attachForTesting(VoxClipDocument(project: moved, demo: false), selection: .fullTake)
        guard let located = real.editor, let suggestion = located.suggestedClips.first else { throw CocoaError(.coderInvalidValue) }
        check("a missing video disables Export: \"Locate the video to export.\"", !located.mediaResolved && located.exportUnavailable == "Locate the video to export.")
        real.selection = .clip(suggestion.id)
        check("a row change the editor refuses (missing video) returns the selection to Full Take", real.selection == .fullTake && located.project.edits.activeClipId == nil)
        located.mediaResolved = true
        check("with the video found, Export Video… is available", located.exportUnavailable == nil && located.canExport)
        real.selection = .clip(suggestion.id)
        check("a selected suggestion disables Export: \"Keep this clip to export it.\"", located.exportUnavailable == "Keep this clip to export it.")
        real.selection = .fullTake
        located.mediaUnreadable = true
        check("an unreadable video disables Export: \"Locate the video to export.\"", located.exportUnavailable == "Locate the video to export." && located.mediaStatus == .unreadable)
        located.close()

        let find = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.title == "Find Clips…" }
        check("Find Clips… is ⇧⌘K", find?.keyEquivalent == "k" && find?.keyEquivalentModifierMask == [.command, .shift])
        guard let light = NSAppearance(named: .aqua), let dark = NSAppearance(named: .darkAqua) else { throw CocoaError(.coderInvalidValue) }
        check("a DEBUG build without the asset keeps VoxClip's Petrol accent", DesignValues.ownsAccent(light) && DesignValues.ownsAccent(dark))
        var readable = true
        for appearance in [light, dark] {
            for accent in [NSColor.systemYellow, .systemBlue, .systemPink, .systemGray, .systemGreen] {
                let mixed = DesignValues.readable(accent, toward: DesignValues.nsColor("text.primary"), on: DesignValues.nsColor("bg.surface"), in: appearance)
                appearance.performAsCurrentDrawingAppearance { if DesignValues.contrast(mixed, DesignValues.nsColor("bg.surface")) < 4.5 { readable = false } }
            }
        }
        check("a system accent's text colour mixes toward text.primary until it reads at 4.5:1 on bg.surface", readable)
        var selection = false
        for appearance in [light, dark] {
            appearance.performAsCurrentDrawingAppearance {
                guard let drawn = (TranscriptNSTextView.selectionAttributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB),
                      let primary = DesignValues.nsColor("text.primary").usingColorSpace(.sRGB) else { selection = false; return }
                selection = abs(drawn.redComponent - primary.redComponent) < 0.01 && abs(drawn.greenComponent - primary.greenComponent) < 0.01 && abs(drawn.blueComponent - primary.blueComponent) < 0.01
            }
            if !selection { break }
        }
        check("selected transcript words draw in text.primary on the platform selection", selection)
        return results
    }

    /// The editor detail (step 7): the right column's width and collapse rule, the
    /// transcript measure, and captures at 1440, 1280 and 1024 wide.
    static func editorLayout(app: AppModel, shell: WorkspaceShell, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        check("the right column starts at 360 at 1440 and 320 at 1280, within 300-560", WorkspaceShell.rightColumnWidth(windowWidth: 1440) == 360
              && WorkspaceShell.rightColumnWidth(windowWidth: 1280) == 320 && WorkspaceShell.rightColumnWidth(windowWidth: 1024) == 300 && WorkspaceShell.rightColumnWidth(windowWidth: 2400) == 560)
        check("the transcript measure is 680 at 1440, about 580 at 1280, 480 at the 596 minimum and never wider than the pane after its gutter",
              TranscriptNSTextView.measure(forPane: 1440 - 252 - 360) == 680 && abs(TranscriptNSTextView.measure(forPane: 1280 - 252 - 320) - 592) < 1
              && TranscriptNSTextView.measure(forPane: 596) == 480 && TranscriptNSTextView.measure(forPane: 500) == 416)
        let rule = WorkspaceShell(app: app)
        rule.windowWidth = 1440
        check("at 1440 the viewer shows beside the sidebar", rule.viewerVisible && rule.columnVisibility == .all)
        rule.windowWidth = 1024
        check("below a 596 transcript pane the viewer collapses first", !rule.viewerVisible && rule.columnVisibility == .all)
        rule.windowWidth = 1440
        check("widening the window brings an automatically hidden viewer back", rule.viewerVisible)
        rule.windowWidth = 1024
        rule.toggleViewer()
        check("Show Viewer at 1024 hides the sidebar to make room", rule.viewerVisible && rule.columnVisibility == .detailOnly)
        rule.toggleViewer()
        check("Hide Viewer again restores the sidebar", !rule.viewerVisible && rule.columnVisibility == .all)
        rule.windowWidth = 900
        check("below 960 the sidebar collapses", rule.columnVisibility == .detailOnly)
        rule.revealSidebar()
        check("at 900 a revealed sidebar shows as the overlay and the column stays collapsed", rule.sidebarOverlay && rule.columnVisibility == .detailOnly)
        rule.windowWidth = 899
        check("the width rule keeps the overlay on a resize below 960", rule.sidebarOverlay && rule.columnVisibility == .detailOnly)
        rule.choose(.home, byClick: false)
        check("the arrow keys keep the overlay open", rule.sidebarOverlay)
        rule.choose(.home, byClick: true)
        check("a click on a row hides the overlay", !rule.sidebarOverlay)
        rule.columnVisibility = .all
        check("below 960 the toolbar's sidebar button shows the overlay, not the column", rule.sidebarOverlay && rule.columnVisibility == .detailOnly)
        rule.toggleSidebar()
        check("View > Hide Sidebar hides the overlay", !rule.sidebarOverlay && !rule.sidebarShown)
        rule.revealSidebar()
        rule.windowWidth = 1100
        check("at 960 and wider the sidebar collapsed by width comes back", rule.columnVisibility == .all && !rule.sidebarOverlay)
        rule.sidebarWidth = 320
        rule.windowWidth = 1180
        check("the narrow rule measures the dragged sidebar: at 1180 with a 320 sidebar the viewer collapses", !rule.viewerVisible)
        rule.sidebarWidth = Double(VCTokens.sizeSidebarIdeal)
        let savedWidth = app.settings.values["ui.rightColumnWidth"]
        rule.windowWidth = 1440
        rule.rememberRightWidth(420.4)
        let remembered = rule.rightWidth, reopened = WorkspaceShell(app: app).rightWidth
        rule.rememberRightWidth(900)
        let clamped = rule.rightWidth
        app.settings.values["ui.rightColumnWidth"] = savedWidth
        check("a dragged right column width is kept in ui.rightColumnWidth for every project, within 300-560", remembered == 420 && reopened == 420 && clamped == 560)

        for (width, height) in [(1440.0, 900.0), (1280, 800), (1024, 700)] {
            // The window has its width before a project opens in it.
            shell.windowWidth = width
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                try await DebugUISuite.snapshot(WorkspaceView(shell: shell).environment(app), name: "editor-\(Int(width))-\(suffix)", size: NSSize(width: width, height: height), appearance: appearance, directory: directory, active: true, mainWindow: true)
            }
            if width == 1024 { check("the 1024 editor collapses the viewer and shows the compact transport", !shell.viewerVisible) }
        }
        shell.windowWidth = 1440
        return results
    }

    /// Find Clips (step 6): a run lands as suggestions in one undo step, "nothing
    /// matched" and "no connector" show in the sidebar, and the popover's layout.
    static func findClips(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        func capture(_ shell: WorkspaceShell, _ name: String) async throws {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                try await DebugUISuite.snapshot(SidebarRowsPreview(shell: shell).environment(app), name: "\(name)-\(suffix)", size: NSSize(width: 252, height: 520), appearance: appearance, directory: directory, active: true)
            }
        }
        let keys = ["llm.connector", "llm.model.ollama", "llm.clips.snapToLines"]
        let saved = keys.map { app.settings.values[$0] }
        defer { app.connectorOverride = nil; for (key, value) in zip(keys, saved) { app.settings.values[key] = value } }
        var bare = try fiveQuestions(from: fixture)
        bare.edits.clips = []
        let shell = WorkspaceShell(app: app)
        await shell.attachForTesting(VoxClipDocument(project: bare, demo: true), selection: .fullTake)
        guard let model = shell.editor else { throw CocoaError(.coderInvalidValue) }
        defer { model.close() }
        try await capture(shell, "sidebar-no-clips")

        app.settings.values["llm.connector"] = nil
        shell.columnVisibility = .detailOnly
        model.requestFindClips(from: .toolbar)
        check("with no connector, Find Clips shows the hidden sidebar and its setup callout instead of the popover", model.showAISetup && !model.showFindClips && shell.columnVisibility == .all)
        try await capture(shell, "sidebar-no-connector")

        app.settings.values["llm.connector"] = .string("ollama")
        app.settings.values["llm.model.ollama"] = .string("fixture-local")
        app.settings.values["llm.clips.snapToLines"] = .bool(false)
        model.requestFindClips(from: .sidebar)
        check("with a connector, Find Clips opens the popover at the sidebar action", model.showFindClips && model.findClipsAnchor == .sidebar && !model.showAISetup)
        model.showFindClips = false
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await DebugUISuite.snapshot(FindClipsPopover(model: model).environment(app), name: "find-clips-popover-\(suffix)", size: NSSize(width: 340, height: 300), appearance: appearance, directory: directory, active: true)
        }

        app.connectorOverride = { _ in FixtureClipConnector(spans: [(20, 70), (95, 145), (170, 220)]) }
        shell.columnVisibility = .detailOnly
        let steps = model.undoSteps
        let playhead = model.playhead, exportTitle = model.exportTitle, subtitle = model.subtitle
        model.findClips()
        let revealed = shell.columnVisibility == .all
        await model.findTask?.value
        check("Find Clips adds three suggestions and keeps none", model.suggestedClips.count == 3 && model.keptClips.isEmpty && model.project.ai.results.count == 1 && model.clipError == nil)
        check("a run shows the hidden sidebar for its progress", revealed)
        let first = model.suggestedClips.first?.id
        check("Find Clips focuses its first new suggestion without selecting it, in one undo step: the scope, playhead, Export and subtitle stay",
              first != nil && model.focusedSuggestion == first && model.project.edits.activeClipId == nil && shell.selection == .fullTake
              && model.playhead == playhead && model.exportTitle == exportTitle && model.subtitle == subtitle && model.undoSteps == steps + 1)
        model.undoManager?.undo()
        check("one undo removes the three suggestions and their AI result", model.suggestedClips.isEmpty && model.project.ai.results.isEmpty && shell.selection == .fullTake)
        model.undoManager?.redo()
        check("redo brings the suggestions back", model.suggestedClips.count == 3 && model.project.ai.results.count == 1)
        model.keepAll()
        model.undoManager?.undo()
        check("Keep All then undo restores all three suggestions", model.suggestedClips.count == 3 && model.keptClips.isEmpty)

        model.finding = true
        try await capture(shell, "sidebar-finding")
        model.finding = false
        app.connectorOverride = { _ in FixtureClipConnector(spans: []) }
        model.findClips()
        await model.findTask?.value
        check("a run with no clips shows the no-match message under Suggested", model.clipError == EditorModel.noClipsMatched && model.suggestedClips.count == 3)
        try await capture(shell, "sidebar-no-match")

        // Return keeps the focused suggestion and ⌫ dismisses it; focus moves to the next
        // suggestion and the selection stays (design §6.2).
        let rows = model.suggestedClips.map(\.id)
        model.focusedSuggestion = rows.first
        try await capture(shell, "sidebar-focused-suggestion")
        model.actOnFocusedSuggestion(keep: true)
        let keptFocused = model.keptClips.contains { $0.id == rows[0] } && model.focusedSuggestion == rows[1]
        model.actOnFocusedSuggestion(keep: false)
        check("Return keeps the focused suggestion and ⌫ dismisses the next; focus moves on and the selection stays",
              keptFocused && !model.isSuggestion(rows[1]) && model.focusedSuggestion == rows[2] && shell.selection == .fullTake && model.project.edits.activeClipId == nil)

        // A fallback model's answer says so under Suggested, announced once (ai.md §4.3).
        let fallbackShell = WorkspaceShell(app: app)
        await fallbackShell.attachForTesting(VoxClipDocument(project: bare, demo: true), selection: .fullTake)
        guard let fallback = fallbackShell.editor else { throw CocoaError(.coderInvalidValue) }
        defer { fallback.close() }
        app.connectorOverride = { _ in FixtureClipConnector(spans: [(20, 70), (95, 145), (170, 220)], answeringModel: "fixture-fallback") }
        fallback.findClips()
        await fallback.findTask?.value
        let note = "Answered by fixture-fallback because fixture-local was busy."
        check("a fallback model's answer shows \"\(note)\" under Suggested, announced once (\(fallback.lastAnnouncement ?? fallback.clipError ?? "nothing"))",
              fallback.fallbackNote == note && fallback.suggestedClips.count == 3 && fallback.announcements.filter { $0.contains(note) }.count == 1)
        try await capture(fallbackShell, "sidebar-fallback-note")
        return results
    }

    /// The transcript and clips of `mac/editor-dark.png`, on synthetic word timings:
    /// four kept clips, one AI suggestion, the mockup's cut fillers and its cut sentence.
    static func fiveQuestions(from base: Project) throws -> Project {
        let paragraphs = [
            "So, um, here's the thing nobody tells you about posting every day.",
            "You don't have to film every day. I film once a week, one afternoon, and that single take turns into seven or eight short clips.",
            "The trick is to stop thinking in videos and start thinking in sentences. Every good clip is one idea, said cleanly, with a clear start and a clear end. If you can't say where it starts, it isn't a clip yet.",
            "I write five questions on a card, the kind people ask me in the comments, and I answer each one out loud like I'm talking to a friend. No script. The script is what makes it sound like a script.",
            "Here's the part that matters most. Your first sentence has to work on mute. Most people, um, scroll with the sound off, so if someone only reads the caption, do they want the second sentence? If not, you, uh, keep cutting until they do. Usually that means the first ten words go.",
            "And yeah, I, I, um, I mess up a lot. That's fine. I pause, take a breath and say the line again. Then I cut the bad take, which, uh, which is the worst part. Then I cut the bad take in the transcript. It takes seconds, because I'm deleting words, not hunting through a waveform.",
            "The best thirty seconds of your week are already on your phone. Post those. One habit for a bad week: film anyway, and keep only the sentence that still sounds true."
        ]
        // Each paragraph's pace makes the summaries read the checklist's acceptance values
        // (step 8): "2:10 after cuts · 8 cuts", "Clip 2 · 0:20 after cuts · 2 cuts" and
        // "Clip 4 · 0:11 · No cuts yet". Gaps stay under the pause threshold inside a paragraph.
        let paces = [1.33, 1.33, 1.33, 1.33, 0.92, 1.33, 2.14]
        var words: [TimedWord] = []
        var time = 0.4
        for (paragraph, pace) in zip(paragraphs, paces) {
            for token in paragraph.split(separator: " ") {
                let text = String(token), length = pace * (0.16 + 0.035 * Double(text.count))
                words.append(TimedWord(id: "w\(words.count + 1)", text: text, start: time, end: time + length))
                time += length + (".?!".contains(text.last ?? " ") ? 0.55 : 0.07)
            }
            time += 1.1
        }
        func find(_ phrase: String, after start: Int = 0) throws -> Int {
            let tokens = phrase.split(separator: " ").map(String.init)
            guard let index = (start..<max(start, words.count - tokens.count + 1)).first(where: { index in tokens.indices.allSatisfy { words[index + $0].text == tokens[$0] } }) else {
                throw CocoaError(.coderInvalidValue)
            }
            return index
        }
        func clip(_ id: String, _ title: String, from first: String, through last: String, suggested: Bool = false) throws -> ClipRange {
            let start = try find(first), end = try find(last, after: start) + last.split(separator: " ").count - 1
            return ClipRange(id: id, startWordId: words[start].id, endWordId: words[end].id, title: title, origin: suggested ? .ai : .manual, selected: !suggested)
        }
        let retake = try find("Then I cut the bad take, which,")
        var cut = [try find("um, here's"), try find("um, scroll"), try find("uh, keep")].map { words[$0].id }
        cut += try (find("I, I, um,")..<(find("I, I, um,") + 3)).map { words[$0].id }
        cut += (retake..<(retake + 13)).map { words[$0].id }

        var project = base
        project.id = "five-questions"
        project.title = "Five questions"
        project.transcript?.words = words
        project.transcript?.durationSeconds = time
        project.media.source.durationSeconds = time
        project.captions.styleId = "box-highlight"
        project.edits.cutWordIds = cut
        // Eight cuts: the five word runs and the pauses after the first three paragraphs.
        project.edits.cutPauseIds = try detectPauses(words, thresholdSeconds: project.edits.pauseThresholdSeconds).prefix(3).map(\.id)
        project.edits.corrections = [:]
        project.edits.activeClipId = nil
        project.edits.clips = [
            try clip("five-1", "Think in sentences", from: "The trick is", through: "a clip yet."),
            try clip("five-2", "It has to work on mute", from: "Here's the part", through: "ten words go."),
            try clip("five-3", "And yeah, I mess up a lot", from: "And yeah,", through: "a waveform."),
            try clip("five-4", "The best thirty seconds", from: "The best thirty", through: "Post those."),
            try clip("five-5", "One habit for a bad week", from: "One habit for", through: "sounds true.", suggested: true)
        ]
        return project
    }
}

/// A connector that answers Find Clips with the given word spans. With an answering
/// model it reports another model's answer, as a fallback does (ai.md §4.3).
actor FixtureClipConnector: LLMConnector {
    nonisolated let id: ConnectorID
    let spans: [(Int, Int)]
    let answeringModel: String?
    init(spans: [(Int, Int)], answeringModel: String? = nil) {
        self.spans = spans
        self.answeringModel = answeringModel
        id = answeringModel == nil ? .ollama : .anthropic
    }
    func status() -> ConnectorStatus { .ready }
    func models(refresh: Bool) -> [LLMModel] { [LLMModel(id: "fixture-local", name: "Fixture", contextTokens: 128000, source: .curated)] }
    func contextTokens(model: String) -> Int? { 128000 }
    func send(_ request: LLMRequest, model: String) -> RawCompletion {
        let clips = spans.enumerated().map { "{\"title\":\"Suggestion \($0.offset + 1)\",\"reason\":\"One idea, cleanly said\",\"score\":\(8 - $0.offset),\"start_word\":\($0.element.0),\"end_word\":\($0.element.1)}" }
        return RawCompletion(text: "{\"clips\":[\(clips.joined(separator: ","))]}", model: answeringModel ?? model, stop: .complete)
    }
}
#endif
