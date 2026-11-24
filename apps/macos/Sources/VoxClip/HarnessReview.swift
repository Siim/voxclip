import SwiftUI
import VoxClipCore

extension EditorModel {
    @discardableResult func keepHarnessProposal(_ proposal: HarnessProposal, at url: URL) throws -> [ClipPlanAsset] {
        guard document.fileURL == url, !document.demo, capabilities.edit, !capabilities.aiBusy, !musicPanel.isBusy, let shared = app.shared else {
            throw HarnessError.invalid("Finish the current edit and try again. Your project is unchanged.")
        }
        let (next, assets) = try proposal.evaluate(project, shared: shared)
        try HarnessInbox.dismiss(proposal, for: url)
        if next != project { replace(next, name: "Keep timeline proposal") }
        return assets
    }
}

@MainActor struct HarnessReview: View {
    let model: EditorModel
    let shell: WorkspaceShell
    @ObservedObject private var document: VoxClipDocument
    @State private var pending: HarnessProposal?
    @State private var issue: String?
    @State private var actionError: String?
    @State private var estimate: String?
    @State private var checkedURL: URL?
    @State private var checkedEdit: Date?
    @State private var paid: PaidMusic?
    @State private var submitted = false
    @State private var assets: [ClipPlanAsset] = []
    @State private var assetProject: Project?
    @State private var workingAsset: String?
    @State private var illustrationKeyAvailable: Bool?

    private struct PaidMusic {
        let clipId: String
        let sourceKey: String
        let prompt: String
        let estimate: String?
    }

    init(model: EditorModel, shell: WorkspaceShell) {
        self.model = model
        self.shell = shell
        document = model.document
    }

    var body: some View {
        VStack(spacing: 0) {
            if let pending { review(pending) }
            else if let issue { InlineNotice(text: issue) }
            if let paid { music(paid) }
            ForEach(assets, id: \.id) { asset in assetAction(asset) }
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
        if paid != nil || !assets.isEmpty { return "Finish or dismiss the previous asset actions first." }
        return nil
    }

    private func review(_ proposal: HarnessProposal) -> some View {
        let timeline = proposal.timeline
        let blocked = issue ?? unavailable
        return VStack(alignment: .leading, spacing: 6) {
            Text("Timeline proposal · \(model.scopeName(timeline.clipId))").font(.headline)
            Text(verbatim: timeline.reason).lineLimit(3)
            DisclosureGroup("Proposed changes") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if let title = timeline.title { Text("Title: \(title)") }
                        if let style = timeline.captionStyle { Text("Captions: \(style)") }
                        if let trackId = timeline.musicTrackId {
                            Text("Reuse music: \(model.project.music.first { $0.id == trackId }?.title ?? trackId)")
                        }
                        ForEach(Array((timeline.cuts ?? []).enumerated()), id: \.offset) { _, cut in
                            Text("\(cutLabel(cut)): \(cut.reason)")
                        }
                        ForEach(Array((timeline.effects ?? []).enumerated()), id: \.offset) { _, effect in
                            Text("\(effectLabel(effect)): \(effect.reason)")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 120)
            }
            if let prompt = timeline.generateMusic {
                Text("Music: \(prompt)").lineLimit(2)
                Text(estimate.map { "About \($0) to generate music. Keeping the timeline doesn't send anything." }
                     ?? "Keeping the timeline doesn't generate music.").foregroundStyle(.secondary)
            }
            if timeline.effects?.contains(where: { $0.kind == .illustration || $0.kind == .soundEffect }) == true {
                Text("Keeping the timeline doesn't request illustrations or sounds.").foregroundStyle(.secondary)
            }
            if let blocked { Text(blocked).foregroundStyle(.secondary) }
            HStack {
                Button("Keep") { keep(proposal) }.disabled(blocked != nil)
                    .accessibilityIdentifier("voxclip.harness.keep")
                Button("Undo") { dismiss(proposal) }
                    .accessibilityIdentifier("voxclip.harness.undo")
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignValues.color("bg.muted"))
        .accessibilityIdentifier("voxclip.harness.review")
    }

    private func cutLabel(_ cut: ClipAutopilotPlan.Cut) -> String {
        let words = model.words
        guard words.indices.contains(cut.startWord), words.indices.contains(cut.endWord), cut.startWord <= cut.endWord else {
            return "Cut words \(cut.startWord)–\(cut.endWord)"
        }
        let selection = words[cut.startWord...cut.endWord].filter { $0.kind == .word }
        let excerpt = selection.prefix(12).map { model.text($0) }.joined(separator: " ")
        return "Cut “\(excerpt)\(selection.count > 12 ? "…" : "")”"
    }

    private func effectLabel(_ effect: ClipPlanEffect) -> String {
        if let template = effect.template {
            switch template {
            case .titleCard(let text), .kineticCaption(let text), .logoSting(let text): return "\(template.label) “\(text)”"
            case .counter(let from, let to): return "\(template.label) \(from) to \(to)"
            }
        }
        let name: String = switch effect.kind {
        case .zoom: "Zoom"
        case .punchIn: "Punch in"
        case .motionTitle: "Animated title"
        case .motionTemplate: effect.template?.label ?? "Motion template"
        case .lowerThird: "Lower third"
        case .emojiPop: "Emoji pop"
        case .soundEffect: "Sound effect"
        case .illustration: "Illustration"
        case .colourLook: "Colour look"
        case .speedForPart: "Speed change"
        case .bRoll: "B-roll"
        case .screenshot: "Screenshot"
        case .videoStack: "Video stack"
        }
        return effect.text.map { "\(name) “\($0)”" } ?? name
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
            estimate = nil
            if let next, let shared = model.app.shared {
                let candidate = try next.applying(to: model.project, shared: shared)
                estimate = try next.estimatedMusicPrice(in: candidate, shared: shared)
            } else if next != nil { issue = "VoxClip can't read its timeline resources." }
        } catch let error as HarnessError {
            issue = error.localizedDescription
        } catch {
            issue = "VoxClip can't read this timeline proposal. Your project is unchanged."
        }
    }

    private func keep(_ proposal: HarnessProposal) {
        guard let url = document.fileURL, url == checkedURL, unavailable == nil else { return }
        do {
            assets = try model.keepHarnessProposal(proposal, at: url)
            assetProject = model.project
            if assets.contains(where: { $0.kind == .illustration }) {
                illustrationKeyAvailable = nil
                Task { illustrationKeyAvailable = (try? await model.app.secrets.key(for: "fal"))?.isEmpty == false }
            }
            if let prompt = proposal.timeline.generateMusic {
                submitted = false
                paid = PaidMusic(clipId: proposal.timeline.clipId, sourceKey: model.project.media.source.contentKey,
                                 prompt: prompt, estimate: estimate)
            }
            actionError = nil
            refresh()
        } catch let error as HarnessError { actionError = error.localizedDescription; refresh() }
        catch { actionError = "VoxClip couldn't keep this timeline. Your project is unchanged."; refresh() }
    }

    private func dismiss(_ proposal: HarnessProposal) {
        guard let url = document.fileURL, url == checkedURL else { return }
        do {
            try HarnessInbox.dismiss(proposal, for: url)
            actionError = nil
        } catch { actionError = "VoxClip couldn't discard this timeline. Your project is unchanged." }
        refresh()
    }
}
