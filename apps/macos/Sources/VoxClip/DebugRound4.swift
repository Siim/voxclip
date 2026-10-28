#if DEBUG
import AppKit
import SwiftUI
import VoxClipCore
import VoxClipMedia
import Darwin

@MainActor enum DebugRound4 {
    static func run(app: AppModel, directory: URL) async {
        var results: [DebugUISuite.Result] = []
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let shared = app.shared else { throw VoxClipError.sharedResourcesMissing }
            let fixture = try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
            results += DebugCapabilities.run(app: app, fixture: fixture)
            results += try await DebugExport.run(app: app, fixture: fixture, directory: directory, captures: false)
            results += try await DebugRewrite.run(app: app, fixture: fixture, directory: directory)
            results += try await DebugAccessibility.run(app: app, fixture: fixture, directory: directory)
            results += try await gallery(app: app, fixture: fixture, directory: directory)
            try captures(app: app, fixture: fixture, directory: directory)
        } catch {
            results.append(.init(name: "headless harness error: \(UserMessages.message(error))", passed: false))
        }
        try? ProjectJSON.encoder().encode(results).write(to: directory.appendingPathComponent("results.json"), options: .atomic)
        print("Mac redesign non-window checks: \(results.filter(\.passed).count)/\(results.count). Native UI and save-boundary gates are separate.")
        exit(results.allSatisfy(\.passed) ? 0 : 1)
    }
    private static func gallery(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        let editor = EditorModel(document: VoxClipDocument(project: fixture), app: app, preview: DemoPreviewEngine())
        defer { editor.close() }
        editor.mediaResolved = true; editor.refresh()
        for appearance in ["light", "dark"] {
            for width in [320, 360] {
                let paneWidth: Int = width - 40
                let tileWidth: Int = paneWidth / 2
                let targetWidth: Double = Double(tileWidth)
                let rawHeight: Double = targetWidth * 0.45
                let tileHeight: Int = Int(rawHeight.rounded())
                for style in app.styles {
                    for chip in [false, true] {
                        let outputWidth: Int = chip ? 64 : tileWidth
                        let outputHeight: Int = chip ? 36 : tileHeight
                        var input = editor.captionTileInput(style)
                        input.frameAvailable = false
                        input.backdrop = appearance == "light" ? "#4B4B4B" : "#181818"
                        input.tileSize = PixelSize(width: outputWidth * 2, height: outputHeight * 2)
                        guard let image = await app.captions.tile(input), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                              let bitmap = DebugCaptionsSection.tileBitmap(cg, width: outputWidth, height: outputHeight) else {
                            results.append(.init(name: "\(style.id) gallery raster exists", passed: false)); continue
                        }
                        let height = DebugCaptionsSection.glyphPixelHeight(bitmap)
                        let label = "\(appearance)-\(width)-\(style.id)-\(chip ? "chip" : "tile")"
                        results.append(.init(name: "\(label) glyph height ≥8px (\(height))", passed: height >= 8))
                        results.append(.init(name: "\(label) no edge-clipped word", passed: !DebugCaptionsSection.edgeHasGlyph(bitmap)))
                        if let bytes = bitmap.representation(using: .png, properties: [:]) { try bytes.write(to: directory.appendingPathComponent(label + ".png")) }
                    }
                }
            }
        }
        return results
    }
    private static func captures(app: AppModel, fixture: Project, directory: URL) throws {
        let editor = EditorModel(document: VoxClipDocument(project: fixture), app: app, preview: DemoPreviewEngine())
        defer { editor.close() }
        editor.mediaResolved = true; editor.refresh()
        if let clip = editor.keptClips.first { editor.activate(clip) }
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let scopes = VStack(alignment: .leading, spacing: 16) {
                Text(editor.exportScopeLabel(.thisClip)).font(.system(size: 13))
                Text(editor.exportScopeLabel(.allClips)).font(.system(size: 13))
                Text(editor.exportScopeLabel(.fullVideo)).font(.system(size: 13))
            }.padding(16)
            try bitmap(scopes, name: "export-scope-copy-\(name)", width: 360, height: 160, scheme: scheme, directory: directory)
            let fullKey = ExportLedger.key(.fullEdit, aspect: editor.project.export.aspect)
            editor.activeExportKey = fullKey; editor.exporting = true
            editor.exportProgress = ExportProgress(phase: .encoding, fraction: 0.25)
            try bitmap(FullTakeRow(editor: editor), name: "full-take-progress-\(name)", width: 300, height: 70, scheme: scheme, directory: directory)
            editor.exporting = false; editor.failedExports[fullKey] = directory
            try bitmap(FullTakeRow(editor: editor), name: "full-take-failed-\(name)", width: 300, height: 70, scheme: scheme, directory: directory)
            editor.failedExports = [:]
            let fingerprint = try ExportFingerprint.value(editor.project, target: .fullEdit)
            for changed in [false, true] {
                try app.exportLedger.record(ExportRecord(projectID: editor.project.id, targetID: "full", exportedAt: Date(),
                    planFingerprint: changed ? "capture-edited" : fingerprint, styleId: editor.project.captions.styleId,
                    aspect: editor.project.export.aspect, outputPath: directory.appendingPathComponent("fixture.mp4").path))
                try bitmap(FullTakeRow(editor: editor), name: "full-take-\(changed ? "changed" : "exported")-\(name)", width: 300, height: 70, scheme: scheme, directory: directory)
            }
            let range = 3...min(9, editor.words.count - 1)
            let envelope = AudioEnvelope(sampleRate: 48_000, levels: Array(repeating: 0.01, count: 100_000))
            let fake = RewriteFixtureConnector()
            let connector = RewriteConnector(connector: fake, model: "fixture-local", name: "Ollama", group: "local", plan: "")
            let session = RewriteSession(editor: editor, range: range, envelope: envelope, connector: connector)
            session.edit("A clearer passage")
            let reviewCopy = VStack(alignment: .leading, spacing: 12) {
                Text("Rewrite · Beta").font(.system(size: 13, weight: .semibold))
                Text("What should change?")
                Text(session.sendLine).font(.system(size: 11))
                Text("New words").font(.system(size: 12, weight: .semibold))
                Text(session.newWords)
                Text(session.review?.changeSummary ?? "").font(.system(size: 11))
                ForEach(session.review?.voiceHunks.indices ?? 0..<0, id: \.self) { index in
                    Text(session.review?.voiceHunks[index].meter?.copy ?? session.review?.voiceHunks[index].refusal ?? "").font(.system(size: 11))
                }
                Text("Exports show AI MODIFIED on the video and in the post.").font(.system(size: 11))
            }.padding(16)
            try bitmap(reviewCopy, name: "rewrite-copy-\(name)", width: 360, height: 420, scheme: scheme, directory: directory)
            session.edit(session.source.dropLast().map(\.text).joined(separator: " "))
            session.close()
            let disclosure = EditorModel.exportSheetDisclosure(required: true) ?? ""
            try bitmap(Label(disclosure, systemImage: "waveform").font(.caption).padding(16), name: "export-disclosure-\(name)", width: 500, height: 70, scheme: scheme, directory: directory)
        }
    }
    static func bitmap<Content: View>(_ content: Content, name: String, width: Double, height: Double, scheme: ColorScheme, directory: URL) throws {
        let previousAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        defer { NSApp.appearance = previousAppearance }
        let renderer = ImageRenderer(content: content.frame(width: width, height: height).background(DesignValues.color("bg.window")).sceneAccent().environment(\.colorScheme, scheme).preferredColorScheme(scheme))
        renderer.scale = 1
        var image: CGImage?
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { image = renderer.cgImage }
        guard let image, let bytes = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.coderInvalidValue) }
        try bytes.write(to: directory.appendingPathComponent(name + "-offscreen.png"))
    }
}
#endif
