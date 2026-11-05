import Foundation

/// The hook's title card (design.md §6.7): Make it postable shows the planner's hook (ai.md §16) as an Ask Claude title
/// (`ClipEffect` kind `title`, Roboto Black, at the top) over the first ~2 s of the clip as it renders.
public enum ClipHookTitle {
    /// How long the card shows, in rendered seconds.
    public static let seconds = 2.0
    /// The card sits at the top: clear of the captions in every shape.
    public static let position = ClipEffect.Position.top
    static let idPrefix = "fx-hook-"

    /// Whether `effect` is a hook card (a title Make it postable added).
    public static func isHook(_ effect: ClipEffect) -> Bool { effect.kind == .title && effect.id.hasPrefix(idPrefix) }

    /// The clip's hook card, if it has one.
    public static func existing(clipID: String, in project: Project) -> ClipEffect? {
        project.clipEffects.first { isHook($0) && $0.clipId == clipID }
    }

    /// The hook as a title's text: one line, trimmed, at most `ClipEffect.maximumTitleScalars` scalars; nil when empty.
    public static func text(_ hook: String) -> String? {
        let line = String(String.UnicodeScalarView(hook.unicodeScalars.map { $0.properties.generalCategory == .control ? " " : $0 }))
        let words = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let limited = String(String.UnicodeScalarView(words.unicodeScalars.prefix(ClipEffect.maximumTitleScalars)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return limited.isEmpty ? nil : limited
    }

    /// The card for `hook` on `clipID` as `project` plays it, replacing the clip's existing card (same id). It runs from the
    /// clip's first kept frame to the source time its render reaches `seconds` later (cuts skipped, at the clip's speed),
    /// and starts one overlay fade early, so the first frame (the thumbnail) shows it whole. Nil when the hook is empty or
    /// the clip is unknown.
    public static func effect(hook: String, clipID: String, in project: Project) -> ClipEffect? {
        guard let text = text(hook), let span = ClipControlsProject.sourceSpan(of: clipID, in: project) else { return nil }
        let speed = ClipControlsProject.controls(for: clipID, in: project)?.speed ?? 1
        let edited = ClipSpeedTiming(speed: speed).edited(seconds)
        var first = span.lowerBound, last = min(span.upperBound, span.lowerBound + edited)
        if let timeline = try? RenderCallerInputs.timeline(project: project, clipID: clipID), timeline.duration > 0 {
            first = timeline.sourceTime(0)
            // EditPlan's endpoint convention puts the end of the render at the end of the recording; the clip ends first.
            last = edited < timeline.duration ? timeline.sourceTime(edited) : span.upperBound
        }
        let start = max(0, first - ClipEffect.overlayFadeSeconds)
        guard last > start else { return nil }
        let id = existing(clipID: clipID, in: project)?.id ?? nextID(in: project)
        return ClipEffect(id: id, clipId: clipID, kind: .title, start: start, end: min(last, start + ClipEffect.maximumSeconds),
                          text: text, position: position)
    }

    static func nextID(in project: Project) -> String {
        let used = Set(project.clipEffects.map(\.id))
        var index = 1
        while used.contains("\(idPrefix)\(index)") { index += 1 }
        return "\(idPrefix)\(index)"
    }
}
