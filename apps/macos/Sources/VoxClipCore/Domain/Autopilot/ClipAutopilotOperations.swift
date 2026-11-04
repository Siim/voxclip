import Foundation

/// The background track a plan picked, for the music package to generate and mix (ai.md §16.6). Nothing here plays,
/// generates or bills.
public struct ClipAutopilotMusicCue: Sendable, Equatable {
    public let clipID: String
    public let picked: ClipAutopilotPlan.Music
    public let alternatives: [ClipAutopilotPlan.Music]
    /// The clip's length after the plan's cuts and pause cuts, which the generated track must cover.
    public let seconds: Double
}

/// One reviewable decision as an editor operation (ai.md §16.6). The review lists one row per operation with Undo or
/// Change; `id` is stable for a plan, so a row survives a re-render.
public struct ClipAutopilotOperation: Sendable, Equatable, Identifiable {
    public enum Decision: String, Sendable, CaseIterable { case clip, title, cut, pauseCut, rewrite, captions, zoom, music, hook, postText }

    public enum Action: Sendable, Equatable {
        /// An `EditCommand` the editor's reducer applies as it is: cuts and pause cuts (`cutSelection` of ids none of which
        /// is cut yet, so it always cuts), the clip range (`addClip` or `updateClip`) and its title (`renameClip`).
        case edit(EditCommand)
        /// A Rewrite proposal for the selection: the creator's voice re-records `text` over `scope` (`RewriteScope.selection`).
        /// It needs a voice, a quote and a paid click, so `apply` leaves it pending.
        case rewrite(scope: RewriteScope, text: String)
        /// The project's caption settings. `pendingFont` names the plan's font when it is not bundled yet (Roboto Black): the
        /// style's own font renders until it is.
        case captions(CaptionSettings, pendingFont: ClipAutopilotPlan.Font?)
        /// A punch-in cue for the clip.
        case motion(MotionCue)
        /// The music package's input; `apply` leaves it pending.
        case music(ClipAutopilotMusicCue)
        /// The first-2-seconds on-screen text. The editor has no title card yet, so `apply` leaves it pending.
        case hook(clipID: String, text: String)
        /// The clip's share text (`project.share.captions[clipID]`).
        case shareText(clipID: String, text: String)
    }

    public let id: String
    public let decision: Decision
    public let action: Action
    public let reason: String
}

public enum ClipAutopilotMapping {
    /// The operations for one plan, in review order: the clip, its title, cuts, pause cuts, rewrites, captions, zooms, music,
    /// hook and post text. `clipID` names the clip: an existing clip is updated, a new id (a series clip) is added as an AI
    /// clip. `fonts` is the bundled font table (`ClipAutopilotFonts`).
    public static func operations(for plan: ClipAutopilotPlan, clipID: String, project: Project,
                                  fonts: [ClipAutopilotPlan.Font: String]) throws -> [ClipAutopilotOperation] {
        guard let transcript = project.transcript else { throw VoiceLabError.invalidInput }
        let words = transcript.words
        guard plan.startWord >= 0, plan.endWord < words.count, plan.startWord <= plan.endWord,
              clipID.range(of: "\\A(?:" + EditingLimits.clipIDPattern + ")\\z", options: .regularExpression) != nil else {
            throw VoiceLabError.invalidInput
        }
        let state = try EditState(transcript: transcript, edits: project.edits)
        var operations: [ClipAutopilotOperation] = []
        func add(_ id: String, _ decision: ClipAutopilotOperation.Decision, _ action: ClipAutopilotOperation.Action, _ reason: String = "") {
            operations.append(.init(id: id, decision: decision, action: action, reason: reason))
        }
        let title = plan.title.isEmpty ? nil : plan.title
        if let existing = project.edits.clips.first(where: { $0.id == clipID }) {
            let current = (words.firstIndex { $0.id == existing.startWordId }, words.firstIndex { $0.id == existing.endWordId })
            if current.0 != plan.startWord || current.1 != plan.endWord {
                add("clip", .clip, .edit(.updateClip(id: clipID, startIndex: plan.startWord, endIndex: plan.endWord)))
            }
            if let title, title != existing.title { add("title", .title, .edit(.renameClip(id: clipID, title: title))) }
        } else {
            add("clip", .clip, .edit(.addClip(ClipRange(id: clipID, startWordId: words[plan.startWord].id, endWordId: words[plan.endWord].id,
                                                        title: title, origin: .ai, selected: true))))
        }
        for (index, cut) in plan.cuts.enumerated() {
            let ids = (cut.startWord...cut.endWord).map { words[$0].id }.filter { !state.cutWordIds.contains($0) }
            if !ids.isEmpty { add("cut-\(index)", .cut, .edit(.cutSelection(ids: ids)), cut.reason) }
        }
        for (index, pause) in plan.pauseCuts.enumerated() {
            guard let found = state.pauses.first(where: { $0.afterIndex == pause.afterWord }), !state.cutPauseIds.contains(found.id) else { continue }
            add("pause-\(index)", .pauseCut, .edit(.cutSelection(ids: [found.id])), pause.reason)
        }
        for (index, rewrite) in plan.rewrites.enumerated() {
            add("rewrite-\(index)", .rewrite, .rewrite(scope: .selection(rewrite.startWord...rewrite.endWord), text: rewrite.text), rewrite.reason)
        }
        var settings = project.captions
        settings.styleId = plan.captions.styleId
        var overrides = settings.overrides
        func merge(_ key: String, _ values: [String: JSONValue]) {
            var object = overrides[key]?.aiObject ?? [:]
            for (name, value) in values { object[name] = value }
            overrides[key] = .object(object)
        }
        merge("text", ["transform": .string(plan.captions.textCase.transform)])
        merge("layout", plan.captions.wordsPerCaption == 1 ? ["maxWords": .number(1), "maxLines": .number(1)]
                                                           : ["maxWords": .number(Double(plan.captions.wordsPerCaption))])
        let file = fonts[plan.captions.font]
        if let file {
            merge("font", ["file": .string(file), "family": .string(plan.captions.font.family), "weight": .number(Double(plan.captions.font.weight))])
        }
        settings.overrides = overrides
        add("captions", .captions, .captions(settings, pendingFont: file == nil ? plan.captions.font : nil))
        for (index, zoom) in plan.zooms.enumerated() {
            let frame = MotionKeyframe(progress: 0, scale: zoom.scale)
            let cue = MotionCue(id: "\(clipID)-zoom-\(index)", clipID: clipID, sourceStart: words[zoom.word].start, sourceEnd: words[zoom.untilWord].end,
                                keyframes: [frame, MotionKeyframe(progress: 1, scale: zoom.scale)])
            add("zoom-\(index)", .zoom, .motion(cue), zoom.reason)
        }
        if let picked = plan.pickedMusic {
            add("music", .music, .music(ClipAutopilotMusicCue(clipID: clipID, picked: picked,
                alternatives: plan.music.filter { $0 != picked }, seconds: editedSeconds(plan, state: state))), picked.reason)
        }
        if !plan.hook.isEmpty { add("hook", .hook, .hook(clipID: clipID, text: plan.hook)) }
        if !plan.postText.isEmpty { add("post", .postText, .shareText(clipID: clipID, text: plan.postText)) }
        return operations
    }

    /// The clip's length once the plan's cuts and pause cuts apply: the span, less each cut item and each tightened pause
    /// beyond the project's kept length. Rewrites are counted at the original words' length.
    public static func editedSeconds(_ plan: ClipAutopilotPlan, state: EditState) -> Double {
        let words = state.transcript.words
        guard plan.startWord >= 0, plan.endWord < words.count, plan.startWord <= plan.endWord else { return 0 }
        var seconds = words[plan.endWord].end - words[plan.startWord].start
        let cut = Set(plan.cuts.flatMap { ($0.startWord...$0.endWord).map { words[$0].id } }).union(state.cutWordIds)
        for index in plan.startWord...plan.endWord where cut.contains(words[index].id) { seconds -= words[index].end - words[index].start }
        let tightened = Set(plan.pauseCuts.map(\.afterWord))
        for pause in state.pauses where (plan.startWord..<plan.endWord).contains(pause.afterIndex)
            && (tightened.contains(pause.afterIndex) || state.cutPauseIds.contains(pause.id)) {
            seconds -= max(0, pause.end - pause.start - state.pauseKeepSeconds)
        }
        return max(0, seconds)
    }

    /// Applies what the editor can apply today, in order, to a copy of `project`: edits, captions, motion cues and share
    /// text. Rewrites, music and the hook come back as `pending`. Pure: one undo step is the caller's choice.
    public static func apply(_ operations: [ClipAutopilotOperation], to project: Project) throws -> (project: Project, pending: [ClipAutopilotOperation]) {
        var result = project
        var pending: [ClipAutopilotOperation] = []
        var cues: [MotionCue] = []
        for operation in operations {
            switch operation.action {
            case .edit(let command): try result.applyEditing(command)
            case .captions(let settings, _): result.captions = settings
            case .motion(let cue): cues.append(cue)
            case .shareText(let clipID, let text): result.share.captions[clipID] = text
            case .rewrite, .music, .hook: pending.append(operation)
            }
        }
        if !cues.isEmpty {
            // Motion cues need the v4 project; the Context demo path upgrades and checks them against the clips.
            let kept = result.motionCues.filter { cue in !cues.contains { $0.id == cue.id } }
            result = try ContextDemoProject.settingMotionCues(kept + cues, in: result)
        }
        return (result, pending)
    }
}
