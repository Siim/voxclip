import Foundation
import VoxClipCore

// Rewrite tones everywhere words can be rewritten (design.md §6.3.1 "Rewrite as"): one list, in one order, with the
// creator's default first, shared by the scope bar's strip, the selection bar's strip, ✦ Ask Claude's "Reword these words",
// a clip row's Rewrite as menu, the clip style card's Tone row and the Make it postable review's Change.

/// shared/data/rewrite-tones.json, read once per shared root.
@MainActor enum RewriteToneCatalogCache {
    private static var cached: (root: URL, catalog: RewriteToneCatalog)?
    static func catalog(_ shared: SharedResources?) -> RewriteToneCatalog? {
        guard let shared else { return nil }
        if let cached, cached.root == shared.root { return cached.catalog }
        guard let catalog = try? RewriteToneCatalog.load(shared: shared) else { return nil }
        cached = (shared.root, catalog)
        return catalog
    }
}

/// One chip of the "Rewrite as" strip: Fix mistakes, Shorter, a catalogue tone or a saved tone.
struct RewriteStripItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case fix, tone, saved }
    let id: String
    /// "✦ Viral YouTuber", "Fix mistakes", "My pitch voice".
    let title: String
    /// The exact text Rewrite sends.
    let instruction: String
    /// The menu's trailing line: "hook, punchy, payoff", "saved".
    let detail: String
    let kind: Kind
    /// The creator's default (the clip style's Tone): first in every strip, marked "· your default".
    var isDefault = false

    static let fixMistakesID = "fix-mistakes"
    static let shorterID = "make-shorter"
}

extension AppModel {
    var rewriteToneCatalog: RewriteToneCatalog? { RewriteToneCatalogCache.catalog(shared) }

    /// The user's saved tones (settings `rewrite.myTones`), in the order saved.
    var myRewriteTones: [RewriteTone] { MyRewriteTones.decode(settings.values[RewriteToneCatalog.settingsKey]) }

    /// Every tone a field's text can name: the catalogue's, then the saved ones.
    var allRewriteTones: [RewriteTone] { (rewriteToneCatalog?.tones ?? []) + myRewriteTones }

    /// "+ Save as my tone": keeps `instruction` under `title` in Settings. Nil when the title or text is empty or too long,
    /// or 20 tones are saved already.
    @discardableResult func saveRewriteTone(title: String, instruction: String) -> RewriteTone? {
        let limit = rewriteToneCatalog?.maxMyTones ?? 20
        guard let saved = try? MyRewriteTones.saving(title, instruction: instruction, to: myRewriteTones, limit: limit),
              set(RewriteToneCatalog.settingsKey, MyRewriteTones.encode(saved.tones)) else { return nil }
        return saved.tone
    }

    /// Settings › Clips: renames a saved tone; its id stays, so clip styles that chose it keep it.
    @discardableResult func renameRewriteTone(_ id: String, to title: String) -> Bool {
        guard let next = try? MyRewriteTones.renaming(id, to: title, in: myRewriteTones) else { return false }
        return set(RewriteToneCatalog.settingsKey, MyRewriteTones.encode(next))
    }

    /// Settings › Clips: deletes a saved tone. A clip style that chose it plans as Auto from then on.
    func deleteRewriteTone(_ id: String) {
        set(RewriteToneCatalog.settingsKey, MyRewriteTones.encode(MyRewriteTones.deleting(id, from: myRewriteTones)))
    }
}

extension EditorModel {
    /// The clip style's Tone: the project's, else the Settings default's, else Auto.
    var styleTone: ClipTone { project.clipStyle?.tone ?? savedClipStyle?.tone ?? .auto }

    /// The strip in its one order: the default first, then Fix mistakes, Shorter, the catalogue tones and the saved tones.
    /// The default is the clip style's Tone when it names a tone; Auto, As I said it or a tone no longer known make Fix
    /// mistakes the default.
    var rewriteStripItems: [RewriteStripItem] {
        let presets = RewriteSuggestions.presets
        var items = [
            RewriteStripItem(id: RewriteStripItem.fixMistakesID, title: "Fix mistakes", instruction: RewriteSuggestions.fixMistakes.instruction,
                             detail: "slips and repeats", kind: .fix),
            RewriteStripItem(id: RewriteStripItem.shorterID, title: "Shorter", instruction: presets.first { $0.title == "Make it shorter" }?.instruction ?? "",
                             detail: "mostly by cutting", kind: .fix),
        ]
        items += (app.rewriteToneCatalog?.tones ?? []).map { RewriteStripItem(id: $0.id, title: $0.chipTitle, instruction: $0.instruction, detail: $0.detail, kind: .tone) }
        items += app.myRewriteTones.map { RewriteStripItem(id: $0.id, title: $0.title, instruction: $0.instruction, detail: "saved", kind: .saved) }
        let wanted: String = if case .tone(let id) = styleTone, items.contains(where: { $0.id == id }) { id } else { RewriteStripItem.fixMistakesID }
        guard let index = items.firstIndex(where: { $0.id == wanted }) else { return items }
        var first = items.remove(at: index)
        first.isDefault = true
        return [first] + items
    }

    /// The default tone: what ⇧⌘R and an empty field ask.
    var defaultRewriteItem: RewriteStripItem? { rewriteStripItems.first }

    /// The chip the field's text names (it shows that chip's instruction), if any.
    func rewriteStripMatch(_ text: String) -> RewriteStripItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return rewriteStripItems.first { $0.instruction == trimmed }
    }

    /// A chip: rewrites `scope` (the scope now when nil) in that tone at once. The field then shows the tone's whole
    /// instruction, so the creator can tweak it and press Rewrite again. The AI step is free on a plan; voicing stays a
    /// priced click.
    func rewriteAs(_ item: RewriteStripItem, scope: RewriteScope? = nil) {
        rewriteInstruction = item.instruction
        runRewrite(scope: scope, instruction: item.instruction, verb: "Rewrite")
        announce("Rewriting as \(item.title.replacingOccurrences(of: "✦ ", with: ""))")
    }

    /// "Type your own…" in a strip: rewrites `scope` with the creator's own words.
    func rewriteAs(text: String, scope: RewriteScope? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        rewriteInstruction = ClipBarView.limited(trimmed)
        runRewrite(scope: scope, instruction: rewriteInstruction, verb: "Rewrite")
    }

    /// The scope bar's strip shows while the clip bar offers Rewrite: a transcript, an editable project with AI, words to
    /// rewrite, and media that is not waiting to be found.
    var showsScopeToneStrip: Bool {
        transcribed && capabilities.edit && capabilities.ai && mediaReadOnlyNote == nil && rewriteToneCatalogLoaded
            && RewriteEntryPolicy.canRun(editable: capabilities.ai, scope: rewriteScopeNow)
    }
    var rewriteToneCatalogLoaded: Bool { app.rewriteToneCatalog != nil }

    /// ⇧⌘R (Edit › Rewrite, the transcript's key and its accessibility action): on a word selection without an open
    /// Rewrite there, the default tone at once (design.md §6.3.1); otherwise Rewrite with the field's text, as before.
    func rewriteShortcut() {
        if let scope = selectionRewriteScope, rewrite.map({ $0.isOpen && $0.rewriteScope == scope }) != true,
           rewriteInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || rewriteStripMatch(rewriteInstruction) != nil,
           let item = defaultRewriteItem {
            rewriteAs(item, scope: scope)
        } else {
            runRewrite()
        }
    }

    /// The selected words as Rewrite's scope, for the selection bar's strip.
    var selectionRewriteScope: RewriteScope? {
        if case .selection(let range)? = rewriteScopeNow { return .selection(range) }
        return nil
    }

    /// "+ Save as my tone" on the scope bar: keeps the field's text under `title`; the new tone shows as a chip and in
    /// the card's Tone menu.
    @discardableResult func saveFieldAsTone(_ title: String) -> RewriteTone? {
        guard let tone = app.saveRewriteTone(title: title, instruction: rewriteInstruction) else { return nil }
        announce("Saved “\(tone.title)” as your tone.")
        return tone
    }

    /// The field's text can be saved as a tone: it is not empty and not a chip already.
    var canSaveFieldAsTone: Bool {
        let trimmed = rewriteInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && rewriteStripMatch(trimmed) == nil && app.myRewriteTones.count < (app.rewriteToneCatalog?.maxMyTones ?? 20)
    }
}
