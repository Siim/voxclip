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
    public enum Decision: String, Sendable, CaseIterable {
        case clip, title, correction, cut, pauseCut, rewrite, captions, look, speed, zoom, music, hook, postText
        /// Ask Claude's toolbox (ai.md §18): a bleep or mute, a blur or pixelate, an overlay (title, lower third, sticker,
        /// arrow, circle, progress bar), a freeze frame, a sound effect, a stretch played faster or slower, translated
        /// captions and ducking the music. Additive: the planner's decisions above keep their meaning.
        case bleep, blur, overlay, freeze, sound, stretch, translate, duck
    }

    public enum Action: Sendable, Equatable {
        /// An `EditCommand` the editor's reducer applies as it is: corrections (`correct`), cuts and pause cuts
        /// (`cutSelection` of ids none of which is cut yet, so it always cuts), the clip range (`addClip` or `updateClip`)
        /// and its title (`renameClip`).
        case edit(EditCommand)
        /// A Rewrite proposal for the selection: the creator's voice re-records `text` over `scope` (`RewriteScope.selection`).
        /// It needs a voice, a quote and a paid click, so `apply` leaves it pending.
        case rewrite(scope: RewriteScope, text: String)
        /// The project's caption settings. `pendingFont` names the plan's font when it is not bundled yet (Roboto Black): the
        /// style's own font renders until it is.
        case captions(CaptionSettings, pendingFont: ClipAutopilotPlan.Font?)
        /// The clip's colour look (clip controls, design.md §6.9).
        case look(clipID: String, look: ClipAutopilotPlan.Look)
        /// The whole clip played at `speed.rate`, pitch kept (clip controls, design.md §6.9).
        case speed(clipID: String, speed: ClipAutopilotPlan.Speed)
        /// A framing cue for the clip.
        case motion(MotionCue)
        /// The music package's input; `apply` leaves it pending.
        case music(ClipAutopilotMusicCue)
        /// The first-2-seconds on-screen text: `apply` adds it as the clip's title card (`ClipHookTitle`, design.md §6.7).
        case hook(clipID: String, text: String)
        /// The clip's share text (`project.share.captions[clipID]`).
        case shareText(clipID: String, text: String)
        /// An effect added to `project.clipEffects` (ai.md §18.2): censoring, an overlay, a freeze frame or a sound.
        case effect(ClipEffect)
        case footage(ClipFootage)
        case asset(ClipPlanAsset)
        /// One stretch (source seconds) played at `rate`, pitch kept. A clip has one speed (design.md §6.9), so `apply`
        /// sets it when the stretch covers a whole clip and leaves a part of a clip pending.
        case stretch(clipID: String?, start: Double, end: Double, rate: Double)
        /// Captions of words `startWord...endWord` shown in `language` as `text`. Nothing renders a caption language
        /// override yet, so `apply` leaves it pending.
        case translateCaptions(clipID: String?, startWord: Int, endWord: Int, language: String, text: String)
        /// The clip's (nil: the full video's) background track ducks under the voice.
        case musicDucking(clipID: String?, on: Bool)
    }

    public let id: String
    public let decision: Decision
    public let action: Action
    public let reason: String

    public init(id: String, decision: Decision, action: Action, reason: String) {
        self.id = id; self.decision = decision; self.action = action; self.reason = reason
    }
}

public enum ClipAutopilotMapping {
    /// The operations for one plan, in review order: the clip, its title, corrections, cuts, pause cuts, rewrites, captions,
    /// look, speed, zooms, music, hook and post text. `clipID` names the clip: an existing clip is updated, a new id (a series clip) is added as an AI
    /// clip. `fonts` is the bundled font table (`ClipAutopilotFonts`).
    public static func operations(for plan: ClipAutopilotPlan, clipID: String, project: Project,
                                  fonts: [ClipAutopilotPlan.Font: String], stickers: Set<String> = []) throws -> [ClipAutopilotOperation] {
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
        for (index, correction) in plan.corrections.enumerated() where words[correction.word].kind == .word {
            add("correction-\(index)", .correction, .edit(.correct(id: words[correction.word].id, text: correction.text)), correction.reason)
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
        add("captions", .captions, .captions(settings, pendingFont: file == nil ? plan.captions.font : nil), plan.captions.reason)
        add("look", .look, .look(clipID: clipID, look: plan.look), plan.look.reason)
        if let speed = plan.speed { add("speed", .speed, .speed(clipID: clipID, speed: speed), speed.reason) }
        var zoomRanges: [Range<Double>] = []
        var corrections = state.corrections
        for correction in plan.corrections { corrections[words[correction.word].id] = correction.text }
        for (index, zoom) in plan.zooms.enumerated() {
            guard let range = zoom.sourceRange(in: words, within: plan.startWord...plan.endWord),
                  !zoomRanges.contains(where: { $0.overlaps(range) }),
                  zoom.scale.isFinite, (1...MotionCue.maximumScale).contains(zoom.scale) else { continue }
            let frames: [MotionKeyframe]
            let cueID: String
            var reason = zoom.reason
            if let direction = zoom.direction {
                guard zoom.hasDirectionalSettings,
                      !(zoom.word...zoom.untilWord).contains(where: { state.cutWordIds.contains(words[$0].id) }),
                      !plan.cuts.contains(where: { $0.startWord <= zoom.untilWord && zoom.word <= $0.endWord }),
                      !zoomRanges.contains(where: { abs($0.lowerBound - range.lowerBound) < ClipAutopilotPlan.Zoom.minimumStartSpacing - 1e-9 }) else { continue }
                let phrase = words[zoom.word...zoom.untilWord].filter { $0.kind == .word }
                    .map { corrections[$0.id] ?? $0.text }.joined(separator: " ")
                let excerpt = phrase.count > 96 ? String(phrase.prefix(95)) + "…" : phrase
                reason = "“\(excerpt)” · \(reason)"
                cueID = "\(clipID)-zoom-\(zoom.word)-\(zoom.untilWord)"
                switch direction {
                case .zoomIn: frames = [.init(progress: 0), .init(progress: 0.28, scale: zoom.scale),
                                        .init(progress: 0.7, scale: zoom.scale), .init(progress: 1)]
                case .zoomOut: frames = [.init(progress: 0, scale: zoom.scale), .init(progress: 0.18, scale: zoom.scale),
                                         .init(progress: 1)]
                }
            } else {
                cueID = "\(clipID)-zoom-\(index)"
                frames = [.init(progress: 0, scale: zoom.scale), .init(progress: 1, scale: zoom.scale)]
            }
            let cue = MotionCue(id: cueID, clipID: clipID, sourceStart: range.lowerBound, sourceEnd: range.upperBound, keyframes: frames)
            add("zoom-\(index)", .zoom, .motion(cue), reason)
            zoomRanges.append(range)
        }
        let cutIDs = state.cutWordIds.union(plan.cuts.flatMap { cut in
            (cut.startWord...cut.endWord).compactMap { words.indices.contains($0) ? words[$0].id : nil }
        })
        let tightened = Set(plan.pauseCuts.map(\.afterWord)).union(state.pauses.filter { state.cutPauseIds.contains($0.id) }.map(\.afterIndex))
        var overlayRanges: [Range<Double>] = []
        var footageRanges: [Range<Double>] = []
        var openingTitle = false
        for (index, entry) in (plan.effects ?? []).prefix(ClipPlanEffect.maximumEntries).enumerated() {
            let id = "\(clipID.prefix(48))-plan-fx-\(index)"
            guard let operation = entry.operation(id: id, clipID: clipID, scope: plan.startWord...plan.endWord, words: words,
                                                  cut: cutIDs, tightenedAfter: tightened, stickers: stickers,
                                                  sources: project.media.footageDurations) else { continue }
            switch operation.action {
            case .motion(let cue):
                let range = cue.sourceStart..<cue.sourceEnd
                guard !zoomRanges.contains(where: { $0.overlaps(range) }) else { continue }
                zoomRanges.append(range)
            case .effect(let overlay) where overlay.kind.usesText:
                let range = overlay.start..<overlay.end
                guard !overlayRanges.contains(where: { $0.overlaps(range) }) else { continue }
                overlayRanges.append(range)
                let opening = (plan.startWord...plan.endWord).first(where: { !cutIDs.contains(words[$0].id) }) ?? plan.startWord
                openingTitle = openingTitle || (overlay.kind == .title && overlay.start < words[opening].start + 2)
            case .footage(let entry):
                let range = entry.start..<entry.end
                guard !footageRanges.contains(where: { $0.overlaps(range) }) else { continue }
                footageRanges.append(range)
            default: break
            }
            operations.append(operation)
        }
        if let picked = plan.pickedMusic {
            add("music", .music, .music(ClipAutopilotMusicCue(clipID: clipID, picked: picked,
                alternatives: plan.music.filter { $0 != picked }, seconds: editedSeconds(plan, state: state))), picked.reason)
        }
        if !plan.hook.isEmpty && !openingTitle { add("hook", .hook, .hook(clipID: clipID, text: plan.hook)) }
        if !plan.postText.isEmpty { add("post", .postText, .shareText(clipID: clipID, text: plan.postText)) }
        return operations
    }

    /// The clip's length once the plan's cuts and pause cuts apply, at its own speed: the span, less each cut item and each
    /// tightened pause beyond the project's kept length. Rewrites are counted at the original words' length. The music cue
    /// uses this 1× length, so a track covers the clip at any speed of 1× or faster.
    public static func editedSeconds(_ plan: ClipAutopilotPlan, state: EditState) -> Double {
        let words = state.transcript.words
        guard plan.startWord >= 0, plan.endWord < words.count, plan.startWord <= plan.endWord else { return 0 }
        let cut = Set(plan.cuts.flatMap { ($0.startWord...$0.endWord).map { words[$0].id } }).union(state.cutWordIds)
        return editedSeconds(span: plan.startWord...plan.endWord, words: words, cut: cut, pauses: state.pauses,
                             tightened: Set(plan.pauseCuts.map(\.afterWord)), cutPauseIDs: Set(state.cutPauseIds), keepSeconds: state.pauseKeepSeconds)
    }

    /// The finished clip's length: `editedSeconds` at the plan's speed. The validator stores it as `plan.seconds`.
    public static func finalSeconds(_ plan: ClipAutopilotPlan, state: EditState) -> Double {
        editedSeconds(plan, state: state) / (plan.speed?.rate ?? 1)
    }

    /// `span`'s length less each item in `cut` and each pause after a word in `tightened`, or already in `cutPauseIDs`,
    /// beyond `keepSeconds`.
    static func editedSeconds(span: ClosedRange<Int>, words: [TimedWord], cut: Set<String>, pauses: [Pause], tightened: Set<Int>,
                              cutPauseIDs: Set<String>, keepSeconds: Double) -> Double {
        var seconds = words[span.upperBound].end - words[span.lowerBound].start
        for index in span where cut.contains(words[index].id) { seconds -= words[index].end - words[index].start }
        for pause in pauses where (span.lowerBound..<span.upperBound).contains(pause.afterIndex)
            && (tightened.contains(pause.afterIndex) || cutPauseIDs.contains(pause.id)) {
            seconds -= max(0, pause.end - pause.start - keepSeconds)
        }
        return max(0, seconds)
    }

    /// Applies what the editor can apply today, in order, to a copy of `project`: edits (corrections included), captions,
    /// motion cues, share text, effects, music ducking, the clip's look and speed (clip controls, design.md §6.9), and a
    /// stretch that covers a whole clip (`ClipControlsProject.wholeClip`) as that clip's speed, and the hook as the clip's
    /// title card (`ClipHookTitle`, timed on the clip as the operations before it left it). Rewrites, music, a stretch over
    /// part of a clip come back as `pending`; translated captions are stored as `captionTranslations`. Pure: one undo step is the caller's choice.
    public static func apply(_ operations: [ClipAutopilotOperation], to project: Project) throws -> (project: Project, pending: [ClipAutopilotOperation]) {
        var result = project
        var pending: [ClipAutopilotOperation] = []
        var effects: [ClipEffect] = []
        for operation in operations {
            switch operation.action {
            case .edit(let command): try result.applyEditing(command)
            case .captions(let settings, _): result.captions = settings
            case .motion(let cue):
                guard let next = addingMotionCue(cue, to: result) else { pending.append(operation); continue }
                result = next
            case .shareText(let clipID, let text): result.share.captions[clipID] = text
            case .effect(let effect): effects.append(effect)
            case .footage(let entry):
                if !result.media.setFootage(entry) { pending.append(operation) }
            case .musicDucking(let clipID, let on):
                guard var entry = MusicProject.entry(for: clipID, in: result) else { pending.append(operation); continue }
                entry.ducking = on
                result = try MusicProject.setting(entry, clipId: clipID, in: result)
            case .look(let clipID, let look): result = try ClipControlsProject.settingLook(look.id, clipId: clipID, in: result)
            case .speed(let clipID, let speed): result = try ClipControlsProject.settingSpeed(speed.rate, clipId: clipID, in: result)
            case .stretch(let clipID, let start, let end, let rate):
                guard let whole = ClipControlsProject.wholeClip(clipID, start: start, end: end, in: result) else { pending.append(operation); continue }
                result = try ClipControlsProject.settingSpeed(rate, clipId: whole, in: result)
            case .hook(let clipID, let text):
                guard let card = ClipHookTitle.effect(hook: text, clipID: clipID, in: result) else { pending.append(operation); continue }
                effects.append(card)
            case .translateCaptions(let clipID, let start, let end, let language, let text):
                // The captions of those words in another language (ai.md §18.2); the voice and transcript stay.
                result = try CaptionTranslations.translating(start...end, clipID: clipID, language: language, text: text, in: result)
            case .rewrite, .music, .asset: pending.append(operation)
            }
        }
        result = try ClipEffects.adding(effects, to: result)
        return (result, pending)
    }

    public static func addingMotionCue(_ cue: MotionCue, to project: Project) -> Project? {
        guard cue.isValid, let transcript = project.transcript,
              let clip = project.edits.clips.first(where: { $0.id == cue.clipID }),
              let bounds = clipIndices(clip, words: transcript.words),
              let times = try? clipTimes(transcript.words, clip: clip, startIndex: bounds.lowerBound, endIndex: bounds.upperBound),
              cue.sourceStart >= times.start, cue.sourceEnd <= times.end,
              !project.motionCues.contains(where: { existing in
                  existing.id == cue.id || (existing.clipID == cue.clipID && existing.sourceStart < cue.sourceEnd && cue.sourceStart < existing.sourceEnd)
              }), let state = try? EditState(transcript: transcript, edits: project.edits),
              let segments = try? buildSegments(state, activeClip: clip) else { return nil }
        let rate = Double(project.media.source.audio?.sampleRate ?? 48_000)
        guard let edits = try? buildEditPlan(segments, duration: project.media.source.durationSeconds, sampleRate: rate,
                                             pauseKeepSeconds: state.pauseKeepSeconds),
              edits.kept.contains(where: { interval in
                  Double(interval.startSample) - 0.5 <= cue.sourceStart * rate && cue.sourceEnd * rate <= Double(interval.endSample) + 0.5
              }) else { return nil }
        return try? ContextDemoProject.settingMotionCues(project.motionCues + [cue], in: project)
    }
}
