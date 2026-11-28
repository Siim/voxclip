import SwiftUI
import VoxClipCore

@MainActor extension EditorModel {
    func harnessCreativeData(_ timeline: HarnessTimeline, clip: ClipRange?, result: Project?,
                             operations: [ClipAutopilotOperation], estimate: String?) -> CreativeProposalData {
        let declared = timeline.proposal.target.new?.kind
        let clock = result.map(ProjectClock.build) ?? recordingClock
        let proposalWords = clock?.words ?? words
        let resolved = clip?.playPartIndices(in: proposalWords)?.map { ClipProposal.Part(startWord: $0.lowerBound, endWord: $0.upperBound) }
        let parts = ProposalStripPart.from(resolved ?? timeline.proposal.parts ?? [], words: proposalWords, clock: clock)
        let kind: ClipProposal.NewClip.Kind = declared ?? (parts.count < 2 ? .stretch : clip?.kind == .showreel ? .showreel : .story)
        let title = clip?.title ?? timeline.proposal.title ?? timeline.proposal.target.new?.title ?? scopeName(timeline.clipId)
        let cuts = operations.filter { $0.decision == .cut || $0.decision == .pauseCut }.count
        let edit = if let result, let clip { try? RenderCallerInputs.timeline(project: result, clipID: clip.id) } else { nil as RenderTimeline? }
        let seconds = edit?.duration ?? parts.reduce(0) { $0 + $1.duration }
        let scope = declared == nil ? "updates this clip" : "makes a new clip"
        var metadata = [durationLabel(seconds), "\(parts.count) \(parts.count == 1 ? "part" : "parts")", "\(cuts) \(cuts == 1 ? "cut" : "cuts")", scope]
        if timeline.timelineEditCount > 0 {
            metadata.append("\(timeline.timelineEditCount) timeline \(timeline.timelineEditCount == 1 ? "edit" : "edits")")
        }
        if let key = timeline.recordingKey, let source = project.media.additionalSources.first(where: { $0.contentKey == key }) {
            metadata.append("add recording \(ProjectClock.label(source)) with local transcription")
        }
        let chips = creativeChips(operations, musicEstimate: estimate)
        return CreativeProposalData(source: "\(kind.cardLabel()) · proposed in your terminal", title: title,
            summary: metadata.joined(separator: " · "), parts: parts,
            groups: creativeGroups(operations).filter { !$0.items.isEmpty }, chips: chips,
            cost: chips.contains(where: \.paid) ? "Keeping this timeline doesn't spend. Paid assets are separate actions after Keep." : nil,
            note: timeline.reason)
    }

    func creativeProposalData(_ run: MakeItRun) -> CreativeProposalData? {
        guard let plan = run.plan else { return nil }
        let parts = ProposalStripPart.from(plan.parts, words: words, clock: recordingClock)
        let cuts = run.proposalOperations.filter { $0.decision == .cut || $0.decision == .pauseCut }.count
        var summary = [durationLabel(run.seconds), "\(plan.score)/10", MakeItPanel.verdict(plan.verdict).lowercased()]
        if parts.count > 1 { summary.append(plan.kind == .showreel ? "\(parts.count) quick parts · music-led" : "\(parts.count) parts in your order") }
        if cuts > 0 { summary.append("\(cuts) \(cuts == 1 ? "cut" : "cuts")") }
        var groups = creativeGroups(run.proposalOperations, music: run.proposalMusic, rows: run.rows)
        if let previous = run.priorPlan {
            let oldGroups = creativeGroups(run.priorOperations)
            let proposedGroups = creativeGroups(run.proposalOperations)
            for index in groups.indices {
                let category = groups[index].id
                let changed = proposedGroups[index].items != oldGroups[index].items
                groups[index].changed = changed || (category == .opening && (plan.parts != previous.parts || plan.kind != previous.kind))
            }
        }
        let cost: String
        if let cap = run.budget?.approved ?? run.cap, cap > 0 {
            let spent = run.budget?.spent ?? run.spent
            let limit = Self.makeItDollars(cap)
            let capLabel = limit.hasSuffix(".00") ? String(limit.dropLast(3)) : limit
            cost = "\(Self.makeItDollars(spent)) of your \(capLabel) limit · Undo keeps the paid files in this project."
        } else {
            cost = "Nothing to pay for this one. Everything uses your take, your files or free sounds."
        }
        let chips = creativeChips(run.proposalOperations, run: run)
        let note = run.proposalUndone ? "Undone · paid files stay in this project." : plan.scoreReason
        return CreativeProposalData(source: "\(plan.kind.cardLabel()) · made by Claude", title: plan.title,
            summary: summary.joined(separator: " · "), parts: parts, groups: groups, chips: chips, cost: cost,
            note: note.isEmpty ? nil : note, revised: run.priorPlan != nil)
    }

    func creativeGroups(_ operations: [ClipAutopilotOperation], music: ProjectMusic? = nil, rows: [MakeItRow] = []) -> [CreativeProposalGroup] {
        var items: [CreativeProposalGroup.Section: [CreativeProposalGroup.Item]] = [:]
        for operation in operations {
            guard let section = creativeSection(operation) else { continue }
            if section == .music, music != nil, operation.decision == .music { continue }
            let row = rows.first { $0.id == operation.id }
            let label = creativeLabel(operation, applied: row)
            let reason = [operation.reason, row?.detail ?? ""].filter { !$0.isEmpty }
            items[section, default: []].append(.init(label: label, reason: reason.count == 2 && reason[0] != reason[1] ? reason.joined(separator: " · ") : reason.first ?? ""))
        }
        for row in rows {
            let section: CreativeProposalGroup.Section? = switch row.id {
            case ClipPicture.cropRowID, ClipPicture.coverRowID: .picture
            case ClipPicture.openingRowID: .opening
            case "wholeClip": .extras
            default: row.change == .screens ? .picture : nil
            }
            if let section, !operations.contains(where: { $0.id == row.id }) {
                items[section, default: []].append(.init(label: row.text, reason: row.detail))
            }
        }
        if let music {
            let kind = music.source == .generated ? "generated" : "saved"
            let ducking = music.ducking ? " · ducked" : ""
            let mix = "\(music.gainDb.formatted()) dB\(ducking) · \(music.fadeInSeconds.formatted()) s in, \(music.fadeOutSeconds.formatted()) s out"
            let reason = operations.first { $0.decision == .music }?.reason ?? ""
            items[.music, default: []].insert(.init(label: "“\(music.title)” (\(kind)) · \(mix)", reason: reason), at: 0)
        } else if let row = rows.first(where: { $0.id == "music" }) {
            items[.music, default: []].append(.init(label: row.text, reason: row.detail))
        }
        return CreativeProposalGroup.Section.allCases.map { .init(id: $0, items: items[$0] ?? []) }
    }

    private func creativeSection(_ operation: ClipAutopilotOperation) -> CreativeProposalGroup.Section? {
        switch operation.action {
        case .hook: .opening
        case .look, .speed, .motion, .coverTitle, .stretch: .picture
        case .footage(let entry): entry.kind == .screenshot ? .extras : .picture
        case .asset, .rewrite: .extras
        case .captions, .translateCaptions: .captions
        case .music, .savedMusic, .musicDucking: .music
        case .effect(let effect):
            switch effect.kind {
            case .title: .opening
            case .motionTemplate: effect.template?.isOpening == true ? .opening : .onScreen
            case .lowerThird, .sticker, .arrow, .circle, .progress: .onScreen
            case .blur, .pixelate, .freeze, .colourLook, .speedForPart: .picture
            case .sound, .illustration, .bleep, .mute: .extras
            }
        case .edit, .timeline, .shareText: nil
        }
    }

    private func creativeLabel(_ operation: ClipAutopilotOperation, applied: MakeItRow?) -> String {
        switch operation.action {
        case .hook(_, let text): return "Hook “\(text)” · title card"
        case .look(_, let look):
            guard let preset = ClipLookLibrary.app?.look(look.id.rawValue) else { return "\(look.id.rawValue) look" }
            return Self.makeItLookName(preset, amount: look.amount) + " look"
        case .speed(_, let speed): return "\(Self.rate(speed.rate)) speed"
        case .captions(let settings, let font):
            if let applied { return applied.text }
            let styles = app.shared.flatMap { try? CaptionStyleLibrary(shared: $0).styles } ?? []
            let name = styles.first { $0.id == settings.styleId }?.name ?? settings.styleId
            return [name, font.map { "\($0.family) \($0.weight)" }].compactMap { $0 }.joined(separator: " · ")
        case .footage(let entry):
            let title = switch entry.kind { case .bRoll: "B-roll"; case .screenshot: "Screenshot"; case .videoStack: "Two-video stack" }
            let source = project.media.additionalSources.first { $0.footageKey == entry.footage.sourceKey }
            let name = source.map { URL(fileURLWithPath: $0.absolutePath).deletingPathExtension().lastPathComponent }
            return name.map { "\(title) from \($0)" } ?? title
        case .effect(let effect):
            let title = Self.rowTitle(operation)
            if let text = effect.text { return "\(title) “\(text)”" }
            switch effect.template {
            case .titleCard(let text), .kineticCaption(let text), .logoSting(let text): return "\(title) “\(text)”"
            case .counter(let from, let to): return "\(title) \(from) → \(to)"
            case nil: return title
            }
        case .motion(let cue): return cue.keyframes.allSatisfy { $0.scale == cue.keyframes.first?.scale } ? "Punch-in" : applied?.text ?? "Zoom"
        case .music(let cue): return "Brief: “\(cue.picked.prompt)”"
        case .savedMusic(_, let id, _): return "Saved music: \(project.music.first { $0.id == id }?.title ?? id)"
        case .asset(let asset): return applied?.text ?? "\(Self.rowTitle(operation)): \(asset.text)"
        case .rewrite(_, let text): return applied?.text ?? "Rewrite “\(text)”"
        default: return applied?.text ?? Self.rowTitle(operation)
        }
    }

    func creativeChips(_ operations: [ClipAutopilotOperation], run: MakeItRun? = nil, musicEstimate: String? = nil) -> [CreativeAssetChip] {
        var chips: [CreativeAssetChip] = []
        for operation in operations {
            switch operation.action {
            case .footage(let entry):
                let name = switch entry.kind { case .screenshot: "Local screenshot"; case .bRoll: "B-roll"; case .videoStack: "Video stack" }
                chips.append(.free(name))
            case .effect(let effect) where effect.kind == .motionTemplate: chips.append(.free("Motion template"))
            case .asset(let asset):
                if let run, !run.rows.contains(where: { $0.id == operation.id && $0.undoable }) { continue }
                if asset.kind == .sound { chips.append(.free("Sound")) }
                else {
                    let price = run?.assetPrices[operation.id] ?? clipIllustrationQuote?.usdPerImage
                    chips.append(.paid("Illustration", price: price.map(Self.makeItDollars)))
                }
            case .rewrite where run == nil: chips.append(.paid("Rewrite", price: nil))
            case .savedMusic where run == nil: chips.append(.free("Saved music"))
            default: break
            }
        }
        if let run, run.voiceSpent > 0 { chips.append(.paid("Voice", price: Self.makeItDollars(run.voiceSpent))) }
        if let music = run?.proposalMusic {
            if music.source == .generated { chips.append(.paid("Music", price: run?.assetPrices["music"].map(Self.makeItDollars))) }
            else { chips.append(.free("Saved music")) }
        } else if run == nil, operations.contains(where: { if case .music = $0.action { return true }; return false }) {
            chips.append(.paid("Music", price: musicEstimate))
        }
        var seen = Set<CreativeAssetChip>()
        return chips.filter { seen.insert($0).inserted }
    }
}

@MainActor struct HarnessCreativeProposal: View {
    let data: CreativeProposalData
    let blocked: String?
    let keep: () -> Void
    let undo: () -> Void

    static let changeUnavailable = "Ask Claude Code or Codex in your terminal to change it."

    var body: some View {
        CreativeProposalCard(data: data) {
            HStack(spacing: 6) {
                Button("Keep", action: keep).buttonStyle(.borderedProminent).disabled(blocked != nil)
                    .accessibilityIdentifier("voxclip.harness.keep")
                Button("Undo", action: undo).accessibilityIdentifier("voxclip.harness.undo")
                Button("Change…") {}.disabled(true)
                    .help(Self.changeUnavailable)
                    .accessibilityIdentifier("voxclip.harness.change")
            }
            .controlSize(.small)
            if let blocked { Text(blocked).font(VCType.small.font()).foregroundStyle(.secondary) }
            Text(Self.changeUnavailable).font(VCType.small.font()).foregroundStyle(.secondary)
                .columnLayoutEvidence("proposal.harnessChangeUnavailable", text: Self.changeUnavailable)
        }
    }
}

private extension MotionTemplate {
    var isOpening: Bool {
        switch self {
        case .titleCard, .logoSting: true
        default: false
        }
    }
}

@MainActor struct MakeItCreativeProposal: View {
    let model: EditorModel
    let run: MakeItRun
    var startWithChange = false
    @State private var changing = false

    var body: some View {
        if let data = model.creativeProposalData(run) {
            VStack(alignment: .leading, spacing: 4) {
                CreativeProposalCard(data: data) { actions }
                if changing { CreativeChangeField(title: "\(run.plan?.kind.cardLabel() ?? "Clip") · \(data.title)",
                    sending: run.revisionInFlight, error: run.revisionError, close: { changing = false },
                    send: { model.reviseCreativeProposal(run, instruction: $0) }) }
            }
            .onAppear { changing = startWithChange }
        }
    }

    private var actions: some View {
        let blocked = model.creativeProposalBlocker(run)
        return VStack(alignment: .leading, spacing: 5) {
            if run.proposalKept {
                Text("Kept").font(VCType.small.font()).foregroundStyle(.secondary)
                play
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { reviewActions(blocked: blocked); play }.fixedSize()
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 5) { reviewActions(blocked: blocked) }
                        play
                    }
                }
                if let blocked, !run.revisionInFlight { Text(blocked).font(VCType.small.font()).foregroundStyle(.secondary) }
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder private func reviewActions(blocked: String?) -> some View {
        Button("Keep") { run.proposalKept = true; changing = false }
            .buttonStyle(.borderedProminent).disabled(blocked != nil || run.proposalUndone)
        Button("Undo") { model.undoCreativeProposal(run) }.disabled(blocked != nil || run.proposalUndone)
        Button("Change…") { changing.toggle() }.disabled(blocked != nil)
            .accessibilityIdentifier("voxclip.proposal.change")
    }

    private var play: some View {
        Button { model.playCreativeProposal(run) } label: { Label("Play", systemImage: "play.fill") }
            .disabled(run.proposalUndone || run.running)
    }
}

@MainActor private struct CreativeChangeField: View {
    let title: String
    let sending: Bool
    let error: String?
    let close: () -> Void
    let send: (String) -> Void
    @State private var instruction = ""
    @FocusState private var focused: Bool
    private let chips = ["Shorter", "Calmer music", "No graphics", "End on the telecom deal", "Make it a story instead"]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Change…").font(VCType.callout.font().weight(.semibold))
            Text(title).font(VCType.small.font()).foregroundStyle(.secondary)
            TextField("Tell Claude what to change, for example “slower, no illustration, end on the telecom deal”", text: $instruction)
                .focused($focused).disabled(sending).onSubmit(submit).onExitCommand(perform: close)
                .accessibilityIdentifier("voxclip.proposal.instruction")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { chipButtons }.fixedSize()
                VStack(alignment: .leading, spacing: 4) { chipButtons }
            }
            .controlSize(.small)
            .disabled(sending)
            Text(sending ? "Revising proposal…" : "Return sends · Esc closes")
                .font(VCType.small.font()).foregroundStyle(.secondary)
            if let error { InlineNotice(text: error) }
            Text("Paid files already made are reused. Any new ones come from the same limit.")
                .font(VCType.small.font()).foregroundStyle(.secondary)
        }
        .claudeCard(highlighted: false)
        .onAppear { focused = true }
        .onExitCommand(perform: close)
        .columnLayoutEvidence("proposal.changeField")
    }

    private var chipButtons: some View {
        ForEach(chips, id: \.self) { chip in
            Button(chip) {
                instruction = instruction.isEmpty ? chip : "\(instruction), \(chip.lowercased())"
                focused = true
            }
        }
    }

    private func submit() { if !sending { send(instruction) } }
}
