import SwiftUI
import Observation
import AVFoundation
import VoxClipCore
import VoxClipMedia

enum WorkspaceLocation: String, CaseIterable { case home = "Home", transcript = "Transcript", clips = "Clips" }

@MainActor @Observable public final class EditorModel {
    let document: VoxClipDocument
    let app: AppModel
    var showInspector = false
    var sidebarVisibility: NavigationSplitViewVisibility = .all
    var windowWidth = 1280.0
    var location: WorkspaceLocation = .transcript
    var importProgress: String?
    var importError: String?
    var selectedWordIDs: Set<String> = []
    var selectedPauseIDs: Set<String> = []
    var previewStop: Double?
    var playhead: Double = 0
    var sourceTime: Double = 0
    var isPlaying = false
    var playbackRate: Float = 1
    var showCuts = true
    var showPauses = true
    var editedTimeline = false
    var findVisible = false
    var query = ""
    var textSize = 17.0
    var error: String?
    var previewError: String?
    var captionError: String?
    var progress: String?
    var showExport = false
    var showTranscribe = false
    var showShortcuts = false
    var correctionID: String?
    var correctionText = ""
    var preset = ClipPresetID.best
    var instruction = ""
    var clipError: String?
    var clipAnswer: String?
    var finding = false
    var exportProgress: ExportProgress?
    var exports: [ExportResult] = []
    var exportError: String?
    var exportClipIDs: [String] = []
    var exporting = false
    func presentExport(clipIDs: [String]? = nil) {
        if !exporting { exports = []; exportError = nil; exportClipIDs = clipIDs ?? activeClip.map { [$0.id] } ?? [] }
        showExport = true
    }
    var exportIndex = 0
    var exportStartedAt: Date?
    var sourceURL: URL { URL(fileURLWithPath: project.media.source.absolutePath) }
    var mediaResolved = false { didSet { document.setMediaResolved(mediaResolved) } }
    var plan: EditPlan?
    var voiceLabPlan: VoiceLabOutputPlan?
    var renderTimeline: RenderTimeline? {
        if let voiceLabPlan { return .voiceLab(voiceLabPlan) }
        return plan.map(RenderTimeline.legacy)
    }
    var pauses: [Pause] = []
    var fillerIDs: Set<String> = []
    var summary = EditSummary()
    var transcriptRevision = 0
    var transcriptLayoutRevision = 0
    var wordIndex: [String: Int] = [:]
    var pauseByAfterIndex: [Int: Pause] = [:]
    var pauseIndex: [String: Pause] = [:]
    var cutWordIDs: Set<String> = []
    var cutPauseIDs: Set<String> = []
    var scopeBounds: ClosedRange<Int>?
    var editingAvailable = false
    var timeline = TimelineProjection()
    @ObservationIgnored private var renderedTranscript: Transcript?
    @ObservationIgnored private var renderedEdits: ProjectEdits?
    @ObservationIgnored private var renderedMedia: ProjectMedia?
    @ObservationIgnored private var renderedVoiceLab: ProjectVoiceLab?
    @ObservationIgnored private var fillerCandidateIDs: Set<String> = []
    @ObservationIgnored private var planningSegments: [EditSegment]?
    @ObservationIgnored private var planningWordIndex: [String: Int] = [:]
    @ObservationIgnored private var summaryCache: [(edits: ProjectEdits, summary: EditSummary)] = []
    @ObservationIgnored weak var undoManager: UndoManager? { didSet { undoManager?.levelsOfUndo = 500 } }
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var history: EditHistory?
    @ObservationIgnored let preview: any PreviewEngine
    @ObservationIgnored let nativePreview: PreviewPlayerController?
    @ObservationIgnored let exporter: any Exporter
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var previewRevision: UInt64 = 0
    @ObservationIgnored var workTask: Task<Void, Never>?
    @ObservationIgnored var exportTask: Task<Void, Never>?
    @ObservationIgnored var findTask: Task<Void, Never>?
    @ObservationIgnored var importTask: Task<Void, Never>?
    @ObservationIgnored private var initialised = false

    init(document: VoxClipDocument, app: AppModel, preview: (any PreviewEngine)? = nil, exporter: any Exporter = ExportQueue()) {
        self.document = document
        self.app = app
        self.exporter = exporter
        location = document.project.media.source.absolutePath == "/" ? .home : .transcript
        mediaResolved = document.demo
        if let preview { self.preview = preview; nativePreview = nil }
        else {
            let native = PreviewPlayerController()
            self.preview = native; nativePreview = native
        }
        textSize = app.number("general.transcriptTextSize", fallback: 17)
    }

    var project: Project { document.project }
    var isHome: Bool { project.media.source.absolutePath == "/" }
    var words: [TimedWord] { project.transcript?.words ?? [] }
    var activeClip: ClipRange? { project.edits.clips.first { $0.id == project.edits.activeClipId } }
    var sortedClips: [ClipRange] {
        project.edits.clips.enumerated().sorted {
            let first = index($0.element.startWordId) ?? 0, second = index($1.element.startWordId) ?? 0
            return first == second ? $0.offset < $1.offset : first < second
        }.map(\.element)
    }
    var selectedIDs: [String] { words.filter { selectedWordIDs.contains($0.id) }.map(\.id) }
    var sourceDuration: Double { project.media.source.durationSeconds }
    var duration: Double { renderTimeline?.duration ?? sourceDuration }
    var subtitle: String {
        if exporting { return "Rendering \(exportIndex) of \(max(1, exportClipIDs.count))" }
        if let progress { return progress }
        if !editingAvailable && !words.isEmpty { return "Editing is not available in this build. Your video and edits are still here." }
        if voiceLabPlan == nil && !summary.canExport && !words.isEmpty { return "Keep at least one word before exporting." }
        return "\(timecode(duration)) after cuts · " + Self.summaryText(summary)
    }
    static func summaryText(_ summary: EditSummary) -> String {
        summary.hasEdits ? "\(summary.cutWordCount) \(summary.cutWordCount == 1 ? "word" : "words") and \(summary.cutPauseCount) \(summary.cutPauseCount == 1 ? "pause" : "pauses") cut." : "No cuts yet."
    }
    var canExport: Bool { mediaResolved && !exporting && (voiceLabPlan.map { $0.outputSamples > 0 } ?? (words.isEmpty ? sourceDuration > 0 : editingAvailable && summary.canExport)) }
    var playingWordID: String? {
        let transcript = words
        var lower = 0, upper = transcript.count
        while lower < upper { let middle = (lower + upper) / 2; if transcript[middle].start <= sourceTime { lower = middle + 1 } else { upper = middle } }
        return lower > 0 && sourceTime < transcript[lower - 1].end ? transcript[lower - 1].id : nil
    }
    func index(_ id: String) -> Int? { wordIndex[id] }
    func text(_ word: TimedWord) -> String { project.edits.corrections[word.id] ?? word.text }
    func scopeContains(_ id: String) -> Bool {
        guard let scopeBounds else { return true }
        return wordIndex[id].map(scopeBounds.contains) ?? false
    }
    func start() async {
        guard !initialised else { return }
        initialised = true
        await document.reportWarnings(to: app.log)
        app.openProjectKeys[project.id] = project.media.source.contentKey
        eventTask = Task { [weak self, preview] in
            for await event in preview.events {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .time(let edited, let source):
                    playhead = edited; sourceTime = source
                    if let stop = previewStop, source >= stop { preview.pause(); previewStop = nil }
                case .playing(let playing): isPlaying = playing
                case .failed(let error): previewError = await app.safeError(error)
                case .frame: break
                }
            }
        }
        if !document.demo && sourceURL.path != "/" {
            do {
                let url = try await resolveMediaIdentity()
                var changed = project
                let probe = try await AVMediaProbe().probe(url)
                if document.fileURL == nil {
                    changed.media.source.durationSeconds = probe.durationSeconds
                    changed.media.source.video = probe.video; changed.media.source.audio = probe.audio
                    document.replaceProject(changed)
                }
            } catch { previewError = await app.safeError(error) }
        }
        refresh()
        if mediaResolved { await updatePreview(load: true) }
    }
    func close() {
        previewRevision &+= 1
        workTask?.cancel(); exportTask?.cancel(); findTask?.cancel(); importTask?.cancel(); eventTask?.cancel(); updateTask?.cancel(); preview.close()
        if app.activeHome === self { app.activeHome = nil }
        app.openProjectKeys[project.id] = nil
    }
    func reloadFromDocument(previousProjectID: String) {
        app.openProjectKeys[previousProjectID] = nil
        workTask?.cancel(); exportTask?.cancel(); findTask?.cancel(); importTask?.cancel(); updateTask?.cancel()
        preview.pause(); isPlaying = false; previewStop = nil
        history = nil
        renderedTranscript = nil; renderedEdits = nil; renderedMedia = nil; renderedVoiceLab = nil
        planningSegments = nil; planningWordIndex = [:]; summaryCache.removeAll()
        selectedWordIDs = []; selectedPauseIDs = []; correctionID = nil
        clipAnswer = nil; clipError = nil; error = nil; previewError = nil
        mediaResolved = document.demo
        location = isHome ? .home : .transcript
        refresh()
        updateTask = Task { [weak self] in
            guard let self, !isHome else { return }
            do {
                _ = try await resolveMediaIdentity()
                await updatePreview(load: true)
            } catch is CancellationError {} catch { previewError = await app.safeError(error) }
        }
    }
    func closeEmptyWindow() { if isHome { window?.performClose(nil) } }
    func importVideo(_ url: URL) async {
        guard isHome, importProgress == nil else { return }
        importProgress = "Importing video…"
        importError = nil
        defer { importProgress = nil }
        do {
            let imported = try await importedDocument(url, app: app)
            let probe = try await AVMediaProbe().probe(url)
            try Task.checkCancellation()
            guard isHome else { return }
            var next = imported.project
            next.media.source.durationSeconds = probe.durationSeconds
            next.media.source.video = probe.video
            next.media.source.audio = probe.audio
            app.openProjectKeys[project.id] = nil
            document.replaceProject(next)
            recordDocumentChange()
            mediaResolved = true
            app.openProjectKeys[next.id] = next.media.source.contentKey
            if app.activeHome === self { app.activeHome = nil }
            location = .transcript
            refresh()
            await updatePreview(load: true)
        } catch is CancellationError {
        } catch { importError = await app.safeError(error) }
    }
    func editState() -> EditState? {
        let project = project
        guard let transcript = project.transcript else { return nil }
        let edits = project.edits
        return EditState(transcript: transcript, pauses: pauses, pauseThresholdSeconds: edits.pauseThresholdSeconds, pauseKeepSeconds: edits.pauseKeepSeconds, cutWordIds: Set(edits.cutWordIds), cutPauseIds: Set(edits.cutPauseIds), corrections: edits.corrections, clips: edits.clips, activeClipId: edits.activeClipId)
    }
    func refresh() {
        let project = project
        let words = project.transcript?.words ?? []
        let edits = project.edits
        let transcriptChanged = renderedTranscript != project.transcript
        let editChanged = renderedEdits != edits
        guard transcriptChanged || editChanged || renderedMedia != project.media || renderedVoiceLab != project.voiceLab || renderedEdits == nil else { return }
        if transcriptChanged || renderedEdits?.corrections != edits.corrections {
            transcriptLayoutRevision += 1
            fillerCandidateIDs = Set(words.filter { word in
                word.kind == .unlabeledSpeech || word.kind == .word && (try? isFillerText(edits.corrections[word.id] ?? word.text)) == true
            }.map(\.id))
        }
        if transcriptChanged {
            summaryCache.removeAll(keepingCapacity: true)
            wordIndex = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($0.element.id, $0.offset) })
        }
        if transcriptChanged || renderedEdits?.pauseThresholdSeconds != edits.pauseThresholdSeconds {
            pauses = (try? detectPauses(words, thresholdSeconds: edits.pauseThresholdSeconds)) ?? []
            pauseByAfterIndex = Dictionary(uniqueKeysWithValues: pauses.map { ($0.afterIndex, $0) })
            pauseIndex = Dictionary(uniqueKeysWithValues: pauses.map { ($0.id, $0) })
        }
        cutWordIDs = Set(edits.cutWordIds); cutPauseIDs = Set(edits.cutPauseIds)
        let activeClip = edits.clips.first { $0.id == edits.activeClipId }
        if let clip = activeClip, let lower = index(clip.startWordId), let upper = index(clip.endWordId), lower <= upper { scopeBounds = lower...upper }
        else { scopeBounds = nil }
        fillerIDs = fillerCandidateIDs.subtracting(cutWordIDs).filter { id in
            guard let scopeBounds else { return true }
            return wordIndex[id].map(scopeBounds.contains) ?? false
        }
        let state = editState()
        if history == nil, let state { history = EditHistory(state: state) }
        let coreSummary = summaryCache.first { $0.edits == edits }?.summary ?? state?.summary
        editingAvailable = coreSummary != nil
        summary = coreSummary ?? EditSummary()
        if let coreSummary, !summaryCache.contains(where: { $0.edits == edits }) {
            summaryCache.append((edits, coreSummary))
            if summaryCache.count > 16 { summaryCache.removeFirst() }
        }
        do {
            voiceLabPlan = try VoiceLabRenderPreflight.prepare(project: project,
                scope: activeClip.map { .clip($0.id) } ?? .full,
                paidRoot: app.locations.root.appendingPathComponent("VoiceLab", isDirectory: true))?.prepared.outputPlan
            if let state {
                var comparable = edits
                comparable.cutWordIds = renderedEdits?.cutWordIds ?? []
                let segments: [EditSegment]
                if !transcriptChanged, activeClip == nil, comparable == renderedEdits, var cached = planningSegments {
                    let changed = state.cutWordIds.symmetricDifference(renderedEdits.map { Set($0.cutWordIds) } ?? [])
                    for id in changed {
                        if let position = planningWordIndex[id] { cached[position].cut = state.cutWordIds.contains(id) }
                    }
                    segments = cached
                } else {
                    segments = try buildSegments(state, activeClip: activeClip)
                    planningWordIndex = Dictionary(uniqueKeysWithValues: segments.enumerated().filter { $0.element.kind == .word }.map { ($0.element.id, $0.offset) })
                }
                planningSegments = segments
                plan = try buildEditPlan(segments, duration: sourceDuration, sampleRate: Double(project.media.source.audio?.sampleRate ?? 48_000), pauseKeepSeconds: edits.pauseKeepSeconds)
            } else { planningSegments = nil; planningWordIndex = [:]; plan = Self.uncutPlan(duration: sourceDuration) }
        } catch {
            plan = nil; voiceLabPlan = nil
            previewError = UserMessages.message(error)
        }
        renderedTranscript = project.transcript; renderedEdits = edits; renderedMedia = project.media
        renderedVoiceLab = project.voiceLab
        transcriptRevision += 1
        timeline = TimelineProjection(model: self)
    }
    func word(at source: Double, nearest: Bool = false) -> TimedWord? {
        let words = words
        var lower = 0, upper = words.count
        while lower < upper { let middle = (lower + upper) / 2; if words[middle].start <= source { lower = middle + 1 } else { upper = middle } }
        if nearest {
            if lower == 0 { return words.first }
            if lower == words.count { return words.last }
            return source - words[lower - 1].start <= words[lower].start - source ? words[lower - 1] : words[lower]
        }
        return lower > 0 && source <= words[lower - 1].end ? words[lower - 1] : nil
    }
    func pause(at source: Double) -> Pause? {
        var lower = 0, upper = pauses.count
        while lower < upper { let middle = (lower + upper) / 2; if pauses[middle].start <= source { lower = middle + 1 } else { upper = middle } }
        return lower > 0 && source <= pauses[lower - 1].end ? pauses[lower - 1] : nil
    }
    static func uncutPlan(duration: Double) -> EditPlan {
        let total = Int64(max(0, duration) * 48_000)
        return EditPlan(sampleRate: 48_000, totalSamples: total, cuts: [], kept: total > 0 ? [MediaInterval(startSample: 0, endSample: total)] : [])
    }
    func replace(_ newProject: Project, name: String) {
        guard mediaResolved || name == "Locate media" else { return }
        guard newProject != project else { return }
        preview.pause(); isPlaying = false
        let previous = project
        let mediaChanged = previous.media.source != newProject.media.source
        undoManager?.registerUndo(withTarget: self) { model in model.replace(previous, name: name) }
        undoManager?.setActionName(name)
        var changed = newProject
        changed.modifiedAt = Date()
        document.replaceProject(changed)
        recordDocumentChange()
        error = nil
        refresh()
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            guard let self else { return }
            do {
                if mediaChanged, !document.demo {
                    mediaResolved = false
                    _ = try await resolveMediaIdentity()
                }
                try await Task.sleep(for: .milliseconds(150))
                await updatePreview(load: mediaChanged)
            } catch is CancellationError {} catch { previewError = await app.safeError(error) }
        }
    }
    private func recordDocumentChange() {
        document.updateChangeCount(undoManager?.isUndoing == true ? .changeUndone : undoManager?.isRedoing == true ? .changeRedone : .changeDone)
    }
    func resolveMediaIdentity() async throws -> URL {
        let reference = project.media.source
        let resolved = try await app.projectStore.resolveSource(for: project, projectURL: document.fileURL ?? sourceURL.deletingLastPathComponent().appendingPathComponent("Untitled.voxclip"))
        try Task.checkCancellation()
        guard project.media.source == reference else { throw CancellationError() }
        if reference.absolutePath != resolved.path {
            var changed = project
            changed.media.source.absolutePath = resolved.path
            document.replaceProject(changed)
            document.markEdited()
        }
        mediaResolved = true
        app.openProjectKeys[project.id] = reference.contentKey
        return resolved
    }
    func apply(_ command: EditCommand, name: String, base: Project? = nil) {
        guard mediaResolved else { return }
        guard let state = editState() else { return }
        preview.pause(); isPlaying = false
        var next = base ?? project
        if history?.state != state { history = EditHistory(state: state) }
        history?.apply(command, aiResults: next.ai.results)
        guard let changed = history?.state else { return }
        guard changed != state || next != project else { return }
        next.edits = changed.projectEdits
        let clipIDs = Set(changed.clips.map(\.id))
        next.share.captions = next.share.captions.filter { $0.key == "full" || clipIDs.contains($0.key) }
        replace(next, name: name)
        if case .addAIClips = command, changed == state { clipError = "These clips are already in the list." }
        announce(announcement(command, before: state, after: changed, fallback: name))
    }
    func announcement(_ command: EditCommand, before: EditState, after: EditState, fallback: String) -> String {
        if case .restoreCuts = command { return "Restored all cuts, corrections kept" }
        let added = after.cutWordIds.subtracting(before.cutWordIds)
        let restored = before.cutWordIds.subtracting(after.cutWordIds)
        let ids = added.isEmpty ? restored : added
        let verb = added.isEmpty ? "Restored" : "Cut"
        if ids.count == 1, let id = ids.first, let position = index(id) { return "\(verb) '\(text(words[position]))'" }
        if !ids.isEmpty { return "\(verb) \(ids.count) words" }
        let pauses = after.cutPauseIds.symmetricDifference(before.cutPauseIds).count
        if pauses > 0 { return "\(after.cutPauseIds.count > before.cutPauseIds.count ? "Cut" : "Restored") \(pauses) \(pauses == 1 ? "pause" : "pauses")" }
        return fallback
    }
    func cutSelection(restore: Bool = false) {
        let ids = selectedIDs + selectedPauseIDs.sorted()
        guard !ids.isEmpty else { return }
        let restore = restore || ids.allSatisfy { project.edits.cutWordIds.contains($0) || project.edits.cutPauseIds.contains($0) }
        apply(restore ? .restoreSelection(ids: ids) : .cutSelection(ids: ids), name: restore ? "Restore selection" : "Cut selection")
    }
    func makeClip() {
        guard let start = selectedIDs.first, let end = selectedIDs.last else { return }
        guard !project.edits.clips.contains(where: { $0.startWordId == start && $0.endWordId == end }) else { location = .clips; return }
        let title = words.filter { selectedWordIDs.contains($0.id) }.prefix(7).map { text($0) }.joined(separator: " ")
        apply(.addClip(ClipRange(id: UUID().uuidString.lowercased(), startWordId: start, endWordId: end, title: Self.clipTitle(title))), name: "Make clip from selection")
        location = .clips
    }
    func nudge(_ clip: ClipRange, start: Bool, offset: Int) {
        guard let lower = index(clip.startWordId), let upper = index(clip.endWordId) else { return }
        apply(.updateClip(id: clip.id, startIndex: start ? min(upper, max(0, lower + offset)) : lower, endIndex: start ? upper : max(lower, min(words.count - 1, upper + offset))), name: "Nudge clip edge")
    }
    func setClipEdge(start: Bool) {
        guard let clip = activeClip, let id = selectedIDs.first, let caret = index(id), let lower = index(clip.startWordId), let upper = index(clip.endWordId) else { return }
        guard start ? caret <= upper : caret >= lower else { return }
        apply(.updateClip(id: clip.id, startIndex: start ? caret : lower, endIndex: start ? upper : caret), name: "Set clip edge")
    }
    func activate(_ clip: ClipRange?) {
        apply(.setActiveClip(clipId: clip?.id), name: "Preview clip")
        if let clip, let word = words.first(where: { $0.id == clip.startWordId }) { seek(source: word.start) }
    }
    func moveClip(_ direction: Int) {
        guard !sortedClips.isEmpty else { return }
        let position = sortedClips.firstIndex { $0.id == activeClip?.id } ?? (direction > 0 ? -1 : sortedClips.count)
        activate(sortedClips[min(sortedClips.count - 1, max(0, position + direction))])
    }
    func removeClip(_ id: String) {
        apply(.removeClip(id: id), name: "Remove clip")
    }
    func beginCorrection() {
        guard let id = selectedIDs.first, let word = words.first(where: { $0.id == id }) else { return }
        correctionID = id; correctionText = text(word)
    }
    func saveCorrection(advance: Bool = false) {
        guard let id = correctionID else { return }
        let text = correctionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\n"), text.unicodeScalars.count <= EditingLimits.maxCorrectionScalars else { return }
        apply(.correct(id: id, text: text), name: "Correct spelling")
        correctionID = nil
        if advance, let position = index(id), position + 1 < words.count { selectedWordIDs = [words[position + 1].id]; beginCorrection() }
    }
    func select(_ id: String, extend: Bool = false) {
        selectedPauseIDs = []
        if extend, let anchor = selectedIDs.first, let lower = index(anchor), let upper = index(id) { selectedWordIDs = Set(words[min(lower, upper)...max(lower, upper)].map(\.id)) }
        else { selectedWordIDs = [id] }
        if !isPlaying, let word = words.first(where: { $0.id == id }) { seek(source: word.start) }
    }
    func step(_ offset: Int, extend: Bool = false, sentence: Bool = false) {
        guard !words.isEmpty else { return }
        var position = index(selectedIDs.last ?? "") ?? 0
        repeat { position = min(words.count - 1, max(0, position + offset)) }
        while sentence && position > 0 && position < words.count - 1 && !words[max(0, position - 1)].text.hasSuffix(".")
        select(words[position].id, extend: extend)
    }
    func seek(source: Double) {
        guard let renderTimeline else { return }
        let time = renderTimeline.mapTime(source)
        Task { [weak self] in
            guard let self else { return }
            do { try await preview.seek(to: time, exact: true); playhead = time; sourceTime = source }
            catch { previewError = await app.safeError(error) }
        }
    }
    func transport(_ key: String, shift: Bool = false) {
        guard correctionID == nil else { return }
        switch key.lowercased() {
        case " ":
            if shift, let word = words.first(where: { selectedWordIDs.contains($0.id) }) { seek(source: word.start) }
            if isPlaying { preview.pause() } else { preview.play() }
            isPlaying = preview.isPlaying
        case "j": seek(source: max(0, sourceTime - 3))
        case "k": preview.pause(); isPlaying = false; playbackRate = 1; previewStop = nil
        case "l": playbackRate = isPlaying ? (playbackRate == 1 ? 1.5 : 2) : 1; preview.play(); nativePreview?.player.rate = playbackRate; isPlaying = preview.isPlaying
        case "p": if let word = words.first(where: { selectedWordIDs.contains($0.id) }), let last = words.last(where: { selectedWordIDs.contains($0.id) }) { previewStop = min(sourceDuration, last.end + 2); seek(source: max(0, word.start - 2)); preview.play(); isPlaying = preview.isPlaying }
        case "c", "\r": beginCorrection()
        case "i": setClipEdge(start: true)
        case "o": setClipEdge(start: false)
        case "[": moveClip(-1)
        case "]": moveClip(1)
        case "\u{1b}": activate(nil)
        default: break
        }
    }
    func findNext(backward: Bool = false) {
        let matches = words.filter { text($0).localizedCaseInsensitiveContains(query) }
        guard !query.isEmpty, !matches.isEmpty else { return }
        let current = matches.firstIndex { selectedWordIDs.contains($0.id) } ?? (backward ? 0 : -1)
        select(matches[(current + (backward ? -1 : 1) + matches.count) % matches.count].id)
    }
    func cutMatches() { let ids = words.filter { text($0).localizedCaseInsensitiveContains(query) }.map(\.id); apply(.cutSelection(ids: ids), name: "Cut all matches") }
    func setStyle(_ id: String) { var next = project; next.captions.styleId = id; replace(next, name: "Change caption style") }
    func setAspect(_ aspect: AspectRatio) { var next = project; next.export.aspect = aspect; replace(next, name: "Change aspect") }
    var captionPreset: AspectRatio {
        let size = outputSpec().size
        if 16 * size.width == 9 * size.height { return .portrait }
        if 9 * size.width == 16 * size.height { return .landscape }
        if size.width == size.height { return .square }
        return .source
    }
    func zoom(_ amount: Double) { textSize = min(28, max(13, amount == 0 ? 17 : textSize + amount)); app.set("general.transcriptTextSize", .number(textSize)); transcriptRevision += 1 }
    func copySelection() { copyText(words.filter { selectedWordIDs.contains($0.id) }.map { text($0) }.joined(separator: " ")) }
    func announce(_ message: String) { NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue]) }
    static func clipTitle(_ title: String) -> String {
        String(String.UnicodeScalarView(title.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.prefix(EditingLimits.maxClipTitleScalars)))
    }
    func renderRequest(target: ExportTarget? = nil) async throws -> RenderRequest {
        let project = project
        let state = editState()
        let clip: ClipRange?
        switch target {
        case nil: clip = state?.activeClip
        case .fullEdit: clip = nil
        case .clip(let id):
            guard let selected = project.edits.clips.first(where: { $0.id == id }) else {
                throw VoxClipError.exportFailed("Clip no longer exists")
            }
            clip = selected
        }
        let voiceLab = try VoiceLabRenderPreflight.prepare(project: project,
            scope: clip.map { .clip($0.id) } ?? .full,
            paidRoot: app.locations.root.appendingPathComponent("VoiceLab", isDirectory: true))
        if clip != nil && state == nil { throw VoxClipError.exportFailed("Clip transcript is unavailable") }
        let segments = try state.map { try buildSegments($0, activeClip: clip) }
        var plan = plan
        if target != nil || voiceLab != nil, let state, let segments {
            plan = try buildEditPlan(segments, duration: sourceDuration, sampleRate: Double(project.media.source.audio?.sampleRate ?? 48_000), pauseKeepSeconds: state.pauseKeepSeconds)
        }
        guard let plan else { throw VoxClipError.exportFailed("Could not build the edit plan") }
        guard (voiceLab?.prepared.outputPlan.outputSamples ?? plan.outputSamples) > 0 else { throw VoxClipError.everythingCut }
        let output = outputSpec()
        let layout = try await buildCaptions(segments: segments, plan: plan, output: output, forPreview: target == nil,
                                            project: project, voiceLab: voiceLab?.prepared.outputPlan)
        try Task.checkCancellation()
        return RenderRequest(sourceURL: URL(fileURLWithPath: project.media.source.absolutePath), plan: plan, captions: layout?.track ?? CaptionTrack(),
            output: output, forPreview: target == nil, captionLayout: layout, voiceLab: voiceLab)
    }
    func buildCaptions(segments: [EditSegment]?, plan: EditPlan, output: OutputSpec, forPreview: Bool,
                       project: Project, voiceLab: VoiceLabOutputPlan?) async throws -> CaptionLayoutResult? {
        guard let segments else { return nil }
        let style = app.styles.first { $0.id == project.captions.styleId }
        do {
            let layout = try await app.captions.layout(AppCaptionLayoutInput(segments: segments, settings: project.captions, plan: plan, output: output, language: project.transcript?.language, style: style, voiceLab: voiceLab))
            captionError = app.captions.rejectedOverrides ? "These caption settings could not be applied." : nil
            return layout
        } catch is CancellationError { throw CancellationError() }
        catch {
            captionError = "Captions are not available in this build. Your video and edits are still here."
            if !forPreview || voiceLab != nil { throw error }
            return nil
        }
    }
    func captionTileInput(_ style: CaptionStyle) -> CaptionTileInput {
        let position = word(at: sourceTime).flatMap { index($0.id) } ?? 0
        let sample = words.dropFirst(position).filter { !cutWordIDs.contains($0.id) }.prefix(6).map(text)
        let placement = style.position.userDraggable ? project.captions.positionByAspect[captionPreset.rawValue] ?? project.captions.position : nil
        return CaptionTileInput(state: editState(), plan: plan, style: style, sampleWords: sample, language: project.transcript?.language, frame: outputSpec().size, overrides: project.captions.overrides, position: placement, sourceURL: sourceURL, sourceTime: sourceTime)
    }
    func outputSpec() -> OutputSpec {
        let video = project.media.source.video
        let oriented = video.map(OutputSizing.orientedSize) ?? PixelSize(width: 1920, height: 1080)
        let size = (try? OutputSizing.outputSize(source: oriented, aspect: project.export.aspect)) ?? PixelSize(width: 1920, height: 1080)
        let fps = (try? OutputSizing.outputFrameRate(nominal: video?.frameRate ?? 30)) ?? 30
        return OutputSpec(size: size, fps: fps,
            videoBitrate: OutputSizing.videoBitrate(size: size, aspect: project.export.aspect, quality: project.export.quality, fps: fps),
            quality: project.export.quality)
    }
    func updatePreview(load: Bool) async {
        guard mediaResolved else { return }
        previewRevision &+= 1
        let revision = previewRevision
        do {
            let request = try await renderRequest()
            guard revision == previewRevision, !Task.isCancelled else { return }
            if load { try await preview.load(request) } else { try await preview.update(request) }
            guard revision == previewRevision, !Task.isCancelled else { return }
            previewError = nil
        } catch is CancellationError {} catch {
            guard revision == previewRevision, !Task.isCancelled else { return }
            preview.close(); isPlaying = false; previewStop = nil
            let message = await app.safeError(error)
            guard revision == previewRevision, !Task.isCancelled else { return }
            previewError = message
        }
    }
}

@MainActor func copyText(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
