import Foundation
import VoxClipCore

// The Make it postable review's tone row (design.md §6.7): "✦ Claude wrote it as Viral YouTuber · ▶ · Undo · Change", with
// "Hook first, two lines tightened · voiced 2 phrases, $0.18". Change shows the tones as chips in the row: a tone re-plans
// this clip in it as one undo step ("Change tone"), and As I said it takes the tone's rewording back.

extension EditorModel {
    static let makeItToneRowID = "tone"
    static let makeItAsSaidID = "as-said"

    /// The row for a plan written in a tone; nil when the creator's own tone was kept.
    func makeItToneRow(_ plan: ClipAutopilotPlan, run: MakeItRun, rows: [MakeItRow]) -> MakeItRow? {
        guard let tone = plan.tone else { return nil }
        let voiced = rows.filter { $0.id.hasPrefix("rewrite-") && run.inverses[$0.id] != nil }.count
        var parts = [tone.summary].filter { !$0.isEmpty }
        if voiced > 0 { parts.append("voiced \(voiced) \(voiced == 1 ? "phrase" : "phrases"), \(Self.makeItDollars(run.voiceSpent))") }
        return MakeItRow(id: Self.makeItToneRowID, kind: .choice, text: Self.makeItToneText(tone.title, chosenBy: "Claude"),
                         detail: parts.joined(separator: " · "), play: makeItClipStart(run.clipID), undoable: voiced > 0, change: .tone)
    }

    static func makeItToneText(_ title: String, chosenBy who: String) -> String { "✦ \(who) wrote it as \(title)" }

    /// The chips Change shows: the strip's tones (the catalogue, then the saved ones) and As I said it; Fix mistakes and
    /// Shorter are Rewrite's fixes, not tones a plan is written in.
    var makeItToneChoices: [(id: String, title: String)] {
        let tones = rewriteStripItems.filter { $0.kind != .fix }.map { ($0.id, $0.title) }
        return tones + [(Self.makeItAsSaidID, app.rewriteToneCatalog?.asSaid.label ?? "As I said it")]
    }

    /// A chip on the tone row. As I said it takes the tone's rewording back; a tone takes this clip's decisions back and
    /// plans it again in that tone, all as one undo step. Voicing the new lines keeps the run's price and cap rules.
    func makeItChooseTone(_ id: String, run: MakeItRun) {
        guard !run.running, run.rows.contains(where: { $0.id == Self.makeItToneRowID }) else { return }
        run.openChoice = nil
        if id == Self.makeItAsSaidID { makeItRemoveTone(run, chose: true); return }
        guard run.plan?.tone?.id != id else { return }
        beginUndoGroup("Change tone")
        takeBackMakeIt(run)
        makeIt.forget(run.clipID)
        makeIt.toneOverride = .tone(id)
        launchMakeIt(run.clipID, beginsGroup: false)
    }

    /// Takes the tone's rewording back: every voiced rewrite of the run is turned off (its paid take kept), as one step.
    /// The row's Undo, and As I said it, which then names the creator's choice.
    func makeItRemoveTone(_ run: MakeItRun, chose: Bool) {
        guard let index = run.rows.firstIndex(where: { $0.id == Self.makeItToneRowID }), !run.rows[index].undone, !run.running else { return }
        let ids = run.rows.filter { $0.id.hasPrefix("rewrite-") && !$0.undone && run.inverses[$0.id] != nil }.map(\.id)
        if !ids.isEmpty {
            beginUndoGroup(chose ? "As I said it" : "Undo tone")
            undoGroup?.ownsEdits = true
            for id in ids { makeItUndo(id, in: run) }
            endUndoGroup()
        }
        if chose {
            run.rows[index].text = "You chose \(app.rewriteToneCatalog?.asSaid.label ?? "As I said it")"
            run.rows[index].detail = ids.isEmpty ? "No words were reworded." : "Claude's rewording is taken back; your words play again."
            run.rows[index].undoable = false
            run.rows[index].change = nil
        } else {
            run.rows[index].undone = true
        }
        announce(ids.isEmpty ? "Your own words were kept." : "Claude's rewording taken back.")
    }

    /// ▶ on the tone row: half a second before the clip starts.
    func makeItClipStart(_ clipID: String) -> Double? {
        guard let clip = project.edits.clips.first(where: { $0.id == clipID }), let start = index(clip.startWordId) else { return nil }
        return max(0, words[start].start - 0.5)
    }
}
