import AVKit
import SwiftUI
import VoxClipCore

struct ClipExportReview: Identifiable {
    let url: URL
    let aspect: AspectRatio
    let report: ExportCheckReport?
    let captionPosition: CaptionPosition?
    var id: URL { url }
}

@MainActor struct ExportSelfCheckRows: View {
    let review: ClipExportReview
    var centreCaptions: (() -> Void)? = nil
    @State private var player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Export self-check · \(review.aspect.rawValue)").font(VCType.callout.font()).fontWeight(.semibold)
            if let report = review.report {
                ForEach(report.results, id: \.check) { result in row(result) }
            } else {
                Text("Couldn't check this export. The video was saved.").font(VCType.small.font()).foregroundStyle(.secondary)
            }
            if let player { VideoPlayer(player: player).frame(height: 120) }
        }
        .onDisappear { player?.pause() }
    }

    private func row(_ result: ExportCheckResult) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: result.status == .ok ? "checkmark" : result.status == .warning ? "exclamationmark" : "minus")
                .frame(width: 13)
                .foregroundStyle(result.status == .warning ? DesignValues.color("status.warning") : result.status == .ok ? Color.green : Color.secondary)
                .accessibilityLabel(result.status == .ok ? "Passed" : result.status == .warning ? "Needs review" : "Not measured")
            VStack(alignment: .leading, spacing: 2) {
                Text(title(result)).font(VCType.callout.font())
                Text(detail(result)).font(VCType.small.font()).foregroundStyle(.secondary)
                if result.status == .warning { nextStep(result).font(VCType.small.font()).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if result.check == .captions, result.items.contains(where: { $0.kind == .captionBand }), let centreCaptions {
                Button("Centre captions and re-export", action: centreCaptions).buttonStyle(.borderless)
            }
            if [.words, .sync].contains(result.check), result.status != .skipped {
                Button {
                    let playback = player ?? AVPlayer(url: review.url)
                    player = playback
                    let time = result.items.first?.time ?? 0
                    playback.seek(to: CMTime(seconds: max(0, time - 0.35), preferredTimescale: 600))
                    playback.play()
                } label: { Label("Listen", systemImage: "play.fill").labelStyle(.iconOnly) }
                .buttonStyle(.borderless)
            }
        }
        .padding(7).background(DesignValues.color("bg.sunken"), in: .rect(cornerRadius: 6))
    }

    private func nextStep(_ result: ExportCheckResult) -> Text {
        switch result.check {
        case .words: Text("Listen at the marked word, then adjust the cut or review the Rewrite take.")
        case .sync: Text("Listen at the marked time. Check the source sync or review the revoiced phrase before exporting again.")
        case .loudness where result.items.contains(where: { $0.kind == .timelineAudioLevel || $0.kind == .timelineAudioGap }):
            Text("Listen at the marked time and check the music or sound edit before exporting again.")
        case .loudness: Text("Check that the voice isn't muted and adjust the voice or music level, then export again.")
        case .captions where result.items.contains(where: { $0.kind == .titleBand }):
            Text("Move the title away from the frame edge before exporting again.")
        case .captions: Text("Move the captions inside the safe area before exporting again.")
        }
    }

    private func title(_ result: ExportCheckResult) -> String {
        switch (result.check, result.status) {
        case (.words, .ok): "Every word as edited"
        case (.words, .warning): result.items.count == 1 ? "1 word sounds different" : "\(result.items.count) words need review"
        case (.words, .skipped): "Spoken words"
        case (.sync, _): "Voice and picture timing"
        case (.loudness, _) where result.items.contains(where: { $0.kind == .timelineAudioLevel || $0.kind == .timelineAudioGap }):
            "Edited soundtrack"
        case (.loudness, .ok) where result.integratedLufs == nil: "Edited soundtrack"
        case (.loudness, _): "Feed loudness"
        case (.captions, _): "Captions on screen"
        }
    }

    private func detail(_ result: ExportCheckResult) -> String {
        if result.status == .skipped { return result.reason ?? "Not measured." }
        switch result.check {
        case .words:
            if let issue = result.items.first, let expected = issue.expected {
                let heard = issue.heard.map { "heard as “\($0)”" } ?? "not heard"
                return "At \(durationLabel(issue.time)), “\(expected)” was \(heard)."
            }
            return "Transcribed again on this Mac: \(result.matched ?? 0) of \(result.total ?? 0) words match."
        case .sync:
            return result.status == .ok ? "Measured audio and video timing is within tolerance." : "A track or a revoiced phrase is outside its timing tolerance."
        case .loudness:
            if let issue = result.items.first(where: { $0.kind == .timelineAudioLevel || $0.kind == .timelineAudioGap }) {
                return "At \(durationLabel(issue.time)), the soundtrack differs from the timeline mix."
            }
            if let level = result.integratedLufs, let peak = result.truePeakDbtp {
                return "\(level.formatted(.number.precision(.fractionLength(1)))) LUFS · \(peak.formatted(.number.precision(.fractionLength(1)))) dBTP."
            }
            return result.status == .ok ? "The edited music and sound match the timeline mix." : "No audible mix was measured."
        case .captions:
            return result.status == .ok ? "Every caption is inside the safe area for \(review.aspect.rawValue)." : "A caption or title reaches outside the safe area."
        }
    }
}
