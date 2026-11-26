@preconcurrency import AVFoundation
import Foundation
import Observation
import VoxClipCore
import VoxClipMedia

/// Plays one candidate in the Music section; stopping it never touches the editor's player.
@MainActor protocol MusicAuditioning: AnyObject {
    func play(_ url: URL, finished: @escaping @MainActor @Sendable (Bool) -> Void)
    func stop()
}

@MainActor final class AVMusicAudition: MusicAuditioning {
    private var player: AVPlayer?
    private var status: NSKeyValueObservation?
    private var observers: [any NSObjectProtocol] = []
    func play(_ url: URL, finished: @escaping @MainActor @Sendable (Bool) -> Void) {
        stop()
        let player = AVPlayer(url: url)
        self.player = player
        if let item = player.currentItem {
            status = item.observe(\.status, options: [.initial, .new]) { item, _ in
                if item.status == .failed { Task { @MainActor in finished(false) } }
            }
            let center = NotificationCenter.default
            observers = [center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { _ in
                Task { @MainActor in finished(true) }
            }, center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { _ in
                Task { @MainActor in finished(false) }
            }]
        }
        player.play()
    }
    func stop() {
        player?.pause(); player = nil; status = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
}

/// What the Music section asks of the outside world; tests pass stubs, the app builds them from its own services.
struct MusicPanelServices: Sendable {
    var suggest: @Sendable (MusicBrief, Double) async -> MusicSuggestionResult
    /// The bytes behind a library candidate (downloaded) or a generated one (composed, paid); own files are read directly.
    var fetch: @Sendable (MusicCandidate) async throws -> Data
    var folder: @Sendable () -> URL?

    var generate: (@Sendable (MusicCandidate, @Sendable () async -> Void) async throws -> Data)? = nil
    var browse: (@Sendable (MusicBrief, Double, Int) async throws -> MusicCatalogPage)? = nil
    var price: (@Sendable (MusicBrief, Double) async -> MusicSuggestionResult)? = nil

    func importTrack(_ candidate: MusicCandidate, projectId: String, clipId: String?, dataRoot: URL,
                     accepted: @Sendable () async -> Void = {}) async throws -> ProjectMusic {
        let data: Data
        if candidate.source == .file {
            guard let url = candidate.audioURL, url.isFileURL else { throw VoxClipError.mediaMissing(candidate.title) }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard (1...MusicAssetStore.maximumBytes).contains(size) else { throw VoxClipError.decodeFailed("The music file is empty or too large") }
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } else if candidate.source == .generated, let generate {
            data = try await generate(candidate, accepted)
        } else {
            data = try await fetch(candidate)
            if candidate.source == .generated { await accepted() }
        }
        return try await MusicAssetStore.importing(data, candidate: candidate, projectId: projectId, clipId: clipId, dataRoot: dataRoot)
    }
}

/// Music browsing and audition are separate from the undoable changes to the project's track.
@MainActor @Observable final class MusicPanel {
    enum Phase: Equatable { case idle, searching, pricing, using(String), failed(String) }
    enum SourceTab: String, CaseIterable { case free = "Free tracks", eleven = "Eleven Music", files = "My files" }
    var sourceTab = SourceTab.free
    private(set) var directions = MusicBrief.browseDirections()
    private(set) var selection = 0
    private(set) var catalogNote: String?
    private(set) var generationNote: String?
    private(set) var folderFiles: [MusicCandidate] = []
    private(set) var phase = Phase.idle
    private(set) var playing: String?
    var direction: MusicBrief { directions[selection] }
    var query: String {
        get { direction.query }
        set {
            guard !isUsing, newValue != query else { return }
            directions[selection].query = newValue
            clearCatalog()
        }
    }
    var prompt: String {
        get { direction.prompt }
        set {
            guard !isUsing, newValue != prompt else { return }
            directions[selection].prompt = newValue
            clearPrice()
        }
    }
    var isUsing: Bool { if case .using = phase { true } else { false } }
    var isBusy: Bool { phase == .searching || phase == .pricing || isUsing }
    @ObservationIgnored var services: MusicPanelServices?
    @ObservationIgnored var audition: any MusicAuditioning = AVMusicAudition()
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var loadedFolder: URL?
    @ObservationIgnored private var auditionID: UUID?
    @ObservationIgnored private var liveBrowser: MusicPanelServices?

    private struct QuoteScope: Equatable {
        let project: String, source: String, region: String
        let clip: String?
        let seconds: Int

        @MainActor init(_ model: EditorModel) {
            project = model.project.id; source = model.project.media.source.contentKey
            clip = model.renderedActiveClipID; seconds = MusicPricing.lengthSeconds(forClip: model.musicRenderSeconds)
            region = model.app.string("transcription.elevenlabs.region", fallback: "default")
        }
    }
    private struct CatalogResults {
        let scope: QuoteScope
        var matches: [MusicCandidate] = []
        var nextPage: Int?
    }
    private var catalog: CatalogResults?
    private var pricedChoice: (scope: QuoteScope, services: MusicPanelServices, candidate: MusicCandidate)?
    private var directionScope: (project: String, source: String, clip: String?)?

    func reset() {
        work?.cancel(); work = nil; phase = .idle; liveBrowser = nil; directionScope = nil
        sourceTab = .free
        setDirections([])
    }

    func setDirections(_ briefs: [MusicBrief], model: EditorModel) {
        directionScope = (model.project.id, model.project.media.source.contentKey, model.renderedActiveClipID)
        setDirections(briefs)
    }

    func syncScope(model: EditorModel) {
        let current = (model.project.id, model.project.media.source.contentKey, model.renderedActiveClipID)
        if let directionScope, directionScope == current { return }
        setDirections(model.plannedMusicBrowserBriefs)
        directionScope = current
    }

    private func setDirections(_ briefs: [MusicBrief]) {
        clearCatalog(); clearPrice(); stopAudition()
        if !isUsing { phase = .idle }
        directions = MusicBrief.browseDirections(briefs)
        selection = 0
    }

    func selectDirection(_ index: Int) {
        guard directions.indices.contains(index), selection != index, !isUsing else { return }
        clearCatalog(); clearPrice(); stopAudition(); dismissFailure()
        selection = index
    }

    func directionTitle(_ index: Int) -> String {
        let title = directions[index].mood
        let occurrence = directions[...index].filter { $0.mood.caseInsensitiveCompare(title) == .orderedSame }.count
        return occurrence == 1 ? title : "\(title) (\(occurrence))"
    }

    private func clearCatalog() {
        if let playing, catalog?.matches.contains(where: { $0.id == playing }) == true { stopAudition() }
        catalog = nil; catalogNote = nil
        if phase == .searching { work?.cancel(); work = nil; phase = .idle }
    }

    private func clearPrice() {
        pricedChoice = nil; generationNote = nil
        if phase == .pricing { work?.cancel(); work = nil; phase = .idle }
    }

    nonisolated static let folderKey = "VoxClipMusicFolder"

    /// The user's Music folder: the chosen one, else ~/Music/VoxClip when it exists.
    nonisolated static func folder(defaults: UserDefaults = .standard) -> URL? {
        if let path = defaults.string(forKey: folderKey), !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return MusicLibraryFolder.defaultFolder()
    }

    /// Lists the folder's files once per folder, so the section never opens empty.
    func loadFolder() {
        let folder = services?.folder() ?? Self.folder()
        guard folder != loadedFolder || folderFiles.isEmpty else { return }
        loadedFolder = folder
        folderFiles = MusicLibraryFolder.files(in: folder)
    }

    func chooseFolder(_ url: URL, defaults: UserDefaults = .standard) {
        defaults.set(url.path, forKey: Self.folderKey)
        loadedFolder = nil
        folderFiles = MusicLibraryFolder.files(in: url)
    }

    func search(model: EditorModel) {
        syncScope(model: model)
        guard !isBusy, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        clearCatalog()
        catalog = CatalogResults(scope: QuoteScope(model))
        browse(page: 1, model: model)
    }

    func loadMore(model: EditorModel) {
        guard !isBusy, let page = nextPage(model: model) else { return }
        browse(page: page, model: model)
    }

    private func browse(page: Int, model: EditorModel) {
        if services == nil, liveBrowser == nil { liveBrowser = model.defaultMusicServices() }
        guard let browse = (services ?? liveBrowser)?.browse else {
            catalogNote = "The free music library is unavailable."; return
        }
        let brief = direction, seconds = model.musicRenderSeconds
        let scope = QuoteScope(model)
        catalogNote = nil
        work?.cancel()
        phase = .searching
        work = Task { [weak self] in
            let response: Result<MusicCatalogPage, any Error>
            do { response = .success(try await browse(brief, seconds, page)) }
            catch { response = .failure(error) }
            guard let self, !Task.isCancelled, self.phase == .searching else { return }
            self.phase = .idle
            guard QuoteScope(model) == scope, var catalog = self.catalog else { return }
            switch response {
            case .success(let result):
                var seen = Set(catalog.matches.map(\.id))
                catalog.matches += result.candidates.filter { $0.source == .library && seen.insert($0.id).inserted }
                catalog.nextPage = result.nextPage.flatMap { $0 > page ? $0 : nil }
                self.catalog = catalog
                if catalog.matches.isEmpty {
                    self.catalogNote = catalog.nextPage == nil ? "No usable tracks matched. Try other search words." : "No usable tracks on this page. You can load more."
                }
            case .failure(let error):
                let message: String
                if case .offline? = error as? VoxClipError { message = "Openverse is unavailable while you’re offline." }
                else { message = UserMessages.message(error) }
                self.catalogNote = (page == 1 ? "Search failed: " : "Couldn’t load more tracks: ") + message
                Task { await model.app.logFailure(error, context: .music) }
            }
        }
    }

    func priceGeneration(model: EditorModel) {
        syncScope(model: model)
        guard model.capabilities.edit, !isBusy, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        clearPrice()
        guard let provider = services ?? model.defaultMusicServices(), let price = provider.price else {
            generationNote = "Eleven Music pricing is unavailable."; return
        }
        let brief = direction, seconds = model.musicRenderSeconds, scope = QuoteScope(model)
        work?.cancel()
        phase = .pricing
        work = Task { [weak self] in
            let result = await price(brief, seconds)
            guard let self, !Task.isCancelled, self.phase == .pricing else { return }
            self.phase = .idle
            guard QuoteScope(model) == scope else { return }
            if let candidate = result.candidates.first(where: { $0.needsGeneration && $0.prompt == brief.compositionPrompt && $0.estimate.flatMap(MusicPricing.label) != nil }) {
                self.pricedChoice = (scope, provider, candidate)
            } else {
                self.generationNote = result.notes[.generated] ?? "There is no price for this brief right now."
            }
        }
    }

    func catalogRows(model: EditorModel) -> [MusicCandidate] {
        guard catalog?.scope == QuoteScope(model) else { return [] }
        return catalog?.matches ?? []
    }

    func nextPage(model: EditorModel) -> Int? {
        guard catalog?.scope == QuoteScope(model) else { return nil }
        return catalog?.nextPage
    }

    func generationChoice(model: EditorModel) -> MusicCandidate? {
        guard pricedChoice?.scope == QuoteScope(model) else { return nil }
        return pricedChoice?.candidate
    }

    func clearStaleResults(model: EditorModel) {
        syncScope(model: model)
        let scope = QuoteScope(model)
        if let catalog, catalog.scope != scope { clearCatalog() }
        if let pricedChoice, pricedChoice.scope != scope { clearPrice() }
    }

    /// ▶ stops the editor's playback and any other candidate; a second click stops this one.
    func toggleAudition(_ candidate: MusicCandidate, model: EditorModel) {
        guard !isUsing else { return }
        if playing == candidate.id { stopAudition(); return }
        guard let url = auditionURL(candidate, model: model) else { return }
        dismissFailure()
        model.preview.pause(); model.isPlaying = false
        let token = UUID()
        auditionID = token
        playing = candidate.id
        audition.play(url) { [weak self] succeeded in
            guard let self, self.auditionID == token else { return }
            self.stopAudition()
            if !succeeded, !self.isBusy { self.phase = .failed("Can’t preview “\(candidate.title)”. Try another track.") }
        }
    }

    func stopAudition() {
        audition.stop()
        playing = nil; auditionID = nil
    }

    /// Where ▶ plays from: the stored track when it is the one in use, else the candidate's own file or stream.
    func auditionURL(_ candidate: MusicCandidate, model: EditorModel) -> URL? {
        if let entry = model.currentMusic, candidate.id == Self.usingID(entry) {
            guard let url = candidate.audioURL, FileManager.default.isReadableFile(atPath: url.path) else { return nil }
            return url
        }
        if candidate.source == .library, !catalogRows(model: model).contains(candidate) { return nil }
        guard let url = candidate.audioURL else { return nil }
        return !url.isFileURL || FileManager.default.isReadableFile(atPath: url.path) ? url : nil
    }

    /// Use: stores the track in the project's music folder and sets it under the open clip (or the full video). A
    /// generated candidate is made first; its priced button is the approval and a failure is never retried.
    func use(_ candidate: MusicCandidate, model: EditorModel, timelineShape: ClipPlanMusicShape? = nil) {
        guard model.capabilities.edit else { return }
        guard !isBusy else { return }
        let scope = QuoteScope(model)
        let importer: MusicPanelServices
        if candidate.source == .generated {
            guard let choice = pricedChoice, choice.scope == scope, choice.candidate == candidate else {
                phase = .failed("Get a new price for this clip and brief."); return
            }
            importer = choice.services
            pricedChoice = nil
        } else {
            guard candidate.source != .library || catalogRows(model: model).contains(candidate) else {
                phase = .failed("Search the library again before picking this track."); return
            }
            guard let available = services ?? model.defaultMusicServices() else { return }
            importer = available
        }
        stopAudition()
        phase = .using(candidate.id)
        let projectId = model.project.id, clipId = model.renderedActiveClipID, dataRoot = model.app.locations.root
        work?.cancel()
        work = Task { [weak self] in
            do {
                guard !Task.isCancelled else { return }
                guard QuoteScope(model) == scope else { self?.phase = .idle; return }
                var entry = try await importer.importTrack(candidate, projectId: projectId, clipId: clipId, dataRoot: dataRoot)
                guard let self, !Task.isCancelled else { return }
                guard QuoteScope(model) == scope else {
                    self.phase = .failed("The clip changed. The downloaded track was not added to it."); return
                }
                if let current = model.currentMusic {
                    entry.gainDb = current.gainDb; entry.ducking = current.ducking; entry.duckDb = current.duckDb
                    entry.fadeInSeconds = current.fadeInSeconds; entry.fadeOutSeconds = current.fadeOutSeconds
                }
                if let timelineShape, let shaped = try? timelineShape.placing(entry, in: model.project, clipID: clipId) { entry = shaped }
                try self.apply(entry, clipId: clipId, model: model, name: "Add music")
                self.phase = .idle
            } catch is CancellationError {
                guard !Task.isCancelled else { return }
                self?.phase = .idle
            } catch {
                guard !Task.isCancelled else { return }
                self?.phase = .failed(UserMessages.message(error))
                if self != nil { Task { await model.app.logFailure(error, context: .music) } }
            }
        }
    }

    func remove(model: EditorModel) {
        guard model.capabilities.edit, !isUsing, model.currentMusic != nil else { return }
        stopAudition()
        do { try apply(nil, clipId: model.renderedActiveClipID, model: model, name: "Remove music") }
        catch {
            phase = .failed(UserMessages.message(error))
            Task { await model.app.logFailure(error, context: .music) }
        }
    }

    /// The one volume control: the bed's level under the voice, −40 to 0 dB (−20 by default).
    func setGain(_ gainDb: Double, model: EditorModel) {
        guard model.capabilities.edit, let entry = model.currentMusic else { return }
        let rounded = (gainDb.clamped(to: ProjectMusic.gainRange) * 2).rounded() / 2
        guard rounded != entry.gainDb else { return }
        model.commitTimelineItemEdit(.setTrackGain(track: entry.id, db: rounded))
    }

    private func apply(_ entry: ProjectMusic?, clipId: String?, model: EditorModel, name: String) throws {
        let next = try MusicProject.setting(entry.map { MusicProject.unique($0, in: model.project) }, clipId: clipId, in: model.project)
        model.replace(next, name: name)
    }

    func dismissFailure() { if case .failed = phase { phase = .idle } }

    /// Waits for the current search or Use to finish (the autopilot plan and tests wait on it).
    func settled() async { await work?.value }

    /// The candidate id a stored entry answers to, so the row that made it shows "Using".
    static func usingID(_ entry: ProjectMusic) -> String { "using-" + entry.id }

    func currentRow(model: EditorModel) -> MusicCandidate? {
        guard let entry = model.currentMusic else { return nil }
        return MusicCandidate(id: Self.usingID(entry), source: entry.source, title: entry.title, creator: entry.creator,
                              license: entry.license, attribution: entry.attribution, sourceUrl: entry.sourceUrl,
                              audioURL: MusicRenderInput.url(for: entry.asset, dataRoot: model.app.locations.root),
                              fileExtension: (entry.asset.file as NSString).pathExtension, prompt: entry.prompt,
                              durationSeconds: entry.asset.durationSeconds)
    }
}

extension EditorModel {
    /// Music plays at normal speed under the final clip, so its quote follows the rendered duration.
    var musicRenderSeconds: Double { renderedActiveClipID.map(makeItRenderedSeconds) ?? duration }

    /// The track under the open clip, or under the full video in the full-take tab.
    var currentMusic: ProjectMusic? { MusicProject.entry(for: renderedActiveClipID, in: project) }

    /// The track an export of `target` ("full" or a clip id) mixes, for its credit line.
    func musicCredit(for target: String) -> ProjectMusic? {
        MusicProject.entry(for: target == "full" ? nil : target, in: project)
    }

    /// The app's own sources: Openverse, Eleven Music through the price catalog and spend ledger, and the Music folder.
    func defaultMusicServices() -> MusicPanelServices? {
        let region = ElevenLabsRegion(rawValue: app.string("transcription.elevenlabs.region", fallback: "default")) ?? .default
        let library = OpenverseMusicClient()
        let eleven = app.shared.flatMap { try? VoiceLabPriceCatalog.load(shared: $0) }.map { catalog in
            ElevenMusicClient(keys: app.secrets, catalog: catalog, spend: VoiceLabSpendLedger(locations: app.locations), region: region)
        }
        let keys = app.providerKeyStore
        let service = MusicSuggestionService(library: library, eleven: eleven, hasElevenKey: { await keys.hasKey(for: "elevenlabs") },
                                             folder: { MusicPanel.folder() })
        return MusicPanelServices(
            suggest: { brief, seconds in await service.candidates(for: brief, clipSeconds: seconds) },
            fetch: { candidate in
                switch candidate.source {
                case .library: return try await library.download(candidate)
                case .generated, .file: throw VoxClipError.mediaMissing(candidate.title)
                }
            },
            folder: { MusicPanel.folder() },
            generate: { candidate, accepted in
                guard let eleven, let quote = service.quote(for: candidate) else {
                    throw VoxClipError.providerError("This price is out of date. Get a new price for this brief.", provider: "elevenlabs")
                }
                return try await eleven.compose(quote, accepted: accepted)
            },
            browse: { brief, seconds, page in try await service.browse(brief, clipSeconds: seconds, page: page) },
            price: { brief, seconds in await service.generation(for: brief, clipSeconds: seconds) })
    }

    /// M1 on the timeline: the track spans the clip on either axis, with its title and level.
    func timelineMusic(on axis: TimelineAxis) -> TimelineMusic? {
        guard let entry = currentMusic else { return nil }
        let range: Range<Double>
        if axis == .source {
            let bounds = scopeSourceRange ?? 0...sourceDuration
            range = bounds.lowerBound..<max(bounds.lowerBound + 0.001, bounds.upperBound)
        } else {
            range = 0..<max(0.001, duration)
        }
        return TimelineMusic(title: entry.title, range: range, gainDb: entry.gainDb, fadeIn: entry.fadeInSeconds,
                             fadeOut: entry.fadeOutSeconds, ducking: entry.ducking)
    }
}

/// What the M1 lane draws.
struct TimelineMusic: Equatable {
    let title: String
    let range: Range<Double>
    let gainDb: Double
    let fadeIn: Double
    let fadeOut: Double
    let ducking: Bool
}
