import SwiftUI
import UniformTypeIdentifiers
import VoxClipCore

@MainActor struct ExportSheet: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var scope = ExportScope.fullVideo
    @State private var requestedIDs: [String] = []
    @State private var shareTarget = "full"
    @State private var draft = ShareCaptionDraft()
    @State private var copyRevision = 0
    @State private var copied = false
    @State private var opening = false
    /// The removed-line warning and the X tip (voice-lab.md §11.3–11.4).
    @State private var flow = ShareDisclosureFlow()
    @FocusState private var captionFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export").font(.title2)
            if model.exporting {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(model.exportStatus(at: context.date))
                }
                ProgressView(value: model.exportProgress?.fraction).frame(width: 420).accessibilityLabel("Export progress")
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
                TextEditor(text: Binding(get: { draft.captionDraft }, set: { draft.edit($0); copied = false; flow.edited() })).focused($captionFocused).frame(height: 90).border(Color.secondary.opacity(0.3))
                    .accessibilityLabel("Caption")
                HStack { if let weight = ShareText.weight(draft.captionDraft) { Text("\(weight)/280 X").foregroundStyle(weight > 280 ? DesignValues.color("status.warning") : Color.secondary) }; Text("\(draft.captionDraft.unicodeScalars.count)/3,000 LinkedIn").foregroundStyle(.secondary) }.font(.caption.monospacedDigit())
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(model.exports.map(\.outputURL)) }
                    Button(copied ? "Caption copied." : "Copy caption") { share(.copy) }
                    Button("Open X") { share(.x) }.disabled(opening)
                    Button("Open LinkedIn") { share(.linkedIn) }.disabled(opening)
                }
                if flow.pending != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        InlineNotice(text: ShareDisclosure.removedWarning)
                        HStack {
                            Button(ShareDisclosure.shareAnyway) { if let action = flow.shareAnyway() { perform(action) } }
                            Button(ShareDisclosure.restoreLine) { if let restored = flow.restoreLine(draft) { draft = restored.draft; perform(restored.action) } }
                        }.padding(.horizontal, 12)
                    }
                }
                if flow.showsXTip { InlineNotice(text: ShareDisclosure.xMadeWithAITip) }
                Text("VoxClip copies the caption and reveals the file. Add the video in the browser; nothing is posted automatically.").font(.caption).foregroundStyle(.secondary)
                if let error = model.exportError { InlineNotice(text: error) }
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            } else {
                Form {
                    Picker("What", selection: $scope) {
                        if !model.exportTargets(.thisClip, requestedIDs: requestedIDs).isEmpty { Text(model.exportScopeLabel(.thisClip, requestedIDs: requestedIDs)).tag(ExportScope.thisClip) }
                        Text(model.exportScopeLabel(.allClips)).tag(ExportScope.allClips).disabled(model.keptClips.isEmpty)
                        Text(model.exportScopeLabel(.fullVideo)).tag(ExportScope.fullVideo)
                    }.pickerStyle(.radioGroup)
                    Picker("Aspect", selection: binding(\.aspect)) { Text("9:16").tag(AspectRatio.portrait); Text("1:1").tag(AspectRatio.square); Text("16:9").tag(AspectRatio.landscape); Text("Original").tag(AspectRatio.source) }.pickerStyle(.segmented)
                    Picker("Captions", selection: Binding(get: { model.project.captions.styleId }, set: { model.setStyle($0) })) { Text("Off").tag("off"); ForEach(model.app.styles, id: \.id) { Text($0.name).tag($0.id) } }
                    Toggle("Also save .srt", isOn: binding(\.srt))
                    Picker("Quality", selection: binding(\.quality)) { Text("Standard").tag(ExportQuality.standard); Text("High").tag(ExportQuality.high) }.pickerStyle(.segmented)
                    LabeledContent("Save to") { Text(folder.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")).lineLimit(1).truncationMode(.middle); Button("Choose…") { chooseFolder() } }
                }.formStyle(.grouped).scrollContentBackground(.hidden).frame(minHeight: 300)
                if let disclosure = model.exportDisclosure(targets) { Label(disclosure, systemImage: "waveform").font(.caption) }
                if let note = model.captionError { InlineNotice(text: note) }
                if let error = model.exportError { InlineNotice(text: error) }
                HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button(model.exportError == nil ? "Export" : "Try again") { model.beginExport(targets: targets, folder: folder) }.accessibilityLabel(model.exportAccessibleName(model.exportError == nil ? "Export" : "Try again", targets: targets)).keyboardShortcut(.defaultAction).disabled(!model.canExport || targets.isEmpty) }
            }
        }.padding(24).frame(width: 620)
        .background(DesignValues.color("bg.window"))
        .onAppear {
            requestedIDs = model.exportClipIDs
            scope = model.exportTargets(.thisClip, requestedIDs: requestedIDs).isEmpty ? .fullVideo : .thisClip
        }
        .onChange(of: shareTarget) { _, target in commitCaption(); draft.load(target: target, model: model); copied = false; flow.select() }
        .onChange(of: captionFocused) { _, focused in if !focused { commitCaption() } }
        .onDisappear { commitCaption() }
        .task(id: copyRevision) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)); copied = false } catch {}
        }
    }
    private var targets: [ExportTarget] { model.exportTargets(scope, requestedIDs: requestedIDs) }
    private var folder: URL { ExportSelection.folder(model.project.export.folder ?? model.app.string("export.folder", fallback: "~/Movies/VoxClip")) }
    private func commitCaption() { draft.commit(model: model) }
    /// Copy caption, Open X and Open LinkedIn first warn when the caption no longer carries the disclosure line.
    private func share(_ action: ShareAction) {
        commitCaption()
        if let action = flow.request(action, draft: draft) { perform(action) }
    }
    private func perform(_ action: ShareAction) {
        switch action {
        case .copy: commitCaption(); copyText(draft.captionDraft); copied = true; copyRevision += 1; model.announce("Caption copied.")
        case .x:
            openShare("x")
            if flow.openedX(draft: draft) { model.announce(ShareDisclosure.xMadeWithAITip) }
        case .linkedIn: openShare("linkedin")
        }
    }
    private func binding<Value>(_ key: WritableKeyPath<ProjectExport, Value>) -> Binding<Value> { Binding(get: { model.project.export[keyPath: key] }, set: { value in var project = model.project; project.export[keyPath: key] = value; model.replace(project, name: "Change export options") }) }
    private func chooseFolder() { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.directoryURL = folder; if panel.runModal() == .OK, let url = panel.url { var project = model.project; project.export.folder = url.path; model.replace(project, name: "Change export folder") } }
    /// Copies the caption and reveals the files at once; the composer text is cut off the main actor, and the browser opens
    /// back on it. A second click while the first is still cutting does nothing.
    private func openShare(_ destination: String) {
        guard !opening else { return }
        commitCaption()
        let caption = draft.captionDraft, line = draft.disclosureLine
        copyText(caption); NSWorkspace.shared.activateFileViewerSelecting(model.exports.map(\.outputURL))
        opening = true
        Task {
            defer { opening = false }
            do {
                guard let url = try await Task.detached(priority: .userInitiated, operation: { try ShareText.url(destination, caption: caption, disclosureLine: line) }).value,
                      ["x.com", "www.linkedin.com"].contains(url.host ?? ""), url.scheme == "https" else { return }
                NSWorkspace.shared.open(url)
            } catch { model.exportError = UserMessages.message(error) }
        }
    }
}

enum ShareAction { case copy, x, linkedIn }

/// The export sheet's share actions for the selected target (voice-lab.md §11.3–11.4), as Windows `ShareDisclosureFlow`:
/// Copy caption, Open X and Open LinkedIn share at once while the caption keeps the disclosure line. When the line was
/// removed or changed, the action waits behind the removal warning until [Share anyway] shares the caption as it is or
/// [Restore line] puts the line back and then shares.
@MainActor struct ShareDisclosureFlow {
    /// The share action held behind the removal warning, or nil.
    private(set) var pending: ShareAction?
    /// The "Made with AI" checklist tip, shown after Open X for a target with a line.
    private(set) var showsXTip = false
    /// A share click: the action to perform now, or nil when the removal warning shows first and holds it.
    mutating func request(_ action: ShareAction, draft: ShareCaptionDraft) -> ShareAction? {
        pending = draft.lineRemoved ? action : nil
        return pending == nil ? action : nil
    }
    /// [Share anyway]: the held action, shared with the caption as it is; nil when nothing is held.
    mutating func shareAnyway() -> ShareAction? {
        let action = pending
        pending = nil
        return action
    }
    /// [Restore line]: the draft with the line put back and the held action to perform with it; nil when nothing is held.
    mutating func restoreLine(_ draft: ShareCaptionDraft) -> (draft: ShareCaptionDraft, action: ShareAction)? {
        guard let action = pending else { return nil }
        pending = nil
        var restored = draft
        restored.restoreLine()
        return (restored, action)
    }
    /// Editing the caption withdraws the warning, which was about the text before the edit.
    mutating func edited() { pending = nil }
    /// Another target: its caption has its own line, so the warning and the tip go.
    mutating func select() { pending = nil; showsXTip = false }
    /// After Open X: an intent link can't set X's disclosure flag, so a target with a line shows the checklist tip.
    /// Returns true when the tip should be announced.
    mutating func openedX(draft: ShareCaptionDraft) -> Bool {
        guard draft.disclosureLine != nil else { return false }
        showsXTip = true
        return true
    }
}

@MainActor struct ShareCaptionDraft {
    private(set) var draftTarget: String?
    private(set) var captionDraft = ""
    private(set) var edited = false
    /// The target's Voice Lab disclosure line (voice-lab.md §11.3); nil when it has no AI-modified speech.
    private(set) var disclosureLine: String?
    /// The draft is capped at the 3,000 scalars of `share.captions` with `SharePostText.capCaption`, as the Windows field is,
    /// so the field, Copy caption, both composers and the saved caption see the same text. With AI-modified speech the
    /// field opens with the disclosure line after a blank line (`SharePostText.fieldText`, still within 3,000 scalars).
    mutating func load(target: String, model: EditorModel) {
        draftTarget = target; disclosureLine = model.shareDisclosureLine(target); edited = false
        captionDraft = Self.fieldText(SharePostText.capCaption(model.shareCaption(target)), line: disclosureLine)
    }
    mutating func edit(_ value: String) { captionDraft = SharePostText.capCaption(value); edited = true }
    /// True when the user removed or changed the disclosure line (`ShareDisclosure.isPresent`).
    var lineRemoved: Bool { disclosureLine.map { !ShareDisclosure.isPresent(captionDraft, line: $0) } ?? false }
    /// Restore line: puts the disclosure line back with `SharePostText.fieldText`.
    mutating func restoreLine() {
        guard lineRemoved else { return }
        captionDraft = Self.fieldText(captionDraft, line: disclosureLine); edited = true
    }
    /// After a failed launch check of the share rules the line is still appended, uncut.
    private static func fieldText(_ caption: String, line: String?) -> String {
        if let text = try? SharePostText.fieldText(caption, line: line) { return text }
        guard let line, !ShareDisclosure.isPresent(caption, line: line) else { return caption }
        return caption + "\n\n" + line
    }
    mutating func commit(model: EditorModel) {
        guard edited, let target = draftTarget, !model.exports.isEmpty else { return }
        edited = false
        guard target == "full" || model.project.edits.clips.contains(where: { $0.id == target }) else { return }
        guard captionDraft != model.shareCaption(target) else { return }
        var project = model.project
        project.share.captions[target] = captionDraft
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
    /// nil only when shared/data/share-text.json failed the launch check, which Home already reports.
    static func weight(_ text: String) -> Int? { try? SharePostText.xWeight(text) }
    /// X truncation keeps the disclosure line whole and last (voice-lab.md §11.3); LinkedIn gets the caption as it is.
    static func url(_ destination: String, caption: String, disclosureLine: String?) throws -> URL? {
        let text = try destination == "x" ? SharePostText.composerText(caption, destination: .x, disclosureLine: disclosureLine) : caption
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: destination == "x" ? "https://x.com/intent/post?text=\(encoded)" : "https://www.linkedin.com/feed/?shareActive=true&text=\(encoded)")
    }
}

extension EditorModel {
    /// The disclosure line for a share target, from the plan its export rendered (voice-lab.md §11.1, §11.3), as Windows
    /// reads it from the job snapshot; nil when that render had no enabled AI segment. Edits made during or after the
    /// export don't change it, because the shared file is the one that was rendered.
    func shareDisclosureLine(_ target: String) -> String? { exportDisclosureLines[target] }
    /// Records the disclosure of the plan a target's export rendered, for the share text.
    func recordShareDisclosure(_ target: ExportTarget, disclosure: VoiceLabDisclosurePlan?) {
        exportDisclosureLines[ExportLedger.targetID(target)] = disclosure?.postText
    }
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
        guard !targets.isEmpty, canExport, mediaExportable else { return }
        let renderSnapshot = renderSnapshot()
        let labelPosition = app.voiceLabLabelPosition
        let snapshot = renderSnapshot.project
        let pattern = app.string("export.fileNamePattern", fallback: "{project}-{clip}-{aspect}")
        let openFolderAfter = app.bool("export.openFolderAfter", fallback: false)
        exportError = nil; exports = []; exportDisclosureLines = [:]; exporting = true; exportStartedAt = Date(); exportIndex = 1
        exportClipIDs = targets.compactMap { if case .clip(let id) = $0 { id } else { nil } }
        activeExportKey = targets.first.map { ExportLedger.key($0, aspect: snapshot.export.aspect) }
        let total = targets.count
        announce(total == 1 ? "Exporting 1 video" : "Exporting \(total) videos")
        exportTask = Task { [weak self] in
            guard let self else { return }
            defer { exporting = false; exportProgress = nil; activeExportKey = nil }
            await app.log.write(LogEntry(level: .info, category: "export", message: "start targets=\(targets.count)"))
            do {
                if document.demo { throw VoxClipError.notImplemented("synthetic-preview-only") }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (position, target) in targets.enumerated() {
                    try Task.checkCancellation(); exportIndex = position + 1
                    let key = ExportLedger.key(target, aspect: snapshot.export.aspect)
                    activeExportKey = key
                    failedExports[key] = nil
                    exportProgress = nil
                    let render = try await renderRequest(target: target, snapshot: renderSnapshot, labelPosition: labelPosition)
                    let fingerprint = try ExportFingerprint.value(snapshot, target: target, labelPosition: labelPosition)
                    let name: String
                    switch target { case .fullEdit: name = "full"; case .clip(let id): name = snapshot.edits.clips.first { $0.id == id }?.title ?? "clip" }
                    let aspect = snapshot.export.aspect.rawValue.replacingOccurrences(of: ":", with: "x")
                    let base = ExportSelection.baseName(pattern.replacingOccurrences(of: "{project}", with: snapshot.title ?? "Untitled").replacingOccurrences(of: "{clip}", with: name).replacingOccurrences(of: "{aspect}", with: aspect).replacingOccurrences(of: ".mp4", with: ""))
                    let url = ExportSelection.destination(base: base, folder: folder, writeSRT: snapshot.export.srt)
                    guard url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path else { throw VoxClipError.exportFailed("invalid destination") }
                    let srt = snapshot.export.srt ? url.deletingPathExtension().appendingPathExtension("srt") : nil
                    let job = ExportJob(target: target, render: render, aspect: snapshot.export.aspect, quality: snapshot.export.quality, outputURL: url, writeSRT: snapshot.export.srt, srtURL: srt)
                    let result = try await exporter.export(job) { [weak self] value in Task { @MainActor in
                        guard let self, self.activeExportKey == key else { return }
                        let previousFraction: Double = self.exportProgress?.fraction ?? 0
                        let currentFraction: Double = value.fraction ?? 0
                        let previousQuarter: Double = previousFraction * 4
                        let currentQuarter: Double = currentFraction * 4
                        let before = Int(previousQuarter), after = Int(currentQuarter)
                        self.exportProgress = value
                        if after > before, after < 4 { self.announce("Rendering \(self.exportIndex) of \(total) · \(after * 25)%") }
                    } }
                    exports.append(result)
                    recordShareDisclosure(target, disclosure: render.voiceLab?.prepared.disclosure)
                    try app.exportLedger.record(ExportRecord(projectID: snapshot.id, targetID: ExportLedger.targetID(target), exportedAt: Date(),
                        planFingerprint: fingerprint, styleId: snapshot.captions.styleId, aspect: snapshot.export.aspect, outputPath: result.outputURL.path))
                    activeExportKey = nil
                }
                await app.log.write(LogEntry(level: .info, category: "export", message: "success targets=\(exports.count)"))
                announce("Saved \(exports.count) video\(exports.count == 1 ? "" : "s") to \(FileManager.default.displayName(atPath: folder.path))")
                if openFolderAfter { NSWorkspace.shared.activateFileViewerSelecting(exports.map(\.outputURL)) }
            } catch is CancellationError {
                if let key = activeExportKey { failedExports[key] = folder }
                await app.log.write(LogEntry(level: .info, category: "export", message: "cancelled"))
            } catch VoxClipError.cancelled {
                if let key = activeExportKey { failedExports[key] = folder }
                await app.log.write(LogEntry(level: .info, category: "export", message: "cancelled"))
            } catch {
                if let key = activeExportKey { failedExports[key] = folder }
                exportError = await app.safeError(error, context: "export")
                if let exportError, !exportError.isEmpty { announce(exportError) }
            }
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
