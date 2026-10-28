#if DEBUG
import AppKit
import SwiftUI
import VoxClipCore
import VoxClipMedia

@MainActor enum DebugRedesignScenes {
    static let names = ["live-home", "live-home-empty", "live-dragover", "live-editor-full", "live-editor-clip",
                        "live-editor-1280-blue", "live-compact", "live-selection-bar", "live-suggested", "live-finding",
                        "live-export-clip", "live-rewrite"]
    static func checks(app: AppModel) throws -> [DebugUISuite.Result] {
        guard let root = app.shared?.root else { throw VoxClipError.sharedResourcesMissing }
        let project = try DemoEditing.loadFixture(root.appendingPathComponent("fixtures/projects/five-questions.voxclip"))
        let expected: Set<String> = ["live-home", "live-home-empty", "live-dragover", "live-editor-full", "live-editor-clip", "live-editor-1280-blue", "live-compact", "live-selection-bar", "live-suggested", "live-finding", "live-export-clip", "live-rewrite"]
        return [
            .init(name: "step 18 scene set contains every required name once", passed: Set(names) == expected && names.count == expected.count),
            .init(name: "Five questions has four kept clips and one suggestion", passed: project.edits.clips.filter(\.selected).count == 4 && project.edits.clips.filter { !$0.selected && $0.origin == .ai }.count == 1),
            .init(name: "Five questions has eight cuts and four source fillers", passed: project.edits.cutWordIds.count == 8 && project.transcript?.words.filter { (try? isFillerText($0.text)) == true }.count == 4)
        ]
    }
    static func capture(app: AppModel, directory: URL) async throws -> [DebugUISuite.Result] {
        guard !DebugUISuite.sessionLocked else { throw CocoaError(.userCancelled) }
        guard let root = app.shared?.root else { throw VoxClipError.sharedResourcesMissing }
        let url = root.appendingPathComponent("fixtures/projects/five-questions.voxclip")
        let project = try DemoEditing.loadFixture(url)
        let savedSettings = app.settings, savedRecent = app.recent, savedOverride = app.connectorOverride
        defer { app.settings = savedSettings; app.recent = savedRecent; app.connectorOverride = savedOverride }
        let fake = ConsentFixtureConnector(id: .ollama)
        app.connectorOverride = { _ in fake }
        app.set("llm.connector", .string("ollama")); app.set("llm.model.ollama", .string("fixture-local"))
        app.set("voiceLab.enabled", .bool(true))
        app.recent = [url]; app.recentProjects.refresh([url])
        let shell = WorkspaceShell(app: app)
        var results: [DebugUISuite.Result] = []
        func scene(_ name: String, size: NSSize = NSSize(width: 1440, height: 900), appearance: NSAppearance.Name = .darkAqua,
                   prepare: (@MainActor (NSWindow) async throws -> NSWindow?)? = nil) async throws {
            guard !DebugUISuite.sessionLocked else { throw CocoaError(.userCancelled) }
            try await DebugUISuite.snapshot(WorkspaceView(shell: shell).environment(app), name: name, size: size,
                appearance: appearance, directory: directory, active: true, mainWindow: true, native: true, beforeCapture: prepare)
            results.append(.init(name: "native scene \(name)", passed: true))
        }
        try await scene("live-home")
        app.recent = []
        try await scene("live-home-empty", appearance: .aqua)
        app.recent = [url]; shell.dropTargeted = true
        try await scene("live-dragover")
        shell.dropTargeted = false
        await shell.attachForTesting(VoxClipDocument(project: project, demo: true))
        guard let editor = shell.editor else { throw CocoaError(.coderInvalidValue) }
        defer { editor.close() }
        editor.mediaResolved = true; editor.refresh()
        editor.waveform = WaveformData(fine: Array(repeating: 0.01, count: 300_000))
        try await scene("live-editor-full")
        guard editor.keptClips.count == 4, let second = editor.keptClips.dropFirst().first else { throw CocoaError(.coderInvalidValue) }
        shell.selection = .clip(second.id); editor.setAspect(.portrait)
        try await scene("live-editor-clip", appearance: .aqua)
        shell.selection = .fullTake; editor.setAspect(.landscape)
        if Bundle.main.bundleURL.pathExtension == "app" && UserDefaults.standard.integer(forKey: "AppleAccentColor") == 4 {
            try await scene("live-editor-1280-blue", size: NSSize(width: 1280, height: 800), appearance: .aqua)
        } else {
            results.append(.init(name: "native scene live-editor-1280-blue", passed: false,
                skipped: "Owed: launch a bundled app with the blue system accent (-AppleAccentColor 4)."))
        }
        try await scene("live-compact", size: NSSize(width: 1024, height: 700))
        let selected = Array(editor.words[12...15])
        editor.selectedWordIDs = Set(selected.map(\.id))
        try await scene("live-selection-bar") { window in
            editor.window = window
            guard let text = transcript(in: window.contentView) else { throw CocoaError(.coderInvalidValue) }
            text.selectedRanges = selected.compactMap { word in text.map.span(id: word.id).map { NSValue(range: $0.range) } }
            text.showSelectionBar(focus: !EditorAccessibilityPolicy.reducedEffectsAudit)
            guard text.selectionBarVisible else { throw CocoaError(.coderInvalidValue) }
            if EditorAccessibilityPolicy.reducedEffectsAudit {
                try await reducedEffects(window: window, text: text, directory: directory)
            }
            return nil
        }
        editor.selectedWordIDs = []
        if let suggested = editor.suggestedClips.first { shell.selection = .clip(suggested.id) }
        try await scene("live-suggested")
        shell.selection = .fullTake; editor.finding = true
        try await scene("live-finding")
        editor.finding = false; shell.selection = .clip(second.id)
        try await scene("live-export-clip", appearance: .aqua) { window in
            editor.window = window
            guard !editor.mediaExportable else { throw CocoaError(.coderInvalidValue) }
            editor.exportClipIDs = [second.id]
            editor.showExport = true
            await DebugConnectorRequests.wait { window.attachedSheet != nil }
            guard let sheet = window.attachedSheet else { throw VoxClipError.exportFailed("The staged export sheet did not appear.") }
            return sheet
        }
        editor.showExport = false
        shell.selection = .fullTake
        editor.selectedWordIDs = Set(editor.words[12...15].map(\.id))
        editor.beginRewrite()
        await DebugConnectorRequests.wait { editor.rewrite != nil }
        guard let session = editor.rewrite else { throw CocoaError(.coderInvalidValue) }
        session.setInstruction("Make this clearer")
        await session.detectConnector(); await session.prepare()
        if let quote = session.quote { session.markEstimateShown(quote.id) }
        try await scene("live-rewrite")
        editor.closeRewrite(returnFocus: false)
        try ProjectJSON.encoder().encode(results).write(to: directory.appendingPathComponent("redesign-scenes.json"), options: .atomic)
        return results
    }
    private static func transcript(in view: NSView?) -> TranscriptNSTextView? {
        guard let view else { return nil }
        if let text = view as? TranscriptNSTextView { return text }
        return view.subviews.lazy.compactMap { transcript(in: $0) }.first
    }
    private struct ReducedEffectsResult: Encodable {
        let reduceMotion: Bool
        let reduceTransparency: Bool
        let opaqueBackgroundPixels: Int
        let differingPixels: Int
        let frameIntervalSeconds: Double
        let width: Int
        let height: Int
        let appearance: String
        let expectedBackgroundRGB: [Double]
        let sampledBackgroundRGB: [Double]
        let immediateAlpha: Double
    }
    private static func reducedEffects(window: NSWindow, text: TranscriptNSTextView, directory: URL) async throws {
        guard let bar = text.selectionBarAuditView else { throw CocoaError(.coderInvalidValue) }
        let immediateAlpha: Double = bar.alphaValue
        guard immediateAlpha == 1, EditorAccessibilityPolicy.system.crossfadeDuration == 0 else {
            throw VoxClipError.exportFailed("Reduced-effects bar animated immediately after selection.")
        }
        await Task.yield()
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let barRect = bar.convert(bar.bounds, to: nil)
        let first = try nativeBar(window: window, rect: barRect, name: "reduced-effects-before", directory: directory)
        let firstTime = Date()
        try await Task.sleep(for: .milliseconds(200))
        let second = try nativeBar(window: window, rect: barRect, name: "reduced-effects-after", directory: directory)
        let interval = Date().timeIntervalSince(firstTime)
        let firstPixels = try pixels(first), secondPixels = try pixels(second)
        guard first.width == second.width, first.height == second.height else { throw CocoaError(.coderInvalidValue) }
        var differing = 0
        for offset in stride(from: 0, to: firstPixels.count, by: 4) {
            if firstPixels[offset..<offset + 4] != secondPixels[offset..<offset + 4] { differing += 1 }
        }
        let scale: CGFloat = CGFloat(second.height) / bar.bounds.height
        let backgroundInset: CGFloat = 4
        let scaledRow: CGFloat = backgroundInset * scale
        let sampleRow = Int(scaledRow)
        var opaque = 0
        var sampledRGB: [Double] = []
        let mode = bar.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
        guard let colors = DesignValues.value("color.bg.elevated") as? [String: String], let hex = colors[mode],
              let expected = DesignValues.parse(hex).usingColorSpace(.sRGB) else { throw CocoaError(.coderInvalidValue) }
        let expectedRGB: [Double] = [expected.redComponent, expected.greenComponent, expected.blueComponent]
        let byteMaximum: Double = 255
        for column in (second.width / 3)..<(second.width * 2 / 3) {
            let offset = (sampleRow * second.width + column) * 4
            let rawChannels: [Double] = secondPixels[offset..<offset + 3].map { Double($0) }
            let actual: [Double] = rawChannels.map { $0 / byteMaximum }
            if sampledRGB.isEmpty { sampledRGB = actual }
            let error = max(abs(actual[0] - expected.redComponent),
                max(abs(actual[1] - expected.greenComponent), abs(actual[2] - expected.blueComponent)))
            if error <= 0.025 { opaque += 1 }
        }
        let policy = EditorAccessibilityPolicy.system
        let result = ReducedEffectsResult(reduceMotion: policy.reduceMotion, reduceTransparency: policy.reduceTransparency,
            opaqueBackgroundPixels: opaque, differingPixels: differing, frameIntervalSeconds: interval,
            width: first.width, height: first.height, appearance: bar.effectiveAppearance.name.rawValue,
            expectedBackgroundRGB: expectedRGB, sampledBackgroundRGB: sampledRGB, immediateAlpha: immediateAlpha)
        try ProjectJSON.encoder().encode(result).write(to: directory.appendingPathComponent("reduced-effects.json"), options: .atomic)
        guard policy.reduceMotion, policy.reduceTransparency, bar.alphaValue == 1, opaque >= 10, differing == 0 else {
            throw VoxClipError.exportFailed("Reduced-effects native pixels failed; see reduced-effects.json.")
        }
    }
    private static func nativeBar(window: NSWindow, rect: CGRect, name: String, directory: URL) throws -> CGImage {
        let url = directory.appendingPathComponent(name).appendingPathExtension("png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0,
              let image = NSBitmapImageRep(data: try Data(contentsOf: url))?.cgImage else { throw CocoaError(.fileReadCorruptFile) }
        let scale = CGFloat(image.width) / window.frame.width
        let top = window.frame.height - rect.maxY
        let crop = CGRect(x: rect.minX * scale, y: top * scale, width: rect.width * scale, height: rect.height * scale).integral
        guard let cropped = image.cropping(to: crop),
              let png = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]) else { throw CocoaError(.fileReadCorruptFile) }
        try png.write(to: url, options: .atomic)
        return cropped
    }
    private static func pixels(_ image: CGImage) throws -> [UInt8] {
        let rowBytes = image.width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * image.height)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: rowBytes, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw CocoaError(.fileReadCorruptFile) }
        return bytes
    }
}
#endif
