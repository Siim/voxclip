#if DEBUG
import AppKit
import SwiftUI
import VoxClipCore

/// Home in the main window (step 4) with its media stand-ins (design §5.4): card words,
/// cards in every style, frame choice and posters, every tile state, search, first run
/// and the whole-window drop target, with light and dark captures.
@MainActor enum DebugHome {
    static func run(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        func capture<Content: View>(_ content: Content, _ name: String, size: NSSize = NSSize(width: 1280, height: 800)) async throws {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                try await DebugUISuite.snapshot(content.environment(app), name: "\(name)-\(suffix)", size: size, appearance: appearance, directory: directory, active: true, mainWindow: true)
            }
        }
        guard let root = app.shared?.root, let transcript = fixture.transcript, let resources = app.captionResources else { throw CocoaError(.coderInvalidValue) }
        let cut = Set(fixture.edits.cutWordIds)
        let kept = transcript.words.filter { $0.kind == .word && !cut.contains($0.id) }.map(\.id)
        /// The fixture with its kept words re-spelt to `opening`.
        func spoken(_ opening: String) -> Project {
            var project = fixture
            project.edits.corrections = Dictionary(uniqueKeysWithValues: zip(kept, opening.split(separator: " ").map(String.init)))
            return project
        }
        let style = { (id: String) in app.styles.first { $0.id == id } }
        /// The edited take's card as Home and the sidebar make it, with VoxClipCore.
        func card(_ project: Project, _ styleId: String, wordsVisible: Bool = true) -> CaptionCardText {
            style(styleId).map { CaptionCardText.make(project: project, scope: .fullTake, style: $0, wordsVisible: wordsVisible, resources: resources) } ?? .none
        }
        let sample = card(spoken("Um, The pattern starts with the milk."), "box-highlight")
        check("cards take VoxClipCore's words: no leading filler, no trailing stopword (\(sample.words.map(\.text)))",
              sample.words.map(\.text) == ["The", "pattern", "starts"] && sample.keyIndex == 1 && sample.source == .transcript)
        var latte = spoken("Um, The pattern starts")
        latte.title = "Latte art for beginners"
        let title = card(latte, "box-highlight", wordsVisible: false)
        check("with placeholder words off the card sets the project title", title.source == .title && title.words.map(\.text) == ["Latte", "art", "for", "beginners"])
        var allCut = fixture
        allCut.edits.cutWordIds = transcript.words.map(\.id)
        var untranscribed = fixture
        untranscribed.transcript = nil
        check("a take with every word cut or no transcript has no card", card(allCut, "karaoke").source == .none && card(untranscribed, "karaoke").source == .none)
        let backdrops = ["karaoke": nil, "neon": "#16171D", "clean-subtitle": "#3A3C45", "vox-bold-plus": nil, "vox-bold": "#3A3C45"] as [String: String?]
        let wrong = backdrops.keys.sorted().filter { id in style(id).map { CaptionCardLook.backdrop($0, previewBackground: app.previewBackgrounds[id]) != backdrops[id]! } ?? true }
        check("card backdrops follow the style: stage black, dark preview colour or the plate grey\(wrong.isEmpty ? "" : " (wrong: \(wrong.joined(separator: ", ")))")", wrong.isEmpty)
        if var karaoke = style("karaoke") {
            CaptionCardLook.adapt(&karaoke, fit: .home(), lines: 2, stageBlack: true)
            check("cards on stage black drop near-black strokes and shadows", karaoke.stroke == nil && karaoke.shadows.isEmpty)
        }
        var drawn = 0, rows = 0
        let opening = spoken("Um, The pattern starts with the milk.")
        for caption in app.styles {
            let text = card(opening, caption.id)
            func input(_ fit: CardFit) -> CaptionCardInput {
                CaptionCardInput(text: text, style: caption, previewBackground: app.previewBackgrounds[caption.id], overrides: [:], language: "en", fit: fit)
            }
            if !text.words.isEmpty, let image = await app.captions.card(input(.home())), image.width == 450, image.height == 252 { drawn += 1 }
            if await app.captions.card(input(.row())) != nil, await app.captions.card(input(.clip(captionY: caption.position.y))) != nil { rows += 1 }
        }
        check("every caption style draws a Home card", !app.styles.isEmpty && drawn == app.styles.count)
        check("every caption style draws Full Take and clip-row cards", !app.styles.isEmpty && rows == app.styles.count)
        let black = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        check("a black frame reads as black", black.map(ThumbnailCache.isBlack) == true)
        check("stand-in names read title and state", MediaStatus.transcribing(fraction: 0.42, stage: .transcribing).spokenState == "transcribing 42 percent"
              && MediaStatus.missing.spokenState == "video not found" && MediaStatus.unreadable.spokenState == "video can't be read"
              && MediaStatus.audioOnly.spokenState == "audio only" && MediaStatus.none.spokenState == nil)
        let now = Date()
        check("recent dates read Today and Yesterday", RecentProjects.relativeDay(now) == "Today" && RecentProjects.relativeDay(now.addingTimeInterval(-86_400)) == "Yesterday")

        let saved = app.recent, connector = app.settings.values["llm.connector"], placeholderWords = app.settings.values["general.showPlaceholderWords"]
        defer { app.recent = saved; app.settings.values["llm.connector"] = connector; app.settings.values["general.showPlaceholderWords"] = placeholderWords }
        app.recent = []
        app.settings.values["llm.connector"] = nil
        app.settings.values["general.showPlaceholderWords"] = nil
        let firstRun = WorkspaceShell(app: app)
        try await capture(WorkspaceView(shell: firstRun), "home-first-run")

        let folder = directory.appendingPathComponent("recent", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let corrupt = folder.appendingPathComponent("night-shift-notes.mov")
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7919 &+ 13) }).write(to: corrupt)
        func project(_ title: String, media: String?, duration: Double, clips: Int, daysAgo: Double, style: String, opening: String? = nil,
                     audioOnly: Bool = false, transcribed: Bool = true) throws -> URL {
            var project = opening.map(spoken) ?? fixture
            project.id = UUID().uuidString.lowercased()
            project.title = title
            project.captions.styleId = style
            if let media {
                let url = media.hasPrefix("/") ? URL(fileURLWithPath: media) : root.appendingPathComponent("fixtures/media/\(media)")
                project.media.source.absolutePath = url.path
                project.media.source.sizeBytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                project.media.source.contentKey = try JSONProjectStore.contentKey(for: url)
            } else {
                project.media.source.absolutePath = folder.appendingPathComponent("moved-away.mp4").path
            }
            if audioOnly { project.media.source.video = nil }
            if !transcribed { project.transcript = nil; project.edits.cutWordIds = []; project.edits.cutPauseIds = []; project.edits.corrections = [:] }
            project.media.source.relativePath = nil
            project.media.source.durationSeconds = duration
            project.edits.activeClipId = nil
            project.edits.clips = transcribed ? (0..<clips).map { index in
                let start = index % transcript.words.count, end = min(transcript.words.count - 1, start + index / transcript.words.count)
                return ClipRange(id: "recent-\(index)", startWordId: transcript.words[start].id, endWordId: transcript.words[end].id, title: "Clip \(index + 1)")
            } : []
            let url = folder.appendingPathComponent("\(title).voxclip")
            try JSONProjectStore.encode(project).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: url.path)
            return url
        }
        let urls = [
            try project("Five questions", media: "fillers-chirp.mp4", duration: 144, clips: 4, daysAgo: 0, style: "karaoke"),
            try project("Studio tour", media: "counter-1080p.mp4", duration: 245, clips: 6, daysAgo: 1, style: "two-tone"),
            try project("Launch notes", media: "bars-1080p.mp4", duration: 58, clips: 2, daysAgo: 3, style: "neon"),
            try project("Q&A, October", media: "big-2400x1350.mp4", duration: 760, clips: 9, daysAgo: 5, style: "box-highlight"),
            try project("Podcast intro", media: nil, duration: 192, clips: 3, daysAgo: 9, style: "outline", opening: "Um, Nobody skips the intro. Thanks"),
            try project("Why I left agency life", media: "joins-tone.mov", duration: 408, clips: 5, daysAgo: 14, style: "editorial"),
            try project("Night shift notes", media: corrupt.path, duration: 260, clips: 3, daysAgo: 15, style: "active-pop", opening: "Three pages every night, no excuses"),
            try project("Morning pages", media: "fillers-chirp.mp4", duration: 192, clips: 2, daysAgo: 16, style: "vox-highlight", opening: "Three pages every morning", audioOnly: true),
            try project("Desk setup", media: "counter-1080p.mp4", duration: 151, clips: 0, daysAgo: 17, style: "clean-subtitle"),
            try project("Opening day recap", media: nil, duration: 129, clips: 0, daysAgo: 20, style: "karaoke", transcribed: false),
            try project("First take", media: "fillers-chirp.mp4", duration: 75, clips: 1, daysAgo: 23, style: "pill")
        ]
        app.recent = urls
        let recents = app.recentProjects
        recents.refresh(urls)
        func settled(_ url: URL) -> Bool {
            guard let item = recents.items[url] else { return false }
            let framed = item.media == nil || !item.hasVideo || recents.frames[url] != nil || recents.unreadable.contains(url)
            return framed && (item.words.source == .none || recents.cards[url] != nil)
        }
        let started = Date()
        for _ in 0..<1200 where !urls.allSatisfy(settled) { try await Task.sleep(for: .milliseconds(25)) }
        check("recent projects settle within 30 s (\(Int(Date().timeIntervalSince(started) * 1000)) ms)", urls.allSatisfy(settled))
        check("recent metadata reads the title, take length and kept clips", recents.items[urls[0]]?.title == "Five questions" && recents.items[urls[0]]?.duration == 144 && recents.items[urls[0]]?.keptClips == 4 && recents.items[urls[8]]?.keptClips == 0)
        /// What a tile draws: VoxClipCore's precedence over the tile's sources.
        func standIn(_ url: URL) -> MediaStandIn {
            let sources = recents.sources(url)
            return MediaStandIn.resolve(status: recents.status(url), hasFrame: sources.frame != nil, card: sources.card, styleId: sources.styleId)
        }
        check("a moved video shows its caption card with the missing chip", recents.status(urls[4]) == .missing && recents.cards[urls[4]] != nil && recents.frames[urls[4]] == nil
              && recents.items[urls[4]]?.words.words.map(\.text) == ["Nobody", "skips"] && standIn(urls[4]) == .card(recents.sources(urls[4]).card, styleId: "outline"))
        check("an unreadable video shows its card with the warning chip", recents.status(urls[6]) == .unreadable && recents.cards[urls[6]] != nil)
        check("an audio-only project shows its card with the Audio only chip", recents.status(urls[7]) == .audioOnly && recents.cards[urls[7]] != nil && recents.frames[urls[7]] == nil)
        check("a missing video that was never transcribed stays stage black", recents.status(urls[9]) == .missing && standIn(urls[9]) == .black)
        check("recent thumbnails come from each take's own media", [0, 1, 2, 3, 5, 8, 10].allSatisfy { recents.frames[urls[$0]] != nil }
              && [0, 1, 2, 3, 5, 8, 10].allSatisfy { standIn(urls[$0]) == .frame })
        let poster = app.locations.cache.appendingPathComponent(recents.items[urls[2]]?.contentKey ?? "-").appendingPathComponent("thumbs")
        check("poster frames persist in the take's cache entry", ((try? FileManager.default.contentsOfDirectory(atPath: poster.path)) ?? []).contains { $0.hasPrefix("poster-") && $0.hasSuffix(".jpg") })

        let shell = WorkspaceShell(app: app)
        let open = try VoxClipDocument(data: Data(contentsOf: urls[0]))
        open.adoptOpenedLocation(urls[0])
        await shell.attachForTesting(open, selection: .home)
        check("Home keeps the open project and titles the window VoxClip", shell.showsHome && shell.document === open && shell.title == "VoxClip")
        try await capture(WorkspaceView(shell: shell), "home")
        shell.editor?.progress = "Transcribing on this Mac · 42%"
        shell.editor?.progressFraction = 0.42
        shell.editor?.progressStage = .transcribing
        try await capture(WorkspaceView(shell: shell), "home-transcribing")
        shell.editor?.progress = nil
        shell.editor?.progressFraction = nil
        shell.editor?.progressStage = nil

        let before = recents.cards[urls[4]]
        app.settings.values["general.showPlaceholderWords"] = .bool(false)
        recents.refresh(urls)
        for _ in 0..<200 where recents.cards[urls[4]] === before { try await Task.sleep(for: .milliseconds(25)) }
        check("turning placeholder words off redraws cards with the title", recents.cards[urls[4]] != nil && recents.cards[urls[4]] !== before)
        try await capture(WorkspaceView(shell: shell), "home-title-cards")
        let titled = recents.cards[urls[4]]
        app.settings.values["general.showPlaceholderWords"] = nil
        recents.refresh(urls)
        for _ in 0..<200 where recents.cards[urls[4]] === titled { try await Task.sleep(for: .milliseconds(25)) }

        try await capture(standIns(recents, urls), "standins", size: NSSize(width: 1000, height: 560))
        shell.homeQuery = "podcst"
        try await capture(WorkspaceView(shell: shell), "home-search-empty")
        shell.homeQuery = ""
        shell.dropTargeted = true
        try await capture(WorkspaceView(shell: shell), "home-drop")
        shell.selection = .fullTake
        try await capture(WorkspaceView(shell: shell), "editor-drop")
        shell.dropTargeted = false

        let missing = try VoxClipDocument(data: Data(contentsOf: urls[4]))
        missing.adoptOpenedLocation(urls[4])
        let replaced = await shell.replaceProject(with: missing)
        await shell.started?.value
        check("a missing project opens in place in its missing-media state", replaced && shell.document === missing && shell.editor?.mediaResolved == false && shell.editor?.previewError?.contains("moved-away.mp4") == true)
        shell.editor?.close()
        return results
    }

    /// Every §5.4.4 state at tile and row size, for the stand-in captures.
    private static func standIns(_ recents: RecentProjects, _ urls: [URL]) -> some View {
        func pending(_ url: URL, row: Bool) -> StandInSources { var sources = recents.sources(url, row: row); sources.frame = nil; return sources }
        let tiles: [(String, (Bool) -> StandInSources, MediaStatus, Bool)] = [
            ("a · normal", { recents.sources(urls[2], row: $0) }, .none, false),
            ("b · loading", { _ in StandInSources() }, .loading, true),
            ("b · words ready", { pending(urls[4], row: $0) }, .none, false),
            ("c · video missing", { recents.sources(urls[4], row: $0) }, .missing, false),
            ("c · never transcribed", { recents.sources(urls[9], row: $0) }, .missing, false),
            ("d · transcribing", { recents.sources(urls[0], row: $0) }, .transcribing(fraction: 0.42, stage: .transcribing), false),
            ("d · no frame yet", { recents.sources(urls[9], row: $0) }, .transcribing(fraction: 0.42, stage: .transcribing), false),
            ("d · no fraction", { recents.sources(urls[0], row: $0) }, .transcribing(fraction: nil, stage: .extractingAudio), false),
            ("f · audio only", { recents.sources(urls[7], row: $0) }, .audioOnly, false),
            ("f · corrupt file", { recents.sources(urls[6], row: $0) }, .unreadable, false)
        ]
        return ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(180), spacing: 16), count: 5), alignment: .leading, spacing: 14) {
                ForEach(tiles.indices, id: \.self) { index in
                    let tile = tiles[index]
                    VStack(alignment: .leading, spacing: 6) {
                        MediaThumbnail(status: tile.2, sources: tile.1(false), unread: tile.3, duration: tile.3 ? nil : 192).frame(width: 180, height: 101)
                        HStack(spacing: 8) {
                            MediaThumbnail(status: tile.2, sources: tile.1(true), surface: .row, unread: tile.3, cornerRadius: VCTokens.radiusXs).frame(width: 36, height: 20)
                            Text(tile.0).font(.system(size: 11)).foregroundStyle(DesignValues.color("text.secondary"))
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(DesignValues.color("bg.surface"))
    }
}
#endif
