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
                if let span = model.timelineItemSpan(item.item.id) {
                    let start = item.ranges.first?.start ?? item.marker ?? span.lowerBound
                    let length = item.ranges.last.map { $0.end - start } ?? span.upperBound - span.lowerBound
                    TimelineExactField(label: "Start", value: start, writable: item.movable && item.item.lane != .video && model.capabilities.edit) { time in
                        guard let canvas = zoom.canvas else { return false }
                        return commit(.move(items: [item.item.id], toAnchor: canvas.itemSourceTime(time)))
                    }
                    if let word = model.word(at: span.lowerBound, nearest: true) {
                        Text("on “\(model.text(word))”").foregroundStyle(.secondary).lineLimit(1)
                    }
                    TimelineExactField(label: "Length", value: length, writable: item.movable && model.capabilities.edit) { length in
                        guard let canvas = zoom.canvas else { return false }
                        return commit(.trim(item: item.item.id, edge: .end, toSource: canvas.itemSourceTime(start + length)))
                    }
                }
                if let reason = item.item.reason { Text(reason).foregroundStyle(.secondary) }
                if case .music(let id) = item.item.id, let track = model.currentMusic {
                    musicDetails(track, id: id)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: 24)
        }
        .scrollIndicators(.hidden)
    }

    private func musicDetails(_ track: ProjectMusic, id: String) -> some View {
        let segment = track.segments?.first { $0.id == id }
        let from = segment?.songFromSeconds ?? track.startOffsetSeconds
        let fadeIn = segment?.fadeInSeconds ?? track.fadeInSeconds
        let fadeOut = segment?.fadeOutSeconds ?? track.fadeOutSeconds
        let gain = track.gainDb + (segment?.gainDb ?? 0)
        let duck = track.duckDb ?? (track.ducking ? -12 : 0)
        return Group {
            Text("Song from \(timelineItemTime(from))")
            Text("Fade in \(fadeIn, specifier: "%.1f") s")
            Text("Fade out \(fadeOut, specifier: "%.1f") s")
            Text("Volume \(gain, specifier: "%.1f") dB")
            Text("Dips under voice \(duck, specifier: "%.1f") dB")
            if segment?.loop ?? true { Text("Loop") }
        }
        .foregroundStyle(.secondary)
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
                Button("Delete") {
                    if commit(.delete(items: ids)) { model.selectTimelineItems([]) }
                }.disabled(blocked || speechSelected).help("Delete item (⌫)")
                if let single {
                    switch single.item.id {
                    case .effect, .motion, .footage, .music:
                        Button(single.item.lane == .music ? "Music…" : "Open Editor") { zoom.canvas?.openItem(single.item.id) }
                    default: EmptyView()
                    }
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
    let writable: Bool
    let commit: (Double) -> Bool
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var formatted: String { String(format: "%.3f", value) }

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            TextField(label, text: $draft)
                .labelsHidden().monospacedDigit().frame(width: 65).controlSize(.small)
                .accessibilityLabel("\(label) in seconds")
                .disabled(!writable)
                .focused($focused)
                .onAppear { draft = formatted }
                .onChange(of: value) { if !focused { draft = formatted } }
                .onChange(of: focused) { if !focused { submit() } }
                .onSubmit { submit(); focused = false }
                .onExitCommand { draft = formatted; focused = false }
            Text("s").foregroundStyle(.secondary)
        }
    }

    private func submit() {
        guard draft != formatted else { return }
        if let value = Double(draft), value.isFinite, value >= 0 { _ = commit(value) }
        draft = formatted
    }
}
