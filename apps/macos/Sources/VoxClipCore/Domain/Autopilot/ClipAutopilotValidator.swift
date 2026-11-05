import Foundation

/// Checks a planner reply item by item (ai.md §16.5). Nothing in a reply refuses the whole plan: an invalid item is
/// repaired when one safe repair exists, otherwise dropped, and every change is listed in `repairs`. Only a series moment
/// whose span cannot be read, is too short or too long, or overlaps a better-ranked moment is left out, and the series lists it.
public enum ClipAutopilotValidator {
    /// One clip reply. A span that cannot be read falls back to the whole scope; nil only when the scope has no word.
    public static func plan(_ value: JSONValue, context base: ClipAutopilotContext) -> ClipAutopilotPlan? {
        var log = Log()
        guard let span = span(value, context: base, isSeries: false, log: &log) else { return nil }
        // Corrections come first, so the rewrites' bridge words and every later check read the corrected words.
        let checked = corrections(value[ai: "corrections"], span: span, context: base, log: &log)
        let context = base.correcting(checked.map(\.correction))
        let rewrites = rewrites(value[ai: "rewrites"], span: span, context: context, log: &log)
        let cuts = cuts(value[ai: "cuts"], span: span, rewrites: rewrites, context: context, log: &log)
        let corrections = checked.filter { item in
            guard cuts.contains(where: { ($0.startWord...$0.endWord).contains(item.correction.word) }) else { return true }
            log.drop(item.field, "the plan cuts that word")
            return false
        }.map(\.correction)
        let pauseCuts = pauseCuts(value[ai: "pauseCuts"], span: span, rewrites: rewrites, context: context, log: &log)
        let captions = captions(value, context: context, log: &log)
        let look = look(value, context: context, log: &log)
        let speed = speed(value, context: context, log: &log)
        let (music, pick) = music(value, context: context, log: &log)
        let zooms = zooms(value[ai: "zooms"], span: span, cuts: cuts, context: context, log: &log)
        let limits = context.prompt.limits
        let fallbackTitle = EditingAlgorithms.clipTitle((span.lowerBound...span.upperBound).filter(context.isListedWord).map(context.text)) ?? ""
        let title = text(value[ai: "title"], limit: min(limits.maxTitleScalars, EditingLimits.maxClipTitleScalars), field: "title", log: &log)
        let score = score(value[ai: "score"], context: context, log: &log)
        let verdict = verdict(value[ai: "verdict"], score: score, field: "verdict", log: &log)
        let seconds = ClipAutopilotMapping.editedSeconds(span: span, words: context.words,
            cut: context.cutWordIDs.union(cuts.flatMap { ($0.startWord...$0.endWord).map { context.words[$0].id } }),
            pauses: context.pauses, tightened: Set(pauseCuts.map(\.afterWord)), cutPauseIDs: context.cutPauseIDs,
            keepSeconds: context.pauseKeepSeconds) / (speed?.rate ?? 1)
        let lengthReason = text(value[ai: "lengthReason"], limit: limits.maxReasonScalars, field: "lengthReason", log: &log)
        let tone = tone(value, context: context, log: &log)
        return ClipAutopilotPlan(startWord: span.lowerBound, endWord: span.upperBound,
            title: title.isEmpty ? fallbackTitle : title,
            hook: text(value[ai: "hook"], limit: limits.maxHookScalars, field: "hook", log: &log),
            cuts: cuts, pauseCuts: pauseCuts, corrections: corrections, rewrites: rewrites, captions: captions, look: look, speed: speed,
            music: music, musicPick: pick, zooms: zooms,
            postText: text(value[ai: "postText"], limit: limits.maxPostScalars, field: "postText", log: &log),
            score: score, verdict: verdict,
            scoreReason: text(value[ai: "scoreReason"], limit: limits.maxReasonScalars, field: "scoreReason", log: &log),
            lengthReason: lengthReason, seconds: seconds,
            questions: questions(value[ai: "questions"], context: context, log: &log), repairs: log.repairs,
            flags: flags(seconds: seconds, lengthReason: lengthReason, limits: limits), tone: tone)
    }

    /// The tone the words were written in (prompt version 6, ai.md §16.5). With no tone in the request there is none. A fixed
    /// tone is the plan's tone whatever the reply says (a repair when it differs); As I said it never has one (a repair when
    /// the reply names one). Under Auto the reply's id must be one of the offered tones, read ignoring case and spaces;
    /// "none" or an empty id keeps the creator's own tone, and an unknown one becomes none (a repair).
    static func tone(_ value: JSONValue, context: ClipAutopilotContext, log: inout Log) -> ClipAutopilotPlan.Tone? {
        guard let requested = context.tone else { return nil }
        let raw = (value[ai: "tone"].aiString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let key = raw.lowercased().replacingOccurrences(of: " ", with: "-")
        let none = key.isEmpty || key == "none" || key == "as-said"
        func summary() -> String {
            text(value[ai: "toneSummary"], limit: context.prompt.limits.maxToneSummaryScalars, field: "toneSummary", log: &log)
        }
        switch requested {
        case .asSaid:
            if !none { log.repair("tone", "the creator keeps their own tone; “\(raw)” dropped") }
            return nil
        case .fixed(let tone):
            if key != tone.id { log.repair("tone", "the creator fixed \(tone.id)" + (raw.isEmpty ? "" : "; “\(raw)” replaced")) }
            return .init(id: tone.id, title: tone.title, summary: summary())
        case .auto(let offered):
            if none { return nil }
            guard let tone = offered.first(where: { $0.id == key }) else {
                log.repair("tone", "unknown tone “\(raw)”; none")
                return nil
            }
            return .init(id: tone.id, title: tone.title, summary: summary())
        }
    }

    /// The flags a finished length earns (ai.md §16.5): over `maxReasonedSeconds`, or over `maxTargetSeconds` with no reason.
    static func flags(seconds: Double, lengthReason: String, limits: ClipAutopilotLimits) -> [ClipAutopilotPlan.Flag] {
        if seconds > limits.maxReasonedSeconds {
            return [.init(kind: .overLength, detail: "runs \(toFixed1(seconds)) s, over the \(limits.templateValues["maxReasonedSeconds"]!) s limit")]
        }
        if seconds > limits.maxTargetSeconds && lengthReason.isEmpty {
            return [.init(kind: .longWithoutReason, detail: "runs \(toFixed1(seconds)) s, past \(limits.templateValues["maxTargetSeconds"]!) s with no reason")]
        }
        return []
    }

    /// The first stage of a series: its moments in the reply's rank order, each span checked as a series clip's, then any
    /// moment overlapping a better-ranked one left out, up to `maxClips`. Only the first `postFirst` keeps that verdict.
    public static func moments(_ value: JSONValue, context: ClipAutopilotContext) -> (moments: [ClipAutopilotMoment], repairs: [ClipAutopilotPlan.Repair]) {
        var moments: [ClipAutopilotMoment] = []
        var log = Log()
        let limits = context.prompt.limits
        for (index, item) in value[ai: "clips"].aiArray.enumerated() {
            let field = "clips[\(index)]"
            guard moments.count < limits.maxClips else { log.drop(field, "more than \(limits.maxClips) clips"); continue }
            var spanLog = Log()
            guard let span = span(item, context: context, isSeries: true, log: &spanLog) else {
                log.drop(field, "the clip's span is unreadable, too short or too long"); continue
            }
            if let earlier = moments.firstIndex(where: { $0.startWord <= span.upperBound && span.lowerBound <= $0.endWord }) {
                log.drop(field, "overlaps clip \(earlier + 1)"); continue
            }
            let fallbackTitle = EditingAlgorithms.clipTitle(span.filter(context.isListedWord).map(context.text)) ?? ""
            let title = text(item[ai: "title"], limit: min(limits.maxTitleScalars, EditingLimits.maxClipTitleScalars), field: field + ".title", log: &log)
            let score = score(item[ai: "score"], context: context, field: field + ".score", log: &log)
            var verdict = verdict(item[ai: "verdict"], score: score, field: field + ".verdict", log: &log)
            if verdict == .postFirst, moments.contains(where: { $0.verdict == .postFirst }) {
                verdict = .post; log.repair(field + ".verdict", "only the best clip posts first; post")
            }
            let style = captionStyle(item[ai: "captionStyle"], context: context, field: field + ".captionStyle", log: &log)
            moments.append(.init(startWord: span.lowerBound, endWord: span.upperBound, title: title.isEmpty ? fallbackTitle : title,
                idea: text(item[ai: "idea"], limit: limits.maxReasonScalars, field: field + ".idea", log: &log), score: score, verdict: verdict,
                scoreReason: text(item[ai: "scoreReason"], limit: limits.maxReasonScalars, field: field + ".scoreReason", log: &log),
                captionStyle: style,
                captionReason: text(item[ai: "captionReason"], limit: limits.maxReasonScalars, field: field + ".captionReason", log: &log)))
        }
        return (moments, log.repairs)
    }

    /// A series from its checked plans (nil where a plan failed, with the reason in `failures`): ranked by score, best
    /// first, ties in the moments' order. Only the best `postFirst` keeps that verdict; the others become `post`.
    static func series(_ plans: [ClipAutopilotPlan?], moments: [ClipAutopilotMoment], failures: [Int: String],
                       repairs: [ClipAutopilotPlan.Repair]) -> ClipAutopilotSeries {
        var repairs = repairs
        for (index, plan) in plans.enumerated() where plan == nil {
            repairs.append(.init(field: "plans[\(index)]", action: .dropped, detail: failures[index] ?? "the plan has no words of the clip"))
        }
        var checked: [(order: Int, plan: ClipAutopilotPlan)] = []
        for (order, plan) in plans.enumerated() { if let plan { checked.append((order, plan)) } }
        checked.sort { left, right in
            left.plan.score == right.plan.score ? left.order < right.order : left.plan.score > right.plan.score
        }
        var ranked: [ClipAutopilotPlan] = checked.map(\.plan)
        var first = false
        for index in ranked.indices where ranked[index].verdict == .postFirst {
            if first {
                ranked[index].verdict = .post
                ranked[index].repairs.append(.init(field: "verdict", action: .repaired, detail: "another clip posts first; post"))
            }
            first = true
        }
        return ClipAutopilotSeries(plans: ranked, moments: moments, repairs: repairs)
    }

    struct Log {
        var repairs: [ClipAutopilotPlan.Repair] = []
        mutating func drop(_ field: String, _ detail: String) { repairs.append(.init(field: field, action: .dropped, detail: detail)) }
        mutating func repair(_ field: String, _ detail: String) { repairs.append(.init(field: field, action: .repaired, detail: detail)) }
    }

    /// An integer reply value: a finite whole number within ±10⁹.
    static func integer(_ value: JSONValue) -> Int? {
        guard let number = value.aiDouble, number.isFinite, number == number.rounded(), abs(number) <= 1e9 else { return nil }
        return Int(number)
    }

    /// Text shown to the creator: trimmed, without control characters other than newlines, cut to `limit` Unicode scalars.
    static func text(_ value: JSONValue, limit: Int, field: String, log: inout Log) -> String {
        guard let raw = value.aiString else {
            if value != .null { log.repair(field, "not text") }
            return ""
        }
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0 == "\n" || $0.properties.generalCategory != .control }))
        let trimmed = AIText.trim(cleaned)
        guard trimmed.unicodeScalars.count > limit else { return trimmed }
        log.repair(field, "cut to \(limit) characters")
        return AIText.trim(String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(limit))))
    }

    /// The plan's span: the reply's span inside the scope, its ends moved inward to listed words. A clip plan falls back to
    /// the scope; a series clip without a readable span, or outside the clip-length limits, is nil.
    static func span(_ value: JSONValue, context: ClipAutopilotContext, isSeries: Bool, log: inout Log) -> ClosedRange<Int>? {
        let scope = context.scope
        var start = integer(value[ai: "startWord"]), end = integer(value[ai: "endWord"])
        if start == nil || end == nil || start! > end! || end! < scope.lowerBound || start! > scope.upperBound {
            guard !isSeries else { return nil }
            log.repair("startWord", "the span was unreadable; the whole clip is used")
            start = scope.lowerBound; end = scope.upperBound
        } else if start! < scope.lowerBound || end! > scope.upperBound {
            log.repair("startWord", "the span was moved inside the clip")
            start = max(start!, scope.lowerBound); end = min(end!, scope.upperBound)
        }
        guard var first = start, var last = end else { return nil }
        while first <= last && !context.isListedWord(first) { first += 1 }
        while last >= first && !context.isListedWord(last) { last -= 1 }
        guard first <= last else {
            guard !isSeries, let lower = scope.first(where: context.isListedWord), let upper = scope.last(where: context.isListedWord) else { return nil }
            log.repair("startWord", "the span held no words; the whole clip is used")
            return lower...upper
        }
        if isSeries {
            let seconds = context.words[last].end - context.words[first].start
            guard seconds >= context.prompt.limits.minClipSeconds, seconds <= context.prompt.limits.maxClipSeconds else { return nil }
        }
        return first...last
    }

    static func overlaps(_ range: ClosedRange<Int>, _ ranges: [ClosedRange<Int>]) -> Bool { ranges.contains { $0.overlaps(range) } }

    /// Rewrites (voice-lab.md §8.4 bridge words): a range of 2 to `maxRewriteWords` listed items inside the span that starts
    /// and ends on a word, with no other rewrite in it, and spoken text that keeps both bridge words, changes something, and
    /// holds no link, control character or bracket tag. At most `maxRewrites`, in reply order.
    static func rewrites(_ value: JSONValue, span: ClosedRange<Int>, context: ClipAutopilotContext, log: inout Log) -> [ClipAutopilotPlan.Rewrite] {
        let limits = context.prompt.limits
        var accepted: [ClipAutopilotPlan.Rewrite] = []
        for (index, item) in value.aiArray.enumerated() {
            let field = "rewrites[\(index)]"
            guard accepted.count < limits.maxRewrites else { log.drop(field, "more than \(limits.maxRewrites) rewrites"); continue }
            guard let start = integer(item[ai: "startWord"]), let end = integer(item[ai: "endWord"]), start < end,
                  span.contains(start), span.contains(end) else { log.drop(field, "its words are not inside the clip"); continue }
            let range = start...end
            guard range.allSatisfy(context.isListed), context.isListedWord(start), context.isListedWord(end),
                  range.count <= limits.maxRewriteWords else { log.drop(field, "its range is not a short run of the clip's words"); continue }
            guard !overlaps(range, accepted.map { $0.startWord...$0.endWord }) else { log.drop(field, "overlaps another rewrite"); continue }
            guard let raw = item[ai: "text"].aiString else { log.drop(field, "no text"); continue }
            let spoken = AIText.trim(raw.replacingOccurrences(of: "\n", with: " "))
            let tokens = EditingPrimitives.splitWords(spoken)
            guard !tokens.isEmpty, tokens.count <= limits.maxRewriteTextWords,
                  spoken == VoiceLabAudioTags.sanitizedRequest(spoken, modelID: ""),
                  spoken.range(of: "https?://", options: [.regularExpression, .caseInsensitive]) == nil,
                  !spoken.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                log.drop(field, "its text is not a short spoken phrase"); continue
            }
            let bridge = (leading: [context.text(start)], trailing: [context.text(end)])
            guard VoiceLabTakeProcessing.keepsBridgeWords(spoken, bridge: bridge) else {
                log.drop(field, "its text drops the bridge words “\(bridge.leading[0])” and “\(bridge.trailing[0])”"); continue
            }
            let original = range.filter { context.words[$0].kind == .word }.map(context.text).joined(separator: " ")
            guard VoiceLabTakeQuality.tokens(original) != VoiceLabTakeQuality.tokens(spoken) else { log.drop(field, "changes nothing"); continue }
            accepted.append(.init(startWord: start, endWord: end, text: spoken,
                reason: text(item[ai: "reason"], limit: limits.maxReasonScalars, field: field + ".reason", log: &log)))
        }
        return accepted
    }

    /// Cuts: listed items inside the span, never inside a rewrite (a cut is trimmed around one), merged where they touch, and
    /// never every word of the clip.
    static func cuts(_ value: JSONValue, span: ClosedRange<Int>, rewrites: [ClipAutopilotPlan.Rewrite], context: ClipAutopilotContext,
                     log: inout Log) -> [ClipAutopilotPlan.Cut] {
        let limits = context.prompt.limits
        let protected = rewrites.map { $0.startWord...$0.endWord }
        var pieces: [ClipAutopilotPlan.Cut] = []
        for (index, item) in value.aiArray.enumerated() {
            let field = "cuts[\(index)]"
            guard pieces.count < limits.maxCuts else { log.drop(field, "more than \(limits.maxCuts) cuts"); continue }
            guard var start = integer(item[ai: "startWord"]), var end = integer(item[ai: "endWord"]) else { log.drop(field, "no word range"); continue }
            if start > end { swap(&start, &end); log.repair(field, "its range was reversed") }
            guard start <= span.upperBound, end >= span.lowerBound else { log.drop(field, "outside the clip"); continue }
            if start < span.lowerBound || end > span.upperBound {
                start = max(start, span.lowerBound); end = min(end, span.upperBound); log.repair(field, "trimmed to the clip")
            }
            let kind = item[ai: "kind"].aiString.flatMap(ClipAutopilotPlan.CutKind.init(rawValue:)) ?? {
                log.repair(field + ".kind", "unknown kind; other"); return .other
            }()
            let reason = text(item[ai: "reason"], limit: limits.maxReasonScalars, field: field + ".reason", log: &log)
            // The listed items of the range, split around every rewrite.
            var run: [Int] = []
            var trimmed = false
            let before = pieces.count
            func close() {
                if let first = run.first, let last = run.last {
                    pieces.append(.init(startWord: first, endWord: last, kind: kind, reason: reason.isEmpty ? kind.rawValue : reason))
                }
                run = []
            }
            for position in start...end {
                if protected.contains(where: { $0.contains(position) }) { trimmed = true; close(); continue }
                if context.isListed(position) { run.append(position) }
            }
            close()
            if pieces.count == before { log.drop(field, trimmed ? "inside a rewrite" : "no words of the clip"); continue }
            if trimmed { log.repair(field, "trimmed around a rewrite") }
        }
        // Merge cuts that overlap or touch in listed order; the first one's kind and reason name the merge.
        let listed = span.filter(context.isListed)
        let order = Dictionary(uniqueKeysWithValues: listed.enumerated().map { ($1, $0) })
        var merged: [ClipAutopilotPlan.Cut] = []
        for cut in pieces.sorted(by: { $0.startWord < $1.startWord }) {
            if let last = merged.last, let lastEnd = order[last.endWord], let start = order[cut.startWord], start <= lastEnd + 1 {
                merged[merged.count - 1].endWord = max(last.endWord, cut.endWord)
            } else {
                merged.append(cut)
            }
        }
        let kept = listed.filter { position in context.words[position].kind == .word && !merged.contains { ($0.startWord...$0.endWord).contains(position) } }
        guard !kept.isEmpty else {
            log.drop("cuts", "they removed every word of the clip")
            return []
        }
        return merged
    }

    /// Pause cuts: a detected, uncut pause after a listed word, both of its words inside the span and outside every rewrite.
    static func pauseCuts(_ value: JSONValue, span: ClosedRange<Int>, rewrites: [ClipAutopilotPlan.Rewrite], context: ClipAutopilotContext,
                          log: inout Log) -> [ClipAutopilotPlan.PauseCut] {
        var accepted: [ClipAutopilotPlan.PauseCut] = []
        for (index, item) in value.aiArray.enumerated() {
            let field = "pauseCuts[\(index)]"
            guard accepted.count < context.prompt.limits.maxPauseCuts else { log.drop(field, "too many pause cuts"); continue }
            guard let after = integer(item[ai: "afterWord"]), span.contains(after), span.contains(after + 1), context.isListed(after),
                  let pause = context.pauses.first(where: { $0.afterIndex == after }), !context.cutPauseIDs.contains(pause.id) else {
                log.drop(field, "no pause the editor can tighten follows that word"); continue
            }
            guard !rewrites.contains(where: { ($0.startWord..<$0.endWord).contains(after) }) else { log.drop(field, "inside a rewrite"); continue }
            guard !accepted.contains(where: { $0.afterWord == after }) else { log.drop(field, "repeats another pause cut"); continue }
            accepted.append(.init(afterWord: after, reason: text(item[ai: "reason"], limit: context.prompt.limits.maxReasonScalars,
                                                                 field: field + ".reason", log: &log)))
        }
        return accepted
    }

    /// Captions: a built-in style other than `off`, a font that is bundled or the default (Roboto Black), a known case and
    /// a words-per-caption count inside the limits, with the reason for the style. What the creator fixed in the caption
    /// preference always wins; any other unreadable value falls back to the prompt file's default.
    static func captions(_ value: JSONValue, context: ClipAutopilotContext, log: inout Log) -> ClipAutopilotPlan.Captions {
        let defaults = context.prompt.defaults, limits = context.prompt.limits
        let style = captionStyle(value[ai: "captionStyle"], context: context, field: "captionStyle", log: &log)
        var font = ClipAutopilotPlan.Font(family: value[ai: "captionFont"].aiString.map(AIText.trim) ?? "", weight: integer(value[ai: "captionWeight"]) ?? -1)
        // "Roboto 900" in the family field: the weight belongs in captionWeight.
        if !context.allows(font), let match = font.family.wholeMatch(of: /(.+?)\s+([1-9]00)/), let weight = Int(match.2),
           context.allows(.init(family: String(match.1), weight: weight)) {
            font = .init(family: String(match.1), weight: weight)
            log.repair("captionFont", "the weight was in the family name")
        }
        if let fixed = context.preference?.font, context.allows(fixed) {
            if font != fixed { log.repair("captionFont", "the creator fixed the font; \(fixed.family) \(fixed.weight)") }
            font = fixed
        } else if !context.allows(font) {
            log.repair("captionFont", "unknown font “\(font.family) \(font.weight)”; \(defaults.font.family) \(defaults.font.weight)")
            font = defaults.font
        }
        let replyCase = value[ai: "captionCase"].aiString.flatMap(ClipAutopilotPlan.CaptionCase.init(rawValue:))
        let textCase: ClipAutopilotPlan.CaptionCase
        if let fixed = context.preference?.textCase {
            if replyCase != fixed { log.repair("captionCase", "the creator fixed the case; \(fixed.rawValue)") }
            textCase = fixed
        } else if let replyCase {
            textCase = replyCase
        } else {
            textCase = defaults.textCase
            log.repair("captionCase", "unknown case; \(textCase.rawValue)")
        }
        var words = integer(value[ai: "wordsPerCaption"]) ?? defaults.wordsPerCaption
        if !(limits.minWordsPerCaption...limits.maxWordsPerCaption).contains(words) {
            words = min(max(words, limits.minWordsPerCaption), limits.maxWordsPerCaption)
            log.repair("wordsPerCaption", "clamped to \(words)")
        }
        return .init(styleId: style, font: font, textCase: textCase, wordsPerCaption: words,
                     reason: text(value[ai: "captionReason"], limit: limits.maxReasonScalars, field: "captionReason", log: &log))
    }

    /// A caption style id: the creator's fixed style when there is one, else a built-in style other than `off`, else
    /// `defaults.styleId` (or the first style when the defaults name none).
    static func captionStyle(_ value: JSONValue, context: ClipAutopilotContext, field: String, log: inout Log) -> String {
        let reply = value.aiString ?? ""
        if let fixed = context.fixedStyle {
            if reply != fixed { log.repair(field, "the creator fixed the style; \(fixed)") }
            return fixed
        }
        if context.styleIDs.contains(reply) && reply != "off" { return reply }
        let defaults = context.prompt.defaults
        let fallback = context.styleIDs.contains(defaults.styleID) ? defaults.styleID : context.styleIDs.filter { $0 != "off" }.sorted().first ?? defaults.styleID
        log.repair(field, "unknown style “\(reply)”; \(fallback)")
        return fallback
    }

    /// The look: one of `ClipAutopilotPlan.LookID`, read ignoring case and non-letters ("B&W" is `bw`), with its reason. A
    /// reply without one keeps the original look; an unknown one becomes the original look without its reason (a repair).
    static func look(_ value: JSONValue, context: ClipAutopilotContext, log: inout Log) -> ClipAutopilotPlan.Look {
        guard value[ai: "look"] != .null else { return .original }
        let key = (value[ai: "look"].aiString ?? "").lowercased().filter { $0.isLetter }
        let aliases: [String: ClipAutopilotPlan.LookID] = ["blackandwhite": .bw, "blackwhite": .bw, "monochrome": .bw, "none": .original]
        guard let id = ClipAutopilotPlan.LookID(rawValue: key) ?? aliases[key] else {
            log.repair("look", "unknown look “\(value[ai: "look"].aiString ?? "")”; original")
            return .original
        }
        return .init(id: id, reason: text(value[ai: "lookReason"], limit: context.prompt.limits.maxReasonScalars, field: "lookReason", log: &log))
    }

    /// The speed: a finite rate other than 1 (within 0.005), clamped to `minSpeed...maxSpeed` (a repair), with its reason.
    /// A reply without one, or with 1, plays at its own speed; a rate that is not a positive number is dropped.
    static func speed(_ value: JSONValue, context: ClipAutopilotContext, log: inout Log) -> ClipAutopilotPlan.Speed? {
        let limits = context.prompt.limits
        guard value[ai: "speed"] != .null else { return nil }
        guard let rate = value[ai: "speed"].aiDouble, rate.isFinite, rate > 0 else { log.drop("speed", "not a positive number"); return nil }
        guard abs(rate - 1) >= 0.005 else { return nil }
        var clamped = rate
        if !(limits.minSpeed...limits.maxSpeed).contains(rate) {
            clamped = min(max(rate, limits.minSpeed), limits.maxSpeed)
            log.repair("speed", "clamped to \(clamped)")
        }
        return .init(rate: clamped, reason: text(value[ai: "speedReason"], limit: limits.maxReasonScalars, field: "speedReason", log: &log))
    }

    /// Corrections (ai.md §16.5): a listed word inside the span that reads as `heard` (letters and digits, ignoring case),
    /// or the nearest one within 3 positions that does (a repair); one per word; text of 1 to `maxCorrectionWords` words and
    /// at most `EditingLimits.maxCorrectionScalars`, with no link, control character or bracket tag, that keeps the word's
    /// own leading and trailing punctuation and changes it. At most `maxCorrections`, in reply order.
    static func corrections(_ value: JSONValue, span: ClosedRange<Int>, context: ClipAutopilotContext,
                            log: inout Log) -> [(field: String, correction: ClipAutopilotPlan.Correction)] {
        let limits = context.prompt.limits
        func key(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        var accepted: [(field: String, correction: ClipAutopilotPlan.Correction)] = []
        for (index, item) in value.aiArray.enumerated() {
            let field = "corrections[\(index)]"
            guard accepted.count < limits.maxCorrections else { log.drop(field, "more than \(limits.maxCorrections) corrections"); continue }
            guard let word = integer(item[ai: "word"]) else { log.drop(field, "no word index"); continue }
            let heard = key(item[ai: "heard"].aiString ?? "")
            guard !heard.isEmpty else { log.drop(field, "no heard word"); continue }
            func reads(_ position: Int) -> Bool { span.contains(position) && context.isListedWord(position) && key(context.text(position)) == heard }
            var position = word
            if !reads(word) {
                let near = (1...3).flatMap { [word - $0, word + $0] }.first(where: reads)
                guard let near else { log.drop(field, "word \(word) does not read “\(item[ai: "heard"].aiString ?? "")”"); continue }
                position = near
                log.repair(field, "moved to word \(near), which reads “\(context.text(near))”")
            }
            guard !accepted.contains(where: { $0.correction.word == position }) else { log.drop(field, "repeats another correction"); continue }
            let spelled = AIText.trim((item[ai: "text"].aiString ?? "").replacingOccurrences(of: "\n", with: " "))
            let tokens = EditingPrimitives.splitWords(spelled)
            guard !tokens.isEmpty, tokens.count <= limits.maxCorrectionWords, spelled.unicodeScalars.count <= EditingLimits.maxCorrectionScalars,
                  spelled == VoiceLabAudioTags.sanitizedRequest(spelled, modelID: ""),
                  spelled.range(of: "https?://", options: [.regularExpression, .caseInsensitive]) == nil,
                  !spelled.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                log.drop(field, "its text is not a short spelling"); continue
            }
            let shown = context.text(position)
            let fixed = punctuated(spelled, like: shown)
            guard fixed != shown, fixed.unicodeScalars.count <= EditingLimits.maxCorrectionScalars else { log.drop(field, "changes nothing"); continue }
            accepted.append((field, .init(word: position, heard: shown, text: fixed,
                reason: text(item[ai: "reason"], limit: limits.maxReasonScalars, field: field + ".reason", log: &log))))
        }
        return accepted
    }

    /// `text` with `shown`'s leading and trailing punctuation when `text` has none of its own at that end, so "Tvilio," corrected
    /// to "Twilio" stays "Twilio,".
    static func punctuated(_ text: String, like shown: String) -> String {
        func isMark(_ character: Character) -> Bool { !character.isLetter && !character.isNumber }
        let leading = String(shown.prefix(while: isMark)), trailing = String(shown.reversed().prefix(while: isMark).reversed())
        guard leading.count < shown.count else { return text }
        var result = text
        if let first = result.first, !isMark(first) { result = leading + result }
        if let last = result.last, !isMark(last) { result += trailing }
        return result
    }

    /// Music: up to `maxMusic` suggestions with a title and a prompt, the prompt made instrumental and the level clamped;
    /// the pick falls back to the first suggestion.
    static func music(_ value: JSONValue, context: ClipAutopilotContext, log: inout Log) -> ([ClipAutopilotPlan.Music], Int?) {
        let limits = context.prompt.limits, defaults = context.prompt.defaults
        var accepted: [ClipAutopilotPlan.Music] = []
        var replyIndex: [Int] = []
        for (index, item) in value[ai: "music"].aiArray.enumerated() {
            let field = "music[\(index)]"
            guard accepted.count < limits.maxMusic else { log.drop(field, "more than \(limits.maxMusic) suggestions"); continue }
            let title = text(item[ai: "title"], limit: limits.maxTitleScalars, field: field + ".title", log: &log)
            var prompt = text(item[ai: "prompt"], limit: limits.maxMusicPromptScalars, field: field + ".prompt", log: &log)
                .replacingOccurrences(of: "\n", with: " ")
            guard !title.isEmpty, !prompt.isEmpty else { log.drop(field, "no title or prompt"); continue }
            if prompt.range(of: "instrumental", options: .caseInsensitive) == nil {
                prompt += context.prompt.instrumentalSuffix
                log.repair(field + ".prompt", "made instrumental")
            }
            var level = item[ai: "underVoiceDb"].aiDouble ?? .nan
            if !level.isFinite { level = defaults.underVoiceDb; log.repair(field + ".underVoiceDb", "unreadable; \(level)") }
            else if !(limits.minUnderVoiceDb...limits.maxUnderVoiceDb).contains(level) {
                level = min(max(level, limits.minUnderVoiceDb), limits.maxUnderVoiceDb); log.repair(field + ".underVoiceDb", "clamped to \(level)")
            }
            accepted.append(.init(title: title, mood: text(item[ai: "mood"], limit: limits.maxTitleScalars, field: field + ".mood", log: &log),
                prompt: prompt, reason: text(item[ai: "reason"], limit: limits.maxReasonScalars, field: field + ".reason", log: &log),
                underVoiceDb: level))
            replyIndex.append(index)
        }
        guard !accepted.isEmpty else {
            if !value[ai: "music"].aiArray.isEmpty { log.drop("music", "no usable suggestion") }
            return ([], nil)
        }
        if let wanted = integer(value[ai: "musicPick"]), let position = replyIndex.firstIndex(of: wanted) { return (accepted, position) }
        log.repair("musicPick", "unknown pick; the first suggestion")
        return (accepted, 0)
    }

    /// Zooms: a listed, uncut word inside the span to an `untilWord` at or after it (shortened to `maxZoomSeconds`), a scale
    /// clamped to the limits, never overlapping an earlier zoom.
    static func zooms(_ value: JSONValue, span: ClosedRange<Int>, cuts: [ClipAutopilotPlan.Cut], context: ClipAutopilotContext,
                      log: inout Log) -> [ClipAutopilotPlan.Zoom] {
        let limits = context.prompt.limits
        func isKept(_ position: Int) -> Bool {
            context.isListedWord(position) && !cuts.contains { ($0.startWord...$0.endWord).contains(position) }
        }
        var accepted: [ClipAutopilotPlan.Zoom] = []
        for (index, item) in value.aiArray.enumerated() {
            let field = "zooms[\(index)]"
            guard accepted.count < limits.maxZooms else { log.drop(field, "more than \(limits.maxZooms) zooms"); continue }
            guard let word = integer(item[ai: "word"]), span.contains(word), isKept(word) else { log.drop(field, "not on a kept word of the clip"); continue }
            var until = integer(item[ai: "untilWord"]) ?? word
            if until < word || !span.contains(until) {
                until = min(max(until, word), span.upperBound); log.repair(field + ".untilWord", "moved inside the clip")
            }
            let start = context.words[word].start
            let wanted = until
            while until > word && (context.words[until].end - start > limits.maxZoomSeconds || !context.isListedWord(until)) { until -= 1 }
            guard context.words[until].end - start <= limits.maxZoomSeconds else { log.drop(field, "its word is longer than a zoom"); continue }
            if until != wanted { log.repair(field + ".untilWord", "shortened to end on word \(until)") }
            guard !accepted.contains(where: { $0.word <= until && word <= $0.untilWord }) else { log.drop(field, "overlaps another zoom"); continue }
            var scale = item[ai: "scale"].aiDouble ?? .nan
            if !scale.isFinite { scale = context.prompt.defaults.zoomScale; log.repair(field + ".scale", "unreadable; \(scale)") }
            else if !(limits.minZoomScale...limits.maxZoomScale).contains(scale) {
                scale = min(max(scale, limits.minZoomScale), limits.maxZoomScale); log.repair(field + ".scale", "clamped to \(scale)")
            }
            accepted.append(.init(word: word, untilWord: until, scale: scale,
                reason: text(item[ai: "reason"], limit: limits.maxReasonScalars, field: field + ".reason", log: &log)))
        }
        return accepted.sorted { $0.word < $1.word }
    }

    static func score(_ value: JSONValue, context: ClipAutopilotContext, field: String = "score", log: inout Log) -> Int {
        guard let number = value.aiDouble, number.isFinite else {
            log.repair(field, "unreadable; \(context.prompt.defaults.score)")
            return context.prompt.defaults.score
        }
        let rounded = Int(min(10, max(1, number.rounded())))
        if Double(rounded) != number { log.repair(field, "clamped to \(rounded)") }
        return rounded
    }

    /// The verdict, read with case, spaces, hyphens and underscores ignored, so "post first" is `postFirst`; otherwise the
    /// one the score implies.
    static func verdict(_ value: JSONValue, score: Int, field: String, log: inout Log) -> ClipAutopilotPlan.Verdict {
        let key = (value.aiString ?? "").lowercased().filter { $0.isLetter }
        if let verdict = ClipAutopilotPlan.Verdict.allCases.first(where: { $0.rawValue.lowercased() == key }) { return verdict }
        let implied = ClipAutopilotPlan.Verdict.implied(by: score)
        log.repair(field, "unknown verdict; \(implied.rawValue)")
        return implied
    }

    static func questions(_ value: JSONValue, context: ClipAutopilotContext, log: inout Log) -> [ClipAutopilotPlan.Question] {
        let limits = context.prompt.limits
        var accepted: [ClipAutopilotPlan.Question] = []
        for (index, item) in value.aiArray.enumerated() {
            let field = "questions[\(index)]"
            guard accepted.count < limits.maxQuestions else { log.drop(field, "more than \(limits.maxQuestions) questions"); continue }
            let question = text(item[ai: "question"], limit: limits.maxReasonScalars, field: field, log: &log)
            let answer = text(item[ai: "answer"], limit: limits.maxReasonScalars, field: field + ".answer", log: &log)
            guard !question.isEmpty, !answer.isEmpty else { log.drop(field, "no question or answer"); continue }
            var options: [String] = []
            for option in item[ai: "options"].aiArray {
                let shown = text(option, limit: limits.maxTitleScalars, field: field + ".options", log: &log)
                if !shown.isEmpty, !options.contains(shown), options.count < limits.maxOptions { options.append(shown) }
            }
            accepted.append(.init(question: question, answer: answer, options: options))
        }
        return accepted
    }
}
