import CoreGraphics
import Foundation
import Observation
import VoxClipCore

/// What Home shows for one recent project (design §7 and §5.4).
struct RecentProject: Equatable, Sendable {
    let url: URL
    let title: String
    let duration: Double
    let keptClips: Int
    let modified: Date
    let contentKey: String
    /// The resolved media file; nil when the video was moved or deleted.
    let media: URL?
    /// False for an audio-only project (`media.source.video` is null).
    let hasVideo: Bool
    /// The first kept word's source time, where the poster frame comes from (§5.4.7).
    let frameTime: Double
    /// The edited take's caption cards from VoxClipCore, with transcript words and with
    /// the project title for when placeholder words are off (§5.4.2), and the style they
    /// were made in. `projectStyleId` is the project's own choice, which may be "off".
    let words: CaptionCardText
    let titleWords: CaptionCardText
    let styleId: String
    let projectStyleId: String
    let overrides: [String: JSONValue]
    let language: String?
}

/// Recent-project metadata and stand-ins for Home. Each project file is decoded and
/// its media checked off the main actor, and the result is kept until the file's
/// modification date or the cards' resolved style changes (design §5.4.5). Each tile
/// gets its caption card first and its poster frame when that is decoded; VoxClipCore's
/// `MediaStandIn.resolve` picks between them (design §5.4.1).
@MainActor @Observable final class RecentProjects {
    private(set) var items: [URL: RecentProject] = [:]
    private(set) var frames: [URL: CGImage] = [:]
    private(set) var cards: [URL: CGImage] = [:]
    /// The same cards at sidebar size, without plates (design §5.4.3).
    private(set) var rowCards: [URL: CGImage] = [:]
    /// The card text the drawn cards show.
    private(set) var drawn: [URL: CaptionCardText] = [:]
    private(set) var unreadable: Set<URL> = []
    @ObservationIgnored private var loadedDates: [URL: Date] = [:]
    @ObservationIgnored private var cardKeys: [URL: CardKey] = [:]
    @ObservationIgnored private var tasks: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private unowned let app: AppModel

    private struct CardKey: Equatable { let text: CaptionCardText; let styleId: String; let overrides: [String: JSONValue] }

    init(app: AppModel) { self.app = app }

    /// A Home tile's stand-in sources, or a Recent row's at sidebar size.
    func sources(_ url: URL, row: Bool = false) -> StandInSources {
        StandInSources(frame: frames[url], card: drawn[url] ?? .none, styleId: items[url]?.styleId ?? "", cardImage: row ? rowCards[url] : cards[url])
    }

    func status(_ url: URL) -> MediaStatus {
        guard let item = items[url] else { return .loading }
        if item.media == nil { return .missing }
        if unreadable.contains(url) { return .unreadable }
        return item.hasVideo ? .none : .audioOnly
    }

    /// Loads any project that is new or changed on disk, redraws cards whose words or
    /// style changed, and forgets projects no longer listed.
    func refresh(_ urls: [URL]) {
        let listed = Set(urls)
        for url in Set(items.keys).union(tasks.keys).subtracting(listed) {
            tasks.removeValue(forKey: url)?.cancel()
            items[url] = nil; frames[url] = nil; cards[url] = nil; rowCards[url] = nil; drawn[url] = nil; unreadable.remove(url)
            loadedDates[url] = nil; cardKeys[url] = nil
        }
        let wordsVisible = app.bool("general.showPlaceholderWords", fallback: true)
        let defaultStyle = app.string("captions.defaultStyleId", fallback: "vox-highlight")
        for url in urls where tasks[url] == nil {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let item = items[url], date == nil || loadedDates[url] == date,
               AppModel.cardStyle(item.projectStyleId, default: defaultStyle, in: app.styles)?.id ?? "" == item.styleId {
                guard cardKeys[url] != cardKey(item, wordsVisible: wordsVisible) else { continue }
                tasks[url] = Task { [weak self] in
                    await self?.drawCard(item, wordsVisible: wordsVisible)
                    self?.tasks[url] = nil
                }
                continue
            }
            tasks[url] = Task { [weak self] in
                await self?.load(url, date: date, wordsVisible: wordsVisible)
                self?.tasks[url] = nil
            }
        }
    }

    func cancel() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    private func load(_ url: URL, date: Date?, wordsVisible: Bool) async {
        let styles = app.styles, defaultStyle = app.string("captions.defaultStyleId", fallback: "vox-highlight"), resources = app.captionResources
        let decoded = await Task.detached(priority: .utility) { () -> (project: Project, title: String, words: CaptionCardText, titleWords: CaptionCardText, styleId: String, frameTime: Double)? in
            guard let data = try? Data(contentsOf: url), let project = try? JSONProjectStore.decode(data) else { return nil }
            let title = WorkspaceShell.projectTitle(project, fileURL: url)
            let style = AppModel.cardStyle(project.captions.styleId, default: defaultStyle, in: styles)
            func card(_ wordsVisible: Bool) -> CaptionCardText {
                guard let style, let resources else { return .none }
                return CaptionCardText.make(project: project, scope: .fullTake, style: style, wordsVisible: wordsVisible, resources: resources)
            }
            let cut = Set(project.edits.cutWordIds)
            let first = project.transcript?.words.first { $0.kind == .word && !cut.contains($0.id) }
            return (project, title, card(true), card(false), style?.id ?? "", first?.start ?? 0)
        }.value
        guard let decoded, !Task.isCancelled else { return }
        let project = decoded.project
        let media = try? await app.projectStore.resolveSource(for: project, projectURL: url)
        guard !Task.isCancelled else { return }
        let item = RecentProject(url: url, title: decoded.title, duration: project.media.source.durationSeconds,
            keptClips: project.edits.clips.filter { $0.origin == .manual || $0.selected }.count, modified: date ?? project.modifiedAt,
            contentKey: project.media.source.contentKey, media: media, hasVideo: project.media.source.video != nil,
            frameTime: decoded.frameTime, words: decoded.words, titleWords: decoded.titleWords, styleId: decoded.styleId,
            projectStyleId: project.captions.styleId, overrides: project.captions.overrides, language: project.transcript?.language)
        items[url] = item
        loadedDates[url] = date
        frames[url] = nil
        unreadable.remove(url)
        await drawCard(item, wordsVisible: wordsVisible)
        await loadFrame(item)
    }

    private func cardKey(_ item: RecentProject, wordsVisible: Bool) -> CardKey {
        CardKey(text: wordsVisible ? item.words : item.titleWords, styleId: item.styleId, overrides: item.overrides)
    }

    /// Draws the tile and row cards for the switch's text. A card with no words is still
    /// drawn, as the style's backdrop, for the transcribing state (§5.4.1).
    private func drawCard(_ item: RecentProject, wordsVisible: Bool) async {
        let key = cardKey(item, wordsVisible: wordsVisible)
        guard let style = app.styles.first(where: { $0.id == item.styleId }) else {
            cards[item.url] = nil; rowCards[item.url] = nil; drawn[item.url] = key.text
            cardKeys[item.url] = key
            return
        }
        func input(_ fit: CardFit) -> CaptionCardInput {
            CaptionCardInput(text: key.text, style: style, previewBackground: app.previewBackgrounds[style.id], overrides: item.overrides, language: item.language, fit: fit)
        }
        let image = await app.captions.card(input(.home()))
        let row = await app.captions.card(input(.row()))
        guard !Task.isCancelled else { return }
        cards[item.url] = image
        rowCards[item.url] = row
        drawn[item.url] = key.text
        cardKeys[item.url] = key
    }

    private func loadFrame(_ item: RecentProject) async {
        guard let media = item.media, item.hasVideo else { return }
        let result = await ThumbnailCache.shared.frame(of: media, contentKey: item.contentKey, at: item.frameTime, scope: 0...max(0, item.duration),
                                                       filling: CGSize(width: 280, height: 158), cache: app.locations.cache)
        switch result {
        case .frame(let image)?: frames[item.url] = image
        case .unreadable?: unreadable.insert(item.url)
        case .black?, nil: break
        }
    }

    /// "Today", "Yesterday", a weekday within the week, then "Oct 21" (design §7).
    static func relativeDay(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days > 0 && days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.month(.abbreviated).day()) }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
