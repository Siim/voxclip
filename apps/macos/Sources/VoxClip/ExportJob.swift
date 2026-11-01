import SwiftUI
import Observation
import UniformTypeIdentifiers
import VoxClipCore

/// Per-editor job state survives view removal, tab changes and panel switches.
@MainActor @Observable final class ExportJobState {
    var isOpen = false
    var scope = ExportScope.fullVideo
    var requestedIDs: [String] = []
    var folderOverride: URL?
    var fileNamePattern = ""
    var shareTarget = "full"
    var draft = ShareCaptionDraft()
    var drafts: [String: ShareCaptionDraft] = [:]
    var copied = false
    @ObservationIgnored private(set) var captionCopyTimer: Timer?
    func captionCopied() {
        captionCopyTimer?.invalidate()
        copied = true
        let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.copied = false
                self?.captionCopyTimer = nil
            }
        }
        captionCopyTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func selectScope(_ scope: ExportScope, model: EditorModel) {
        if scope == .thisClip, requestedIDs.isEmpty {
            guard let clip = model.activeClip else { return }
            requestedIDs = [clip.id]
        }
        self.scope = scope
    }
    var opening = false
    var showsXTip = false

    func openedX() -> Bool {
        showsXTip = draft.disclosureLine != nil
        return showsXTip
    }
    func selectShareTarget(_ target: String, model: EditorModel) {
        if let previous = draft.draftTarget { draft.commit(model: model); drafts[previous] = draft }
        shareTarget = target
        if let saved = drafts[target] { draft = saved }
        else { draft.load(target: target, model: model) }
        copied = false; showsXTip = false
    }
}

@MainActor struct ExportJobView: View {
    @Bindable var model: EditorModel
    @FocusState private var captionFocused: Bool
    private var job: ExportJobState { model.exportJob }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.exporting { running }
                    else if !model.exports.isEmpty { result }
                    else { setup }
                }.padding(.horizontal, CaptionsPanelMetrics.inset).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .font(VCType.callout.font())
        .background(DesignValues.color("bg.window"))
        .accessibilityElement(children: .contain).accessibilityLabel("Export job")
        .accessibilityIdentifier("voxclip.export.job")
        .onChange(of: captionFocused) { _, focused in if !focused { job.draft.commit(model: model) } }
        .onDisappear { job.draft.commit(model: model) }
    }
    private var running: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.periodic(from: .now, by: 1)) { context in Text(model.exportStatus(at: context.date)) }
            ProgressView(value: Double(model.exportPercent) / 100).accessibilityLabel("Export progress")
            Text(model.exportProgress?.phase.rawValue.capitalized ?? "Preparing…").foregroundStyle(.secondary)
            Button("Cancel") { model.exportTask?.cancel() }.accessibilityIdentifier("voxclip.export.cancel")
        }
    }
    private var result: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Exported", systemImage: "checkmark.circle.fill").foregroundStyle(DesignValues.color("status.success"))
            ForEach(model.exports, id: \.outputURL) { result in
                HStack { Image(systemName: "film"); Text(result.outputURL.lastPathComponent).lineLimit(1).truncationMode(.middle); Spacer(); Text(timecode(result.durationSeconds)).font(DesignValues.mono()) }.draggable(result.outputURL)
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(model.exports.map(\.outputURL)) }
            DisclosureGroup("Share to X or LinkedIn…", isExpanded: model.app.boolBinding("ui.export.shareExpanded")) { shareControls.padding(.top, 8) }
            if let error = model.exportError { InlineNotice(text: error) }
        }
    }
    private var shareControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Caption for", selection: Binding(get: { job.shareTarget }, set: { job.selectShareTarget($0, model: model) })) {
                ForEach(model.exports, id: \.outputURL) { result in
                    let index = model.exports.firstIndex(where: { $0.outputURL == result.outputURL }) ?? 0
                    let target = model.exportClipIDs.indices.contains(index) ? model.exportClipIDs[index] : "full"
                    Text(target == "full" ? "Full edit" : model.scopeName(target)).tag(target)
                }
            }
            TextEditor(text: Binding(get: { job.draft.captionDraft }, set: { job.draft.edit($0); job.copied = false }))
                .focused($captionFocused).frame(height: 90).border(DesignValues.color("line.default"))
                .accessibilityLabel("Caption")
            if job.draft.disclosureLine != nil {
                Toggle("Add 'AI MODIFIED' line to the post", isOn: Binding(get: { job.draft.addDisclosure }, set: { job.draft.setDisclosure($0); job.copied = false }))
                    .accessibilityIdentifier("voxclip.export.postDisclosure")
                Text("Your video still shows the AI MODIFIED label.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                if let weight = ShareText.weight(job.draft.captionDraft) { Text("\(weight)/280 X").foregroundStyle(weight > 280 ? DesignValues.color("status.warning") : Color.secondary) }
                Text("\(job.draft.captionDraft.unicodeScalars.count)/3,000 LinkedIn").foregroundStyle(.secondary)
            }.font(.system(size: 11, design: .monospaced))
            HStack {
                Button(job.copied ? "Caption copied." : "Copy caption") { copyText(job.draft.captionDraft); job.draft.commit(model: model); job.captionCopied(); model.announce("Caption copied.") }
                Button("Open X") { openShare("x") }.disabled(job.opening)
                Button("Open LinkedIn") { openShare("linkedin") }.disabled(job.opening)
            }
            if job.showsXTip { InlineNotice(text: ShareDisclosure.xMadeWithAITip) }
            Text("VoxClip copies the caption and reveals the file. Add the video in the browser; nothing is posted automatically.").font(.system(size: 11)).foregroundStyle(.secondary)
        }.onAppear { if job.draft.draftTarget == nil { job.selectShareTarget(model.exportClipIDs.first ?? "full", model: model) } }
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            CaptionPropertyRow("What", marker: "export.what") {
                Picker("What", selection: Binding(get: { job.scope }, set: { job.selectScope($0, model: model) })) {
                    if !model.exportTargets(.thisClip, requestedIDs: job.requestedIDs).isEmpty { Text(model.exportScopeLabel(.thisClip, requestedIDs: job.requestedIDs)).tag(ExportScope.thisClip) }
                    Text(model.exportScopeLabel(.allClips)).tag(ExportScope.allClips).disabled(model.keptClips.isEmpty)
                    Text(model.exportScopeLabel(.fullVideo)).tag(ExportScope.fullVideo)
                }.labelsHidden().accessibilityLabel("What")
            }
            Text("ASPECT").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text("Reframed on your face, preview above").font(.system(size: 11)).foregroundStyle(.secondary)
            Picker("Aspect", selection: binding(\.aspect)) { Text("9:16").tag(AspectRatio.portrait); Text("1:1").tag(AspectRatio.square); Text("16:9").tag(AspectRatio.landscape); Text("Original").tag(AspectRatio.source) }.pickerStyle(.segmented)
            Divider()
            CaptionPropertyRow("Captions", marker: "export.captions") {
                Toggle("Burn in captions", isOn: Binding(get: { model.project.captions.styleId != "off" }, set: { model.setCaptionsEnabled($0) })).toggleStyle(.switch)
            }
            CaptionPropertyRow("Style", marker: "export.style") {
                Picker("Caption style", selection: Binding(get: { model.project.captions.styleId }, set: { model.setStyle($0) })) { Text("Off").tag("off"); ForEach(model.app.styles, id: \.id) { Text($0.name).tag($0.id) } }.labelsHidden().accessibilityLabel("Caption style")
            }
            Toggle("Also save .srt", isOn: binding(\.srt))
            CaptionPropertyRow("Quality", marker: "export.quality") {
                Picker("Quality", selection: binding(\.quality)) { Text("Standard").tag(ExportQuality.standard); Text("High").tag(ExportQuality.high) }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Quality")
            }
            Text("\(output.size.width) × \(output.size.height) · \(output.fps.formatted()) fps").font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            CaptionPropertyRow("Save to", marker: "export.folder") {
                Text(folder.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")).lineLimit(1).truncationMode(.middle).help(folder.path).accessibilityLabel("Save to").accessibilityValue(folder.path)
                Button("Choose…") { chooseFolder() }.accessibilityLabel("Choose export folder")
            }
            CaptionPropertyRow("File name", marker: "export.name") {
                TextField("File name", text: Binding(get: { job.fileNamePattern }, set: { job.fileNamePattern = $0 })).accessibilityLabel("File name pattern")
            }
            Text("{project} · {clip} · {aspect} · .mp4").font(.system(size: 11)).foregroundStyle(.secondary)
            if let disclosure = model.exportDisclosure(targets) { Label(disclosure, systemImage: "waveform").font(.system(size: 11)).accessibilityIdentifier("voxclip.export.aiNotice") }
            if let note = model.captionError { InlineNotice(text: note) }
            if let error = model.exportError { InlineNotice(text: error) }
        }
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if !model.exporting && model.exports.isEmpty {
                Text(model.exportEstimate(targets)).font(.system(size: 11)).foregroundStyle(.secondary)
                Button { model.beginExport(targets: targets, folder: folder) } label: { Text(model.exportPrimaryTitle(targets)).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(model.exportAccessibleName(model.exportPrimaryTitle(targets), targets: targets))
                    .accessibilityIdentifier("voxclip.export.primary").disabled(!model.canExport || targets.isEmpty)
                Button("Cancel") { model.finishExportJob() }
            } else if !model.exporting {
                if model.exportError != nil { Button("Try again") { model.beginExport(targets: targets, folder: folder) } }
                Button("Done") { model.finishExportJob() }.accessibilityIdentifier("voxclip.export.done")
            }
        }.padding(.horizontal, CaptionsPanelMetrics.inset).padding(.bottom, 10)
    }
    private var targets: [ExportTarget] { model.exportTargets(job.scope, requestedIDs: job.requestedIDs) }
    private var output: OutputSpec { ExportFingerprint.output(model.project) }
    private var folder: URL { job.folderOverride ?? ExportSelection.folder(model.project.export.folder ?? model.app.string("export.folder", fallback: "~/Movies/VoxClip")) }
    private func binding<Value>(_ key: WritableKeyPath<ProjectExport, Value>) -> Binding<Value> { Binding(get: { model.project.export[keyPath: key] }, set: { value in var project = model.project; project.export[keyPath: key] = value; model.replace(project, name: "Change export options") }) }
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url { job.folderOverride = nil; var project = model.project; project.export.folder = url.path; model.replace(project, name: "Change export folder") }
    }
    private func openShare(_ destination: String) {
        guard !job.opening else { return }
        job.draft.commit(model: model)
        let caption = job.draft.captionDraft, line = job.draft.addDisclosure ? job.draft.disclosureLine : nil
        copyText(caption); NSWorkspace.shared.activateFileViewerSelecting(model.exports.map(\.outputURL)); job.opening = true
        if destination == "x", job.openedX() { model.announce(ShareDisclosure.xMadeWithAITip) }
        Task {
            defer { job.opening = false }
            do {
                guard let url = try await Task.detached(priority: .userInitiated, operation: { try ShareText.url(destination, caption: caption, disclosureLine: line) }).value,
                      ShareText.allowsOpening(url) else { return }
                NSWorkspace.shared.open(url)
            } catch { model.exportError = await model.app.safeError(error) }
        }
    }
}

@MainActor struct ShareCaptionDraft {
    private(set) var draftTarget: String?
    private(set) var captionDraft = ""
    private(set) var edited = false
    private(set) var disclosureLine: String?
    private(set) var addDisclosure = false
    mutating func load(target: String, model: EditorModel) {
        draftTarget = target; disclosureLine = model.shareDisclosureLine(target); edited = false; addDisclosure = false
        captionDraft = Self.removingLine(disclosureLine, from: SharePostText.capCaption(model.shareCaption(target)))
    }
    mutating func edit(_ value: String) {
        captionDraft = SharePostText.capCaption(value); edited = true
        if addDisclosure, let line = disclosureLine, !ShareDisclosure.isPresent(captionDraft, line: line) { addDisclosure = false }
    }
    mutating func setDisclosure(_ enabled: Bool, format: (String, String?) throws -> String = { try SharePostText.fieldText($0, line: $1) }) {
        addDisclosure = enabled && disclosureLine != nil
        let base = Self.removingLine(disclosureLine, from: captionDraft)
        let line = addDisclosure ? disclosureLine : nil
        // If the shared text rules cannot load, keep the user's opt-in honest. The
        // uncut caption is still available to copy or open in LinkedIn.
        captionDraft = (try? format(base, line)) ?? (line.map { base + "\n\n" + $0 } ?? base)
        edited = true
    }
    private static func removingLine(_ line: String?, from text: String) -> String {
        guard let line, text.contains(line) else { return text }
        return text.replacingOccurrences(of: line, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    mutating func commit(model: EditorModel) {
        guard edited, let target = draftTarget, !model.exports.isEmpty else { return }
        edited = false
        guard target == "full" || model.project.edits.clips.contains(where: { $0.id == target }) else { return }
        guard captionDraft != model.shareCaption(target) else { return }
        var project = model.project; project.share.captions[target] = captionDraft
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
    static func allowsOpening(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && ["x.com", "www.linkedin.com"].contains(url.host?.lowercased() ?? "")
    }
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
        guard !exporting, !targets.isEmpty, canExport, mediaExportable else { return }
        // A new render has a new disclosure snapshot. Keep an edited caption, then
        // lazily load fresh drafts (and the off-default opt-in) from its result.
        exportJob.draft.commit(model: self)
        exportJob.draft = ShareCaptionDraft(); exportJob.drafts = [:]
        exportJob.shareTarget = targets.compactMap { if case .clip(let id) = $0 { return id }; return nil }.first ?? "full"
        exportJob.copied = false; exportJob.showsXTip = false
        let renderSnapshot = renderSnapshot()
        let labelPosition = app.voiceLabLabelPosition
        let snapshot = renderSnapshot.project
        let pattern = exportJob.fileNamePattern.isEmpty ? app.string("export.fileNamePattern", fallback: "{project}-{clip}-{aspect}") : exportJob.fileNamePattern
        let openFolderAfter = app.bool("export.openFolderAfter", fallback: false)
        exportError = nil; exports = []; exportDisclosureLines = [:]; exporting = true; exportStartedAt = Date(); exportIndex = 1
        exportClipIDs = targets.compactMap { if case .clip(let id) = $0 { id } else { nil } }
        activeExportKey = targets.first.map { ExportLedger.key($0, aspect: snapshot.export.aspect) }
        var targetNames: [String: String] = [:]
        for target in targets {
            switch target {
            case .fullEdit: targetNames["full"] = "Full Take"
            case .clip(let id): targetNames[id] = scopeName(id)
            }
        }
        let total = targets.count
        announce(total == 1 ? "Exporting 1 video" : "Exporting \(total) videos")
        exportTask = Task { [weak self] in
            guard let self else { return }
            defer { exporting = false; exportProgress = nil; activeExportKey = nil }
            await app.log.write(LogEntry(level: .info, category: "export", message: "start targets=\(targets.count)"))
            var attempt: ExportRecord?
            do {
                if document.demo { throw VoxClipError.notImplemented("synthetic-preview-only") }
                for (position, target) in targets.enumerated() {
                    try Task.checkCancellation()
                    exportIndex = position + 1
                    let key = ExportLedger.key(target, aspect: snapshot.export.aspect)
                    activeExportKey = key
                    failedExports[key] = nil
                    exportProgress = nil
                    let targetName = targetNames[ExportLedger.targetID(target)] ?? "Full Take"
                    attempt = app.exportLedger.entry(projectID: snapshot.id, targetID: ExportLedger.targetID(target), aspect: snapshot.export.aspect)
                        ?? ExportRecord(projectID: snapshot.id, targetID: ExportLedger.targetID(target), exportedAt: Date(),
                            planFingerprint: "", styleId: snapshot.captions.styleId, aspect: snapshot.export.aspect, outputPath: "", targetName: targetName)
                    attempt?.failed = true
                    attempt?.retryFolder = folder.path
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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
                        planFingerprint: fingerprint, styleId: snapshot.captions.styleId, aspect: snapshot.export.aspect, outputPath: result.outputURL.path,
                        targetName: targetName, durationSeconds: result.durationSeconds, width: result.width, height: result.height,
                        byteSize: (try? result.outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)))
                    attempt = nil
                    activeExportKey = nil
                }
                await app.log.write(LogEntry(level: .info, category: "export", message: "success targets=\(exports.count)"))
                announce("Saved \(exports.count) video\(exports.count == 1 ? "" : "s") to \(FileManager.default.displayName(atPath: folder.path))")
                if openFolderAfter { NSWorkspace.shared.activateFileViewerSelecting(exports.map(\.outputURL)) }
            } catch is CancellationError {
                if let key = activeExportKey { failedExports[key] = folder }
                if let attempt {
                    do { try app.exportLedger.record(attempt) }
                    catch { await app.log.write(LogEntry(level: .error, category: "export", message: "Could not save failed export state")) }
                }
                await app.log.write(LogEntry(level: .info, category: "export", message: "cancelled"))
            } catch VoxClipError.cancelled {
                if let key = activeExportKey { failedExports[key] = folder }
                if let attempt {
                    do { try app.exportLedger.record(attempt) }
                    catch { await app.log.write(LogEntry(level: .error, category: "export", message: "Could not save failed export state")) }
                }
                await app.log.write(LogEntry(level: .info, category: "export", message: "cancelled"))
            } catch {
                if let key = activeExportKey { failedExports[key] = folder }
                if let attempt {
                    do { try app.exportLedger.record(attempt) }
                    catch { await app.log.write(LogEntry(level: .error, category: "export", message: "Could not save failed export state")) }
                }
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

extension EditorModel {
    var exportJobContext: String {
        let ids = exportJob.requestedIDs
        if exportJob.scope == .fullVideo { return "Full Edit" }
        if exportJob.scope == .allClips { return "All Clips" }
        return ids.count == 1 ? scopeName(ids.first) : "\(ids.count) Clips"
    }
    func exportPrimaryTitle(_ targets: [ExportTarget]) -> String {
        if exportError != nil { return "Try again" }
        if targets.count > 1 { return "Export \(targets.count) Clips" }
        if case .clip(let id) = targets.first { return "Export \(scopeName(id))" }
        return "Export Full Edit"
    }
    func exportEstimate(_ targets: [ExportTarget]) -> String {
        let duration = targets.reduce(0.0) { total, target in
            switch target { case .fullEdit: return total + editedDuration(nil)
            case .clip(let id): return total + editedDuration(project.edits.clips.first { $0.id == id }) }
        }
        let output = ExportFingerprint.output(project)
        let bytes = duration * Double(output.videoBitrate + output.audioBitrate) / 8
        return "\(timecode(duration)) · about \(max(1, Int((bytes / 1_000_000).rounded()))) MB · H.264"
    }
}
