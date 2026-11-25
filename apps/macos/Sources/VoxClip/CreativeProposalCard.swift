import SwiftUI
import VoxClipCore

struct ProposalStripPart: Equatable {
    let start: Double
    let duration: Double

    static func from(_ parts: [ClipProposal.Part], words: [TimedWord]) -> [Self] {
        parts.compactMap { part in
            guard let first = words[safe: part.startWord], let last = words[safe: part.endWord] else { return nil }
            return Self(start: first.start, duration: max(0, last.end - first.start))
        }
    }
}

struct ProposalPartsStrip: View {
    let parts: [ProposalStripPart]

    var body: some View {
        if !parts.isEmpty {
            GeometryReader { geometry in
                let available = max(0, geometry.size.width - Double(parts.count - 1) * 2)
                let total = parts.reduce(0) { $0 + max(0.1, $1.duration) }
                HStack(spacing: 2) {
                    ForEach(parts.indices, id: \.self) { index in
                        segment(index, width: available * max(0.1, parts[index].duration) / total)
                    }
                }
            }
            .frame(height: 20)
            .accessibilityLabel("Parts in play order: " + parts.map { durationLabel($0.start) }.joined(separator: ", "))
            .columnLayoutEvidence("proposal.parts")
        }
    }

    private func segment(_ index: Int, width: Double) -> some View {
        let time = durationLabel(parts[index].start)
        return RoundedRectangle(cornerRadius: 3)
            .fill(StoryClipPresentation.color(index))
            .overlay {
                if width >= 34 { Text(time).font(DesignValues.mono(9)).foregroundStyle(.black).lineLimit(1) }
            }
            .frame(width: width)
            .help("Part \(index + 1) · \(time) in the take")
            .accessibilityHidden(true)
    }
}

struct CreativeProposalGroup: Identifiable, Equatable {
    enum Section: String, CaseIterable {
        case opening = "Opens", picture = "Picture", onScreen = "On screen", extras = "Extras", captions = "Captions", music = "Music"
    }

    struct Item: Equatable {
        let label: String
        let reason: String
    }

    let id: Section
    var items: [Item]
    var changed = false
    var summary: String { items.isEmpty ? "—" : items.map(\.label).joined(separator: " · ") }
}

struct CreativeAssetChip: Hashable {
    let label: String
    let paid: Bool

    static func free(_ name: String) -> Self { Self(label: "\(name) · free", paid: false) }
    static func paid(_ name: String, price: String?) -> Self {
        Self(label: "\(name) · \(price ?? "paid")", paid: true)
    }
}

struct CreativeProposalData {
    let source: String
    let title: String
    let summary: String
    let parts: [ProposalStripPart]
    let groups: [CreativeProposalGroup]
    let chips: [CreativeAssetChip]
    let cost: String?
    var note: String?
    var revised = false
}

@MainActor struct CreativeProposalCard<Controls: View>: View {
    let data: CreativeProposalData
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(data.source).font(VCType.small.font().weight(.semibold)).foregroundStyle(.secondary)
            Text(data.title).font(VCType.title3.font().weight(.semibold))
            Text(data.summary).font(VCType.small.font()).foregroundStyle(.secondary)
            ProposalPartsStrip(parts: data.parts)
            ForEach(data.groups) { group in CreativeProposalGroupRow(group: group) }
            if !data.chips.isEmpty { assets }
            if let note = data.note { Text(note).font(VCType.small.font()).foregroundStyle(.secondary) }
            if let cost = data.cost { costLine(cost) }
            if data.revised { Text("Revised proposal").font(VCType.small.font()).foregroundStyle(.secondary) }
            controls()
        }
        .fixedSize(horizontal: false, vertical: true)
        .claudeCard(highlighted: false)
        .accessibilityIdentifier("voxclip.proposal.card")
        .columnLayoutEvidence("proposal.card")
    }

    private var assets: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { ForEach(data.chips, id: \.self) { chip($0) } }.fixedSize()
            VStack(alignment: .leading, spacing: 4) { ForEach(data.chips, id: \.self) { chip($0) } }
        }
    }

    private func chip(_ item: CreativeAssetChip) -> some View {
        Text(item.label).font(VCType.small.font())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((item.paid ? Color.orange : Color.green).opacity(0.16), in: Capsule())
    }

    private func costLine(_ cost: String) -> some View {
        Text(cost).font(VCType.small.font()).foregroundStyle(.secondary)
            .padding(7).frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignValues.color("bg.muted"), in: .rect(cornerRadius: 6))
            .columnLayoutEvidence("proposal.cost", text: cost)
    }
}

private struct CreativeProposalGroupRow: View {
    let group: CreativeProposalGroup
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { expanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(group.id.rawValue).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
                    Text(group.summary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    if group.changed { Text("Changed").fontWeight(.semibold).foregroundStyle(DesignValues.color("ai.tint")) }
                    if !group.items.isEmpty { Image(systemName: expanded ? "chevron.up" : "chevron.down").foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(group.items.isEmpty)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                ForEach(group.items.indices, id: \.self) { index in
                    let item = group.items[index]
                    Text(item.reason.isEmpty ? item.label : "\(item.label): \(item.reason)").foregroundStyle(.secondary)
                }
                .padding(.leading, 68)
            }
        }
        .font(VCType.small.font())
    }
}
