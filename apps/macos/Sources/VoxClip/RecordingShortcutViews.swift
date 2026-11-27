import AppKit
import SwiftUI
import VoxClipCore

@MainActor struct OtherRecordingLines: View {
    let editor: EditorModel
    @State private var showAll = false

    var body: some View {
        let runs = editor.otherRecordingLines
        if !runs.isEmpty {
            DisclosureGroup("Only in other recordings · \(runs.count)", isExpanded: Binding(
                get: { editor.otherRecordingLinesExpanded }, set: { editor.otherRecordingLinesExpanded = $0 })) {
                ForEach(showAll ? runs : Array(runs.prefix(20)), id: \.startWordId) { run in
                    RecordingSoloRow(editor: editor, run: run, inline: false)
                        .padding(.vertical, 4)
                }
                if !showAll, runs.count > 20 { Button("Show all \(runs.count)") { showAll = true } }
            }.font(.system(size: 11))
        }
    }
}

@MainActor struct RecordingSoloRow: View {
    let editor: EditorModel
    let run: TakeMatch.SoloRun
    let inline: Bool

    var body: some View {
        if let region = editor.recordingRegions.first(where: { $0.key == run.key }) {
            let after = editor.recordingPlacement(run)
            let quote = editor.recordingPlacementQuote(run)
            let missing = editor.recordingMissingReason(region)
            let part = after.flatMap { anchor in editor.activeClip?.playParts.firstIndex { part in
                editor.wordsBetween(part.startWordId, part.endWordId).contains { $0.id == anchor }
            }}.map { " in part \($0 + 1)" } ?? ""
            VStack(alignment: .leading, spacing: 4) {
                if !inline {
                    HStack(spacing: 5) {
                        RecordingLabel(region: region)
                        Text(editor.recordingLineTime(run.startWordId, run.endWordId, region: region))
                        if run.sentenceCount > 1 { Text("· \(run.sentenceCount) sentences") }
                    }.foregroundStyle(.secondary)
                    Text(editor.recordingLineText(run.startWordId, run.endWordId))
                }
                Text("only in \(region.label)" + (quote.map { " · fits after \($0)\(inline ? "" : part)" } ?? ""))
                    .foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack { actions(after: after, missing: missing) }
                    VStack(alignment: .leading) { actions(after: after, missing: missing) }
                }
                if let missing {
                    Text(missing).foregroundStyle(.secondary)
                    Button("Locate…") { editor.locateRecording(region) }
                } else if after == nil {
                    Text(quote.map { "\($0) isn't in \(editor.scopeName(editor.activeClip?.id)). Insert it at the end, then move it." }
                         ?? "This line has no match in \(editor.scopeName(editor.activeClip?.id)). Insert it at the end, then move it.")
                        .foregroundStyle(.secondary)
                }
            }.font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func actions(after: String?, missing: String?) -> some View {
        Button(inline ? "▶" : "▶ Play There") { editor.playRecordingLineThere(run) }
            .accessibilityLabel("Play There").disabled(after == nil || missing != nil)
        Button("Insert There") { editor.insertRecordingLine(run) }
            .disabled(after == nil || missing != nil || !editor.capabilities.edit)
        if after == nil {
            Button("Insert at End") { editor.insertRecordingLine(run, atEnd: true) }
                .disabled(missing != nil || !editor.capabilities.edit)
        }
    }
}

enum RecordingVersionKey: Equatable {
    case up, down, play, use, close

    init?(code: UInt16, modifiers: NSEvent.ModifierFlags) {
        guard modifiers.isDisjoint(with: [.command, .option, .control, .shift]) else { return nil }
        switch code {
        case 126: self = .up
        case 125: self = .down
        case 49: self = .play
        case 36, 76: self = .use
        case 53: self = .close
        default: return nil
        }
    }
}

@MainActor private struct RecordingLineVersions: View {
    let editor: EditorModel
    let line: RecordingClipLine
    let transcript: TranscriptNSTextView?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Line \(line.number) · \(line.alternatives.count) other version\(line.alternatives.count == 1 ? "" : "s")").fontWeight(.semibold)
                Spacer()
                Button { close() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close Other Versions")
            }
            ForEach([line.take] + line.alternatives, id: \.key) { take in
                if let region = editor.recordingRegions.first(where: { $0.key == take.key }) {
                    version(take, region: region)
                }
            }
            if let pending = editor.pendingRecording, pending.transcriber.isRunning {
                Text("\(pending.label)'s version of this line shows when transcribing finishes.").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .padding(8)
        .background(DesignValues.color("bg.muted"), in: RoundedRectangle(cornerRadius: 6))
        .focusable().focused($focused)
        .onAppear { focused = true }
        .onKeyPress(keys: [.upArrow, .downArrow, .space, .return, .escape]) { press in
            guard press.modifiers.isEmpty else { return .ignored }
            if press.key == .escape { close(); return .handled }
            let key: RecordingVersionKey = switch press.key {
            case .upArrow: .up
            case .downArrow: .down
            case .space: .play
            default: .use
            }
            editor.handleRecordingVersionKey(key, for: line)
            return .handled
        }
    }

    private func close() {
        editor.handleRecordingVersionKey(.close, for: line)
        transcript?.focusRecordingLine(line)
    }

    @ViewBuilder private func version(_ take: TakeMatch.Take, region: ProjectClock.Region) -> some View {
        let current = take.key == line.take.key
        let span = line.span(to: take.key)
        let missing = editor.recordingMissingReason(region)
        let reason = current || missing != nil ? nil : editor.recordingLineCopyReason(line, key: take.key)
        let selected = editor.recordingSelectedVersionKey == take.key
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                RecordingLabel(region: region)
                Text(editor.recordingLineTime(take.startWordId, take.endWordId, region: region)).foregroundStyle(.secondary)
                if current { Text("In \(editor.scopeName(editor.activeClip?.id))").fontWeight(.medium) }
            }
            versionText(take, span: span, current: current)
            let signals = take.signals
            Text("\(signals.fillers) fillers · longest pause \(toFixed1(signals.longestPause)) s · \(Int(signals.wordsPerMinute.rounded())) wpm")
                .foregroundStyle(.secondary)
            if let span, span.endWordId != take.endWordId, let index = editor.index(span.endWordId) {
                Text("Brings in only the words that line up, up to “\(editor.text(editor.words[index]))”.").foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack { versionActions(take, current: current, copy: reason != nil, missing: missing != nil) }
                VStack(alignment: .leading) { versionActions(take, current: current, copy: reason != nil, missing: missing != nil) }
            }
            if let reason { Text(reason).foregroundStyle(.secondary) }
            if let missing {
                Text(missing).foregroundStyle(.secondary)
                Button("Locate…") { editor.locateRecording(region) }
            }
        }
        .padding(6)
        .background(selected ? DesignValues.color("bg.surface") : .clear, in: RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func versionText(_ take: TakeMatch.Take, span: TakeMatch.AlignedSpan?, current: Bool) -> Text {
        let first = current ? line.start : take.startWordId, last = current ? line.end : take.endWordId
        let end = span.flatMap { editor.index($0.endWordId) }
        let changed = Set(span?.changedWordIds ?? [])
        var text = AttributedString()
        for word in editor.wordsBetween(first, last) {
            if !text.characters.isEmpty { text.append(AttributedString(" ")) }
            var piece = AttributedString(editor.text(word))
            if let end, editor.index(word.id).map({ $0 > end }) == true { piece.strikethroughStyle = .single }
            else if changed.contains(word.id) { piece.underlineStyle = .single }
            text.append(piece)
        }
        return Text(text)
    }

    @ViewBuilder private func versionActions(_ take: TakeMatch.Take, current: Bool, copy: Bool, missing: Bool) -> some View {
        Button("▶ Play in Place") {
            editor.recordingSelectedVersionKey = take.key
            editor.playRecordingLineVersion(line, key: take.key)
            focused = true
        }.disabled(missing)
        if !current {
            Button(copy ? "Use in a Copy" : "Use This Version") { editor.useRecordingLineVersion(line, key: take.key) }
                .disabled(missing || !editor.capabilities.edit)
        }
    }
}

enum RecordingInlineControl: Equatable {
    case marker(RecordingClipLine), versions(RecordingClipLine), omitted(RecordingOmittedLine), solo(TakeMatch.SoloRun)

    var inline: Bool { if case .marker = self { true } else { false } }
}

@MainActor private struct RecordingInlineView: View {
    let editor: EditorModel
    let control: RecordingInlineControl
    let transcript: TranscriptNSTextView?

    var body: some View {
        switch control {
        case .marker(let line):
            Button("⇄ \(line.alternatives.count)") { editor.showRecordingLineVersions(line) }
                .font(.system(size: 10)).controlSize(.mini)
                .accessibilityLabel(editor.recordingVersionsAccessibility(line))
        case .versions(let line):
            RecordingLineVersions(editor: editor, line: line, transcript: transcript)
        case .omitted(let line):
            HStack {
                Text("\(line.label) · left out · “\(editor.recordingLineText(line.take.startWordId, line.take.endWordId))”")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 3)
                Button("Put Back") { editor.putBackRecordingLine(line) }
                    .disabled(!editor.capabilities.edit || editor.recordingIsMissing(line.take.key))
            }
            .font(.system(size: 11)).padding(6)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        case .solo(let run):
            RecordingSoloRow(editor: editor, run: run, inline: true)
                .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignValues.color("bg.muted"), in: RoundedRectangle(cornerRadius: 5))
        }
    }
}

@MainActor final class RecordingInlineAttachment: NSTextAttachment {
    static let fileType = "app.voxclip.recording-control"
    weak var editor: EditorModel?
    weak var transcript: TranscriptNSTextView?
    let control: RecordingInlineControl

    init(_ control: RecordingInlineControl, editor: EditorModel, transcript: TranscriptNSTextView?) {
        self.control = control
        self.editor = editor
        self.transcript = transcript
        super.init(data: Data([0]), ofType: Self.fileType)
        Self.registerViewProviderClass(RecordingInlineProvider.self, forFileType: Self.fileType)
    }

    required init?(coder: NSCoder) { nil }

    func content(width: CGFloat) -> AnyView {
        AnyView(Group {
            if let editor { RecordingInlineView(editor: editor, control: control, transcript: transcript) }
        }.frame(width: width, alignment: .leading))
    }
}

@MainActor private final class RecordingInlineProvider: NSTextAttachmentViewProvider, @unchecked Sendable {
    nonisolated override func loadView() {
        MainActor.assumeIsolated {
            guard let attachment = textAttachment as? RecordingInlineAttachment else { return }
            let width = attachment.control.inline ? 38 : 240
            view = NSHostingView(rootView: attachment.content(width: CGFloat(width)))
            tracksTextAttachmentViewBounds = true
        }
    }

    nonisolated override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                               textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        nonisolated(unsafe) let provider = self
        return MainActor.assumeIsolated {
            guard let attachment = provider.textAttachment as? RecordingInlineAttachment,
                  let host = provider.view as? NSHostingView<AnyView> else { return .zero }
            let width = attachment.control.inline ? 38 : max(1, floor(proposedLineFragment.width) - 2)
            if host.frame.width != width {
                host.rootView = attachment.content(width: width)
                host.frame.size.width = width
            }
            let height = attachment.control.inline ? 15 : ceil(host.fittingSize.height) + 4
            return CGRect(x: 0, y: attachment.control.inline ? -3 : 0, width: width, height: height)
        }
    }
}
