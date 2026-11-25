import SwiftUI
import VoxClipCore

extension EditorModel {
    @discardableResult func keepHarnessProposal(_ proposal: HarnessProposal, at url: URL, timeline index: Int = 0) throws -> [ClipPlanAsset] {
        try keepHarnessTimeline(proposal, at: url, index: index).compactMap { if case .asset(let asset) = $0.action { asset } else { nil } }
    }

    func keepHarnessTimeline(_ proposal: HarnessProposal, at url: URL, index: Int) throws -> [ClipAutopilotOperation] {
        guard document.fileURL == url, !document.demo, capabilities.edit, !capabilities.aiBusy, !musicPanel.isBusy, let shared = app.shared else {
            throw HarnessError.invalid("Finish the current edit and try again. Your project is unchanged.")
        }
        let result = try proposal.review(project, shared: shared, at: index)
        try HarnessInbox.resolve(proposal, remaining: proposal.remaining(after: index, project: result.project), for: url)
        if result.project != project { replace(result.project, name: "Keep timeline proposal") }
        return result.pending
    }
}

@MainActor struct HarnessReview: View {
    let model: EditorModel
    let shell: WorkspaceShell
    @ObservedObject private var document: VoxClipDocument
    @State private var pending: HarnessProposal?
    @State private var issue: String?
    @State private var actionError: String?
    @State private var reviews: [Int: Review] = [:]
    @State private var checkedURL: URL?
    @State private var checkedEdit: Date?
    @State private var paid: PaidMusic?
    @State private var submitted = false
    @State private var assets: [ClipPlanAsset] = []
    @State private var rewrites: [ClipAutopilotOperation] = []
    @State private var rewriteClipID: String?
    @State private var assetProject: Project?
    @State private var workingAsset: String?
    @State private var illustrationKeyAvailable: Bool?

    private struct PaidMusic {
        let clipId: String
        let sourceKey: String
        let prompt: String
        let estimate: String?
    }

    private struct Review {
        let operations: [ClipAutopilotOperation]
        let estimate: String?
        let issue: String?
    }

    init(model: EditorModel, shell: WorkspaceShell) {
        self.model = model
        self.shell = shell
        document = model.document
    }

    var body: some View {
        VStack(spacing: 0) {
            if let pending {
                ForEach(pending.timelines.indices, id: \.self) { index in review(pending, at: index) }
            }
            else if let issue { InlineNotice(text: issue) }
            if let paid { music(paid) }
            ForEach(assets, id: \.id) { asset in assetAction(asset) }
            ForEach(rewrites) { operation in rewriteAction(operation) }
            if let actionError { InlineNotice(text: actionError) }
        }
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: document.project.modifiedAt) { refresh() }
    }

    private var unavailable: String? {
        if !model.capabilities.edit { return "Open a writable project with its source video to keep this timeline." }
        if model.capabilities.aiBusy || model.musicPanel.isBusy { return "Finish the current action before keeping this timeline." }
        if paid != nil || !assets.isEmpty || !rewrites.isEmpty { return "Finish or dismiss the previous asset actions first." }
        return nil
    }

    private func review(_ proposal: HarnessProposal, at index: Int) -> some View {
        let timeline = proposal.timelines[index]
        let detail = reviews[index]
        let blocked = issue ?? detail?.issue ?? unavailable
        let name = timeline.proposal.target.new?.title ?? model.scopeName(timeline.clipId)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Timeline proposal · \(name)").font(.headline)
            Text(verbatim: timeline.reason).lineLimit(3)
            DisclosureGroup("Proposed changes") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if let parts = timeline.proposal.parts {
                            Text(parts.map { "\($0.startWord)–\($0.endWord)" }.joined(separator: " → "))
                        }
                        ForEach(detail?.operations ?? []) { operation in
                            Text(operationLabel(operation))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 120)
            }
            if let prompt = timeline.generateMusic {
                Text("Music: \(prompt)").lineLimit(2)
                Text(detail?.estimate.map { "About \($0) to generate music. Keeping the timeline doesn't send anything." }
                     ?? "Keeping the timeline doesn't generate music.").foregroundStyle(.secondary)
            }
            if timeline.effects?.contains(where: { $0.kind == .illustration || $0.kind == .soundEffect }) == true {
                Text("Keeping the timeline doesn't request illustrations or sounds.").foregroundStyle(.secondary)
            }
            if let blocked { Text(blocked).foregroundStyle(.secondary) }
            HStack {
                Button("Keep") { keep(proposal, at: index) }.disabled(blocked != nil)
                    .accessibilityIdentifier("voxclip.harness.keep")
                Button("Undo") { dismiss(proposal, at: index) }
                    .accessibilityIdentifier("voxclip.harness.undo")
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignValues.color("bg.muted"))
        .accessibilityIdentifier("voxclip.harness.review")
    }

    private func operationLabel(_ operation: ClipAutopilotOperation) -> String {
        let label: String = switch operation.action {
        case .edit(.renameClip(_, let title)): "Title: \(title ?? "")"
        case .captions(let settings, _): "Captions: \(settings.styleId)"
        case .savedMusic(_, let id): "Reuse music: \(model.project.music.first { $0.id == id }?.title ?? id)"
        default: EditorModel.rowTitle(operation)
        }
        return operation.reason.isEmpty ? label : "\(label) · \(operation.reason)"
    }

    private func rewriteAction(_ operation: ClipAutopilotOperation) -> some View {
        let stale = model.project != assetProject
        return VStack(alignment: .leading, spacing: 6) {
            Text("Proposed rewrite").font(.headline)
            Text(model.rowDetail(operation)).lineLimit(3)
            if stale { Text("The edit changed. Ask for a new timeline proposal.").foregroundStyle(.secondary) }
            HStack {
                Button("Review rewrite and price") {
                    guard !stale, let clipID = rewriteClipID,
                          case .rewrite(.selection(let range), let text) = operation.action else { return }
                    if MakeItRewriteDriver.openSession(editor: model, clipID: clipID, range: range, text: text) != nil {
                        rewrites.removeAll { $0.id == operation.id }
                    } else { actionError = "This rewrite doesn't fit the kept words." }
                }.disabled(stale || model.openRewrite != nil || !model.capabilities.edit)
                Button("Dismiss") { rewrites.removeAll { $0.id == operation.id } }
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(DesignValues.color("bg.muted"))
    }

    private func assetAction(_ asset: ClipPlanAsset) -> some View {
        let illustration = asset.kind == .illustration
        let saved = illustration && model.savedPlanIllustration(asset, client: EditorModel.clipPlanAssets) != nil
        let quote = illustration ? model.clipIllustrationQuote?.usdPerImage : nil
        let blocked: String? = if model.project != assetProject { "The edit changed. Ask for a new timeline proposal." }
            else if workingAsset != nil { "Wait for the current asset." }
            else if !model.capabilities.edit || model.capabilities.aiBusy { "Finish the current edit first." }
            else if illustration && !saved && quote == nil { "Illustration pricing isn't available." }
            else if illustration && !saved && illustrationKeyAvailable != true {
                illustrationKeyAvailable == nil ? "Checking for a fal.ai key…" : "Add a fal.ai key in Settings to generate an illustration."
            } else { nil }
        let title = !illustration ? "Find sound · free" : saved ? "Place saved illustration" :
            quote.map { "Generate illustration · up to \(EditorModel.makeItDollars($0))" } ?? "Generate illustration"
        return VStack(alignment: .leading, spacing: 6) {
            Text(illustration ? "Proposed illustration" : "Proposed sound effect").font(.headline)
            Text(verbatim: asset.text).lineLimit(3)
            if let blocked { Text(blocked).foregroundStyle(.secondary) }
            HStack {
                Button(title) { if blocked == nil { place(asset, approved: quote) } }.disabled(blocked != nil)
                    .accessibilityIdentifier(illustration ? "voxclip.harness.generateIllustration" : "voxclip.harness.findSound")
                Button("Dismiss") { assets.removeAll { $0.id == asset.id } }.disabled(workingAsset != nil)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignValues.color("bg.muted"))
    }

    private func place(_ asset: ClipPlanAsset, approved: Decimal?) {
        guard workingAsset == nil, model.project == assetProject else { return }
        let snapshot = model.project
        workingAsset = asset.id
        actionError = nil
        Task {
            defer { workingAsset = nil }
            do {
                let result = try await model.collectPlanAsset(asset, client: EditorModel.clipPlanAssets) { price in
                    approved.map { price <= $0 } == true && !model.isLeaving && model.project == snapshot
                }
                guard let result else { actionError = "No asset was placed. Check your settings and try again."; return }
                guard !model.isLeaving, model.project == snapshot else {
                    actionError = "The asset was saved but not placed because the edit changed."
                    return
                }
                model.replace(try ClipEffects.adding([result], to: snapshot), name: "Place timeline asset")
                assetProject = model.project
                assets.removeAll { $0.id == asset.id }
                model.announce("Placed the \(asset.kind == .sound ? "sound effect" : "illustration")")
            } catch {
                actionError = await model.app.safeError(error, context: .llm)
            }
        }
    }

    private func music(_ action: PaidMusic) -> some View {
        let panel = model.musicPanel
        let sourceMatches = model.project.media.source.contentKey == action.sourceKey
        let clipExists = model.project.edits.clips.contains { $0.id == action.clipId }
        let inScope = sourceMatches && model.renderedActiveClipID == action.clipId
        let candidate = inScope && panel.prompt == action.prompt ? panel.generationChoice(model: model) : nil
        let price = candidate?.estimate.flatMap(MusicPricing.label)
        let blocked = !sourceMatches || !clipExists ? "The clip changed. Ask for a new music proposal."
            : !inScope ? "Open the proposed clip to confirm the price."
            : panel.phase == .pricing ? "Checking the price…"
            : price == nil ? panel.generationNote ?? "Confirm a price before generating music." : nil
        return VStack(alignment: .leading, spacing: 6) {
            Text("Proposed music").font(.headline)
            Text(verbatim: action.prompt).lineLimit(3)
            if submitted {
                if panel.isUsing { Text("Generating music…") }
                else if case .failed(let message) = panel.phase { Text(message).foregroundStyle(.secondary) }
                else { Text("Review the result in Music.").foregroundStyle(.secondary) }
            } else {
                if let blocked { Text(blocked).foregroundStyle(.secondary) }
                HStack {
                    Button(price.map { "Generate music · \($0)" } ?? action.estimate.map { "Generate music · about \($0)" } ?? "Generate music") {
                        guard let candidate, !model.isLeaving, model.renderedActiveClipID == action.clipId, !panel.isBusy else { return }
                        panel.use(candidate, model: model)
                        submitted = true
                    }
                    .disabled(price == nil || !model.capabilities.edit || panel.isBusy)
                    .accessibilityIdentifier("voxclip.harness.generateMusic")
                    if sourceMatches && clipExists && !inScope {
                        Button("Open clip") { shell.choose(.clip(action.clipId), byClick: true) }
                    } else if inScope && price == nil {
                        Button("Get price") { prepareMusic(action) }.disabled(panel.isBusy || !model.capabilities.edit)
                    }
                }
            }
            Button(submitted ? "Done" : "Dismiss") { paid = nil }.disabled(submitted && panel.isUsing)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignValues.color("bg.muted"))
        .task(id: inScope) { if inScope && !submitted { prepareMusic(action) } }
    }

    private func prepareMusic(_ action: PaidMusic) {
        let panel = model.musicPanel
        guard !panel.isBusy, model.capabilities.edit, !model.isLeaving, model.renderedActiveClipID == action.clipId,
              model.project.media.source.contentKey == action.sourceKey else { return }
        panel.syncScope(model: model)
        panel.sourceTab = .eleven
        panel.prompt = action.prompt
        panel.priceGeneration(model: model)
    }

    private func refresh() {
        guard !document.demo, !document.isVersion, let url = document.fileURL else { pending = nil; issue = nil; return }
        do {
            let next = try HarnessInbox.read(for: url)
            guard next != pending || checkedURL != url || checkedEdit != model.project.modifiedAt || (next == nil && issue != nil) else { return }
            checkedURL = url
            checkedEdit = model.project.modifiedAt
            pending = next
            issue = nil
            reviews = [:]
            if let next, let shared = model.app.shared {
                try next.validateRevision(of: model.project)
                for index in next.timelines.indices {
                    do {
                        let candidate = try next.review(model.project, shared: shared, at: index)
                        let estimate = try? next.estimatedMusicPrice(in: candidate.project, shared: shared, at: index)
                        reviews[index] = Review(operations: candidate.operations, estimate: estimate, issue: nil)
                    } catch {
                        reviews[index] = Review(operations: [], estimate: nil, issue: error.localizedDescription)
                    }
                }
            } else if next != nil { issue = "VoxClip can't read its timeline resources." }
        } catch let error as HarnessError {
            issue = error.localizedDescription
        } catch {
            issue = "VoxClip can't read this timeline proposal. Your project is unchanged."
        }
    }

    private func keep(_ proposal: HarnessProposal, at index: Int) {
        guard let url = document.fileURL, url == checkedURL, unavailable == nil else { return }
        do {
            let clipID = try proposal.clipID(at: index)
            let operations = try model.keepHarnessTimeline(proposal, at: url, index: index)
            assets = operations.compactMap { if case .asset(let asset) = $0.action { asset } else { nil } }
            rewrites = operations.filter { $0.decision == .rewrite }
            rewriteClipID = clipID
            assetProject = model.project
            if assets.contains(where: { $0.kind == .illustration }) {
                illustrationKeyAvailable = nil
                Task { illustrationKeyAvailable = (try? await model.app.secrets.key(for: "fal"))?.isEmpty == false }
            }
            if let prompt = proposal.timelines[index].generateMusic {
                submitted = false
                paid = PaidMusic(clipId: clipID, sourceKey: model.project.media.source.contentKey,
                                 prompt: prompt, estimate: reviews[index]?.estimate)
            }
            actionError = nil
            refresh()
        } catch let error as HarnessError { actionError = error.localizedDescription; refresh() }
        catch { actionError = "VoxClip couldn't keep this timeline. Your project is unchanged."; refresh() }
    }

    private func dismiss(_ proposal: HarnessProposal, at index: Int) {
        guard let url = document.fileURL, url == checkedURL else { return }
        do {
            try HarnessInbox.resolve(proposal, remaining: proposal.discarding(at: index), for: url)
            actionError = nil
        } catch { actionError = "VoxClip couldn't discard this timeline. Your project is unchanged." }
        refresh()
    }
}
