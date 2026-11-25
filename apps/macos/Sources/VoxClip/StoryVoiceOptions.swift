import SwiftUI
import VoxClipCore

@MainActor struct StoryPartClipButtons: View {
    let model: EditorModel
    let clip: ClipRange
    var includesAll = true

    var body: some View {
        if let parts = clip.parts, !parts.isEmpty {
            let position = min(model.selectedStoryPartIndex, parts.count - 1)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons(parts, position: position) }
                VStack(alignment: .leading, spacing: 6) { buttons(parts, position: position) }
            }
            .disabled(!model.capabilities.edit || model.activeClip?.id != clip.id)
        }
    }

    @ViewBuilder private func buttons(_ parts: [ClipPart], position: Int) -> some View {
        Button("Make Clip of Part \(position + 1)") { model.makeClipsOfStoryParts([parts[position].id]) }
            .fixedSize()
        if includesAll {
            Button("Make Clips of All \(parts.count) Parts") { model.makeClipsOfStoryParts(parts.map(\.id)) }
                .fixedSize()
        }
    }
}

@MainActor struct StoryVoiceOptions: View {
    let model: EditorModel
    let clip: ClipRange

    private var estimates: WholeClipRevoice.Price? {
        guard let shared = model.app.shared, let catalog = try? VoiceLabPriceCatalog.load(shared: shared),
              let ranges = clip.playPartIndices(in: model.words) else { return nil }
        let spoken = ranges.flatMap { model.words[$0] }.filter { $0.kind == .word && !model.cutWordIDs.contains($0.id) }
        let characters = spoken.map { model.text($0) }.joined(separator: " ").unicodeScalars.count
        guard characters > 0 else { return nil }
        let seconds = LipsyncLimits.uploadSeconds(model.editedDuration(clip) + 2)
        return try? WholeClipRevoice.price(characters: characters, ttsModel: VoiceLabWordingFit.modelID,
                                          videoSeconds: seconds, lipsync: .standard, catalog: catalog)
    }

    var body: some View {
        let price = estimates
        let reason = StoryClipPresentation.lipSyncReason(partCount: clip.playParts.count)
        let priceLine = price.map { "voice ≈ \(VoiceLabCostPresentation.format($0.voice.usd)) + lip sync ≈ \(VoiceLabCostPresentation.format($0.lipsync.usd))" }
        let actionTitle = price.map { "Revoice Whole Clip · ≈ \(VoiceLabCostPresentation.format($0.voice.usd + $0.lipsync.usd))" } ?? "Revoice Whole Clip"
        VStack(alignment: .leading, spacing: 12) {
            Text("How should it sound?").font(VCType.callout.font(.semibold)).accessibilityAddTraits(.isHeader)
            option("Only the changed phrases", detail: "your recording stays", reason: StoryClipPresentation.rewriteReason)
            option("The whole clip in your voice, lip-synced", detail: priceLine, reason: reason)
            StoryPartClipButtons(model: model, clip: clip)
            Button(actionTitle) {}.disabled(true).accessibilityHint(reason)
                .columnLayoutEvidence("voice.story.revoice", text: actionTitle)
            Text("Not available on a story clip yet. Phrases you already revoiced still play in their parts.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(VCType.small.font())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func option(_ title: String, detail: String?, reason: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {} label: { Label(title, systemImage: "circle").font(VCType.small.font(.semibold)) }
                .buttonStyle(.plain).disabled(true).accessibilityHint(reason)
            if let detail { Text(detail).foregroundStyle(.secondary) }
            Text(reason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignValues.color("bg.muted"), in: RoundedRectangle(cornerRadius: 6))
    }
}
