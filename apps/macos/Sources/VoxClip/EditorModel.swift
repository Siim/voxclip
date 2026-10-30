import SwiftUI
import Observation
import AVFoundation
import VoxClipCore
import VoxClipMedia

struct EditorRenderSnapshot {
    let project: Project
    let state: EditState?
    let plan: EditPlan?
}

@MainActor @Observable public final class EditorModel {
    let document: VoxClipDocument
    let app: AppModel
    var showFindClips = false
    var findClipsAnchor = FindClipsAnchor.toolbar
    /// The sidebar's "Choose how VoxClip finds clips…" callout (no connector chosen).
    var showAISetup = false
    var selectedWordIDs: Set<String> = [] { didSet { if selectedWordIDs != oldValue { rewriteOpenTask?.cancel() } } }
    var selectedPauseIDs: Set<String> = [] { didSet { if selectedPauseIDs != oldValue { rewriteOpenTask?.cancel() } } }
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
    var textSize = DesignValues.transcriptTextSize
    var error: String?
    var previewError: String?
    var captionError: String?
    var progress: String?
    /// Transcription's completed fraction while `progress` shows a percentage.
    var progressFraction: Double?
    /// Transcription's stage while it runs, for the media chips (design §5.4.8).
    var progressStage: MediaTranscriptionStage?
    /// The running transcription as a media status (design §5.4.4 d), or nil.
    var transcriptionStatus: MediaStatus? {
        guard progress != nil, let progressStage else { return nil }
        return .transcribing(fraction: progressStage == .transcribing ? progressFraction : nil, stage: progressStage)
    }
    var showExport = false
    var showTranscribe = false
    var correctionID: String?
    var correctionText = ""
    var rewriteRange: ClosedRange<Int>?
    var rewrite: RewriteSession?
    var focusedPane = EditorPane.transcript
    var paneFocusRequest = 0
    var scopeScrollRevision = 0
    var lastStyleId: String?
    @ObservationIgnored private var galleryKey = ""
    @ObservationIgnored private var galleryPages: [String: CaptionGalleryPages] = [:]
    var showVoiceLabOptIn = false
    var rewriteInsertionAfterID: String?
    @ObservationIgnored var rewriteOpenTask: Task<Void, Never>?
    private var pendingRewriteSelection: Set<String> = []
    func beginRewrite(inserting: Bool = false, entry: RewriteEntry = .selection) {
        let action = RewriteEntryPolicy.resolve(inserting ? .insertWords : entry, enabled: app.bool("voiceLab.enabled"),
            noticeAccepted: app.bool("voiceLab.betaNoticeAccepted"), editable: capabilities.ai, selection: !selectedIDs.isEmpty)
        if action == .turnOnVoiceLab { pendingRewriteSelection = selectedWordIDs; showVoiceLabOptIn = true; return }
        guard action == .openPassage, let first = selectedIDs.first, let last = selectedIDs.last,
              let lower = index(first), let upper = index(last) else { return }
        closeRewrite(returnFocus: false)
        let snapshot = project
        let selection = selectedWordIDs
        let pauses = selectedPauseIDs
        let caret = sourceTime
        let signature = rewriteConnectorSignature
        rewriteOpenTask = Task { [weak self] in
            guard let self else { return }
            if waveform == nil { await loadWaveform() }
            guard !Task.isCancelled, capabilities.ai, app.voiceLabRewriteEnabled, project == snapshot,
                  selectedWordIDs == selection, selectedPauseIDs == pauses, sourceTime == caret,
                  rewriteConnectorSignature == signature else { return }
            let provider = app.providers.first { $0.id == app.string("llm.connector") }
            let connector: RewriteConnector? = provider.map { (provider: ProviderChoice) -> RewriteConnector in
                RewriteConnector(connector: app.connector(provider.id), model: app.string("llm.model.\(provider.id)", fallback: provider.defaultModel ?? ""),
                    name: provider.label, group: provider.group, plan: provider.id == "codex" ? "ChatGPT plan" : "Claude plan")
            }
            let envelope = waveform.map { AudioEnvelope(sampleRate: Double(project.media.source.audio?.sampleRate ?? 48_000), levels: $0.fine) }
            rewriteRange = lower...upper
            rewrite = RewriteSession(editor: self, range: lower...upper, envelope: envelope, connector: connector,
                consent: { [weak self] in
                    guard let self, let provider else { return false }
                    return await self.rewriteConsent(provider: provider, signature: signature, snapshot: snapshot)
                }, connectorIsCurrent: { [weak self] in self?.rewriteConnectorSignature == signature })
            if app.shell.editor === self, !app.shell.viewerVisible { app.shell.toggleViewer() }
            transcriptRevision += 1
        }
    }
    var rewriteConnectorSignature: [String] {
        let id = app.string("llm.connector")
        return [id, app.string("llm.model.\(id)"), app.string("llm.baseUrl.\(id)"), app.string("llm.cliPath.\(id)")]
    }
    func closeRewrite(returnFocus: Bool = true) {
        rewriteOpenTask?.cancel(); rewrite?.close(); rewrite = nil; rewriteRange = nil
        transcriptRevision += 1
        if returnFocus { _ = focusTranscript(in: window) }
    }
    private func rewriteConsent(provider: ProviderChoice, signature: [String], snapshot: Project) async -> Bool {
        guard capabilities.edit, project == snapshot, rewriteConnectorSignature == signature else { return false }
        guard let connector = rewrite?.connector?.connector else { return false }
        do {
            return try await app.authorizeConnectorRequest(provider, connector: connector, action: .rewrite,
                wordCount: rewrite?.source.filter { $0.kind == .word }.count ?? 0, parent: window) { [self] in
                    capabilities.edit && project == snapshot && rewriteConnectorSignature == signature && rewrite?.isOpen == true
                }
        } catch is CancellationError { return false } catch {
            rewrite?.setReadinessProblem(await app.safeError(error, context: "ai:Rewrite"))
            return false
        }
    }
    func enableVoiceLab() {
        app.set("voiceLab.betaNoticeAccepted", .bool(true))
        app.set("voiceLab.enabled", .bool(true))
        showVoiceLabOptIn = false
        guard selectedWordIDs == pendingRewriteSelection else { return }
        beginRewrite(entry: .menu)
    }
    var preset = ClipPresetID.best
    var instruction = ""
    var clipError: String?
    /// "Answered by {fallback} because {model} was busy." after a Find Clips run that
    /// used the fallback model (ai.md §4.3), shown under the Suggested header.
    var fallbackNote: String?
    /// The suggestion that has keyboard focus after Find Clips, without being selected
    /// (design §6.2): Return keeps it and ⌫ dismisses it.
    var focusedSuggestion: String?
    var finding = false
    var exportProgress: ExportProgress?
    var exports: [ExportResult] = []
    var exportError: String?
    var exportClipIDs: [String] = []
    var activeExportKey: String?
    var failedExports: [String: URL] = [:]
    var exporting = false
    func presentExport(clipIDs: [String]? = nil) {
        guard capabilities.writable, mediaExportable else { return }
        if !exporting { exports = []; exportError = nil; exportClipIDs = clipIDs ?? activeClip.map { [$0.id] } ?? [] }
        showExport = true
    }
    var exportIndex = 0
    var exportStartedAt: Date?
    var sourceURL: URL { URL(fileURLWithPath: project.media.source.absolutePath) }
    var mediaResolved = false { didSet { document.setMediaResolved(mediaResolved); if !mediaResolved { closeRewrite(returnFocus: false) } } }
    /// The project has a transcript. Unlike `project`, views observe it, so a transcript
    /// that arrives or is undone redraws the transcript column.
    private(set) var transcribed = false
    /// Bumped by every refresh that finds the project changed. Views that derive what they
    /// show from `project`, which they can't observe, read it (the toolbar's Export).
    private(set) var projectRevision = 0
    /// The video is there but can't be read (design §5.4.4 f, corrupt file).
    var mediaUnreadable = false { didSet { if mediaUnreadable { closeRewrite(returnFocus: false) } } }
    var canMoveCaptions: Bool {
        !document.demo && capabilities.captionPosition && !mediaUnreadable && (previewError == nil || !mediaResolved)
    }
    /// The open project's media state for its stand-ins and Export (design §5.4.4).
    var mediaStatus: MediaStatus {
        if let transcriptionStatus { return transcriptionStatus }
        if document.demo { return .demo }
        if !mediaResolved { return .missing }
        if mediaUnreadable { return .unreadable }
        return project.media.source.video == nil ? .audioOnly : .none
    }
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
    var waveform: WaveformData?
    var waveformRevision = 0
    var waveformKey: WaveformCache.Key? {
        guard !document.demo, mediaResolved, !mediaUnreadable, project.media.source.audio != nil else { return nil }
        return WaveformCache.Key(contentKey: project.media.source.contentKey, source: sourceURL, cache: app.locations.cache)
    }
    func loadWaveform() async {
        let key = waveformKey
        let value = if let key { await WaveformCache.shared.load(key) } else { nil as WaveformData? }
        guard !Task.isCancelled, key == waveformKey else { return }
        waveform = value; waveformRevision += 1
        timeline = TimelineProjection(model: self)
    }
    var displayTimeline: TimelineProjection {
        var display = timeline
        let indices = selectedWordIDs.compactMap { wordIndex[$0] }
        var starts = indices.map { words[$0].start }
        var ends = indices.map { words[$0].end }
        for id in selectedPauseIDs {
            if let pause = pauseIndex[id] { starts.append(pause.start); ends.append(pause.end) }
        }
        if let start = starts.min(), let end = ends.max() { display.selection = timelineBand(start: start, end: end) }
        if let rewrite = rewriteRange, words.indices.contains(rewrite.lowerBound), words.indices.contains(rewrite.upperBound) {
            display.rewrite = timelineBand(start: words[rewrite.lowerBound].start, end: words[rewrite.upperBound].end)
        }
        return display
    }
    var timelineAccessibilityValue: String {
        let current: Double = editedTimeline ? playhead : sourceTime
        let total: Double = editedTimeline ? duration : sourceDuration
        let cuts: Int = summary.cutWordCount + summary.cutPauseCount
        return timelineValueText(time: current, total: total, cuts: cuts, edited: editedTimeline)
    }
    private func timelineBand(start: Double, end: Double) -> TimelineBand {
        let lower = renderTimeline?.mapTime(start) ?? start
        let upper = renderTimeline?.mapTime(end) ?? end
        return TimelineBand(source: start...max(start, end), edited: lower...max(lower, upper))
    }
    @ObservationIgnored private var renderedTranscript: Transcript?
    @ObservationIgnored private var renderedEdits: ProjectEdits?
    @ObservationIgnored private var renderedMedia: ProjectMedia?
    @ObservationIgnored private var renderedVoiceLab: ProjectVoiceLab?
    @ObservationIgnored private var fillerCandidateIDs: Set<String> = []
    @ObservationIgnored private var planningSegments: [EditSegment]?
    @ObservationIgnored private var planningWordIndex: [String: Int] = [:]
    @ObservationIgnored private var summaryCache: [(edits: ProjectEdits, summary: EditSummary)] = []
    /// Edited lengths and card words by scope ("full" or a clip id), cleared by refresh().
    @ObservationIgnored private var scopeDurations: [String: Double] = [:]
    @ObservationIgnored private var scopeCards: [String: CaptionCardText] = [:]
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
    @ObservationIgnored private var initialised = false
    /// Set by the shell's leave boundary: edits freeze, and late results cannot
    /// change a project that is leaving.
    var isLeaving = false { didSet { if isLeaving { closeRewrite(returnFocus: false) } } }
    /// Called when a refresh finds a different active clip, for example after Undo.
    @ObservationIgnored var onActiveClipChange: ((String?) -> Void)?
    /// A new editor puts keyboard focus in its transcript once it shows.
    @ObservationIgnored var wantsTranscriptFocus = true
    /// Shows the sidebar for the Find Clips setup callout and a run's progress (design §6.2).
    @ObservationIgnored var onNeedsSidebar: (() -> Void)?
    #if DEBUG
    @ObservationIgnored var editTimestampForTests: Date?
    /// The last VoiceOver announcement, for harness checks.
    @ObservationIgnored var lastAnnouncement: String?
    /// Every VoiceOver announcement, for "announced once" checks.
    @ObservationIgnored var announcements: [String] = []
    /// Undo steps registered, for harness checks of one-step commands.
    @ObservationIgnored var undoSteps = 0
    #endif
    @ObservationIgnored private var renderedActiveClipID: String?

    init(document: VoxClipDocument, app: AppModel, preview: (any PreviewEngine)? = nil, exporter: (any Exporter)? = nil) {
        document.beginVoiceLabActivity(paidRoot: app.locations.root.appendingPathComponent("VoiceLab"))
        self.document = document
        self.app = app
        self.exporter = exporter ?? ExportQueue(exporter: AVExporter(cleanupRegistry: app.locations.root.appendingPathComponent("Scratch", isDirectory: true)))
        mediaResolved = document.demo
        if let preview { self.preview = preview; nativePreview = nil }
        else {
            let native = PreviewPlayerController()
            self.preview = native; nativePreview = native
        }
        textSize = app.number("general.transcriptTextSize", fallback: DesignValues.transcriptTextSize)
        refresh()
    }

    var project: Project { document.project }
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
        return summaryLine
    }
    /// The edit summary for the selected row (design §3.5): "{edited} after cuts · {n}
    /// cuts", "Clip {k} · " first for a clip or suggestion, and "{edited} · No cuts yet"
    /// when nothing in the scope is cut.
    var summaryLine: String {
        let scope = activeClip.flatMap { clipNumber($0.id) }.map { "Clip \($0) · " } ?? ""
        let edited = durationLabel(duration), cuts = cutCount
        return cuts == 0 ? "\(scope)\(edited) · No cuts yet" : "\(scope)\(edited) after cuts · \(cuts == 1 ? "1 cut" : "\(cuts) cuts")"
    }
    /// Cuts in the scope (design §3.5): the maximal runs of consecutive cut words, plus
    /// the cut pauses between the scope's words.
    var cutCount: Int { let cuts = scopeCuts; return cuts.runs + cuts.pauses }
    /// The scope's cut words, the runs they form and its cut pauses.
    private var scopeCuts: (words: Int, runs: Int, pauses: Int) {
        guard !words.isEmpty else { return (0, 0, 0) }
        let range = scopeBounds ?? 0...(words.count - 1)
        var cut = 0, runs = 0, previous = false
        for index in range {
            let isCut = cutWordIDs.contains(words[index].id)
            if isCut { cut += 1 }
            if isCut && !previous { runs += 1 }
            previous = isCut
        }
        let cutPauses = pauses.filter { cutPauseIDs.contains($0.id) && range.lowerBound <= $0.afterIndex && $0.afterIndex < range.upperBound }.count
        return (cut, runs, cutPauses)
    }
    /// The edit summary's detail (design §3.5), which VoiceOver reads after the subtitle:
    /// "{source} source · {w} words cut in {r} places · {p} pauses cut".
    var summaryDetail: String {
        let cuts = scopeCuts
        let span = scopeBounds.flatMap { try? clipTimes(words, startIndex: $0.lowerBound, endIndex: $0.upperBound) }
        let source = span.map { $0.end - $0.start } ?? sourceDuration
        let cutWords = cuts.words == 1 ? "1 word" : "\(cuts.words) words", places = cuts.runs == 1 ? "1 place" : "\(cuts.runs) places"
        let cutPauses = cuts.pauses == 1 ? "1 pause" : "\(cuts.pauses) pauses"
        return "\(durationLabel(source)) source · \(cutWords) cut in \(places) · \(cutPauses) cut"
    }
    /// "Export Video…" for the full take, "Export Clip…" for a clip (design §3.5).
    var exportTitle: String { activeClip == nil ? "Export Video…" : "Export Clip…" }
    /// The video is there to export: not a demo, found and readable (design §5.4.4).
    var mediaExportable: Bool { !document.demo && mediaResolved && !mediaUnreadable }
    /// Why Export can't run for the scope, as its tooltip and accessible description
    /// (design §3.5 and §5.4.4); nil when it can or while an export runs.
    var exportUnavailable: String? {
        if document.demo { return "Demo projects have no video to export." }
        if !mediaExportable { return "Locate the video to export." }
        if let clip = activeClip, isSuggestion(clip.id) { return "Keep this clip to export it." }
        return canExport || exporting ? nil : "Keep at least one word before exporting."
    }
    var canExport: Bool { capabilities.export && !document.demo && (voiceLabPlan.map { $0.outputSamples > 0 } ?? (words.isEmpty ? sourceDuration > 0 : editingAvailable && summary.canExport)) }
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
            } catch {
                // The file resolved but its probe failed: it is there and can't be read.
                mediaUnreadable = mediaResolved
                previewError = await app.safeError(error)
            }
        }
        refresh()
        if mediaResolved { await updatePreview(load: true) }
    }
    func close() {
        closeRewrite(returnFocus: false)
        previewRevision &+= 1
        workTask?.cancel(); exportTask?.cancel(); findTask?.cancel(); eventTask?.cancel(); updateTask?.cancel(); preview.close()
        app.openProjectKeys[project.id] = nil
    }
    func reloadFromDocument(previousProjectID: String) {
        closeRewrite(returnFocus: false)
        app.openProjectKeys[previousProjectID] = nil
        workTask?.cancel(); exportTask?.cancel(); findTask?.cancel(); updateTask?.cancel()
        preview.pause(); isPlaying = false; previewStop = nil
        history = nil
        renderedTranscript = nil; renderedEdits = nil; renderedMedia = nil; renderedVoiceLab = nil
        planningSegments = nil; planningWordIndex = [:]; summaryCache.removeAll()
        selectedWordIDs = []; selectedPauseIDs = []; correctionID = nil
        fallbackNote = nil; focusedSuggestion = nil; clipError = nil; error = nil; previewError = nil
        mediaResolved = document.demo
        refresh()
        updateTask = Task { [weak self] in
            guard let self, sourceURL.path != "/" else { return }
            do {
                _ = try await resolveMediaIdentity()
                await updatePreview(load: true)
            } catch is CancellationError {} catch { previewError = await app.safeError(error) }
        }
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
        if transcribed != (project.transcript != nil) { transcribed = project.transcript != nil }
        projectRevision += 1
        scopeDurations.removeAll(keepingCapacity: true)
        scopeCards.removeAll(keepingCapacity: true)
        if transcriptChanged || renderedEdits?.clips != edits.clips || renderedVoiceLab != project.voiceLab {
            transcriptLayoutRevision += 1
        }
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
                paidRoot: app.locations.root.appendingPathComponent("VoiceLab", isDirectory: true), labelPosition: app.voiceLabLabelPosition)?.prepared.outputPlan
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
        if edits.activeClipId != renderedActiveClipID {
            renderedActiveClipID = edits.activeClipId
            onActiveClipChange?(edits.activeClipId)
        }
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
    func replace(_ newProject: Project, name: String, restoringSnapshot: Bool = false) {
        // A Versions-browser version is read-only.
        guard capabilities.writable, capabilities.media || name == "Locate media" || onlyCaptionPositionChanged(newProject) else { return }
        // The title follows the document's name, not the edit history (design §2), so
        // undoing an edit made before a Save As or Rename keeps the new title.
        var newProject = newProject
        newProject.title = project.title
        guard newProject != project else { return }
        closeRewrite(returnFocus: false)
        preview.pause(); isPlaying = false
        let previous = project
        let mediaChanged = previous.media.source != newProject.media.source
        undoManager?.registerUndo(withTarget: self) { model in model.replace(previous, name: name, restoringSnapshot: true) }
        undoManager?.setActionName(name)
        #if DEBUG
        undoSteps += 1
        #endif
        var changed = newProject
        if !restoringSnapshot {
        #if DEBUG
        changed.modifiedAt = editTimestampForTests ?? Date()
        #else
        changed.modifiedAt = Date()
        #endif
        }
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
    #if DEBUG
    func waitForPendingPreviewForAudit() async { await updateTask?.value }
    #endif
    private func recordDocumentChange() {
        document.updateChangeCount(undoManager?.isUndoing == true ? .changeUndone : undoManager?.isRedoing == true ? .changeRedone : .changeDone)
    }
    private func onlyCaptionPositionChanged(_ candidate: Project) -> Bool {
        var positionEdit = project
        positionEdit.captions.position = candidate.captions.position
        positionEdit.captions.positionByAspect = candidate.captions.positionByAspect
        positionEdit.modifiedAt = candidate.modifiedAt
        positionEdit.title = candidate.title
        return positionEdit == candidate
    }
    func resolveMediaIdentity() async throws -> URL {
        let reference = project.media.source
        let resolved = try await app.projectStore.resolveSource(for: project, projectURL: document.fileURL ?? sourceURL.deletingLastPathComponent().appendingPathComponent("Untitled.voxclip"))
        try Task.checkCancellation()
        // Only a change to the media itself makes this check stale. A Save As or Move that
        // lands meanwhile rewrites the relative path, and the check still holds.
        let current = project.media.source
        guard current.contentKey == reference.contentKey, current.sizeBytes == reference.sizeBytes,
              current.absolutePath == reference.absolutePath else { throw CancellationError() }
        if reference.absolutePath != resolved.path, !document.isVersion {
            var changed = project
            changed.media.source.absolutePath = resolved.path
            document.replaceProject(changed)
            document.markEdited()
        }
        mediaResolved = true
        app.openProjectKeys[project.id] = reference.contentKey
        return resolved
    }
    /// The relink flow for missing media (editing §10.3): choose the file, confirm a
    /// different-looking one, and attach it as one "Locate media" step.
    func locateMedia() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let probe = try await AVMediaProbe().probe(url)
                let next: Project
                do {
                    next = try await app.projectStore.relink(project, to: url, probe: probe)
                } catch VoxClipError.mediaMissing(_) {
                    guard probe.durationSeconds.isFinite, abs(probe.durationSeconds - sourceDuration) <= 0.05 else {
                        previewError = "This file's duration differs by more than 0.05 seconds. Choose another file. Edits are saved."
                        return
                    }
                    let alert = NSAlert(); alert.messageText = "This file looks different. Use it anyway?"; alert.addButton(withTitle: "Use it"); alert.addButton(withTitle: "Choose another")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    next = try await app.projectStore.relink(project, to: url, probe: probe, confirmedDifferent: true)
                }
                mediaResolved = true
                mediaUnreadable = false
                replace(next, name: "Locate media")
                await updatePreview(load: true)
            } catch { previewError = await app.safeError(error) }
        }
    }
    func apply(_ command: EditCommand, name: String, base: Project? = nil, announcing message: String? = nil) {
        guard capabilities.edit else { return }
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
        announce(message ?? announcement(command, before: state, after: changed, fallback: name))
    }
    /// Applies several commands as one undo step. Returns false when nothing changed.
    @discardableResult func apply(_ commands: [EditCommand], name: String) -> Bool {
        guard capabilities.edit, let state = editState() else { return false }
        preview.pause(); isPlaying = false
        if history?.state != state { history = EditHistory(state: state) }
        var next = project
        for command in commands { history?.apply(command, aiResults: next.ai.results) }
        guard let changed = history?.state, changed != state else { return false }
        next.edits = changed.projectEdits
        let clipIDs = Set(changed.clips.map(\.id))
        next.share.captions = next.share.captions.filter { $0.key == "full" || clipIDs.contains($0.key) }
        replace(next, name: name)
        return true
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
        let selected = selectedIDs + selectedPauseIDs.sorted()
        let ids = restore ? selected : selected.filter { (id: String) -> Bool in
            !cutWordIDs.contains(id) && !cutPauseIDs.contains(id)
        }
        guard !ids.isEmpty else { return }
        apply(restore ? .restoreSelection(ids: ids) : .cutSelection(ids: ids), name: restore ? "Restore selection" : "Cut selection")
    }
    func toggleSelectionCut() {
        let ids = selectedIDs + selectedPauseIDs.sorted()
        let restore: Bool = !ids.isEmpty && ids.allSatisfy { (id: String) -> Bool in cutWordIDs.contains(id) || cutPauseIDs.contains(id) }
        cutSelection(restore: restore)
    }
    /// Make Clip (⌘K, design §3.4): one undo step adds the clip and selects its row. A
    /// selection an existing clip already covers selects that clip instead.
    func makeClip() {
        guard let start = selectedIDs.first, let end = selectedIDs.last else { return }
        if let existing = project.edits.clips.first(where: { $0.startWordId == start && $0.endWordId == end }) {
            let message = clipNumber(existing.id).map { "Clip \($0) already covers these words." } ?? "A clip already covers these words."
            if activeClip?.id == existing.id { announce(message) } else { activate(existing, announcing: message) }
            return
        }
        let title = EditingAlgorithms.clipTitle(words.lazy.filter { self.selectedWordIDs.contains($0.id) }.map { self.text($0) })
        let clip = ClipRange(id: UUID().uuidString.lowercased(), startWordId: start, endWordId: end, title: title)
        guard apply([.addClip(clip), .setActiveClip(clipId: clip.id)], name: "Make clip from selection") else { return }
        announce(clipNumber(clip.id).map { "Clip \($0) made." } ?? "Clip made.")
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
    func timelineSourceTime(_ time: Double) -> Double {
        guard editedTimeline else { return time }
        if time <= 0 { return scopeBounds.map { words[$0.lowerBound].start } ?? 0 }
        if time >= duration { return scopeBounds.map { words[$0.upperBound].end } ?? sourceDuration }
        let mapped: Double = renderTimeline?.sourceTime(time) ?? time
        guard let scope = scopeBounds else { return mapped }
        return mapped.clamped(to: words[scope.lowerBound].start...words[scope.upperBound].end)
    }
    func timelineTrimIndex(_ clip: ClipRange, start: Bool, fraction: Double) -> Int? {
        let time: Double = timeline.time(fraction, edited: editedTimeline)
        let source: Double = timelineSourceTime(time)
        guard let candidate = trimIndex(start: start, source: source),
              let lower = index(clip.startWordId), let upper = index(clip.endWordId) else { return nil }
        return start ? candidate.clamped(to: 0...upper) : candidate.clamped(to: lower...(words.count - 1))
    }
    func trimIndex(start: Bool, source: Double) -> Int? {
        guard !words.isEmpty else { return nil }
        var lower = 0
        var upper = words.count
        while lower < upper {
            let middle = (lower + upper) / 2
            let boundary = start ? words[middle].start : words[middle].end
            if boundary < source { lower = middle + 1 } else { upper = middle }
        }
        if lower == 0 { return 0 }
        if lower == words.count { return words.count - 1 }
        let previous = start ? words[lower - 1].start : words[lower - 1].end
        let next = start ? words[lower].start : words[lower].end
        return source - previous <= next - source ? lower - 1 : lower
    }
    func trimClip(_ clip: ClipRange, start: Bool, index: Int) {
        guard let lower = self.index(clip.startWordId), let upper = self.index(clip.endWordId) else { return }
        let nextStart = start ? index.clamped(to: 0...upper) : lower
        let nextEnd = start ? upper : index.clamped(to: lower...(words.count - 1))
        guard nextStart != lower || nextEnd != upper else { return }
        apply(.updateClip(id: clip.id, startIndex: nextStart, endIndex: nextEnd), name: "Trim clip")
    }
    func adjustTrim(start: Bool, offset: Int) {
        guard let clip = activeClip, let current = index(start ? clip.startWordId : clip.endWordId) else { return }
        trimClip(clip, start: start, index: current + offset)
    }
    func activate(_ clip: ClipRange?, announcing message: String? = nil) {
        let previous = project.edits.activeClipId
        apply(.setActiveClip(clipId: clip?.id), name: "Preview clip", announcing: message)
        if project.edits.activeClipId == clip?.id {
            seekToActiveClip()
            if previous != clip?.id { scopeScrollRevision += 1 }
        }
    }
    /// Moves the playhead to the active clip's first word.
    private func seekToActiveClip() {
        if let clip = activeClip, let word = words.first(where: { $0.id == clip.startWordId }) { seek(source: word.start) }
    }
    func moveClip(_ direction: Int) {
        guard !sortedClips.isEmpty else { return }
        let position = sortedClips.firstIndex { $0.id == activeClip?.id } ?? (direction > 0 ? -1 : sortedClips.count)
        activate(sortedClips[min(sortedClips.count - 1, max(0, position + direction))])
    }
    func removeClip(_ id: String) {
        rowAction([.removeClip(id: id)] + focusNext(after: id), name: "Remove clip", announcing: clipNumber(id).map { "Clip \($0) removed." } ?? "Clip removed.")
    }

    // Clips in the sidebar (design §3.4 and §6.2): kept clips number 1…n in transcript
    // order and suggestions continue after them.
    var keptClips: [ClipRange] { sortedClips.filter { $0.origin == .manual || $0.selected } }
    var suggestedClips: [ClipRange] { sortedClips.filter { $0.origin == .ai && !$0.selected } }
    func clipNumber(_ id: String) -> Int? {
        let kept = keptClips
        if let position = kept.firstIndex(where: { $0.id == id }) { return position + 1 }
        return suggestedClips.firstIndex { $0.id == id }.map { kept.count + $0 + 1 }
    }
    func isSuggestion(_ id: String) -> Bool { suggestedClips.contains { $0.id == id } }
    /// The row after a clip in sidebar order: the next kept clip or suggestion, else Full
    /// take (nil).
    func clipAfter(_ id: String) -> String? {
        let rows = keptClips + suggestedClips
        guard let position = rows.firstIndex(where: { $0.id == id }), position + 1 < rows.count else { return nil }
        return rows[position + 1].id
    }
    /// Keep, Dismiss and Remove on the selected row move the selection to the next row in
    /// the same undo step (design §3.4).
    private func focusNext(after id: String) -> [EditCommand] {
        project.edits.activeClipId == id ? [.setActiveClip(clipId: clipAfter(id))] : []
    }
    /// A row action as one undo step; the playhead follows when the selection moved.
    private func rowAction(_ commands: [EditCommand], name: String, announcing message: String) {
        let active = project.edits.activeClipId
        guard apply(commands, name: name) else { return }
        announce(message)
        if project.edits.activeClipId != active { seekToActiveClip() }
    }
    func keep(_ id: String) {
        let number = sortedClips.filter { $0.origin == .manual || $0.selected || $0.id == id }.firstIndex { $0.id == id }.map { $0 + 1 }
        rowAction([.setClipSelected(id: id, selected: true)] + focusNext(after: id), name: "Keep clip", announcing: number.map { "Clip \($0) kept." } ?? "Clip kept.")
    }
    /// Keeps every suggestion as one undo step.
    func keepAll() {
        let ids = suggestedClips.map(\.id)
        guard !ids.isEmpty, apply(ids.map { .setClipSelected(id: $0, selected: true) }, name: "Keep all suggestions") else { return }
        announce(ids.count == 1 ? "Clip \(keptClips.count) kept." : "\(ids.count) clips kept.")
    }
    func dismiss(_ id: String) { rowAction([.removeClip(id: id)] + focusNext(after: id), name: "Dismiss suggestion", announcing: "Suggestion dismissed.") }
    /// Return on the focused suggestion keeps it, ⌫ dismisses it, and focus moves to the
    /// next suggestion (design §6.2). False when no suggestion has focus.
    @discardableResult func actOnFocusedSuggestion(keep: Bool) -> Bool {
        guard let id = focusedSuggestion, isSuggestion(id) else { focusedSuggestion = nil; return false }
        let rows = suggestedClips.map(\.id)
        let next: String? = rows.firstIndex(of: id).flatMap { (index: Int) -> String? in
            let following: Int = index + 1
            return following < rows.count ? rows[following] : nil
        }
        if keep { self.keep(id) } else { dismiss(id) }
        focusedSuggestion = isSuggestion(id) ? id : next
        return true
    }
    func renameClip(_ id: String, to title: String) {
        apply(.renameClip(id: id, title: EditingAlgorithms.clipTitle([title])), name: "Rename clip")
    }
    /// The edited length of a clip, or of the full take for nil (design §3.4 meta line).
    func editedDuration(_ clip: ClipRange?) -> Double {
        let key = clip?.id ?? "full"
        if let cached = scopeDurations[key] { return cached }
        guard let state = editState(), let segments = try? buildSegments(state, activeClip: clip),
              let plan = try? buildEditPlan(segments, duration: sourceDuration, sampleRate: Double(project.media.source.audio?.sampleRate ?? 48_000), pauseKeepSeconds: state.pauseKeepSeconds)
        else { return clip == nil ? sourceDuration : 0 }
        scopeDurations[key] = plan.duration
        return plan.duration
    }
    /// The caption card's words for a scope (design §5.4.2), from VoxClipCore.
    func cardText(_ scope: CaptionCardScope, wordsVisible: Bool) -> CaptionCardText {
        _ = transcriptRevision
        guard let style = app.cardStyle(for: project), let resources = app.captionResources else { return .none }
        let key: String
        switch scope { case .fullTake: key = "full"; case .clip(let id): key = id }
        let cacheKey = "\(key)|\(wordsVisible)|\(style.id)"
        if let cached = scopeCards[cacheKey] { return cached }
        let text = CaptionCardText.make(project: project, scope: scope, style: style, wordsVisible: wordsVisible, resources: resources)
        scopeCards[cacheKey] = text
        return text
    }
    /// The source time of a scope's first kept word, where its thumbnail frame is taken.
    func firstKeptTime(_ clip: ClipRange?) -> Double? {
        let cut = Set(project.edits.cutWordIds)
        let lower = clip.flatMap { index($0.startWordId) } ?? 0, upper = clip.flatMap { index($0.endWordId) } ?? words.count - 1
        guard lower <= upper, upper < words.count else { return nil }
        return words[lower...upper].first { $0.kind == .word && !cut.contains($0.id) }?.start
    }
    func beginCorrection() {
        guard capabilities.edit, let id = selectedIDs.first, let word = words.first(where: { $0.id == id }) else { return }
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
    func setStyle(_ id: String) {
        if id == "off", project.captions.styleId != "off" { lastStyleId = project.captions.styleId }
        else if id != "off" { lastStyleId = id }
        var next = project; next.captions.styleId = id; replace(next, name: "Change caption style")
    }
    func setCaptionsEnabled(_ enabled: Bool) {
        guard enabled else { setStyle("off"); return }
        let previous = lastStyleId ?? app.string("captions.defaultStyleId")
        setStyle(app.styles.contains { $0.id == previous } ? previous : app.styles.first?.id ?? "off")
    }
    var captionsEdited: Bool {
        !project.captions.overrides.isEmpty || project.captions.positionByAspect[captionPreset.rawValue] != nil || project.captions.position != nil
    }
    var captionSummary: String {
        guard let library = app.styles.first(where: { $0.id == project.captions.styleId }) else { return "Off" }
        let resolved = (try? library.resolved(overrides: project.captions.overrides, frame: outputSpec().size)) ?? library
        var parts: [String] = []
        if let accent = resolved.accent {
            let names = ["#FFE14D": "Yellow", "#4BE38A": "Green", "#5CE1FF": "Cyan", "#FF6FAE": "Pink", "#F3F0E7": "Paper", "#FFFFFF": "White"]
            parts.append(names[accent.uppercased()] ?? "Colour")
        }
        parts.append(resolved.text.transform == .uppercase ? "ALL CAPS" : "As said")
        let count = resolved.layout.maxWords
        parts.append(count >= 16 ? "Line" : count == 1 ? "1 word" : "\(count) words")
        return parts.joined(separator: " · ")
    }
    func setAspect(_ aspect: AspectRatio) { var next = project; next.export.aspect = aspect; replace(next, name: "Change aspect") }
    var captionPreset: AspectRatio {
        let size = outputSpec().size
        if 16 * size.width == 9 * size.height { return .portrait }
        if 9 * size.width == 16 * size.height { return .landscape }
        if size.width == size.height { return .square }
        return .source
    }
    func zoom(_ amount: Double) { textSize = (amount == 0 ? DesignValues.transcriptTextSize : textSize + amount).clamped(to: DesignValues.transcriptZoom); app.set("general.transcriptTextSize", .number(textSize)); transcriptRevision += 1 }
    func copySelection() { copyText(words.filter { selectedWordIDs.contains($0.id) }.map { text($0) }.joined(separator: " ")) }
    func announce(_ message: String) {
        #if DEBUG
        lastAnnouncement = message
        announcements.append(message)
        #endif
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    func renderSnapshot() -> EditorRenderSnapshot {
        EditorRenderSnapshot(project: project, state: editState(), plan: plan)
    }
    func renderRequest(target: ExportTarget? = nil, snapshot: EditorRenderSnapshot? = nil, labelPosition: VoiceLabLabelPosition? = nil) async throws -> RenderRequest {
        let snapshot = snapshot ?? renderSnapshot()
        let project = snapshot.project
        let state = snapshot.state
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
            paidRoot: app.locations.root.appendingPathComponent("VoiceLab", isDirectory: true), labelPosition: labelPosition ?? app.voiceLabLabelPosition)
        if clip != nil && state == nil { throw VoxClipError.exportFailed("Clip transcript is unavailable") }
        let segments = try state.map { try buildSegments($0, activeClip: clip) }
        var plan = snapshot.plan
        if target != nil || voiceLab != nil, let state, let segments {
            plan = try buildEditPlan(segments, duration: project.media.source.durationSeconds, sampleRate: Double(project.media.source.audio?.sampleRate ?? 48_000), pauseKeepSeconds: state.pauseKeepSeconds)
        }
        guard let plan else { throw VoxClipError.exportFailed("Could not build the edit plan") }
        guard (voiceLab?.prepared.outputPlan.outputSamples ?? plan.outputSamples) > 0 else { throw VoxClipError.everythingCut }
        let output = ExportFingerprint.output(project)
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
        let visible = app.bool("general.showPlaceholderWords", fallback: true)
        let key = "\(projectRevision):\(activeClip?.id ?? "full"):\(visible)"
        if galleryKey != key { galleryKey = key; galleryPages = [:] }
        let scope: CaptionCardScope = activeClip.map { .clip($0.id) } ?? .fullTake
        if galleryPages[style.id] == nil, let resources = app.captionResources {
            galleryPages[style.id] = CaptionGalleryPages(project: project, scope: scope, style: style, wordsVisible: visible, resources: resources)
        }
        let sample = transcriptionStatus != nil ? CaptionGallerySample.preview(style) : galleryPages[style.id]?.sample(at: playhead) ?? CaptionGallerySample.preview(style)
        let selected = style.id == project.captions.styleId
        let overrides = selected ? project.captions.overrides : [:]
        let placement = selected && style.position.userDraggable ? project.captions.positionByAspect[captionPreset.rawValue] ?? project.captions.position : nil
        let resolved = (try? style.resolved(overrides: overrides, frame: outputSpec().size)) ?? style
        let lower = activeClip.flatMap { clip in index(clip.startWordId).map { words[$0].start } } ?? 0
        let upper = activeClip.flatMap { clip in index(clip.endWordId).map { words[$0].end } } ?? sourceDuration
        let time = (floor(sourceTime * 4) / 4).clamped(to: lower...max(lower, upper))
        let frameAvailable = !document.demo && mediaResolved && !mediaUnreadable && project.media.source.video != nil
        let loading = mediaStatus == .loading || (transcriptionStatus != nil && !frameAvailable)
        return CaptionTileInput(state: nil, plan: nil, style: style, sampleWords: sample.words.map(\.text), language: sample.source == .preview ? "en" : project.transcript?.language, frame: outputSpec().size, overrides: overrides, position: placement, sourceURL: sourceURL, sourceTime: time,
                                sample: sample, backdrop: CaptionCardLook.backdrop(resolved, previewBackground: app.previewBackgrounds[style.id]), frameAvailable: frameAvailable, loading: loading,
                                contentKey: project.media.source.contentKey)
    }
    func outputSpec() -> OutputSpec {
        ExportFingerprint.output(project)
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

extension EditorModel {
    enum FindClipsAnchor { case toolbar, sidebar }
    static let noClipsMatched = "No clips matched. Try another style or describe what you want."
    /// The chosen clip-finding connector, nil when none is set up.
    var findConnector: ProviderChoice? { app.providers.first { $0.id == app.string("llm.connector") } }
    func requestFindClips(from anchor: FindClipsAnchor) {
        guard capabilities.ai, !words.isEmpty else { return }
        showAISetup = false
        findClipsAnchor = anchor
        showFindClips = true
    }
    /// Asks the chosen connector for clips. They arrive as suggestions in one undo step.
    func findClips() {
        guard capabilities.ai, let shared = app.shared, let transcript = project.transcript, let provider = app.providers.first(where: { $0.id == app.string("llm.connector") }) else { return }
        let corrections = project.edits.corrections
        let cuts = Set(project.edits.cutWordIds)
        let selectedModel = app.string("llm.model.\(provider.id)", fallback: provider.defaultModel ?? "")
        let selectedSignature = rewriteConnectorSignature
        let selectedPreset = preset
        let instructions = instruction
        let snapshot = project
        do {
            guard self.capabilities.ai, self.project == snapshot, self.app.string("llm.connector") == provider.id,
                  self.app.string("llm.model.\(provider.id)", fallback: provider.defaultModel ?? "") == selectedModel,
                  self.rewriteConnectorSignature == selectedSignature,
                  let lease = self.llmRuns.acquire() else { return }
            let runs = self.llmRuns
            let connector = self.app.connector(provider.id)
            self.findTask?.cancel(); self.finding = true; self.clipError = nil; self.fallbackNote = nil; self.showAISetup = false
            self.onNeedsSidebar?()
            self.announce("Finding clips")
            self.findTask = Task { [self] in
                defer { self.finding = false; runs.release(lease) }
                do {
                    guard try await app.authorizeConnectorRequest(provider, connector: connector, action: .findClips,
                        wordCount: transcript.words.filter { $0.kind == .word }.count, parent: window, isCurrent: { [self] in
                            !isLeaving && project == snapshot && rewriteConnectorSignature == selectedSignature
                        }) else { return }
                    let catalog = LLMCatalog(document: try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: shared.root.appendingPathComponent("catalog/llm-providers.json"))))
                    let finder = ClipFinder(runner: LLMRunner(keys: app.secrets, catalog: catalog, log: app.log), shared: shared)
                    let presets = try await finder.presets()
                    guard let preset = presets.first(where: { $0.id == selectedPreset }) else { throw ClipFinderGateError.needInstructions(message: "Choose a clip preset.") }
                    let result = try await finder.find(ClipFinderRequest(transcript: transcript, corrections: corrections, cutWordIds: cuts, preset: preset, instruction: instructions, snap: app.bool("llm.clips.snapToLines", fallback: true)), connector: connector, model: selectedModel)
                    try Task.checkCancellation()
                    let usedFallback = await finder.lastUsedFallback == true && result.model != selectedModel
                    guard project.transcript == transcript else { return }
                    guard !result.clips.isEmpty else { clipError = Self.noClipsMatched; return }
                    var next = project
                    next.ai.results.append(result)
                    let ranges = result.clips.enumerated().map { position, clip in ClipRange(id: UUID().uuidString.lowercased(), startWordId: clip.startWordId, endWordId: clip.endWordId, title: clip.title, origin: .ai, aiResultId: result.id, aiClipIndex: position) }
                    // One undo step: the result arrives as suggestions, not kept clips.
                    guard capabilities.edit, let state = editState() else { return }
                    if history?.state != state { history = EditHistory(state: state) }
                    let before = Set(state.clips.map(\.id))
                    history?.apply(.addAIClips(resultId: result.id, clips: ranges), aiResults: next.ai.results)
                    let added = (history?.state.clips ?? []).filter { !before.contains($0.id) }
                    for clip in added { history?.apply(.setClipSelected(id: clip.id, selected: false), aiResults: next.ai.results) }
                    guard let changed = history?.state, changed != state else { clipError = "These clips are already in the list."; return }
                    next.edits = changed.projectEdits
                    replace(next, name: "Find clips")
                    // The first new suggestion in transcript order is focused, not selected
                    // (design §6.2): the scope, playhead, Export and subtitle stay.
                    focusedSuggestion = added.min { (index($0.startWordId) ?? .max) < (index($1.startWordId) ?? .max) }?.id
                    fallbackNote = usedFallback ? "Answered by \(result.model) because \(selectedModel) was busy." : nil
                    announce([added.count == 1 ? "Found 1 clip." : "Found \(added.count) clips.", fallbackNote].compactMap { $0 }.joined(separator: " "))
                } catch is CancellationError {} catch LLMError.cancelled {} catch VoxClipError.cancelled {} catch {
                    let message = await app.safeError(error, context: "ai:\(provider.label)")
                    if !message.isEmpty { clipError = message }
                }
            }
        }
    }
}
