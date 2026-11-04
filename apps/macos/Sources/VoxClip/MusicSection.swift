import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoxClipCore
import VoxClipMedia

/// The Music section under Captions (doc/spec/music.md §6), in the Captions panel's look: an uppercase heading, 24 pt
/// rows, a 120 pt key column. Claude's best three across sources, each with ▶, a source badge and Use (a generation
/// shows its price on the button, which is the approval); "Using" on the chosen one; search; Add a file…; one volume
/// slider. Without suggestions it lists the Music folder's files, never an empty list. No sheets or alerts.
@MainActor struct MusicSection: View {
    @Bindable var model: EditorModel
    @Bindable var panel: MusicPanel
    @State private var gain: Double?

    init(model: EditorModel) {
        self.model = model
        self.panel = model.musicPanel
    }

    var body: some View {
        let _ = model.projectRevision
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(DesignValues.color("line.default")).frame(height: 1).padding(.top, 6).accessibilityHidden(true)
            heading
            ForEach(panel.rows(model: model)) { candidate in
                MusicCandidateRow(candidate: candidate, model: model, panel: panel)
            }
            if panel.rows(model: model).isEmpty {
                Text("Search for music, or add a file of your own.")
                    .font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.tertiary"))
                    .frame(height: CaptionsPanelMetrics.propertyRowHeight)
            }
            searchRow
            if let entry = model.currentMusic { volumeRow(entry) }
            ForEach(panel.notes, id: \.self) { note in
                Text(note).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
                    .fixedSize(horizontal: false, vertical: true).padding(.vertical, 2)
            }
            if case .failed(let message) = panel.phase {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary"))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Dismiss") { panel.dismissFailure() }.buttonStyle(.link).font(VCType.small.font())
                }
                .padding(.vertical, 2)
                .accessibilityIdentifier("voxclip.music.error")
            }
            Text(footer).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
                .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                .accessibilityIdentifier("voxclip.music.footer")
        }
        .onAppear { panel.loadFolder() }
        .onDisappear { panel.stopAudition() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voxclip.music")
        .columnLayoutEvidence("captions.music")
    }

    private var heading: some View {
        HStack(spacing: 8) {
            Text("Music").textCase(.uppercase).font(VCType.small.font(.semibold)).tracking(0.55)
                .foregroundStyle(DesignValues.color("text.tertiary"))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("voxclip.music.heading")
            Spacer(minLength: 8)
            if panel.phase == .searching {
                ProgressView().controlSize(.mini).accessibilityLabel("Finding music")
            }
            if model.currentMusic != nil {
                Button("Remove") { panel.remove(model: model) }
                    .buttonStyle(.plain).font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.secondary"))
                    .disabled(!model.capabilities.edit)
                    .accessibilityIdentifier("voxclip.music.remove")
            }
        }
        .frame(height: 30)
    }

    private var searchRow: some View {
        HStack(spacing: 6) {
            TextField("Search music or add a file…", text: $panel.query)
                .textFieldStyle(.roundedBorder).font(VCType.callout.font())
                .onSubmit { panel.search(model: model) }
                .accessibilityIdentifier("voxclip.music.search")
            Button("Add a file…") { addFile() }
                .font(VCType.callout.font())
                .disabled(!model.capabilities.edit || isUsing)
                .accessibilityIdentifier("voxclip.music.addFile")
        }
        .padding(.vertical, 4)
    }

    private func volumeRow(_ entry: ProjectMusic) -> some View {
        CaptionPropertyRow("Volume", marker: "music.volume") {
            HStack(spacing: 6) {
                Slider(value: Binding(get: { gain ?? entry.gainDb }, set: { gain = $0 }), in: ProjectMusic.gainRange) { editing in
                    if !editing, let value = gain { panel.setGain(value, model: model); gain = nil }
                }
                .controlSize(.mini)
                .disabled(!model.capabilities.edit)
                .accessibilityLabel("Music volume")
                .accessibilityValue(Self.gainLabel(gain ?? entry.gainDb))
                .accessibilityIdentifier("voxclip.music.volume")
                Text(Self.gainLabel(gain ?? entry.gainDb)).font(VCType.small.font()).monospacedDigit()
                    .foregroundStyle(DesignValues.color("text.tertiary")).frame(width: 44, alignment: .trailing)
            }
        }
    }

    static func gainLabel(_ db: Double) -> String {
        let value = (db * 2).rounded() / 2
        let text = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
        return (value < 0 ? text.replacingOccurrences(of: "-", with: "\u{2212}") : text) + " dB"
    }

    private var isUsing: Bool { if case .using = panel.phase { return true } else { return false } }

    /// Every footer names the next step.
    var footer: String { Self.footer(phase: panel.phase, using: model.currentMusic, hasRows: !panel.rows(model: model).isEmpty) }

    static func footer(phase: MusicPanel.Phase, using: ProjectMusic?, hasRows: Bool) -> String {
        switch phase {
        case .searching: return "Finding music across the free library, Eleven Music and your folder…"
        case .using: return "Adding the track under the voice…"
        case .failed: return "Nothing was changed. Try another track, or try this one again."
        case .idle:
            if let using {
                let credit = using.creditLine == nil ? "" : " The credit goes in the post text."
                return "It dips while you talk and fades out at the end. Next: Export.\(credit)"
            }
            return hasRows ? "Next: \u{25B6} to listen, then Use." : "Next: search, or add a file."
        }
    }

    /// The system file picker (allowed: it is not an editor pop-up), limited to MP3, M4A, WAV and AIFF.
    private func addFile() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = true; picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        picker.allowedContentTypes = [.mp3, .mpeg4Audio, .wav, .aiff]
        picker.directoryURL = MusicPanel.folder()
        guard picker.runModal() == .OK, let url = picker.url, let candidate = MusicLibraryFolder.candidate(for: url) else { return }
        panel.use(candidate, model: model)
    }
}

/// One candidate: ▶ (■ while playing), the title and creator, a source badge, then Use, "Using" or the priced Make.
@MainActor struct MusicCandidateRow: View {
    let candidate: MusicCandidate
    @Bindable var model: EditorModel
    @Bindable var panel: MusicPanel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                play
                VStack(alignment: .leading, spacing: 0) {
                    Text(candidate.title).font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.primary")).lineLimit(1)
                    if let detail { Text(detail).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary")).lineLimit(1) }
                }
                Spacer(minLength: 4)
                Text(Self.badge(candidate)).font(VCType.small.font(.semibold)).foregroundStyle(DesignValues.color("text.secondary"))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(DesignValues.color("bg.raised")))
                    .accessibilityLabel(Self.badgeName(candidate))
                action
            }
            .frame(minHeight: 30)
            if candidate.needsGeneration, !isUsingThis {
                Text(sendsLine).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 28)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voxclip.music.row." + candidate.source.rawValue)
    }

    private var isUsingThis: Bool { model.currentMusic.map { MusicPanel.usingID($0) == candidate.id } ?? false }
    private var detail: String? {
        if isUsingThis { return nil }
        let parts = [candidate.creator, candidate.reason, candidate.durationSeconds.map(Self.length)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    private var sendsLine: String {
        let seconds = candidate.durationSeconds.map { Int($0) } ?? 0
        return "Sends this prompt to ElevenLabs for a \(seconds) s instrumental: \u{201C}\(candidate.prompt ?? "")\u{201D}"
    }

    @ViewBuilder private var play: some View {
        if panel.auditionURL(candidate, model: model) != nil {
            let playing = panel.playing == candidate.id
            Button { panel.toggleAudition(candidate, model: model) } label: {
                Image(systemName: playing ? "stop.fill" : "play.fill").font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(DesignValues.color("text.secondary"))
            .accessibilityLabel(playing ? "Stop \(candidate.title)" : "Play \(candidate.title)")
            .accessibilityIdentifier("voxclip.music.play")
        } else {
            Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(DesignValues.color("text.tertiary"))
                .frame(width: 22, height: 22).accessibilityHidden(true)
        }
    }

    @ViewBuilder private var action: some View {
        if isUsingThis {
            Text("Using").font(VCType.callout.font(.semibold)).foregroundStyle(DesignValues.color("text.secondary"))
                .accessibilityIdentifier("voxclip.music.using")
        } else if panel.phase == .using(candidate.id) {
            ProgressView().controlSize(.mini).accessibilityLabel(candidate.needsGeneration ? "Making music" : "Adding music")
        } else {
            Button(Self.actionTitle(candidate)) { panel.use(candidate, model: model) }
                .font(VCType.callout.font()).controlSize(.small)
                .disabled(!model.capabilities.edit || isBusy)
                .accessibilityIdentifier("voxclip.music.use")
        }
    }
    private var isBusy: Bool { if case .using = panel.phase { return true } else { return false } }

    /// "Use", or for a generation "Make · $0.11" (the click is the approval).
    static func actionTitle(_ candidate: MusicCandidate) -> String {
        guard candidate.needsGeneration else { return "Use" }
        return candidate.estimate.flatMap(MusicPricing.label).map { "Make \u{00B7} " + $0 } ?? "Make"
    }
    static func badge(_ candidate: MusicCandidate) -> String {
        switch candidate.source {
        case .library: candidate.license == .by ? "CC BY" : candidate.license == .cc0 ? "CC0" : "PD"
        case .generated: "Eleven"
        case .file: "Yours"
        }
    }
    static func badgeName(_ candidate: MusicCandidate) -> String {
        switch candidate.source {
        case .library: "Free library, \(badge(candidate))"
        case .generated: "Made with Eleven Music"
        case .file: "Your file"
        }
    }
    static func length(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return whole >= 60 ? "\(whole / 60):" + String(format: "%02d", whole % 60) : "\(whole) s"
    }
}
