import SwiftUI
import VoxClipCore

/// The clip style card's Tone row (design.md §6.6): the tone "Claude does it all" and Make it postable write each clip's
/// words in, and every "Rewrite as" strip's default. ✦ Auto (Claude picks per clip), As I said it, the catalogue tones,
/// then the saved ones. Rewording "Never reword" disables it and says why.
@MainActor struct ClipStyleToneRow: View {
    let editor: EditorModel
    let style: ClipStyle

    var body: some View {
        let catalog = editor.app.rewriteToneCatalog
        let saved = editor.app.myRewriteTones
        let never = style.rewording == .off
        let value = Self.label(style.tone, catalog: catalog, saved: saved)
        HStack(alignment: .firstTextBaseline, spacing: VCTokens.spacingLabelGap) {
            Text("Tone").font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary")).frame(width: 68, alignment: .leading)
            Menu {
                if let catalog {
                    option(.auto, "✦ \(catalog.auto.label)", detail: catalog.auto.detail)
                    option(.asSaid, catalog.asSaid.label, detail: catalog.asSaid.detail)
                    Divider()
                    ForEach(catalog.tones) { tone in option(.tone(tone.id), tone.chipTitle, detail: tone.detail) }
                    if !saved.isEmpty {
                        Divider()
                        ForEach(saved) { tone in option(.tone(tone.id), tone.title, detail: tone.detail) }
                    }
                }
            } label: {
                HStack(spacing: VCTokens.spacing1) {
                    Text(value).font(.system(size: 12)).foregroundStyle(DesignValues.color(never ? "text.tertiary" : "text.primary"))
                        .lineLimit(3).multilineTextAlignment(.leading)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(DesignValues.color("text.tertiary"))
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
            .disabled(never || catalog == nil)
            .help(never ? "Rewording is “Never reword”, so Claude keeps your words as said. Change Rewording to use a tone."
                        : "The tone Claude writes each clip's words in. Every Rewrite as strip puts it first.")
            .accessibilityLabel("Tone, \(value)" + (never ? ", unavailable while rewording is Never reword" : ""))
            .accessibilityIdentifier("voxclip.clipStyle.tone")
        }
    }

    /// The row's value: "✦ Auto · Claude picks per clip", "As I said it", "✦ Viral YouTuber", a saved tone's title, or
    /// Auto for a tone this Mac does not know.
    static func label(_ tone: ClipTone, catalog: RewriteToneCatalog?, saved: [RewriteTone]) -> String {
        switch tone {
        case .auto: return "✦ " + (catalog.map { "\($0.auto.label) · \($0.auto.detail)" } ?? "Auto")
        case .asSaid: return catalog?.asSaid.label ?? "As I said it"
        case .tone(let id):
            guard let found = catalog?.tone(id, saved: saved) else { return "✦ " + (catalog.map { "\($0.auto.label) · \($0.auto.detail)" } ?? "Auto") }
            return found.isSaved ? found.title : found.chipTitle
        }
    }

    private func option(_ tone: ClipTone, _ title: String, detail: String) -> some View {
        Button { editor.updateClipStyle { $0.tone = tone } } label: {
            if style.tone == tone { Label("\(title)  \(detail)", systemImage: "checkmark") } else { Text("\(title)  \(detail)") }
        }
    }
}
