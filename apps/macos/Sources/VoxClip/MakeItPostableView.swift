import SwiftUI
import VoxClipCore

// ✦ Make it postable in the right column (doc/design.md §6.7): while Claude works, its progress lines with Stop; then
// one review, "Ready to post · 0:46 · score 8/10", one line per decision with ▶ · Undo or Change, "Claude chose X ·
// Change" lines, the post text with Copy, and Export. Nothing pops up; the footer always names the next step.

@MainActor struct MakeItPanel: View {
    @Bindable var model: EditorModel
    let run: MakeItRun

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: VCTokens.spacingGroupGap) {
                    headline
                    if run.running || run.rows.isEmpty { progress }
                    if !run.rows.isEmpty { decisions }
                    if !model.makeItPostCopy(run).isEmpty, !run.running { postText }
                    if !model.makeIt.series.isEmpty { MakeItSeriesList(model: model) }
                }
                .padding(.horizontal, VCTokens.spacingCardPadding)
                .padding(.top, VCTokens.spacingGroupGap)
                .padding(.bottom, VCTokens.spacing5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Make it postable")
        .columnLayoutEvidence("makeIt.panel")
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) {
            HStack(spacing: VCTokens.spacingRowGap) {
                if run.running { ProgressView().controlSize(.small) }
                Text(model.makeItHeadline(run)).font(VCType.title3.font()).fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                    .columnLayoutEvidence("makeIt.headline", text: model.makeItHeadline(run))
            }
            if let plan = run.plan, !run.running {
                Text(Self.verdict(plan.verdict) + (plan.scoreReason.isEmpty ? "" : " · " + plan.scoreReason))
                    .font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !run.running, let line = model.makeItSendLine(run) { MakeItSendLine(model: model, run: run, line: line) }
            if case .failed(let message) = run.phase {
                Text(message).font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.secondary"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.makeItLengthNotes(run), id: \.self) { note in
                Text(note).font(VCType.small.font()).foregroundStyle(DesignValues.color(note.hasPrefix("⚠") ? "text.primary" : "text.secondary"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let cap = run.cap, run.spent > 0 || run.running {
                Text("Spent \(EditorModel.makeItDollars(run.spent)) of up to \(EditorModel.makeItDollars(cap))")
                    .font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
            }
        }
    }

    static func verdict(_ verdict: ClipAutopilotPlan.Verdict) -> String {
        switch verdict {
        case .postFirst: "Post this first"
        case .post: "Worth posting"
        case .casualPost: "A casual post"
        case .holdBack: "Hold this one back"
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: VCTokens.spacingRowGap) {
            ForEach(Array(run.lines.enumerated()), id: \.offset) { index, line in
                let last = index == run.lines.count - 1
                HStack(spacing: VCTokens.spacingRowGap) {
                    Image(systemName: last && run.running ? "circle.dotted" : "checkmark")
                        .font(.system(size: 11)).frame(width: 14)
                        .foregroundStyle(DesignValues.color(last && run.running ? "text.tertiary" : "text.secondary"))
                    Text(line).font(VCType.callout.font())
                        .foregroundStyle(DesignValues.color(last && run.running ? "text.primary" : "text.secondary"))
                }
                .accessibilityElement(children: .combine)
            }
        }
        .columnLayoutEvidence("makeIt.progress")
    }

    private var decisions: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(run.rows) { row in
                MakeItRowView(model: model, run: run, row: row)
                Divider().opacity(0.5)
            }
        }
        .columnLayoutEvidence("makeIt.decisions")
    }

    private var postText: some View {
        VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) {
            HStack {
                Text("Post text").font(VCType.small.font()).fontWeight(.semibold).foregroundStyle(DesignValues.color("text.secondary"))
                Spacer()
                Button(run.copied ? "Copied" : "Copy") { model.copyMakeItPostText(run) }
                    .buttonStyle(.borderless).font(VCType.small.font())
                    .accessibilityLabel(run.copied ? "Post text copied" : "Copy post text")
                    .columnLayoutEvidence("makeIt.copy", text: "Copy")
            }
            Text(model.makeItPostCopy(run)).font(VCType.callout.font()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, VCTokens.spacingFieldPaddingX).padding(.vertical, VCTokens.spacingFieldPaddingY)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(DesignValues.color("bg.input")))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DesignValues.color("line.edge")))
        }
        .columnLayoutEvidence("makeIt.postText")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: VCTokens.spacingRowGap) {
            Divider()
            Text(model.makeItNextStep(run)).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary"))
                .fixedSize(horizontal: false, vertical: true)
                .columnLayoutEvidence("makeIt.next", text: model.makeItNextStep(run))
            // At the video's cap the run waits: the same priced Continue as the sidebar card.
            if run.running, run.budget?.needed != nil { CapContinueBlock(editor: model, id: "makeIt.continue") }
            HStack(spacing: VCTokens.spacingRowGap) {
                if run.running {
                    Button("Stop") { model.stopMakeIt() }.disabled(run.cancelled)
                        .columnLayoutEvidence("makeIt.stop", text: "Stop")
                } else if case .failed = run.phase {
                    Button("Try Again") { model.makeIt.forget(run.clipID); model.makeItPostable(run.clipID) }
                        .buttonStyle(.borderedProminent).disabled(!model.canMakeItPostable(run.clipID))
                        .columnLayoutEvidence("makeIt.tryAgain", text: "Try Again")
                } else {
                    Button { model.makeItExport(run) } label: { Text(exportTitle).frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).disabled(!model.canExport || !model.mediaExportable || model.exporting)
                        .accessibilityLabel(exportTitle)
                        .columnLayoutEvidence("makeIt.export", text: exportTitle)
                    if run.rows.contains(where: { $0.undoable && !$0.undone }) {
                        Button("Undo All") { model.makeItUndoAll(run) }.buttonStyle(.borderless)
                            .columnLayoutEvidence("makeIt.undoAll", text: "Undo All")
                    }
                }
            }
            if model.exporting, let progress = model.exportProgress?.fraction {
                ProgressView(value: progress).controlSize(.small)
            }
        }
        .padding(.horizontal, VCTokens.spacingCardPadding)
        .padding(.vertical, VCTokens.spacingFooterPaddingY)
    }

    /// "Export · 16:9 + 9:16".
    private var exportTitle: String {
        "Export · " + model.makeItStyle.shapes.map(\.rawValue).joined(separator: " + ")
    }
}

/// One decision: what Claude did and why, with ▶, Undo and Change where they act.
@MainActor struct MakeItRowView: View {
    let model: EditorModel
    let run: MakeItRun
    let row: MakeItRow

    var body: some View {
        VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) {
            HStack(alignment: .firstTextBaseline, spacing: VCTokens.spacingRowGap) {
                Image(systemName: glyph).font(.system(size: 11)).frame(width: 14)
                    .foregroundStyle(DesignValues.color(row.kind == .note ? "text.tertiary" : "ai.tint"))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: VCTokens.spacing1) {
                    Text(model.makeItRowText(row, run: run)).font(VCType.callout.font()).strikethrough(row.undone)
                        .foregroundStyle(DesignValues.color(row.undone ? "text.tertiary" : "text.primary"))
                        .fixedSize(horizontal: false, vertical: true)
                    if !row.detail.isEmpty {
                        Text(row.detail).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: VCTokens.spacingRowGap)
                actions
            }
            if row.change == .look || row.change == .speed, run.openChoice == row.id, !row.options.isEmpty, !row.undone {
                // The other looks or speeds; a chip applies at once, as one undo step.
                HStack(spacing: VCTokens.spacingChipGap) {
                    ForEach(row.options, id: \.self) { option in
                        Button(option) { model.makeItChoose(option, rowID: row.id, run: run) }.buttonStyle(.bordered).controlSize(.small)
                            .accessibilityLabel(row.change == .look ? "Use the \(option) look" : "Play at \(option)")
                            .columnLayoutEvidence("makeIt.choice.\(row.id).\(option)", text: option)
                    }
                }
                .padding(.leading, 22)
            }
            if !row.frames.isEmpty, !row.undone, row.change != .cover || run.openChoice != row.id {
                MakeItFrameRow(model: model, frames: row.frames.filter { row.change != .cover || $0.picked }, arrow: row.id == "frames-opening")
                    .padding(.leading, 22)
            }
            if row.change == .cover, run.openChoice == row.id, !row.undone {
                // The three candidates as small frames; one click makes it the cover, as one undo step.
                MakeItFrameRow(model: model, frames: row.frames, arrow: false) { frame in model.makeItChooseCover(frame.time, run: run) }
                    .padding(.leading, 22)
            }
            if row.change == .screens, run.openChoice == EditorModel.makeItScreensID, !row.undone,
               run.rows.first(where: { $0.change == .screens })?.id == row.id, let record = run.frames {
                // The clip's detected screens, each with a toggle: blurred or left sharp, one undo step each.
                VStack(alignment: .leading, spacing: VCTokens.spacing1) {
                    ForEach(record.sent.blur, id: \.id) { candidate in
                        Toggle(isOn: Binding(get: { model.makeItScreenBlurred(candidate.id, run: run) },
                                             set: { _ in model.makeItToggleScreen(candidate.id, run: run) })) {
                            Text("\(EditorModel.screenName(candidate.rect, video: model.project.media.source.video).capitalizedFirst) at "
                                 + model.makeItClipTime(candidate.start, clipID: run.clipID) + "–" + model.makeItClipTime(candidate.end, clipID: run.clipID))
                                .font(VCType.small.font())
                        }
                        .toggleStyle(.switch).controlSize(.mini)
                        .columnLayoutEvidence("makeIt.screen.\(candidate.id)", text: candidate.id)
                    }
                }
                .padding(.leading, 22)
            }
            if row.change == .tone, run.openChoice == row.id, !row.undone {
                // The tones as chips; one re-plans this clip in it (one undo step), As I said it takes the rewording back.
                ClipStyleFlowLayout(spacing: VCTokens.spacingChipGap) {
                    ForEach(model.makeItToneChoices, id: \.id) { choice in
                        RewriteToneChip(title: choice.title, selected: choice.id == run.plan?.tone?.id,
                                        identifier: "voxclip.makeIt.tone.\(choice.id)") { model.makeItChooseTone(choice.id, run: run) }
                            .disabled(choice.id != EditorModel.makeItAsSaidID && !model.capabilities.ai)
                    }
                }
                .padding(.leading, 22)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Tones")
            }
            if row.change == .hook, run.openChoice == row.id, !row.undone {
                // The hook's text, edited in place; Return applies it to the title card as one undo step.
                MakeItHookField(text: model.makeItHook(run), commit: { model.makeItSetHook($0, rowID: row.id, run: run) }, cancel: { run.openChoice = nil })
                    .padding(.leading, 22)
            }
            if row.kind == .question, case .question(let index) = row.change, run.openQuestion == index, !row.options.isEmpty {
                HStack(spacing: VCTokens.spacingChipGap) {
                    ForEach(row.options, id: \.self) { option in
                        Button(option) { model.makeItAnswer(option, question: index, run: run) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(!model.canMakeItPostable(run.clipID))
                    }
                }
                .padding(.leading, 22)
            }
        }
        .padding(.vertical, VCTokens.spacingRowPaddingY)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.makeItRowText(row, run: run))
        .columnLayoutEvidence("makeIt.row.\(row.id)", text: model.makeItRowText(row, run: run))
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: VCTokens.spacing2) {
            if row.play != nil, !row.undone {
                Button { model.makeItPlay(row) } label: { Image(systemName: "play.fill").font(.system(size: 10)) }
                    .buttonStyle(.borderless).help("Play from here").accessibilityLabel("Play \(model.makeItRowText(row, run: run))")
            }
            if row.undoable, !row.undone, !run.running {
                Button("Undo") { model.makeItUndo(row.id, in: run) }.buttonStyle(.borderless)
                    .accessibilityLabel("Undo \(model.makeItRowText(row, run: run))")
            }
            if let change = row.change, !row.undone, !run.running {
                Button(row.actionTitle ?? (change == .post ? "Copy" : "Change")) { model.makeItChange(change, run: run) }
                    .buttonStyle(.borderless).accessibilityLabel("Change \(model.makeItRowText(row, run: run))")
            }
        }
        .font(VCType.small.font())
        .fixedSize()
    }

    private var glyph: String {
        switch row.kind {
        case .decision: "checkmark"
        case .choice: "sparkles"
        case .question: "questionmark.circle"
        case .note: "info.circle"
        }
    }
}

/// The hook row's inline field: the card's text, at most a title's length; Return applies it, Escape closes it.
@MainActor struct MakeItHookField: View {
    @State var text: String
    let commit: (String) -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Hook", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(VCType.callout.font())
            .focused($focused)
            .onAppear { focused = true }
            .onSubmit { commit(text) }
            .onExitCommand(perform: cancel)
            .onChange(of: text) { _, value in
                if value.unicodeScalars.count > ClipEffect.maximumTitleScalars {
                    text = String(String.UnicodeScalarView(value.unicodeScalars.prefix(ClipEffect.maximumTitleScalars)))
                }
            }
            .accessibilityLabel("Hook text; Return applies it to the title card")
            .columnLayoutEvidence("makeIt.hookField", text: text)
    }
}

/// "✦ Make top 3 postable": the ranked clips, their score and verdict, and how far each run is.
@MainActor struct MakeItSeriesList: View {
    let model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: VCTokens.spacingRowGap) {
            Text("Top clips").font(VCType.small.font()).fontWeight(.semibold).foregroundStyle(DesignValues.color("text.secondary"))
            ForEach(Array(model.makeIt.series.enumerated()), id: \.element) { rank, id in
                HStack(spacing: VCTokens.spacingRowGap) {
                    Text("\(rank + 1)").font(DesignValues.mono(11)).foregroundStyle(DesignValues.color("text.tertiary")).frame(width: 14)
                    Text(model.project.edits.clips.first { $0.id == id }?.title ?? model.scopeName(id)).font(VCType.callout.font()).lineLimit(1)
                    Spacer(minLength: VCTokens.spacingRowGap)
                    if let score = model.makeIt.scores[id] {
                        Text("\(score.score)/10 · \(MakeItPanel.verdict(score.verdict))").font(VCType.small.font())
                            .foregroundStyle(DesignValues.color("text.secondary")).lineLimit(1)
                    }
                    Text(state(id)).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary")).fixedSize()
                }
                .contentShape(Rectangle())
                .onTapGesture { if model.makeIt.run(for: id) != nil { model.makeIt.shownClipID = id; _ = model.setScope(id) } }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
            }
        }
        .columnLayoutEvidence("makeIt.series")
    }
    private func state(_ id: String) -> String {
        guard let run = model.makeIt.run(for: id) else { return model.makeIt.queue.contains(id) ? "Waiting" : "" }
        switch run.phase {
        case .planning, .applying: return "Making…"
        case .ready: return "Ready"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        }
    }
}

/// ✦ on a clip row (kept or suggested): the row's one-click Make it postable, 22 × 20 like ⋯ so the title keeps its room
/// at 176 pt. Its tooltip and spoken name carry the price: "Make it postable · up to $0.42".
@MainActor struct MakeItRowButton: View {
    let model: EditorModel
    let clipID: String
    let action: () -> Void
    var body: some View {
        let title = model.makeItTitle(clipID: clipID)
        Button(action: action) {
            Text("✦").font(.system(size: 12)).foregroundStyle(DesignValues.color("ai.tint"))
                .frame(width: 22, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.borderless).focusable(false)
        .help(title)
        .accessibilityLabel(title.replacingOccurrences(of: "✦ ", with: ""))
        .columnLayoutEvidence("explorer.clipMakeIt", text: title)
    }
}

/// The send line under the score (design.md §6.7.1): what the AI read of the picture, then up to five of the sent frames
/// with their times; a click seeks the preview.
@MainActor struct MakeItSendLine: View {
    let model: EditorModel
    let run: MakeItRun
    let line: (lead: String, emphasis: String, tail: String)

    var body: some View {
        VStack(alignment: .leading, spacing: VCTokens.spacingRowGap) {
            (Text(line.lead) + Text(line.emphasis).fontWeight(.semibold).foregroundColor(DesignValues.color("text.primary")) + Text(line.tail))
                .font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary"))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, VCTokens.spacingFieldPaddingX).padding(.vertical, VCTokens.spacingFieldPaddingY)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(DesignValues.color("bg.input")))
                .columnLayoutEvidence("makeIt.sendLine", text: line.lead + line.emphasis + line.tail)
            let strip = model.makeItFrameStrip(run)
            if !strip.isEmpty {
                MakeItFrameRow(model: model, frames: strip, arrow: false, times: true)
                    .columnLayoutEvidence("makeIt.frameStrip", text: "\(strip.count)")
            }
        }
    }
}

/// Small frames in a row: the opening's before → after, the cover and its candidates, the send line's strip. A click seeks
/// the preview there, or picks it when `pick` is given.
@MainActor struct MakeItFrameRow: View {
    let model: EditorModel
    let frames: [MakeItRowFrame]
    let arrow: Bool
    var times = false
    var pick: ((MakeItRowFrame) -> Void)?

    var body: some View {
        HStack(spacing: VCTokens.spacingChipGap) {
            ForEach(Array(frames.enumerated()), id: \.element.id) { index, frame in
                if arrow, index > 0 {
                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(DesignValues.color("text.tertiary"))
                        .accessibilityHidden(true)
                }
                Button { if let pick { pick(frame) } else { model.seek(source: frame.time) } } label: { thumbnail(frame) }
                    .buttonStyle(.plain)
                    .help(pick == nil ? "Show this frame" : "Use this frame as the cover")
                    .accessibilityLabel((pick == nil ? "Frame at " : "Cover at ") + AIText.formatTime(frame.time) + (frame.tag.map { ", \($0)" } ?? ""))
            }
        }
    }

    private func thumbnail(_ frame: MakeItRowFrame) -> some View {
        let image = NSImage(data: frame.jpeg) ?? NSImage()
        return Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            .frame(width: 64, height: 36).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(DesignValues.color(frame.picked ? "ai.tint" : "line.edge"), lineWidth: frame.picked ? 2 : 1))
            .overlay(alignment: .bottomLeading) {
                if let tag = frame.tag {
                    Text(tag).font(.system(size: 8, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 3).background(DesignValues.color("status.error")).clipShape(RoundedRectangle(cornerRadius: 2))
                        .padding(1)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if times {
                    Text(AIText.formatTime(frame.time)).font(DesignValues.mono(8)).foregroundStyle(.white.opacity(0.85)).padding(.trailing, 3)
                }
            }
    }
}

extension String {
    /// The string with its first character upper-cased.
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
