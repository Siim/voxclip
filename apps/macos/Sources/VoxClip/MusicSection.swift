import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoxClipCore
import VoxClipMedia

/// The editable library and Eleven Music directions, and the track under this clip.
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
            currentTrack
            directionPicker
            sourcePicker
            switch panel.sourceTab {
            case .free: libraryBrowser
            case .eleven: generationEditor
            case .files: fileBrowser
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
            caption(footer).padding(.top, 4)
                .accessibilityIdentifier("voxclip.music.footer")
        }
        .onAppear { panel.clearStaleResults(model: model); panel.loadFolder() }
        .onChange(of: model.project.id) { panel.clearStaleResults(model: model) }
        .onChange(of: model.project.media.source.contentKey) { panel.clearStaleResults(model: model) }
        .onChange(of: model.renderedActiveClipID) { panel.clearStaleResults(model: model) }
        .onChange(of: MusicPricing.lengthSeconds(forClip: model.musicRenderSeconds)) { panel.clearStaleResults(model: model) }
        .onChange(of: panel.sourceTab) { panel.stopAudition() }
        .onDisappear { panel.stopAudition() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voxclip.music")
        .columnLayoutEvidence("captions.music")
    }

    private var currentTrack: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let current = panel.currentRow(model: model), let entry = model.currentMusic {
                HStack(spacing: 8) {
                    MusicCandidateRow(candidate: current, model: model, panel: panel)
                    Button("Turn off") { panel.remove(model: model) }
                        .buttonStyle(.plain).font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.secondary"))
                        .disabled(!model.capabilities.edit || panel.isUsing)
                        .accessibilityIdentifier("voxclip.music.remove")
                }
                volumeRow(entry)
            } else {
                Text("No music yet").font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.secondary"))
                    .frame(minHeight: 28)
                    .accessibilityLabel("Music off")
            }
        }
        .padding(.bottom, 6)
        .accessibilityIdentifier("voxclip.music.heading")
    }

    private var directionPicker: some View {
        VStack(alignment: .leading, spacing: 3) {
            Picker("Mood", selection: Binding(get: { panel.selection }, set: { panel.selectDirection($0) })) {
                ForEach(panel.directions.indices, id: \.self) { index in
                    Text(panel.directionTitle(index)).tag(index)
                }
            }
            .font(VCType.callout.font()).disabled(panel.isUsing)
            .accessibilityIdentifier("voxclip.music.direction")
            if let reason = panel.direction.reason { caption(reason) }
        }
    }

    private var sourcePicker: some View {
        Picker("Music source", selection: $panel.sourceTab) {
            ForEach(MusicPanel.SourceTab.allCases, id: \.self) { source in Text(source.rawValue).tag(source) }
        }
        .labelsHidden().pickerStyle(.segmented)
        .padding(.vertical, 6)
        .disabled(panel.isUsing)
        .accessibilityIdentifier("voxclip.music.source")
    }

    private var libraryBrowser: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Search free music", text: $panel.query)
                    .textFieldStyle(.roundedBorder).font(VCType.callout.font())
                    .onSubmit { panel.search(model: model) }.disabled(panel.isUsing)
                    .accessibilityIdentifier("voxclip.music.search")
                Button("Search") { panel.search(model: model) }
                    .font(VCType.callout.font()).disabled(panel.isBusy || panel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("voxclip.music.search.submit")
            }
            ForEach(panel.catalogRows(model: model)) { candidate in
                MusicCandidateRow(candidate: candidate, model: model, panel: panel)
            }
            if let note = panel.catalogNote { caption(note) }
            if panel.nextPage(model: model) != nil {
                Button(panel.phase == .searching ? "Loading tracks…" : "More free tracks") { panel.loadMore(model: model) }
                    .font(VCType.callout.font()).disabled(panel.isBusy).padding(.vertical, 4)
                    .accessibilityIdentifier("voxclip.music.more")
            }
        }
        .padding(.vertical, 4)
    }

    private var generationEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Make an original track")
            caption("Eleven Music · paid · one version per Make")
            TextField("Describe the music (no vocals)", text: $panel.prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder).font(VCType.callout.font()).lineLimit(3...6)
                .disabled(panel.isUsing)
                .accessibilityIdentifier("voxclip.music.brief")
            if panel.isUsing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).accessibilityHidden(true)
                    caption("Making and adding one version…")
                }
            } else if let candidate = panel.generationChoice(model: model) {
                MusicCandidateRow(candidate: candidate, model: model, panel: panel)
            } else {
                HStack(spacing: 6) {
                    Button("Get price") { panel.priceGeneration(model: model) }
                        .font(VCType.callout.font())
                        .disabled(!model.capabilities.edit || panel.isBusy || panel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("voxclip.music.price")
                    caption("No audio yet. Getting a price doesn’t generate music.")
                }
            }
            if let note = panel.generationNote { caption(note) }
        }
    }

    private var fileBrowser: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Add a file…") { addFile() }
                .font(VCType.callout.font()).disabled(!model.capabilities.edit || panel.isBusy)
                .accessibilityIdentifier("voxclip.music.addFile")
            if panel.folderFiles.isEmpty { caption("No tracks in your Music folder.") }
            ForEach(panel.folderFiles) { candidate in
                MusicCandidateRow(candidate: candidate, model: model, panel: panel)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(VCType.small.font(.semibold)).foregroundStyle(DesignValues.color("text.secondary"))
            .padding(.top, 6).accessibilityAddTraits(.isHeader)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
            .fixedSize(horizontal: false, vertical: true)
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

    var footer: String { Self.footer(phase: panel.phase, using: model.currentMusic, hasRows: !panel.catalogRows(model: model).isEmpty || !panel.folderFiles.isEmpty) }

    static func footer(phase: MusicPanel.Phase, using: ProjectMusic?, hasRows: Bool) -> String {
        switch phase {
        case .searching: return "Searching the free library…"
        case .pricing: return "Checking the price for this brief…"
        case .using: return "Adding the track under the voice…"
        case .failed: return "Choose another track, or get a new price for the brief."
        case .idle:
            if let using {
                let credit = using.creditLine == nil ? "" : " The credit goes in the post text."
                return "It dips while you talk and fades out at the end. Next: Export.\(credit)"
            }
            return hasRows ? "Preview a track, then pick it for this clip." : "Search the library, price a brief, or add a file."
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

/// A candidate with its source, preview availability and separate pick or priced Make action.
@MainActor struct MusicCandidateRow: View {
    let candidate: MusicCandidate
    @Bindable var model: EditorModel
    @Bindable var panel: MusicPanel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                play
                VStack(alignment: .leading, spacing: 0) {
                    Text(isUsingThis ? "Using \(candidate.title)" : candidate.title)
                        .font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.primary")).lineLimit(1)
                        .accessibilityIdentifier(isUsingThis ? "voxclip.music.using" : "voxclip.music.title")
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
            if candidate.source == .library, !isUsingThis {
                VStack(alignment: .leading, spacing: 2) {
                    if let attribution = candidate.attribution {
                        Text(attribution).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let raw = candidate.sourceUrl, let url = URL(string: raw), url.scheme == "https" {
                        Link("Track source", destination: url).font(VCType.small.font())
                    }
                }
                .padding(.leading, 28)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voxclip.music.row." + candidate.source.rawValue)
    }

    private var isUsingThis: Bool { model.currentMusic.map { MusicPanel.usingID($0) == candidate.id } ?? false }
    private var detail: String? {
        let unavailable = !candidate.needsGeneration && panel.auditionURL(candidate, model: model) == nil ? "Preview unavailable" : nil
        let parts = [candidate.creator, candidate.durationSeconds.map(Self.length), unavailable, candidate.reason].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    private var sendsLine: String {
        let seconds = candidate.durationSeconds.map { Int($0) } ?? 0
        return "Sends the brief above to ElevenLabs for one \(seconds) s instrumental. Editing the brief is free."
    }

    @ViewBuilder private var play: some View {
        if panel.auditionURL(candidate, model: model) != nil {
            let playing = panel.playing == candidate.id
            Button { panel.toggleAudition(candidate, model: model) } label: {
                Label(playing ? "Stop" : "Preview", systemImage: playing ? "stop.fill" : "play.fill")
                    .labelStyle(.iconOnly).font(VCType.small.font()).frame(minWidth: 26, minHeight: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(DesignValues.color("text.secondary"))
            .disabled(panel.isUsing)
            .accessibilityLabel(playing ? "Stop preview of \(candidate.title)" : "Preview \(candidate.title)")
            .help(playing ? "Stop preview" : "Preview track")
            .accessibilityIdentifier("voxclip.music.play")
        } else {
            Image(systemName: candidate.needsGeneration ? "sparkles" : "speaker.slash")
                .font(.system(size: 10)).foregroundStyle(DesignValues.color("text.tertiary"))
                .frame(width: 22, height: 22).accessibilityHidden(true)
        }
    }

    @ViewBuilder private var action: some View {
        if !isUsingThis {
            if panel.phase == .using(candidate.id) {
                ProgressView().controlSize(.mini).accessibilityLabel(candidate.needsGeneration ? "Making music" : "Adding music")
            } else {
                Button(Self.actionTitle(candidate)) { panel.use(candidate, model: model) }
                    .font(VCType.callout.font()).controlSize(.small)
                    .disabled(!model.capabilities.edit || panel.isBusy || (candidate.needsGeneration
                        ? candidate.estimate.flatMap(MusicPricing.label) == nil : candidate.audioURL == nil))
                    .accessibilityIdentifier("voxclip.music.use")
            }
        }
    }
    static func actionTitle(_ candidate: MusicCandidate) -> String {
        guard candidate.needsGeneration else { return "Pick" }
        return candidate.estimate.flatMap(MusicPricing.label).map { "Make & use \u{00B7} " + $0 } ?? "Price unavailable"
    }
    static func badge(_ candidate: MusicCandidate) -> String {
        switch candidate.source {
        case .library: candidate.license == .by ? "CC BY" : candidate.license == .cc0 ? "CC0" : "PD"
        case .generated: candidate.needsGeneration ? "Not made" : "Eleven"
        case .file: "Yours"
        }
    }
    static func badgeName(_ candidate: MusicCandidate) -> String {
        switch candidate.source {
        case .library: "Openverse, \(badge(candidate))"
        case .generated: candidate.needsGeneration ? "Eleven Music, not generated yet" : "Made with Eleven Music"
        case .file: "Your file"
        }
    }
    static func length(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return whole >= 60 ? "\(whole / 60):" + String(format: "%02d", whole % 60) : "\(whole) s"
    }
}
