import AVKit
import SwiftUI
import VoxClipCore
import VoxClipMedia

@MainActor private struct CardThumbnail: View {
    let url: URL?
    let start: Double
    let portrait: Bool
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            else { Image(systemName: "film").font(VCType.small.font()).foregroundStyle(.tertiary) }
        }
        .frame(width: portrait ? 22 : 52, height: portrait ? 36 : 30)
        .background(DesignValues.color("bg.sunken"))
        .clipShape(.rect(cornerRadius: 4))
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 104, height: 104)
            if let frame = try? await generator.image(at: CMTime(seconds: start, preferredTimescale: 600)).image, !Task.isCancelled {
                image = frame
            }
        }
    }
}

@MainActor struct CardImportView: View {
    let shell: WorkspaceShell
    @State private var takePlayer: AVPlayer?
    private var card: CardImport { shell.cardImport }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch card.stage {
            case .offer: offer
            case .copying, .finding, .ranking: progress
            case .making, .done: results
            }
            if let notice = card.notice { InlineNotice(text: notice).padding(.top, 8) }
        }
        .accessibilityIdentifier("voxclip.home.cardImport")
        .onDisappear { takePlayer?.pause() }
    }

    private var offer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                heading(offerTitle)
                Spacer()
                Button("Dismiss") { card.dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if card.scanRunning { ProgressView().controlSize(.small) }
            Text(offerDetail).font(VCType.callout.font()).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("✦ Make clips from \(card.selected.count) new · up to $\(CardImport.cap)") { card.start(shell.app) }
                    .buttonStyle(.borderedProminent).disabled(card.blocked(shell.app) != nil)
                Button(card.picking ? "Done picking" : "Pick recordings") { card.picking.toggle() }
                    .buttonStyle(.borderless).disabled(card.newFiles.isEmpty)
            }
            if let reason = card.blocked(shell.app), !card.scanRunning { small(reason) }
            small("Claude Code receives your transcript, recording names and selected still frames on your Claude plan. Voice and lip sync stay within the $\(CardImport.cap) cap.")
            if card.picking {
                ForEach(card.newFiles) { file in selection(file) }
                Button("Copy selected without making clips") { card.start(shell.app, copyOnly: true) }
                    .disabled(card.blocked(shell.app, copyOnly: true) != nil)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.45)))
    }

    private var offerTitle: String {
        "\(card.name) · \(card.files.count) recordings · \(durationLabel(card.files.reduce(0) { $0 + $1.duration }))"
    }

    private var offerDetail: String {
        if card.scanRunning { return "Reading the recordings on this Mac…" }
        if card.files.isEmpty { return "No supported recordings found. VoxClip can import MOV, MP4 and M4V." }
        if card.newFiles.isEmpty { return "These recordings have already been copied to this Mac." }
        let size = ByteCountFormatter.string(fromByteCount: card.bytes, countStyle: .file)
        let capacity = card.capacity.map { ", \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) free" } ?? ""
        return "\(card.newFiles.count) new since the last import. Selected recordings copy to Movies › VoxClip › \(card.destinationName) (\(size)\(capacity))."
    }

    private func selection(_ file: FolderRecording) -> some View {
        let title = "\(file.url.deletingPathExtension().lastPathComponent) · \(durationLabel(file.duration))"
        return Toggle(title, isOn: Binding(get: { card.chosen.contains(file.id) }, set: { _ in card.toggle(file.id) })).toggleStyle(.checkbox)
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                heading("\(card.destinationName) · \(card.rows.count) recordings")
                step("Copied to this Mac", value: "\(card.copied) of \(card.rows.count)", complete: card.stage != .copying, active: card.stage == .copying)
                step("Transcribing on this Mac, two at a time", value: "\(card.transcribed) of \(card.rows.count)", complete: card.stage == .ranking, active: card.rows.contains { $0.status == "Transcribing" })
                step(card.stage == .ranking ? "Ranking moments and merging retakes" : "Finding moments", value: "\(card.moments.count) so far", complete: false, active: card.stage == .ranking || card.rows.contains { $0.status == "Finding" })
                step("Making the best ones postable", value: "", complete: false, active: false)
                ProgressView(value: Double(card.copied + card.transcribed), total: Double(max(1, card.rows.count * 2)))
                    .accessibilityLabel("Copy and transcription progress")
            }.padding(12)
            ForEach(card.rows) { row in recordingRow(row) }
            status
        }
        .background(DesignValues.color("bg.window"), in: .rect(cornerRadius: 8))
    }

    private func step(_ label: String, value: String, complete: Bool, active: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: complete ? "checkmark" : active ? "circle.fill" : "circle")
                .frame(width: 13).foregroundStyle(complete ? Color.green : active ? Color.accentColor : .secondary)
            Text(label).font(VCType.callout.font())
            Spacer()
            small(value)
        }
    }

    private var results: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if card.stage == .done { finished.padding(12) }
            else {
                HStack {
                    heading("Best across the card · \(card.moments.count) moments")
                    Spacer()
                    small("\(min(12, card.moments.filter { $0.score >= 7 }.count)) worth posting")
                }.padding(12)
            }
            if !card.retakes.isEmpty { retakeReview.padding(.horizontal, 12).padding(.bottom, 8) }
            ForEach(Array(card.moments.enumerated()), id: \.element.id) { index, moment in momentRow(moment, index: index + 1) }
            if card.moments.isEmpty || card.rows.contains(where: { $0.status != "Found" && $0.status != "Copied" }) {
                ForEach(card.rows) { row in recordingRow(row) }
            }
            status
        }
        .background(DesignValues.color("bg.window"), in: .rect(cornerRadius: 8))
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 6) {
            heading(card.budget == nil ? "\(card.copied) recordings copied" : "\(card.ready.count) clips ready from \(card.name)")
            small(card.budget == nil ? "Each recording is saved as a project." : "From \(card.copied) recordings in \(durationLabel(card.elapsed ?? 0)) · \(card.spent) of $\(CardImport.cap) · \(card.merged) retakes merged")
            if card.budget != nil {
                HStack(spacing: 8) {
                    Button("Export All · 9:16") { card.export(.portrait) }.buttonStyle(.borderedProminent).disabled(card.ready.isEmpty || card.exporting)
                    Button("Also 16:9") { card.export(.landscape) }.buttonStyle(.bordered).disabled(card.ready.isEmpty || card.exporting)
                    Button("Show in Finder") { if let url = card.exports { NSWorkspace.shared.open(url) } }.buttonStyle(.borderless).disabled(card.exports == nil)
                }
                small(card.exporting ? "Exporting and checking on this Mac…" : "Movies › VoxClip › Exports › \(card.destinationName): videos, covers and posts.txt.")
                if card.ready.isEmpty { small("No clips are ready to export. Open a recording to continue in the editor.") }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(DesignValues.color("bg.surface"), in: .rect(cornerRadius: 8))
    }

    private var retakeReview: some View {
        DisclosureGroup("\(card.merged) \(card.merged == 1 ? "retake merged" : "retakes merged")") {
            ForEach(card.retakes) { pair in
                VStack(alignment: .leading, spacing: 4) {
                    small("Kept “\(pair.kept.clip.title ?? "Untitled clip")” from \(pair.kept.recording.file.url.lastPathComponent). The other take is still in its project.")
                    HStack {
                        Button("Hear kept take") { play(pair.kept) }.disabled(pair.kept.recording.localMedia == nil)
                        Button("Hear other take") { play(pair.other) }.disabled(pair.other.recording.localMedia == nil)
                        if let url = pair.other.recording.url {
                            Button("Use the other take") {
                                Task { if await shell.openProject(at: url) { shell.choose(.clip(pair.other.id), byClick: false) } }
                            }.disabled(card.owns(url))
                        }
                    }.buttonStyle(.borderless)
                }.padding(.vertical, 4)
            }
            if card.running { small("You can open the other take once the card finishes.") }
            if let takePlayer { VideoPlayer(player: takePlayer).frame(height: 130) }
        }.font(VCType.callout.font()).padding(8).background(DesignValues.color("bg.surface"), in: .rect(cornerRadius: 6))
    }

    private func play(_ moment: CardImport.Moment) {
        guard let url = moment.recording.localMedia else { return }
        let player = takePlayer ?? AVPlayer()
        let item = AVPlayerItem(url: url)
        item.forwardPlaybackEndTime = CMTime(seconds: moment.start + moment.seconds, preferredTimescale: 600)
        player.replaceCurrentItem(with: item)
        player.seek(to: CMTime(seconds: moment.start, preferredTimescale: 600))
        takePlayer = player
        player.play()
    }

    private func recordingRow(_ row: CardImport.Recording) -> some View {
        let title = "\(row.file.url.deletingPathExtension().lastPathComponent) · \(durationLabel(row.file.duration))"
        let detail = if row.saveFailed { "Couldn't save the latest changes. Earlier work is kept." }
            else if row.status == "Transcribing", let fraction = row.model?.progressFraction { "Transcribing · \(fraction.formatted(.percent.precision(.fractionLength(0))))" }
            else { row.detail }
        return listRow(title, detail: detail, badge: row.status, portrait: false, url: row.url, media: row.localMedia)
    }

    private func momentRow(_ moment: CardImport.Moment, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            listRow("\(index) · \(moment.clip.title ?? "Untitled clip")",
                    detail: "\(moment.recording.file.url.deletingPathExtension().lastPathComponent) · \(durationLabel(moment.start)) · score \(moment.score) · \(durationLabel(moment.seconds))",
                    badge: badge(moment), portrait: true, url: moment.recording.url, clip: moment.id, media: moment.recording.localMedia, start: moment.start)
            ForEach(moment.recording.model?.exportJob.checks[moment.id] ?? []) { review in
                ExportSelfCheckRows(review: review).padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
    }

    private func badge(_ moment: CardImport.Moment) -> String {
        switch moment.run?.phase {
        case .ready: "Ready"
        case .applying, .planning: "Making…"
        case .failed: "Needs review"
        case .stopped: "Stopped"
        case nil: card.stage == .done || moment.score < 7 ? "Suggested" : "Next"
        }
    }

    private func listRow(_ title: String, detail: String, badge: String, portrait: Bool, url: URL?, clip: String? = nil, media: URL?, start: Double = 0) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 9) {
                CardThumbnail(url: media, start: start, portrait: portrait).frame(width: 52)
                VStack(alignment: .leading, spacing: 0) {
                    if let url {
                        Button(title) { Task {
                            if await shell.openProject(at: url), let clip { shell.choose(.clip(clip), byClick: false) }
                        } }.buttonStyle(.plain).lineLimit(1).disabled(card.owns(url))
                    } else { Text(title).lineLimit(1) }
                    small(detail).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(badge).font(VCType.small.font())
                    .foregroundStyle(badge == "Ready" || badge == "Found" ? Color.green : Color.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            .font(VCType.callout.font()).padding(.horizontal, 12).padding(.vertical, 7)
        }
    }

    private var status: some View {
        HStack {
            small(card.budget == nil ? "Saved on this Mac" : card.stage == .copying || card.stage == .finding ? "✦ Claude does it all · \(card.transcribed) of \(card.rows.count) transcribed" : "✦ Claude does it all · \(card.ready.count) ready")
            Spacer()
            if card.budget != nil { small("\(card.spent) / $\(CardImport.cap)") }
            if card.running { Button("Stop") { card.stop() }.buttonStyle(.borderless) }
            else { Button("Dismiss") { card.dismiss() }.buttonStyle(.borderless).disabled(card.exporting) }
        }
        .padding(12)
    }

    private func heading(_ text: String) -> some View { Text(text).font(VCType.callout.font()).fontWeight(.semibold) }
    private func small(_ text: String) -> some View { Text(text).font(VCType.small.font()).foregroundStyle(.secondary) }
}
