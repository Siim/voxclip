#if DEBUG
import AppKit
import VoxClipCore

/// Checks run by hand from a bundle.sh build with the screen unlocked. They launch like a
/// user's app, not as a harness session, so the main window keeps its restorable state.
///
/// Every value follows its flag, or AppKit opens a loose path argument as a document.
///
/// - `-recoveryProbe prepare -probeFolder <folder> -probeMovie <movie>` imports the movie,
///   gives it a transcript, cuts words, waits for AppKit's own autosave and then for the
///   window's restorable state. The caller kills the app with `kill -9`.
/// - `-recoveryProbe verify -probeFolder <folder>` is the relaunch: the never-saved project
///   must come back in the main window with its cuts (design §2).
/// - `-accentProbe <folder>` captures the sidebar's Home row and glyph in light and dark,
///   focused, unfocused and in an inactive window, and reports their colours (lead note 3a).
@MainActor enum DebugProbes {
    static var requested: Bool { CommandLine.arguments.contains("-recoveryProbe") || CommandLine.arguments.contains("-accentProbe") }
    /// Which launch path reopened a project: the main window's restorable state, or
    /// AppKit asking a document for its windows.
    static var reopenedBy: [String] = []
    /// The probe's folder, for traces written while AppKit encodes or restores state.
    static var folder: URL?
    static func trace(_ line: String) {
        guard let folder else { return }
        let file = folder.appendingPathComponent("restoration-trace.txt")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try? (text + "\(Date().formatted(date: .omitted, time: .standard)) \(line)\n").write(to: file, atomically: true, encoding: .utf8)
    }

    static func run(app: AppModel) async {
        let arguments = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let index: Int = arguments.firstIndex(of: flag) else { return nil }
            let next: Int = index + 1
            return next < arguments.count ? arguments[next] : nil
        }
        await app.start()
        folder = value("-probeFolder").map { URL(fileURLWithPath: $0) }
        if let phase = value("-recoveryProbe"), let folder {
            if phase == "prepare", let movie = value("-probeMovie") { await prepareRecovery(app: app, folder: folder, movie: URL(fileURLWithPath: movie)) }
            else if phase == "verify" { await verifyRecovery(app: app, folder: folder) }
        } else if let folder = value("-accentProbe") {
            await accent(app: app, folder: URL(fileURLWithPath: folder))
        }
    }

    private struct Marker: Codable {
        let projectID: String
        let title: String
        let cutWordIds: [String]
        let autosave: String
        let note: String
    }
    private struct Check: Codable {
        let name: String
        let passed: Bool
    }

    private static func write<Value: Encodable>(_ value: Value, _ name: String, in folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(value).write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    private static func prepareRecovery(app: AppModel, folder: URL, movie: URL) async {
        let shell = app.shell
        func fail(_ reason: String) { write(["error": reason], "recovery-marker.json", in: folder) }
        await shell.importVideo(movie)
        await shell.started?.value
        guard let document = shell.document, let editor = shell.editor, let root = app.shared?.root else { fail("import failed: \(shell.notice ?? "no notice")"); return }
        // The transcript arrives as the scene audit gives one, then three words are cut.
        guard let transcript = try? DemoEditing.loadFixture(root.appendingPathComponent("fixtures/projects/interview-take.voxclip")).transcript else { fail("no transcript fixture"); return }
        var transcribed = document.project
        transcribed.transcript = transcript
        document.replaceProject(transcribed)
        editor.refresh()
        let ids = editor.words.prefix(3).map(\.id)
        editor.apply(.cutSelection(ids: ids), name: "Cut selection")
        // AppKit's own autosave of the untitled project; nothing asks for it early.
        var autosave: URL?
        for _ in 0..<1800 {
            if let url = document.autosavedContentsFileURL, let data = try? Data(contentsOf: url), let saved = try? JSONProjectStore.decode(data),
               Set(ids).isSubset(of: saved.edits.cutWordIds) { autosave = url; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let autosave else { fail("no autosave with the cuts within 180 s"); return }
        // The restorable state is written after the autosave invalidates it.
        try? await Task.sleep(for: .seconds(6))
        let window = shell.windowController?.window
        write(Marker(projectID: document.project.id, title: shell.projectTitle, cutWordIds: ids, autosave: autosave.path,
                     note: "autosaved by AppKit; window restorable \(window?.isRestorable == true), restoration class \(window?.restorationClass.map { String(describing: $0) } ?? "none")"),
              "recovery-marker.json", in: folder)
    }

    private static func verifyRecovery(app: AppModel, folder: URL) async {
        let shell = app.shell
        let marker = (try? Data(contentsOf: folder.appendingPathComponent("recovery-marker.json"))).flatMap { try? JSONDecoder().decode(Marker.self, from: $0) }
        for _ in 0..<300 where shell.document == nil { try? await Task.sleep(for: .milliseconds(100)) }
        await shell.started?.value
        try? await Task.sleep(for: .milliseconds(500))
        let document = shell.document
        let window = shell.windowController?.window
        var checks = [
            Check(name: "the relaunch after kill -9 reopens the never-saved project in the main window", passed: document != nil && window?.isVisible == true && document?.windowControllers.first === shell.windowController),
            Check(name: "it is the same project, still untitled, read from its autosave", passed: marker != nil && document?.project.id == marker?.projectID && document?.fileURL == nil
                  && document?.autosavedContentsFileURL?.standardizedFileURL.path == marker.map { URL(fileURLWithPath: $0.autosave).standardizedFileURL.path }),
            Check(name: "the cuts made before the kill are back", passed: marker.map { Set($0.cutWordIds).isSubset(of: document?.project.edits.cutWordIds ?? []) } ?? false),
            Check(name: "it is still an edited document, so a normal quit asks to keep or delete it", passed: document?.isDocumentEdited == true && window?.isDocumentEdited == true),
            Check(name: "the window shows its editor, titled with the movie's name", passed: !shell.showsHome && window?.title == marker?.title),
        ]
        checks.append(Check(name: "only one main window and one document", passed: NSDocumentController.shared.documents.count == 1
                            && NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }.count == 1))
        checks.append(Check(name: "reopened by: \(reopenedBy.isEmpty ? "nothing traced" : reopenedBy.joined(separator: "; "))", passed: !reopenedBy.isEmpty))
        write(checks, "recovery-results.json", in: folder)
        // A normal quit still asks to keep or delete the never-saved project. Quit runs a
        // modal loop until the review ends, so a timer answers the prompt with Cancel.
        let answer = Timer(timeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard quitPrompt == nil, let prompt = NSApp.windows.first(where: { ($0.isSheet || $0 is NSSavePanel) && $0.isVisible }) ?? NSApp.modalWindow else { return }
                quitPrompt = "\(type(of: prompt)) \"\(prompt.title)\""
                quitName = (prompt as? NSSavePanel)?.nameFieldStringValue
                // The keep/delete prompt is a save panel drawn by another process.
                if let panel = prompt as? NSSavePanel { panel.cancel(nil) }
                else if let cancel = button(titled: "Cancel", in: prompt.contentView) { cancel.performClick(nil) }
            }
        }
        RunLoop.main.add(answer, forMode: .common)
        NSApp.terminate(nil)
        answer.invalidate()
        checks.append(Check(name: "a normal quit still asks to keep or delete it, and Cancel keeps it open (\(quitPrompt ?? "no prompt"))", passed: quitPrompt != nil && shell.document === document))
        checks.append(Check(name: "the prompt names the project after the movie, never Untitled (\(quitName ?? "no name"))",
                            passed: marker.map { quitName?.hasPrefix($0.title) == true } ?? false))
        write(checks, "recovery-results.json", in: folder)
        // The probe's autosave goes, and its document closes without the keep/delete prompt.
        if let url = document?.autosavedContentsFileURL { try? FileManager.default.removeItem(at: url) }
        document?.close()
        exit(checks.allSatisfy(\.passed) ? 0 : 1)
    }

    private static var quitPrompt: String?
    private static var quitName: String?
    private static func button(titled title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { button(titled: title, in: $0) }.first
    }

    private static func accent(app: AppModel, folder: URL) async {
        let shell = app.shell
        guard let window = shell.windowController?.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(1.5))
        shell.selection = .home
        var rows: [[String: String]] = []
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(1))
            guard let table = firstTable(in: window.contentView) else { rows.append(["capture": name, "error": "no sidebar list"]); continue }
            // The focused selection: the list is the first responder in the key window.
            window.makeFirstResponder(table)
            try? await Task.sleep(for: .milliseconds(700))
            rows.append(measure(window, table, name: "\(name)-focused", folder: folder, appearance: appearance))
            // The unfocused selection: the key window's focus is elsewhere.
            window.makeFirstResponder(nil)
            try? await Task.sleep(for: .milliseconds(700))
            rows.append(measure(window, table, name: "\(name)-unfocused", folder: folder, appearance: appearance))
            // An inactive window: another window is key.
            let other = NSWindow(contentRect: NSRect(x: window.frame.maxX - 260, y: window.frame.minY + 60, width: 220, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            other.title = "Accent probe"
            other.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(900))
            rows.append(measure(window, table, name: "\(name)-inactive", folder: folder, appearance: appearance))
            other.close()
        }
        NSApp.appearance = nil
        write(rows, "accent-results.json", in: folder)
        exit(0)
    }

    private static func firstTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { firstTable(in: $0) }.first
    }

    /// The Home row's selection fill (right of its label) and its glyph (the pixel in the
    /// row's first 44 points that differs most from that fill), as the window server drew
    /// them, with AppKit's resolved accent colours.
    private static func measure(_ window: NSWindow, _ table: NSTableView, name: String, folder: URL, appearance: NSAppearance.Name) -> [String: String] {
        let file = folder.appendingPathComponent("accent-\(name).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        guard (try? process.run()) != nil else { return ["capture": name, "error": "screencapture did not start"] }
        process.waitUntilExit()
        guard let data = try? Data(contentsOf: file), let image = NSBitmapImageRep(data: data) else { return ["capture": name, "error": "no image"] }
        let scale = Double(image.pixelsWide) / window.frame.width
        let row = table.convert(table.rect(ofRow: 0), to: nil)
        func pixel(_ x: Double, _ y: Double) -> NSColor? {
            image.colorAt(x: Int(x * scale), y: Int((window.frame.height - y) * scale))?.usingColorSpace(.sRGB)
        }
        let fill = pixel(row.maxX - 14, row.midY)
        var glyph: NSColor?
        var farthest = 0.0
        if let fill {
            for x in stride(from: row.minX + 2, to: row.minX + 44, by: 0.5) {
                for y in stride(from: row.minY + 3, to: row.maxY - 3, by: 0.5) {
                    guard let color = pixel(x, y) else { continue }
                    let distance = abs(color.redComponent - fill.redComponent) + abs(color.greenComponent - fill.greenComponent) + abs(color.blueComponent - fill.blueComponent)
                    if distance > farthest { farthest = distance; glyph = color }
                }
            }
        }
        var accent = "", selected = "", unemphasized = ""
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            accent = hex(NSColor.controlAccentColor)
            selected = hex(NSColor.selectedContentBackgroundColor)
            unemphasized = hex(NSColor.unemphasizedSelectedContentBackgroundColor)
        }
        return ["capture": name, "selectionFill": hex(fill), "glyph": hex(glyph), "controlAccentColor": accent, "selectedContentBackgroundColor": selected,
                "unemphasizedSelectedContentBackgroundColor": unemphasized, "petrol": appearance == .aqua ? "#1C6B69" : "#237D7A",
                "firstResponder": window.firstResponder.map { String(describing: type(of: $0)) } ?? "none", "key": String(window.isKeyWindow)]
    }

    private static func hex(_ color: NSColor?) -> String {
        guard let color = color?.usingColorSpace(.sRGB) else { return "none" }
        func channel(_ component: CGFloat) -> Int {
            let scaled: CGFloat = component * 255
            return Int(scaled.rounded())
        }
        let red: Int = channel(color.redComponent)
        let green: Int = channel(color.greenComponent)
        let blue: Int = channel(color.blueComponent)
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
#endif
