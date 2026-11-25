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
        case clip, title, correction, cut, pauseCut, rewrite, captions, look, speed, zoom, music, hook, postText, coverTitle
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
        case savedMusic(clipID: String, trackID: String)
        case coverTitle(clipID: String, text: String)
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
        try operations(for: plan.canonicalProposal(clipID: clipID, in: project), clipID: clipID, project: project,
                       fonts: fonts, stickers: stickers, plan: plan)
    }

    public static func operations(for proposal: ClipProposal, clipID: String, project: Project,
                                  fonts: [ClipAutopilotPlan.Font: String], stickers: Set<String> = []) throws -> [ClipAutopilotOperation] {
        try operations(for: proposal, clipID: clipID, project: project, fonts: fonts, stickers: stickers, plan: nil)
    }

    private static func operations(for proposal: ClipProposal, clipID: String, project: Project,
                                   fonts: [ClipAutopilotPlan.Font: String], stickers: Set<String>,
                                   plan: ClipAutopilotPlan?) throws -> [ClipAutopilotOperation] {
        guard let transcript = project.transcript else { throw VoiceLabError.invalidInput }
        let words = transcript.words
        let existing = project.edits.clips.first { $0.id == clipID }
        guard clipID.range(of: "\\A(?:" + EditingLimits.clipIDPattern + ")\\z", options: .regularExpression) != nil,
              (proposal.target.clipId == clipID && existing != nil && proposal.target.new == nil) ||
              (proposal.target.clipId == nil && existing == nil && proposal.target.new != nil) else {
            throw VoiceLabError.invalidInput
        }
        let previous = existing?.playParts ?? []
        let parts = try proposal.parts.map { ranges in
            try ranges.enumerated().map { index, range in
                guard range.startWord >= 0, range.endWord < words.count, range.startWord <= range.endWord else { throw VoiceLabError.invalidInput }
                let start = words[range.startWord].id, end = words[range.endWord].id
                return previous.first { $0.startWordId == start && $0.endWordId == end }
                    ?? ClipPart(id: "proposal-part-\(index + 1)", startWordId: start, endWordId: end)
            }
        } ?? previous
        guard (1...12).contains(parts.count),
              let spans = StoryClips.indices(parts.map { ($0.startWordId, $0.endWordId) }, words: words),
              let startWord = spans.map(\.lowerBound).min(), let endWord = spans.map(\.upperBound).max(),
              proposal.target.new.map({ ($0.kind == .stretch) == (parts.count == 1) }) != false else {
            throw HarnessError.invalid("Choose nonoverlapping parts in play order.")
        }
        func scope(_ start: Int, _ end: Int) -> ClosedRange<Int>? {
            guard start <= end else { return nil }
            return spans.first { $0.contains(start) && $0.contains(end) }
        }
        let state = try EditState(transcript: transcript, edits: project.edits)
        var operations: [ClipAutopilotOperation] = []
        func add(_ id: String, _ decision: ClipAutopilotOperation.Decision, _ action: ClipAutopilotOperation.Action, _ reason: String = "") {
            operations.append(.init(id: id, decision: decision, action: action, reason: reason))
        }
        let title = proposal.title.flatMap { $0.isEmpty ? nil : $0 }
        if let existing {
            if parts != previous {
                if parts.count == 1 && existing.parts == nil {
                    add("clip", .clip, .edit(.updateClip(id: clipID, startIndex: startWord, endIndex: endWord)), proposal.reason)
                } else {
                    let command = EditCommand.setClipParts(id: clipID, parts: parts)
                    var candidate = project
                    try candidate.applyEditing(command)
                    guard candidate.edits.clips.first(where: { $0.id == clipID })?.playParts.map(\.startWordId) == parts.map(\.startWordId),
                          candidate.edits.clips.first(where: { $0.id == clipID })?.playParts.map(\.endWordId) == parts.map(\.endWordId) else {
                        throw HarnessError.invalid("These parts would replace protected work. Propose a new clip instead.")
                    }
                    add("clip", .clip, .edit(command), proposal.reason)
                }
            }
            if let title, title != existing.title { add("title", .title, .edit(.renameClip(id: clipID, title: title))) }
        } else {
            let new = proposal.target.new
            let kind: StoryClipKind? = parts.count > 1 ? (new?.kind == .showreel ? .showreel : .story) : nil
            add("clip", .clip, .edit(.addClip(ClipRange(id: clipID, startWordId: words[startWord].id, endWordId: words[endWord].id,
                title: title ?? new.flatMap { $0.title.isEmpty ? nil : $0.title }, origin: .ai, selected: true,
                parts: parts.count > 1 ? parts : nil, kind: kind))), proposal.reason)
        }
        for (index, correction) in (proposal.corrections ?? []).enumerated() {
            guard scope(correction.word, correction.word) != nil, words[correction.word].kind == .word else {
                throw HarnessError.invalid("A correction is outside the clip or does not name a spoken word.")
            }
            add("correction-\(index)", .correction, .edit(.correct(id: words[correction.word].id, text: correction.text)), correction.reason)
        }
        var cutIDs = state.cutWordIds
        var requestedCuts = Set<String>()
        for (index, cut) in (proposal.cuts ?? []).enumerated() {
            guard scope(cut.startWord, cut.endWord) != nil else { throw HarnessError.invalid("A cut is outside a clip part.") }
            let spoken = words[cut.startWord...cut.endWord].filter { $0.kind == .word }.map(\.id)
            if plan == nil && (spoken.isEmpty || !requestedCuts.isDisjoint(with: spoken)) {
                throw HarnessError.invalid("Cuts must name distinct spoken words.")
            }
            requestedCuts.formUnion(spoken)
            let ids = spoken.filter { !cutIDs.contains($0) }
            cutIDs.formUnion(ids)
            if !ids.isEmpty { add("cut-\(index)", .cut, .edit(.cutSelection(ids: ids)), cut.reason) }
        }
        if plan == nil && !spans.contains(where: { words[$0].contains { $0.kind == .word && !cutIDs.contains($0.id) } }) {
            throw HarnessError.invalid("Keep at least one spoken word in the clip.")
        }
        var tightened = Set(state.pauses.filter { state.cutPauseIds.contains($0.id) }.map(\.afterIndex))
        for (index, pause) in (proposal.pauseCuts ?? []).enumerated() {
            guard let part = scope(pause.afterWord, pause.afterWord), pause.afterWord < part.upperBound,
                  let found = state.pauses.first(where: { $0.afterIndex == pause.afterWord }) else {
                if plan == nil { throw HarnessError.invalid("Choose a detected pause inside a clip part.") }
                continue
            }
            guard tightened.insert(pause.afterWord).inserted else { continue }
            add("pause-\(index)", .pauseCut, .edit(.cutSelection(ids: [found.id])), pause.reason)
        }
        for (index, rewrite) in (proposal.rewrites ?? []).enumerated() {
            guard scope(rewrite.startWord, rewrite.endWord) != nil else { throw HarnessError.invalid("A rewrite crosses a clip part.") }
            add("rewrite-\(index)", .rewrite, .rewrite(scope: .selection(rewrite.startWord...rewrite.endWord), text: rewrite.text), rewrite.reason)
        }
        if proposal.captionStyle != nil || proposal.font != nil || proposal.textCase != nil || proposal.wordsPerCaption != nil {
        var settings = plan == nil ? project.captionSettings(forClip: clipID) : project.captions
        if let style = proposal.captionStyle { settings.styleId = style }
        var overrides = settings.overrides
        func merge(_ key: String, _ values: [String: JSONValue]) {
            var object = overrides[key]?.aiObject ?? [:]
            for (name, value) in values { object[name] = value }
            overrides[key] = .object(object)
        }
        if let textCase = proposal.textCase { merge("text", ["transform": .string(textCase.transform)]) }
        if let count = proposal.wordsPerCaption {
            merge("layout", count == 1 ? ["maxWords": .number(1), "maxLines": .number(1)] : ["maxWords": .number(Double(count))])
        }
        let file = proposal.font.flatMap { fonts[$0] }
        if let file, let font = proposal.font {
            merge("font", ["file": .string(file), "family": .string(font.family), "weight": .number(Double(font.weight))])
        }
        settings.overrides = overrides
        add("captions", .captions, .captions(settings, pendingFont: file == nil ? proposal.font : nil), plan?.captions.reason ?? "")
        }
        if let look = proposal.look { add("look", .look, .look(clipID: clipID, look: look), look.reason) }
        if let speed = proposal.speed { add("speed", .speed, .speed(clipID: clipID, speed: speed), speed.reason) }
        var zoomRanges: [Range<Double>] = []
        var corrections = state.corrections
        for correction in proposal.corrections ?? [] { corrections[words[correction.word].id] = correction.text }
        for (index, zoom) in (plan?.zooms ?? []).enumerated() {
            guard let part = scope(zoom.word, zoom.untilWord), let range = zoom.sourceRange(in: words, within: part),
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
        var overlayRanges: [Range<Double>] = []
        var footageRanges: [Range<Double>] = []
        var openingTitle = false
        for (index, entry) in (proposal.effects ?? []).prefix(ClipPlanEffect.maximumEntries).enumerated() {
            let id = "\(clipID.prefix(48))-plan-fx-\(index)"
            guard let part = scope(entry.startWord, entry.endWord),
                  let operation = entry.operation(id: id, clipID: clipID, scope: part, words: words,
                                                  cut: cutIDs, tightenedAfter: tightened, stickers: stickers,
                                                  sources: project.media.footageDurations) else {
                if plan == nil { throw HarnessError.invalid("Effect \(index + 1) doesn’t fit those kept words or its selected footage.") }
                continue
            }
            switch operation.action {
            case .motion(let cue):
                let range = cue.sourceStart..<cue.sourceEnd
                if zoomRanges.contains(where: { $0.overlaps(range) }) {
                    if plan == nil { throw HarnessError.invalid("The proposed zooms overlap.") }
                    continue
                }
                zoomRanges.append(range)
            case .effect(let overlay) where overlay.kind.usesText:
                let range = overlay.start..<overlay.end
                if overlayRanges.contains(where: { $0.overlaps(range) }) {
                    if plan == nil { throw HarnessError.invalid("The proposed overlays overlap.") }
                    continue
                }
                overlayRanges.append(range)
                let openingPart = spans[0]
                let opening = openingPart.first(where: { !cutIDs.contains(words[$0].id) }) ?? openingPart.lowerBound
                openingTitle = openingTitle || (part == openingPart && overlay.kind == .title && overlay.start < words[opening].start + 2)
            case .footage(let entry):
                let range = entry.start..<entry.end
                if footageRanges.contains(where: { $0.overlaps(range) }) {
                    if plan == nil { throw HarnessError.invalid("The proposed footage overlaps.") }
                    continue
                }
                footageRanges.append(range)
            default: break
            }
            operations.append(operation)
        }
        if let trackID = proposal.music?.trackId {
            add("music", .music, .savedMusic(clipID: clipID, trackID: trackID))
        } else if let brief = proposal.music?.brief {
            let picked = plan?.pickedMusic ?? .init(title: "Proposed music", mood: "", prompt: brief, reason: proposal.reason, underVoiceDb: 18)
            let seconds = spans.reduce(0.0) { total, span in
                total + editedSeconds(span: span, words: words, cut: cutIDs, pauses: state.pauses, tightened: tightened,
                                       cutPauseIDs: state.cutPauseIds, keepSeconds: state.pauseKeepSeconds)
            }
            add("music", .music, .music(ClipAutopilotMusicCue(clipID: clipID, picked: picked,
                alternatives: (plan?.music ?? []).filter { $0 != picked }, seconds: seconds)), picked.reason)
        }
        if let hook = proposal.hook, !hook.isEmpty && !openingTitle { add("hook", .hook, .hook(clipID: clipID, text: hook)) }
        if let postText = proposal.postText, !postText.isEmpty { add("post", .postText, .shareText(clipID: clipID, text: postText)) }
        if plan == nil, let coverTitle = proposal.coverTitle { add("cover", .coverTitle, .coverTitle(clipID: clipID, text: coverTitle)) }
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
    public static func apply(_ operations: [ClipAutopilotOperation], to project: Project, clipCaptions: (id: String, style: ClipStyle)? = nil) throws -> (project: Project, pending: [ClipAutopilotOperation]) {
        var result = project
        var pending: [ClipAutopilotOperation] = []
        var effects: [ClipEffect] = []
        for operation in operations {
            switch operation.action {
            case .edit(let command): try result.applyEditing(command)
            case .captions(let settings, _):
                if let clipCaptions {
                    result.clipStyle = (result.clipStyle ?? clipCaptions.style).choosingCaptionStyle(settings.styleId, forClip: clipCaptions.id, current: settings)
                } else { result.captions = settings }
            case .motion(let cue):
                guard let next = addingMotionCue(cue, to: result) else { pending.append(operation); continue }
                result = next
            case .shareText(let clipID, let text): result.share.captions[clipID] = text
            case .effect(let effect): effects.append(effect)
            case .footage(let entry):
                if !result.media.setFootage(entry) { pending.append(operation) }
                else { result.schemaVersion = max(4, result.schemaVersion) }
            case .savedMusic(let clipID, let trackID):
                guard var track = result.music.first(where: { $0.id == trackID }) else { throw HarnessError.invalid("Choose a saved music track from this project.") }
                track.clipId = clipID
                result = try MusicProject.setting(MusicProject.unique(track, in: result), clipId: clipID, in: result)
            case .coverTitle(let clipID, let text):
                guard let clip = result.edits.clips.first(where: { $0.id == clipID }), let words = result.transcript?.words,
                      let first = words.first(where: { $0.id == clip.playParts.first?.startWordId }), ClipHookTitle.text(text) == text else {
                    throw HarnessError.invalid("Choose a short, single-line cover title.")
                }
                var controls = ClipControlsProject.controls(for: clipID, in: result) ?? ProjectClipControls(clipId: clipID)
                controls.coverSeconds = controls.coverSeconds ?? first.start
                controls.coverTitle = text
                result = try ClipControlsProject.setting(controls, in: result)
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
