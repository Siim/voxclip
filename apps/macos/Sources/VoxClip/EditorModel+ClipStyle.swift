import Foundation
import VoxClipCore

/// The editor's clip style card and caption pick state (design.md §6.6).
@MainActor @Observable final class ClipStyleState {
    /// The card was reopened from the status bar after a choice.
    var reopened = false
    var picking = false
    var error: String?
    /// The inline send confirmation of Pick styles, in the Captions panel.
    let confirmation = ConnectorConfirmation()
    @ObservationIgnored var task: Task<Void, Never>?
}

/// shared/data/clip-styles.json, read once per shared root.
@MainActor enum ClipStyleCatalogCache {
    private static var cached: (root: URL, catalog: ClipStyleCatalog)?
    static func catalog(_ shared: SharedResources?) -> ClipStyleCatalog? {
        guard let shared else { return nil }
        if let cached, cached.root == shared.root { return cached.catalog }
        guard let catalog = try? ClipStyleCatalog.load(shared: shared) else { return nil }
        cached = (shared.root, catalog)
        return catalog
    }
}

extension CaptionStyle {
    /// "Roboto Black": the family and the weight's name, as the clip style card's Captions row shows the font.
    var fontName: String {
        let weights = [100: "Thin", 200: "ExtraLight", 300: "Light", 400: "Regular", 500: "Medium", 600: "SemiBold", 700: "Bold", 800: "ExtraBold", 900: "Black"]
        let weight = weights[font.weight] ?? "\(font.weight)"
        return weight == "Regular" ? font.family : "\(font.family) \(weight)"
    }
}

extension EditorModel {
    var clipStyles: ClipStyleCatalog? { ClipStyleCatalogCache.catalog(app.shared) }

    /// Settings' default clip style (`clipStyle.default`), if the user ever chose one.
    var savedClipStyle: ClipStyle? {
        guard let value = app.settings.values["clipStyle.default"], let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(ClipStyle.self, from: data)
    }

    /// What the card shows: the project's clip style, else the one a new project starts with (nothing is stored until
    /// the user chooses).
    var cardClipStyle: ClipStyle? {
        project.clipStyle ?? clipStyles?.initial(saved: savedClipStyle)
    }

    /// The card shows once above the clip list, the first time the project has clips, until the user chooses; the
    /// status bar item reopens it. A read-only project never shows it: every control on it changes the project.
    /// Until the creator chooses who makes the clips, card A asks that instead; in Claude mode the card shows only when
    /// reopened, since Claude decides the rest.
    var showsClipStyleCard: Bool {
        guard capabilities.edit, clipStyles != nil, !showsClipsModeCard else { return false }
        return clipStyleState.reopened || (!claudeModeOn && project.clipStyle == nil && !project.edits.clips.isEmpty)
    }

    func chooseClipPreset(_ id: ClipStylePresetID, collapse: Bool = true) {
        guard let clipStyles else { return }
        commitClipStyle(clipStyles.style(for: id, mine: savedClipStyle), name: "Choose clip style", collapse: collapse)
    }

    /// A row on the card changed: the style becomes the user's own ("My style").
    func updateClipStyle(_ change: (inout ClipStyle) -> Void) {
        guard var style = cardClipStyle else { return }
        change(&style)
        style.preset = .mine
        commitClipStyle(style, name: "Change clip style", collapse: false)
    }

    func setClipCaptions(_ choice: ClipCaptionChoice) {
        guard let style = cardClipStyle else { return }
        var next = style.fixingCaptions(choice)
        next.preset = .mine
        commitClipStyle(next, name: "Change clip style", collapse: false)
    }

    /// Done: keeps what the card shows, storing it if the user had not chosen yet.
    func collapseClipStyleCard() {
        if project.clipStyle == nil, let style = cardClipStyle { commitClipStyle(style, name: "Choose clip style", collapse: true) }
        clipStyleState.reopened = false
    }

    func reopenClipStyleCard() {
        guard capabilities.edit else { return }
        clipStyleState.reopened = true
        onNeedsSidebar?()
    }

    private func commitClipStyle(_ style: ClipStyle, name: String, collapse: Bool) {
        guard capabilities.edit, (try? style.validate()) != nil else { return }
        var next = project
        next.clipStyle = style
        if let fixed = style.fixedCaptionStyle, fixed == "off" || app.styles.contains(where: { $0.id == fixed }) {
            if fixed != "off", next.captions.styleId != "off" { lastStyleId = fixed }
            next.captions.styleId = fixed
        }
        if next != project { replace(next, name: name) }
        // Settings keeps the style without its picks (settings schema `clipStyle.default`).
        if let data = try? JSONEncoder().encode(style), case .object(var value)? = try? JSONDecoder().decode(JSONValue.self, from: data) {
            value["captionPicks"] = nil
            app.set("clipStyle.default", .object(value))
        }
        if collapse { clipStyleState.reopened = false }
        applyCaptionPick()
    }

    // MARK: Claude picks the caption style

    /// The AI's pick for the active clip while the clip style's captions are Auto.
    var activeCaptionPick: ClipCaptionPick? {
        guard let style = project.clipStyle, case .auto = style.captions, let id = activeClip?.id else { return nil }
        return style.captionPicks[id]
    }

    /// With Auto, the active clip uses the AI's pick for it, as one undo step. A style the user chose (a gallery tile,
    /// the Export picker, the card's Captions row) fixes the clip style's captions, so this never overrides it.
    func applyCaptionPick() {
        guard capabilities.edit, let pick = activeCaptionPick, project.captions.styleId != pick.styleId,
              app.styles.contains(where: { $0.id == pick.styleId }) else { return }
        var next = project
        next.captions.styleId = pick.styleId
        lastStyleId = pick.styleId
        replace(next, name: "Use Claude's caption style")
    }

    /// Every clip, kept and suggested, with its edited words, for the pick request.
    var captionPickClips: [CaptionPickClip] {
        let cut = Set(project.edits.cutWordIds)
        return (keptClips + suggestedClips).compactMap { clip in
            guard let lower = index(clip.startWordId), let upper = index(clip.endWordId), lower <= upper else { return nil }
            let text = words[lower...upper].filter { $0.kind == .word && !cut.contains($0.id) }.map(text).joined(separator: " ")
            return CaptionPickClip(id: clip.id, title: clip.title, seconds: editedDuration(clip), text: text)
        }
    }

    /// Pick styles is offered only when it can run: captions are Auto, there are clips, an AI is chosen and nothing
    /// else holds the project's AI lease.
    var canPickCaptionStyles: Bool {
        guard capabilities.ai, findConnector != nil, let style = project.clipStyle, case .auto = style.captions else { return false }
        return !project.edits.clips.isEmpty && !clipStyleState.picking
    }

    /// Clips without a pick yet; Pick styles reads "Pick styles for 3 clips".
    var unpickedClipCount: Int {
        let picks = project.clipStyle?.captionPicks ?? [:]
        return project.edits.clips.filter { picks[$0.id] == nil }.count
    }

    func pickCaptionStyles() {
        guard canPickCaptionStyles, let shared = app.shared, let clipStyles, let style = project.clipStyle,
              let provider = findConnector, let lease = llmRuns.acquire() else { return }
        let runs = llmRuns, state = clipStyleState, snapshot = project
        let clips = captionPickClips, library = app.styles
        let model = app.string("llm.model.\(provider.id)", fallback: provider.defaultModel ?? "")
        let connector = app.connector(provider.id)
        let wordCount = clips.reduce(0) { $0 + EditingPrimitives.splitWords($1.text).count }
        state.error = nil
        state.task?.cancel()
        state.task = Task { [self] in
            defer { state.picking = false; runs.release(lease) }
            do {
                guard try await app.authorizeConnectorRequest(provider, connector: connector, action: .pickCaptions, wordCount: wordCount,
                                                               confirmation: state.confirmation, verb: "Pick styles",
                                                               isCurrent: { [self] in !isLeaving && project == snapshot }) else { return }
                state.picking = true
                announce("Picking caption styles")
                let catalog = try LLMCatalog(shared: shared)
                let picker = CaptionPicker(runner: LLMRunner(keys: app.secrets, catalog: catalog, log: app.log), prompt: try CaptionPickPrompt.load(shared: shared), catalog: catalog)
                let result = try await picker.pick(style, clips: clips, library: library, styles: clipStyles, connector: connector, model: model, language: project.transcript?.language)
                try Task.checkCancellation()
                // A choice made while the request ran wins: only a still-Auto clip style takes the picks.
                guard capabilities.edit, let current = project.clipStyle, case .auto = current.captions else { return }
                var next = project
                next.clipStyle = current.pruned(clipIDs: Set(project.edits.clips.map(\.id))).recording(result.style.captionPicks)
                guard next != project else { return }
                replace(next, name: "Claude picked caption styles")
                let count = result.style.captionPicks.count
                announce(count == 1 ? "Picked a caption style for 1 clip" : "Picked caption styles for \(count) clips")
                applyCaptionPick()
            } catch is CancellationError {} catch LLMError.cancelled {} catch {
                let message = await app.safeError(error, context: "ai:\(provider.label)")
                if !message.isEmpty { state.error = message }
            }
        }
    }

    // MARK: Status bar

    /// "Style: Auto · ≤60 s · 16:9+9:16" once the project has a clip style.
    /// In Claude mode, or until the creator chooses, the item names the mode instead (ClaudeMode.swift).
    var statusClipStyle: StatusItem? {
        if let mode = statusClaudeMode { return mode }
        guard let style = project.clipStyle, let clipStyles else { return nil }
        let text = style.summary(presetLabel: clipStyles.preset(style.preset).label)
        return StatusItem(kind: .clipStyle, parts: [StatusText(string: text)], dim: true,
                          spoken: text.replacingOccurrences(of: " · ", with: ", ").replacingOccurrences(of: "≤", with: "up to "),
                          help: capabilities.edit ? "Change how clips are made." : nil)
    }
}
