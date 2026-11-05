@preconcurrency import AVFoundation
import Foundation
import Observation
import VoxClipCore
import VoxClipMedia

/// Plays one candidate in the Music section; stopping it never touches the editor's player.
@MainActor protocol MusicAuditioning: AnyObject {
    func play(_ url: URL)
    func stop()
}

@MainActor final class AVMusicAudition: MusicAuditioning {
    private var player: AVPlayer?
    func play(_ url: URL) {
        stop()
        let player = AVPlayer(url: url)
        self.player = player
        player.play()
    }
    func stop() { player?.pause(); player = nil }
}

/// What the Music section asks of the outside world; tests pass stubs, the app builds them from its own services.
struct MusicPanelServices: Sendable {
    var suggest: @Sendable (MusicBrief, Double) async -> MusicSuggestionResult
    /// The bytes behind a library candidate (downloaded) or a generated one (composed, paid); own files are read directly.
    var fetch: @Sendable (MusicCandidate) async throws -> Data
    var folder: @Sendable () -> URL?
}

/// The Music section's state (doc/spec/music.md §6): Claude's best three, the user's folder, search, the track in use
/// and the one candidate playing. Every change to the project goes through `EditorModel.replace`, so it undoes.
@MainActor @Observable final class MusicPanel {
    enum Phase: Equatable { case idle, searching, using(String), failed(String) }
    private(set) var candidates: [MusicCandidate] = []
    private(set) var notes: [String] = []
    private(set) var folderFiles: [MusicCandidate] = []
    private(set) var phase = Phase.idle
    private(set) var playing: String?
    private(set) var brief: MusicBrief?
    var query = ""
    @ObservationIgnored var services: MusicPanelServices?
    @ObservationIgnored var audition: any MusicAuditioning = AVMusicAudition()
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var loadedFolder: URL?

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

    /// Claude's (or the autopilot plan's) suggestion: fetches the best three across sources.
    func suggest(_ brief: MusicBrief, model: EditorModel) {
        guard let services = services ?? model.defaultMusicServices() else { return }
        self.brief = brief
        phase = .searching
        let seconds = model.duration
        work?.cancel()
        work = Task { [weak self] in
            let result = await services.suggest(brief, seconds)
            guard let self, !Task.isCancelled else { return }
            self.candidates = result.candidates
            self.notes = MusicSource.allCases.compactMap { result.notes[$0] }
            if self.phase == .searching { self.phase = .idle }
        }
    }

    /// The search field: its words become both the library query and the generation mood.
    func search(model: EditorModel) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        suggest(MusicBrief(mood: text, query: text), model: model)
    }

    /// ▶ stops the editor's playback and any other candidate; a second click stops this one.
    func toggleAudition(_ candidate: MusicCandidate, model: EditorModel) {
        if playing == candidate.id { stopAudition(); return }
        guard let url = auditionURL(candidate, model: model) else { return }
        model.preview.pause(); model.isPlaying = false
        audition.play(url)
        playing = candidate.id
    }

    func stopAudition() {
        audition.stop()
        playing = nil
    }

    /// Where ▶ plays from: the stored track when it is the one in use, else the candidate's own file or stream.
    func auditionURL(_ candidate: MusicCandidate, model: EditorModel) -> URL? {
        if let entry = model.currentMusic, candidate.id == Self.usingID(entry) {
            return MusicRenderInput.url(for: entry.asset, dataRoot: model.app.locations.root)
        }
        return candidate.needsGeneration ? nil : candidate.audioURL
    }

    /// Use: stores the track in the project's music folder and sets it under the open clip (or the full video). A
    /// generated candidate is made first; its priced button is the approval and a failure is never retried.
    func use(_ candidate: MusicCandidate, model: EditorModel) {
        guard model.capabilities.edit, phase != .using(candidate.id) else { return }
        guard let services = services ?? model.defaultMusicServices() else { return }
        stopAudition()
        phase = .using(candidate.id)
        let projectId = model.project.id, clipId = model.renderedActiveClipID, dataRoot = model.app.locations.root
        work?.cancel()
        work = Task { [weak self] in
            do {
                let data: Data
                if candidate.source == .file, let url = candidate.audioURL {
                    data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
                } else {
                    data = try await services.fetch(candidate)
                }
                let entry = try await MusicAssetStore.importing(data, candidate: candidate, projectId: projectId, clipId: clipId, dataRoot: dataRoot)
                guard let self, !Task.isCancelled else { return }
                try self.apply(entry, clipId: clipId, model: model, name: "Add music")
                self.phase = .idle
            } catch is CancellationError {
                self?.phase = .idle
            } catch {
                self?.phase = .failed(UserMessages.message(error))
            }
        }
    }

    func remove(model: EditorModel) {
        guard model.capabilities.edit, model.currentMusic != nil else { return }
        stopAudition()
        do { try apply(nil, clipId: model.renderedActiveClipID, model: model, name: "Remove music") }
        catch { phase = .failed(UserMessages.message(error)) }
    }

    /// The one volume control: the bed's level under the voice, −40 to 0 dB (−20 by default).
    func setGain(_ gainDb: Double, model: EditorModel) {
        guard model.capabilities.edit, var entry = model.currentMusic else { return }
        let rounded = (gainDb.clamped(to: ProjectMusic.gainRange) * 2).rounded() / 2
        guard rounded != entry.gainDb else { return }
        entry.gainDb = rounded
        do { try apply(entry, clipId: entry.clipId, model: model, name: "Change music volume") }
        catch { phase = .failed(UserMessages.message(error)) }
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

    /// The rows: the track in use first (as its own candidate), then the suggestions, else the folder's files.
    func rows(model: EditorModel) -> [MusicCandidate] {
        var rows: [MusicCandidate] = []
        if let entry = model.currentMusic {
            rows.append(MusicCandidate(id: Self.usingID(entry), source: entry.source, title: entry.title, creator: entry.creator,
                                       license: entry.license, attribution: entry.attribution, sourceUrl: entry.sourceUrl,
                                       fileExtension: (entry.asset.file as NSString).pathExtension, prompt: entry.prompt,
                                       durationSeconds: entry.asset.durationSeconds))
        }
        let suggestions = candidates.isEmpty ? Array(folderFiles.prefix(3)) : candidates
        rows += suggestions.filter { candidate in
            guard let entry = model.currentMusic else { return true }
            return !(candidate.title == entry.title && candidate.source == entry.source)
        }
        return rows
    }
}

extension EditorModel {
    /// The track under the open clip, or under the full video in the full-take tab.
    var currentMusic: ProjectMusic? { MusicProject.entry(for: renderedActiveClipID, in: project) }

    /// The track an export of `target` ("full" or a clip id) mixes, for its credit line.
    func musicCredit(for target: String) -> ProjectMusic? {
        MusicProject.entry(for: target == "full" ? nil : target, in: project)
    }

    /// The app's own sources: Openverse, Eleven Music through the price catalog and spend ledger, and the Music folder.
    func defaultMusicServices() -> MusicPanelServices? {
        guard let shared = app.shared, let catalog = try? VoiceLabPriceCatalog.load(shared: shared) else { return nil }
        let region = ElevenLabsRegion(rawValue: app.string("transcription.elevenlabs.region", fallback: "default")) ?? .default
        let library = OpenverseMusicClient()
        let eleven = ElevenMusicClient(keys: app.secrets, catalog: catalog, spend: VoiceLabSpendLedger(locations: app.locations), region: region)
        let keys = app.providerKeyStore
        let service = MusicSuggestionService(library: library, eleven: eleven, hasElevenKey: { await keys.hasKey(for: "elevenlabs") },
                                             folder: { MusicPanel.folder() })
        return MusicPanelServices(
            suggest: { brief, seconds in await service.candidates(for: brief, clipSeconds: seconds) },
            fetch: { candidate in
                switch candidate.source {
                case .library: return try await library.download(candidate)
                case .generated:
                    guard let quote = service.quote(for: candidate) else {
                        throw VoxClipError.providerError("This price is out of date. Search again to see the current price.", provider: "elevenlabs")
                    }
                    return try await eleven.compose(quote)
                case .file: throw VoxClipError.mediaMissing(candidate.title)
                }
            },
            folder: { MusicPanel.folder() })
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
