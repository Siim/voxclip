import SwiftUI
import VoxClipCore

// The one "Rewrite as" strip (design.md §6.3.1), in every place words can be rewritten: the scope bar under the clip bar,
// the transcript selection bar, ✦ Ask Claude's "Reword these words", a clip row's Rewrite as menu and the Make it postable
// review. Same tones, same order, the creator's default first and marked. A chip rewrites at once.

/// One chip: 24 high, a capsule. The default carries the AI tint outline and "· your default"; the chip whose
/// instruction the field shows is selected (600, the selected-row fill).
@MainActor struct RewriteToneChip: View {
    let title: String
    var isDefault = false
    var selected = false
    var defaultSuffix = " · your default"
    var identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(isDefault ? title + defaultSuffix : title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(isDefault ? DesignValues.accentText : DesignValues.color("text.primary"))
                .lineLimit(1)
                .padding(.horizontal, VCTokens.spacingFieldPaddingX)
                .frame(minHeight: 24)
                .background(DesignValues.color(selected ? "bg.selectedRow" : "bg.muted"), in: .capsule)
                .overlay(Capsule().strokeBorder(isDefault ? DesignValues.accentText.opacity(0.7) : DesignValues.color(selected ? "line.strong" : "line.default")))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isDefault ? "\(title.replacingOccurrences(of: "✦ ", with: "")), your default" : title.replacingOccurrences(of: "✦ ", with: ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

/// The chips of the strip, wrapped, with anything a place adds after them ("Type your own…", "+ Save as my tone").
@MainActor struct RewriteToneChips<Trailing: View>: View {
    let items: [RewriteStripItem]
    var selectedID: String?
    var defaultSuffix = " · your default"
    let place: String
    let choose: (RewriteStripItem) -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ClipStyleFlowLayout(spacing: VCTokens.spacingChipGap) {
            ForEach(items) { item in
                RewriteToneChip(title: item.title, isDefault: item.isDefault, selected: item.id == selectedID, defaultSuffix: defaultSuffix,
                                identifier: "voxclip.\(place).tone.\(item.id)") { choose(item) }
                    .help(item.instruction)
            }
            trailing()
        }
    }
}

/// A dashed chip for a step that is not a tone: "Type your own…", "+ Save as my tone", "More…".
@MainActor struct RewriteToneGhostChip: View {
    let title: String
    let identifier: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).foregroundStyle(DesignValues.color("text.secondary"))
                .padding(.horizontal, VCTokens.spacingFieldPaddingX).frame(minHeight: 24)
                .overlay(Capsule().strokeBorder(DesignValues.color("line.default"), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

/// The transcript selection's strip, right under the selection bar: "Rewrite these words as", the hint, every chip (the
/// default first), then "Type your own…", which opens an inline field. A chip rewrites the selected words at once.
@MainActor struct SelectionRewriteStrip: View {
    let model: EditorModel
    let dismiss: () -> Void
    @State private var typing = false
    @State private var text = ""
    @FocusState private var fieldFocused: Bool
    static let width: CGFloat = 460
    static let hint = "runs at once · voice it after: one priced click"

    var body: some View {
        VStack(alignment: .leading, spacing: VCTokens.spacingRowGap) {
            HStack(alignment: .firstTextBaseline, spacing: VCTokens.spacingRowGap) {
                Text("Rewrite these words as").font(.system(size: 12, weight: .semibold)).foregroundStyle(DesignValues.color("text.secondary"))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: VCTokens.spacingRowGap)
                Text(Self.hint).font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary"))
            }
            RewriteToneChips(items: model.rewriteStripItems, place: "selectionStrip", choose: { item in
                let scope = model.selectionRewriteScope
                dismiss()
                model.rewriteAs(item, scope: scope)
            }) {
                if !typing {
                    RewriteToneGhostChip(title: "Type your own…", identifier: "voxclip.selectionStrip.typeOwn") { typing = true; fieldFocused = true }
                }
            }
            if typing {
                TextField("Say how to rewrite these words", text: $text)
                    .textFieldStyle(.plain).font(VCType.callout.font()).vcFieldChrome()
                    .focused($fieldFocused)
                    .onSubmit {
                        let scope = model.selectionRewriteScope
                        dismiss()
                        model.rewriteAs(text: text, scope: scope)
                    }
                    .accessibilityLabel("Your own instruction")
                    .accessibilityIdentifier("voxclip.selectionStrip.field")
            }
        }
        .padding(VCTokens.spacingCardPadding)
        .frame(width: Self.width, alignment: .leading)
        .background(DesignValues.color("bg.elevated"), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(DesignValues.color("line.strong"), lineWidth: 1) }
        .disabled(!model.capabilities.ai || !model.capabilities.edit)
        .onExitCommand(perform: dismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rewrite these words as")
        .accessibilityIdentifier("voxclip.selectionStrip")
    }
}

/// The scope bar's always-visible strip under the clip bar (Full take or the open clip): "Tone", the chips with the one
/// the field shows selected, and "+ Save as my tone", which names the field's text in a small inline field with Save.
/// Under `menuBelow` wide it collapses to "Tone: ✦ Viral YouTuber ⌄", a menu.
@MainActor struct ScopeToneStrip: View {
    @Bindable var model: EditorModel
    @State private var naming = false
    @State private var name = ""
    @State private var width: CGFloat = 600
    @FocusState private var nameFocused: Bool
    static let menuBelow: CGFloat = 440

    var body: some View {
        let items = model.rewriteStripItems
        let selected = model.rewriteStripMatch(model.rewriteInstruction)
        let running = model.rewrite?.task.state == .running
        Group {
            if width < Self.menuBelow {
                HStack(spacing: VCTokens.spacingLabelGap) {
                    RewriteAsMenu(model: model, label: "Tone: " + ((selected ?? items.first)?.title ?? "Fix mistakes"), place: "scopeStrip")
                    Spacer(minLength: 0)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: VCTokens.spacingRowGap) {
                    Text("Tone").font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary"))
                        .accessibilityHidden(true)
                    RewriteToneChips(items: items, selectedID: selected?.id, defaultSuffix: " · default", place: "scopeStrip",
                                     choose: { model.rewriteAs($0) }) {
                        if naming {
                            HStack(spacing: VCTokens.spacingLabelGap) {
                                TextField("Name this tone", text: $name)
                                    .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 140).vcFieldChrome()
                                    .focused($nameFocused)
                                    .onSubmit(save)
                                    .onExitCommand { naming = false }
                                    .accessibilityIdentifier("voxclip.scopeStrip.toneName")
                                Button("Save", action: save).controlSize(.small)
                                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                                    .accessibilityIdentifier("voxclip.scopeStrip.saveTone")
                            }
                        } else if model.canSaveFieldAsTone {
                            RewriteToneGhostChip(title: "+ Save as my tone", identifier: "voxclip.scopeStrip.saveAsTone") {
                                name = ""; naming = true; nameFocused = true
                            }
                        }
                    }
                }
            }
        }
        .disabled(running)
        .padding(.horizontal, VCTokens.spacingPanePaddingMacos).padding(.vertical, VCTokens.spacingRowGap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignValues.color("bg.surface"))
        .overlay(alignment: .bottom) { Rectangle().fill(DesignValues.color("line.default")).frame(height: 1) }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rewrite as")
        .accessibilityIdentifier("voxclip.scopeStrip")
    }

    private func save() {
        guard model.saveFieldAsTone(name) != nil else { return }
        naming = false; name = ""
    }
}

/// "Rewrite as ▾": the same strip as a menu, for a clip row (kept or suggested) and the narrow scope bar. The default is
/// first and marked; choosing one rewrites `scope` (the scope now when nil) at once.
@MainActor struct RewriteAsMenu: View {
    let model: EditorModel
    var scope: RewriteScope?
    var label = "Rewrite as"
    let place: String
    /// A clip row passes its own action (keep a suggestion first, open the clip); else the scope is rewritten here.
    var choose: ((RewriteStripItem) -> Void)?
    /// A 22 × 20 icon for the clip row, beside ✦ and ⋯.
    var compact = false

    var body: some View {
        Menu {
            RewriteAsMenuItems(model: model, place: place) { item in
                if let choose { choose(item) } else { model.rewriteAs(item, scope: scope) }
            }
        } label: {
            if compact {
                Image(systemName: "pencil.line").font(.system(size: 11)).frame(width: 22, height: 20).contentShape(Rectangle())
            } else {
                full
            }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(!model.capabilities.ai || !model.capabilities.edit)
        .help("Rewrite as: the words in a tone, at once. Your default is first.")
        .accessibilityLabel(label)
        .accessibilityIdentifier("voxclip.\(place).rewriteAs")
    }

    private var full: some View {
            HStack(spacing: VCTokens.spacing1) {
                Text(label).font(.system(size: 12)).foregroundStyle(DesignValues.accentText).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(DesignValues.accentText)
            }
            .padding(.horizontal, VCTokens.spacingRowGap).frame(minHeight: 22)
            .background(DesignValues.color("bg.muted"), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(DesignValues.color("line.default")))
            .contentShape(Rectangle())
    }
}

/// The strip's items as menu rows, the default first and marked: for "Rewrite as ▾" and a clip row's ⋯ › Rewrite As.
@MainActor struct RewriteAsMenuItems: View {
    let model: EditorModel
    let place: String
    let choose: (RewriteStripItem) -> Void
    var body: some View {
        ForEach(model.rewriteStripItems) { item in
            Button { choose(item) } label: {
                Text(item.isDefault ? item.title + " · your default" : item.title) + Text("  " + item.detail).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("voxclip.\(place).menu.\(item.id)")
        }
    }
}
