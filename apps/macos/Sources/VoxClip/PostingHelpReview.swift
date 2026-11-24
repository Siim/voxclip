import SwiftUI
import VoxClipCore

@MainActor @Observable final class PostingReviewState {
    private(set) var clips: [PostingClip] = []
    private(set) var music: [String: ProjectMusic] = [:]
    var plan: PostingPlan?
    var loading = true
    var working = false
    var error: String?

    func record(_ target: ExportTarget, name: String, result: ExportResult, render: RenderRequest, snapshot: EditorRenderSnapshot) {
        guard case .clip(let id) = target, !clips.contains(where: { $0.id == id }) else { return }
        let words = snapshot.exportedWords(target: target, render: render)
        music[id] = render.music?.entry
        clips.append(PostingClip(id: id, title: name, words: words.map(\.text).joined(separator: " "), duration: result.durationSeconds))
    }
}

@MainActor struct PostingHelpReview: View {
    let model: EditorModel
    @State private var network = ShareDestination.x
    private var state: PostingReviewState { model.exportJob.posting }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Posting help").fontWeight(.semibold)
            if let plan = state.plan { drafts(plan) }
            else { offer }
            if let error = state.error { InlineNotice(text: error) }
        }
        .accessibilityIdentifier("voxclip.export.postingHelp")
        .task(id: state.clips) { await model.restorePostingPlan(state) }
        .task(id: model.postingCheckKey) { await model.checkPostingConnector() }
    }

    private var offer: some View {
        VStack(alignment: .leading, spacing: 6) {
            let reason = model.postingUnavailable(state)
            Button(model.postingButtonTitle) { model.startPostingPlan(state) }
                .disabled(reason != nil)
                .accessibilityIdentifier("voxclip.export.postingHelp.ask")
            if state.working { ProgressView("Claude is making a posting plan…") }
            else if let reason { Text(reason).font(VCType.small.font()).foregroundStyle(.secondary) }
            else {
                Text("Sends clip names, lengths and excerpts of the edited words to Claude. Nothing is posted.")
                    .font(VCType.small.font()).foregroundStyle(.secondary)
                if let copy = model.postingPriceNote { Text(copy).font(VCType.small.font()).foregroundStyle(.secondary) }
            }
        }
    }

    private func drafts(_ plan: PostingPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Suggested order and times. Nothing is scheduled or posted.").foregroundStyle(.secondary)
            Picker("Network", selection: $network) {
                Text("X").tag(ShareDestination.x)
                Text("LinkedIn").tag(ShareDestination.linkedIn)
                Text("VoxConvo").tag(ShareDestination.voxConvo)
            }.pickerStyle(.segmented)
            ForEach(Array(plan.entries.enumerated()), id: \.element.id) { rank, entry in
                if state.clips.indices.contains(entry.clip - 1) { draft(rank: rank + 1, entry: entry, clip: state.clips[entry.clip - 1]) }
            }
        }
    }

    private func draft(rank: Int, entry: PostingPlan.Entry, clip: PostingClip) -> some View {
        let credit = state.music[clip.id]?.creditLine
        let copy = MusicCredits.postText(entry.posts[network].copyText, music: state.music[clip.id])
        let post = (try? SharePostText.composerText(copy, destination: network, disclosureLine: credit)) ?? copy
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(rank). \(clip.title)").fontWeight(.semibold)
            Text(entry.when).foregroundStyle(.secondary)
            Text(post).textSelection(.enabled)
            Button("Copy post text") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(post, forType: .string)
                model.announce("Post text copied.")
            }
        }
    }
}

extension EditorModel {
    private var postingProvider: ProviderChoice? { findConnector.flatMap { ["anthropic", "claude-code"].contains($0.id) ? $0 : nil } }

    var postingCheckKey: String? {
        postingProvider.map { $0.id + ":" + app.string("llm.cliPath.\($0.id)") }
    }

    private var postingCost: VoiceLabCostPresentation.Kind? {
        guard let provider = postingProvider, let id = ConnectorID(rawValue: provider.id) else { return nil }
        return app.llmSendKind(id)
    }

    var postingButtonTitle: String {
        switch postingCost {
        case .inline: "Ask Claude for a posting plan · On your Claude plan"
        case .confirm: "Ask Claude for a posting plan · Billed to your key"
        case nil: "Ask Claude for a posting plan"
        }
    }

    var postingPriceNote: String? {
        if case .confirm(let copy) = postingCost { return copy }
        return nil
    }

    func postingUnavailable(_ state: PostingReviewState) -> String? {
        guard !state.clips.isEmpty else { return "Export a clip, not the full edit, to get posting help." }
        guard state.clips.count <= PostingHelpService.maxClips else { return "Export up to \(PostingHelpService.maxClips) clips at a time for posting help." }
        guard !state.loading else { return "Looking for a saved posting plan…" }
        guard let provider = postingProvider else { return "Choose Claude or Anthropic in AI settings." }
        guard app.shared != nil else { return "Posting help is unavailable in this build." }
        guard let status = app.detectedConnectorStatus[provider.id] else { return "Checking Claude…" }
        guard status == .ready, postingCost != nil else { return "Set up \(provider.label) in AI settings. \(FindClipsPopover.statusText(status))." }
        guard !llmRuns.isBusy, !state.working else { return "Wait for the current Claude request." }
        return nil
    }

    func checkPostingConnector() async {
        if let provider = postingProvider { _ = await app.connectorStatus(provider) }
    }

    private func postingService() throws -> PostingHelpService {
        guard let shared = app.shared else { throw VoxClipError.sharedResourcesMissing }
        let catalog = try LLMCatalog(shared: shared)
        return try PostingHelpService(shared: shared, catalog: catalog,
            runner: LLMRunner(keys: app.secrets, catalog: catalog, log: app.log), archive: app.postingHelpArchive)
    }

    func restorePostingPlan(_ state: PostingReviewState) async {
        guard !state.working else { return }
        defer { state.loading = false }
        guard (1...PostingHelpService.maxClips).contains(state.clips.count), state.plan == nil else { return }
        state.loading = true
        do { state.plan = try await postingService().restore(projectID: project.id, clips: state.clips) }
        catch { state.error = "The saved posting plan couldn't be read. Your exports are still here." }
    }

    func startPostingPlan(_ state: PostingReviewState) {
        guard state.plan == nil, postingUnavailable(state) == nil, let provider = postingProvider, let quotedCost = postingCost,
              let lease = llmRuns.acquire() else { return }
        let connector = app.connector(provider.id), model = app.effectiveModel(for: provider)
        let projectID = project.id, clips = state.clips, runs = llmRuns
        state.working = true; state.error = nil
        Task { [self] in
            defer { state.working = false; runs.release(lease) }
            guard await app.connectorStatus(provider, using: connector) == .ready, app.llmSendKind(connector.id) == quotedCost else {
                state.error = "Claude's connection or price changed. Check it before asking again."
                return
            }
            do {
                state.plan = try await postingService().ask(projectID: projectID, clips: clips, connector: connector, model: model)
                announce("Posting plan ready")
            } catch {
                state.error = await app.safeError(error, context: .askClaude, messageContext: "ai:\(provider.label)")
            }
        }
    }
}
