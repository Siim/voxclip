import SwiftUI
import VoxClipCore

@MainActor struct TimelineItemBar: View {
    let model: EditorModel
    let zoom: TimelineZoom

    private var items: [TimelineItemDisplay] {
        _ = model.projectRevision
        return zoom.canvas?.content.items.filter { model.timelineItemSelection.contains($0.item.id) } ?? []
    }

    var body: some View {
        let items = items
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if items.count == 1, let item = items.first { fields(item) }
                actions(items)
            }
            .padding(.horizontal, 10).padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(VCType.small.font())
            .background(DesignValues.color("bg.window"))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Selected timeline items")
        }
    }

    private func fields(_ item: TimelineItemDisplay) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Text(item.title).fontWeight(.semibold).lineLimit(1)
                let disabledReason = model.timelineFieldDisabledReason(item)
                if let span = model.timelineItemSpan(item.item.id) {
                    let start = item.ranges.first?.start ?? item.marker ?? span.lowerBound
                    let length = item.ranges.last.map { $0.end - start } ?? span.upperBound - span.lowerBound
                    let startReason = disabledReason ?? (item.item.lane == .video ? "Drag a story part to reorder it." : nil)
                    TimelineExactField(label: "Start", value: start, disabledReason: startReason) { time in
                        guard let canvas = zoom.canvas else { return false }
                        return commit(.move(items: [item.item.id], toAnchor: canvas.itemSourceTime(time)))
                    }
                    if let startReason, disabledReason == nil { Text(startReason).foregroundStyle(.secondary) }
                    if let word = model.word(at: span.lowerBound, nearest: true) {
                        Text("on “\(model.text(word))”").foregroundStyle(.secondary).lineLimit(1)
                    }
                    TimelineExactField(label: "Length", value: length, disabledReason: disabledReason) { length in
                        guard let canvas = zoom.canvas else { return false }
                        return commit(.trim(item: item.item.id, edge: .end, toSource: canvas.itemSourceTime(start + length)))
                    }
                }
                if let reason = disabledReason ?? item.item.reason { Text(reason).foregroundStyle(.secondary) }
                if let fades = item.fades {
                    TimelineExactField(label: "Fade in", value: fades.fadeIn, disabledReason: disabledReason) { value in
                        commit(.fade(item: item.item.id, edge: .start, seconds: value))
                    }
                    TimelineExactField(label: "Fade out", value: fades.fadeOut, disabledReason: disabledReason) { value in
                        commit(.fade(item: item.item.id, edge: .end, seconds: value))
                    }
                }
                if let from = item.recordingStart {
                    TimelineExactField(label: "Recording from", value: from, disabledReason: disabledReason) { value in
                        commit(.slip(item: item.item.id, bySeconds: value - from))
                    }
                }
                if let audio = item.audio {
                    audioDetails(audio, item: item, disabledReason: disabledReason)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: 24)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder private func audioDetails(_ audio: TimelineAudioItem, item: TimelineItemDisplay, disabledReason: String?) -> some View {
        let id = item.item.id
        TimelineExactField(label: "Volume", value: audio.gainDb, disabledReason: disabledReason, unit: "dB") { value in
            commit(audio.setGain(id, db: value))
        }
        TimelineExactField(label: audio.offsetLabel, value: audio.mediaStart, disabledReason: disabledReason) { value in
            commit(.slip(item: id, bySeconds: value - audio.mediaStart))
        }
        if let track = audio.music {
            TimelineExactField(label: "Dips under voice", value: audio.duckDb, disabledReason: disabledReason, unit: "dB") { value in
                commit(.setDuck(track: track.id, db: value))
            }
            let reason = disabledReason ?? model.timelineEditReason(.setLoop(item: id, !audio.loop))
            Toggle("Loop", isOn: Binding(get: { audio.loop }, set: { value in _ = commit(.setLoop(item: id, value)) }))
                .disabled(reason != nil).help(reason ?? "Loop the song when it ends.")
                .accessibilityHint(reason ?? "Loop the song when it ends.")
            if let reason, disabledReason == nil { Text(reason).foregroundStyle(.secondary) }
        }
    }

    private func actions(_ items: [TimelineItemDisplay]) -> some View {
        let ids = items.map(\.item.id)
        let single = items.count == 1 ? items.first : nil
        let speechSelected = items.contains { $0.item.lane == .video }
        let blocked = !model.capabilities.edit || items.contains { !$0.movable }
        let splitReason = items.contains(where: \.wordLocked) ? "A bleep covers whole words. Trim it to fewer words instead." : nil
        let disabledReason = blocked ? "This item is read-only." : speechSelected ? "Use Split All to split speech." : splitReason
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if single == nil { Text("\(items.count) items").fontWeight(.semibold) }
                Button("Split") {
                    model.splitTimelineItems(ids)
                    zoom.canvas?.renderContent(keepingZoom: true)
                }.disabled(blocked || speechSelected || splitReason != nil).help("Split at playhead (B)")
                Button("Duplicate") { _ = commit(.duplicate(items: ids, toAnchor: nil)) }
                    .disabled(blocked || speechSelected).help("Duplicate item (⌘D)")
                if let single {
                    let keyframe = model.timelineKeyframeAtPlayhead(single)
                    let reason = model.timelineFieldDisabledReason(single) ?? (keyframe.map { model.timelineEditReason($0) } ?? "Choose a sound or music item.")
                    Button("Add keyframe") { if let keyframe { _ = commit(keyframe) } }
                        .disabled(reason != nil).help(reason ?? "Add volume keyframe at playhead (⌥K)")
                    if let reason, single.audio != nil { Text(reason).foregroundStyle(.secondary) }
                }
                Button("Delete") {
                    if commit(.delete(items: ids)) { model.selectTimelineItems([]) }
                }.disabled(blocked || speechSelected).help("Delete item (⌫)")
                if let single {
                    if single.hasHiddenWords {
                        Button("Restore Words") {
                            model.restoreTimelineWords(single)
                            zoom.canvas?.renderContent(keepingZoom: true)
                        }.disabled(!model.capabilities.edit)
                    }
                    switch single.item.id {
                    case .effect, .motion, .footage:
                        Button("Open Editor") { zoom.canvas?.openItem(single.item.id) }
                    default: EmptyView()
                    }
                    let musicSelected = single.item.lane == .music
                    Button("Music…") { zoom.canvas?.openItem(single.item.id) }
                        .disabled(!musicSelected).help(musicSelected ? "Open Music" : "Choose a music item.")
                }
                if let disabledReason { Text(disabledReason).foregroundStyle(.secondary) }
            }
            .controlSize(.small)
            .frame(height: 24)
        }
        .scrollIndicators(.hidden)
    }

    private func commit(_ command: TimelineEdit) -> Bool {
        let changed = model.commitTimelineItemEdit(command)
        zoom.canvas?.renderContent(keepingZoom: true)
        return changed
    }
}

@MainActor private struct TimelineExactField: View {
    let label: String
    let value: Double
    let disabledReason: String?
    var unit = "s"
    let commit: (Double) -> Bool
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var formatted: String { String(format: "%.3f", value) }

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            TextField(label, text: $draft)
                .labelsHidden().monospacedDigit().frame(width: 65).controlSize(.small)
                .accessibilityLabel("\(label) in \(unit == "dB" ? "decibels" : "seconds")")
                .disabled(disabledReason != nil)
                .help(disabledReason ?? "")
                .accessibilityHint(disabledReason ?? "")
                .focused($focused)
                .onAppear { draft = formatted }
                .onChange(of: value) { if !focused { draft = formatted } }
                .onChange(of: focused) { if !focused { submit() } }
                .onSubmit { submit(); focused = false }
                .onExitCommand { draft = formatted; focused = false }
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private func submit() {
        guard disabledReason == nil else { draft = formatted; return }
        guard draft != formatted else { return }
        if let value = Double(draft.replacingOccurrences(of: "−", with: "-")), value.isFinite, unit == "dB" || value >= 0 { _ = commit(value) }
        draft = formatted
    }
}
