import SwiftUI
import UniformTypeIdentifiers
import VoxClipCore

@MainActor struct ExportSheet: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var clips = false
    @State private var requestedIDs: [String] = []
    @State private var shareTarget = "full"
    @State private var draft = ShareCaptionDraft()
    @State private var copyRevision = 0
    @State private var copied = false
    @FocusState private var captionFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export").font(.title2)
            if model.exporting {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(model.exportStatus(at: context.date))
                }
                ProgressView(value: model.exportProgress?.fraction).frame(width: 420)
                Text(model.exportProgress?.phase.rawValue.capitalized ?? "Preparing…").foregroundStyle(.secondary)
                HStack { Button("Close") { dismiss() }; Spacer(); Button("Cancel") { model.exportTask?.cancel() } }
            } else if !model.exports.isEmpty {
                Label("Saved \(model.exports.count) video\(model.exports.count == 1 ? "" : "s") to \(model.exports.first?.outputURL.deletingLastPathComponent().path ?? folder.path)", systemImage: "checkmark.circle.fill").foregroundStyle(DesignValues.color("status.success"))
                ForEach(model.exports, id: \.outputURL) { result in
                    HStack { Image(systemName: "film"); Text(result.outputURL.lastPathComponent); Spacer(); Text(timecode(result.durationSeconds)).font(DesignValues.mono()) }.draggable(result.outputURL)
                }
                Picker("Caption for", selection: $shareTarget) {
                    if model.exportClipIDs.isEmpty { Text("Full edit").tag("full") }
                    ForEach(model.exportClipIDs, id: \.self) { id in Text(model.project.edits.clips.first { $0.id == id }?.title ?? "Clip").tag(id) }
                }.onAppear { let target = model.exportClipIDs.first ?? "full"; draft.load(target: target, model: model); shareTarget = target }
                TextEditor(text: Binding(get: { draft.captionDraft }, set: { draft.edit($0); copied = false })).focused($captionFocused).frame(height: 90).border(Color.secondary.opacity(0.3))
                HStack { Text("\(ShareText.weight(draft.captionDraft))/280 X").foregroundStyle(ShareText.weight(draft.captionDraft) > 280 ? Color.orange : Color.secondary); Text("\(draft.captionDraft.unicodeScalars.count)/3,000 LinkedIn").foregroundStyle(.secondary) }.font(.caption.monospacedDigit())
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(model.exports.map(\.outputURL)) }
                    Button(copied ? "Caption copied." : "Copy caption") { commitCaption(); copyText(draft.captionDraft); copied = true; copyRevision += 1 }
                    Button("Open X") { openShare("x") }
                    Button("Open LinkedIn") { openShare("linkedin") }
                }
                Text("VoxClip copies the caption and reveals the file. Add the video in the browser; nothing is posted automatically.").font(.caption).foregroundStyle(.secondary)
                if let error = model.exportError { InlineNotice(text: error) }
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            } else {
                Form {
                    if let id = requestedIDs.first {
                        LabeledContent("What", value: requestedIDs.count == 1 ? "This clip · \(model.project.edits.clips.first { $0.id == id }?.title ?? "Clip")" : "\(requestedIDs.count) clips")
                    } else {
                        Picker("What", selection: $clips) { Text("Full video (with edits)").tag(false); Text("Selected clips (\(model.sortedClips.filter(\.selected).count))").tag(true) }.pickerStyle(.radioGroup)
                    }
                    Picker("Aspect", selection: binding(\.aspect)) { Text("Source").tag(AspectRatio.source); Text("16:9").tag(AspectRatio.landscape); Text("9:16").tag(AspectRatio.portrait); Text("1:1").tag(AspectRatio.square) }.pickerStyle(.segmented)
                    Picker("Captions", selection: Binding(get: { model.project.captions.styleId }, set: { model.setStyle($0) })) { Text("Off").tag("off"); ForEach(model.app.styles, id: \.id) { Text($0.name).tag($0.id) } }
                    Toggle("Also save .srt", isOn: binding(\.srt))
                    Picker("Quality", selection: binding(\.quality)) { Text("Standard").tag(ExportQuality.standard); Text("High").tag(ExportQuality.high) }.pickerStyle(.segmented)
                    LabeledContent("Save to") { Text(folder.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")).lineLimit(1).truncationMode(.middle); Button("Choose…") { chooseFolder() } }
                }.formStyle(.grouped).scrollContentBackground(.hidden).frame(minHeight: 300)
                if let note = model.captionError { InlineNotice(text: note) }
                if let error = model.exportError { InlineNotice(text: error) }
                HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button(model.exportError == nil ? "Export" : "Try again") { model.beginExport(targets: targets, folder: folder) }.keyboardShortcut(.defaultAction).disabled(!model.canExport || targets.isEmpty) }
            }
        }.padding(24).frame(width: 620)
        .background(DesignValues.color("bg.window"))
        .onAppear {
            requestedIDs = model.exportClipIDs
            clips = !requestedIDs.isEmpty
        }
        .onChange(of: shareTarget) { _, target in commitCaption(); draft.load(target: target, model: model); copied = false }
        .onChange(of: captionFocused) { _, focused in if !focused { commitCaption() } }
        .onDisappear { commitCaption() }
        .task(id: copyRevision) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)); copied = false } catch {}
        }
    }
    private var targets: [ExportTarget] { ExportSelection.targets(requestedIDs: requestedIDs, selectedClips: clips ? model.sortedClips.filter(\.selected).map(\.id) : nil) }
    private var folder: URL { ExportSelection.folder(model.project.export.folder ?? model.app.string("export.folder", fallback: "~/Movies/VoxClip")) }
    private func commitCaption() { draft.commit(model: model) }
    private func binding<Value>(_ key: WritableKeyPath<ProjectExport, Value>) -> Binding<Value> { Binding(get: { model.project.export[keyPath: key] }, set: { value in var project = model.project; project.export[keyPath: key] = value; model.replace(project, name: "Change export options") }) }
    private func chooseFolder() { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.directoryURL = folder; if panel.runModal() == .OK, let url = panel.url { var project = model.project; project.export.folder = url.path; model.replace(project, name: "Change export folder") } }
    private func openShare(_ destination: String) {
        commitCaption()
        let caption = draft.captionDraft
        copyText(caption); NSWorkspace.shared.activateFileViewerSelecting(model.exports.map(\.outputURL))
        guard let url = ShareText.url(destination, caption: caption), ["x.com", "www.linkedin.com"].contains(url.host ?? ""), url.scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor struct ShareCaptionDraft {
    private(set) var draftTarget: String?
    private(set) var captionDraft = ""
    private(set) var edited = false
    mutating func load(target: String, model: EditorModel) {
        draftTarget = target; captionDraft = model.shareCaption(target); edited = false
    }
    mutating func edit(_ value: String) { captionDraft = value; edited = true }
    mutating func commit(model: EditorModel) {
        guard edited, let target = draftTarget, !model.exports.isEmpty else { return }
        edited = false
        guard target == "full" || model.project.edits.clips.contains(where: { $0.id == target }) else { return }
        let value = String(String.UnicodeScalarView(captionDraft.unicodeScalars.prefix(3000)))
        guard value != model.shareCaption(target) else { return }
        var project = model.project
        project.share.captions[target] = value
        model.replace(project, name: "Edit share caption")
    }
}

enum ExportSelection {
    static func targets(requestedIDs: [String], selectedClips: [String]?) -> [ExportTarget] {
        if !requestedIDs.isEmpty { return requestedIDs.map(ExportTarget.clip) }
        return selectedClips?.map(ExportTarget.clip) ?? [.fullEdit]
    }
    static func folder(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL }
    static func baseName(_ value: String) -> String {
        let safe = String(value.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ")).inverted).joined(separator: "-").trimmingCharacters(in: .whitespaces).prefix(100))
        return safe.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } ? safe : "VoxClip-export"
    }
    static func destination(base: String, folder: URL, writeSRT: Bool) -> URL {
        var url = folder.appendingPathComponent(base).appendingPathExtension("mp4")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) || writeSRT && FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("srt").path) {
            url = folder.appendingPathComponent("\(base) \(suffix)").appendingPathExtension("mp4")
            suffix += 1
        }
        return url
    }
}

enum ShareText {
    static func weight(_ text: String) -> Int {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let source = text as NSString
        let matches = detector?.matches(in: text, range: NSRange(location: 0, length: source.length)).filter { ["http", "https"].contains($0.url?.scheme ?? "") } ?? []
        var remainder = text
        for match in matches.reversed() { if let range = Range(match.range, in: remainder) { remainder.removeSubrange(range) } }
        return matches.count * 23 + remainder.reduce(0) { total, character in
            if character.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F || $0.value == 0x20E3 }) { return total + 2 }
            return total + character.unicodeScalars.reduce(0) { subtotal, scalar in let value = scalar.value; return subtotal + ((value <= 4351 || (8192...8205).contains(value) || (8208...8223).contains(value) || (8242...8247).contains(value)) ? 1 : 2) }
        }
    }
    static func url(_ destination: String, caption: String) -> URL? {
        var text = caption
        if destination == "x", weight(text) > 280 {
            var parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
            repeat { if !parts.isEmpty { parts.removeLast() }; text = parts.joined(separator: " ") + "…" } while weight(text) > 280 && !parts.isEmpty
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: destination == "x" ? "https://x.com/intent/post?text=\(encoded)" : "https://www.linkedin.com/feed/?shareActive=true&text=\(encoded)")
    }
}

extension EditorModel {
    func shareCaption(_ target: String) -> String {
        if let saved = project.share.captions[target] { return saved }
        let clip = project.edits.clips.first { $0.id == target }
        let lower = clip.flatMap { index($0.startWordId) } ?? 0, upper = clip.flatMap { index($0.endWordId) } ?? max(0, words.count - 1)
        guard lower <= upper else { return clip?.title ?? "" }
        let kept = words.enumerated().filter { (lower...upper).contains($0.offset) && !project.edits.cutWordIds.contains($0.element.id) }.map { text($0.element) }
        var sentence: [String] = []
        var ended = false
        for word in kept.prefix(40) { sentence.append(word); if let last = word.last, ".?!…".contains(last) { ended = true; break } }
        let first = sentence.joined(separator: " ") + (!ended && !sentence.isEmpty ? "…" : "")
        return [clip?.title, first].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    func beginExport(targets: [ExportTarget], folder: URL) {
        guard !targets.isEmpty, !exporting else { return }
        exportError = nil; exports = []; exporting = true; exportStartedAt = Date(); exportIndex = 1
        exportClipIDs = targets.compactMap { if case .clip(let id) = $0 { id } else { nil } }
        exportTask = Task { [weak self] in
            guard let self else { return }
            defer { exporting = false; exportProgress = nil }
            await app.log.write(LogEntry(level: .info, category: "export", message: "start targets=\(targets.count)"))
            do {
                if document.demo { throw VoxClipError.notImplemented("synthetic-preview-only") }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (position, target) in targets.enumerated() {
                    try Task.checkCancellation(); exportIndex = position + 1
                    let render = try await renderRequest(target: target)
                    let name: String
                    switch target { case .fullEdit: name = "full"; case .clip(let id): name = project.edits.clips.first { $0.id == id }?.title ?? "clip" }
                    let aspect = project.export.aspect.rawValue.replacingOccurrences(of: ":", with: "x")
                    let pattern = app.string("export.fileNamePattern", fallback: "{project}-{clip}-{aspect}")
                    let base = ExportSelection.baseName(pattern.replacingOccurrences(of: "{project}", with: project.title ?? "Untitled").replacingOccurrences(of: "{clip}", with: name).replacingOccurrences(of: "{aspect}", with: aspect).replacingOccurrences(of: ".mp4", with: ""))
                    let url = ExportSelection.destination(base: base, folder: folder, writeSRT: project.export.srt)
                    guard url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path else { throw VoxClipError.exportFailed("invalid destination") }
                    let srt = project.export.srt ? url.deletingPathExtension().appendingPathExtension("srt") : nil
                    let job = ExportJob(target: target, render: render, aspect: project.export.aspect, quality: project.export.quality, outputURL: url, writeSRT: project.export.srt, srtURL: srt)
                    let result = try await exporter.export(job) { [weak self] value in Task { @MainActor in self?.exportProgress = value } }
                    exports.append(result)
                }
                await app.log.write(LogEntry(level: .info, category: "export", message: "success targets=\(exports.count)"))
                if app.bool("export.openFolderAfter", fallback: false) { NSWorkspace.shared.activateFileViewerSelecting(exports.map(\.outputURL)) }
            } catch is CancellationError {
                await app.log.write(LogEntry(level: .info, category: "export", message: "cancelled"))
            } catch VoxClipError.cancelled {
                await app.log.write(LogEntry(level: .info, category: "export", message: "cancelled"))
            } catch { exportError = await app.safeError(error, context: "export") }
        }
    }
    func exportStatus(at now: Date) -> String {
        let total = max(1, exportClipIDs.count)
        guard let fraction = exportProgress?.fraction, fraction > 0, let started = exportStartedAt else { return "Rendering \(exportIndex) of \(total) · preparing…" }
        let completed = (Double(max(0, exportIndex - 1)) + min(1, fraction)) / Double(total)
        let remaining = max(0, now.timeIntervalSince(started) * (1 - completed) / completed)
        return "Rendering \(exportIndex) of \(total) · \(Int(min(1, fraction) * 100))% · about \(durationLabel(remaining)) left"
    }
}
