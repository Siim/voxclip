import CryptoKit
import Foundation

/// What the creator asked Claude about (ai.md §18.1): selected words, a whole clip, or a time range on the timeline.
public struct AskClaudeSelection: Sendable, Equatable {
    public enum Scope: Sendable, Equatable {
        /// Transcript word indices, inclusive.
        case words(ClosedRange<Int>)
        case clip(String)
        /// Source seconds.
        case time(ClosedRange<Double>)
    }
    public var scope: Scope
    /// The clip the answer's effects belong to: the clip of the tab or row, nil for the full video.
    public var clipID: String?
    public init(scope: Scope, clipID: String?) { self.scope = scope; self.clipID = clipID }
}

/// Something Vision found on screen in the selection (ai.md §18.1): a face or a text box, with the source seconds it was
/// seen over and its rect in picture space. `label` (D1, D2…) is how the request and the reply name it.
public struct AskClaudeDetection: Sendable, Equatable {
    public enum Kind: String, Sendable { case face, text }
    public var label: String
    public var kind: Kind
    public var start: Double
    public var end: Double
    public var rect: ClipEffect.Rect
    public var text: String?
    public init(label: String, kind: Kind, start: Double, end: Double, rect: ClipEffect.Rect, text: String? = nil) {
        self.label = label; self.kind = kind; self.start = start; self.end = end; self.rect = rect; self.text = text
    }
}

/// The selection resolved against the project: its word range (nil when a time range holds no words), its source range and
/// its clip.
public struct AskClaudeScope: Sendable, Equatable {
    public var words: ClosedRange<Int>?
    public var start: Double
    public var end: Double
    public var clipID: String?
    public var isClip: Bool
    public var isTime: Bool

    public static func resolve(_ selection: AskClaudeSelection, in project: Project) throws -> AskClaudeScope {
        let words = project.transcript?.words ?? []
        if let clipID = selection.clipID, !project.edits.clips.contains(where: { $0.id == clipID }) { throw VoiceLabError.invalidInput }
        switch selection.scope {
        case .words(let range):
            guard range.lowerBound >= 0, range.upperBound < words.count else { throw VoiceLabError.invalidInput }
            return AskClaudeScope(words: range, start: words[range.lowerBound].start, end: words[range.upperBound].end,
                                  clipID: selection.clipID, isClip: false, isTime: false)
        case .clip(let id):
            guard let clip = project.edits.clips.first(where: { $0.id == id }),
                  let first = words.firstIndex(where: { $0.id == clip.startWordId }),
                  let last = words.firstIndex(where: { $0.id == clip.endWordId }), first <= last else { throw VoiceLabError.invalidInput }
            return AskClaudeScope(words: first...last, start: words[first].start, end: words[last].end, clipID: id, isClip: true, isTime: false)
        case .time(let range):
            let duration = project.media.source.durationSeconds
            let start = max(0, range.lowerBound), end = min(duration > 0 ? duration : range.upperBound, range.upperBound)
            guard start.isFinite, end.isFinite, end - start >= 0.1 else { throw VoiceLabError.invalidInput }
            let inside = words.indices.filter { words[$0].end > start && words[$0].start < end }
            let span = inside.first.map { $0...(inside.last ?? $0) }
            return AskClaudeScope(words: span, start: start, end: end, clipID: selection.clipID, isClip: false, isTime: true)
        }
    }
}

/// shared/prompts/ask-claude.json (ai.md §18.3). Pure: the same inputs give the same strings.
public struct AskClaudePrompt: Sendable {
    public static let path = "prompts/ask-claude.json"
    public let document: JSONValue
    public let sha256: String

    public init(data: Data) throws {
        let document = try JSONDecoder().decode(JSONValue.self, from: data)
        guard document[ai: "schemaVersion"].aiInt == 1, document[ai: "promptVersion"].aiInt == 1, document[ai: "system"].aiString != nil,
              document[ai: "output"][ai: "schema"] != .null, !document[ai: "toolbox"].aiArray.isEmpty else { throw VoxClipError.sharedResourcesMissing }
        self.document = document
        self.sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func load(shared: SharedResources) throws -> AskClaudePrompt {
        try AskClaudePrompt(data: Data(contentsOf: shared.root.appendingPathComponent(path)))
    }

    public var promptVersion: Int { document[ai: "promptVersion"].aiInt ?? 1 }
    private func limit(_ key: String, _ fallback: Int) -> Int { document[ai: "limits"][ai: key].aiInt ?? fallback }
    public var maxOps: Int { limit("maxOps", 12) }
    public var contextWords: Int { limit("contextWords", 20) }
    public var maxSelectionWords: Int { limit("maxSelectionWords", 400) }
    public var maxDetections: Int { limit("maxDetections", 24) }
    public var maxInstructionChars: Int { limit("maxInstructionChars", 500) }
    public var maxTextChars: Int { limit("maxTextChars", 80) }
    public var maxReasonChars: Int { limit("maxReasonChars", 120) }
    public var maxChoiceChars: Int { limit("maxChoiceChars", 120) }
    public var maxDetectionTextChars: Int { limit("maxDetectionTextChars", 60) }
    /// The stickers the prompt offers: the bundled emoji (`shared/fonts/noto-emoji/png128`), without variation selectors.
    public var stickers: Set<String> { Set(document[ai: "stickers"].aiArray.compactMap(\.aiString)) }
    /// The toolbox kinds the prompt offers, in its order.
    public var kinds: [String] { document[ai: "toolbox"].aiArray.compactMap { $0[ai: "kind"].aiString } }

    private func template(_ key: String) -> String { document[ai: "request"][ai: key].aiString ?? "" }
    private static func fill(_ template: String, _ values: [String: String]) -> String {
        values.reduce(template) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
    }
    /// Seconds and normalized numbers in the request: two decimals, a point, no grouping.
    public static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0.00" }
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// The instruction for `instruction` on `scope`. `current` are the effects already on the stretch, `detections` the
    /// Vision findings (at most `maxDetections`), `aspect` the export shape.
    public func instruction(_ instruction: String, scope: AskClaudeScope, project: Project, current: [String],
                            detections: [AskClaudeDetection], aspect: String) -> String {
        let words = project.transcript?.words ?? []
        let corrections = project.edits.corrections
        func text(_ index: Int) -> String { corrections[words[index].id] ?? words[index].text }
        let n = Self.number
        let selection: String
        if let range = scope.words, !scope.isTime {
            let values = ["first": String(range.lowerBound), "last": String(range.upperBound), "start": n(scope.start), "end": n(scope.end)]
            selection = Self.fill(template(scope.isClip ? "selectionClip" : "selectionWords"), values)
        } else {
            selection = Self.fill(template("selectionTime"), ["start": n(scope.start), "end": n(scope.end)])
        }
        let lines: String
        if let range = scope.words {
            lines = range.prefix(maxSelectionWords).map { index in
                Self.fill(template("wordLine"), ["index": String(index), "start": n(words[index].start), "end": n(words[index].end), "text": text(index)])
            }.joined(separator: "\n")
        } else { lines = template("noWords") }
        let before: String, after: String
        if let range = scope.words {
            let lower = max(0, range.lowerBound - contextWords)
            before = lower < range.lowerBound ? (lower..<range.lowerBound).map(text).joined(separator: " ") : template("noContext")
            let upper = min(words.count, range.upperBound + 1 + contextWords)
            after = range.upperBound + 1 < upper ? ((range.upperBound + 1)..<upper).map(text).joined(separator: " ") : template("noContext")
        } else { before = template("noContext"); after = template("noContext") }
        let clip: String
        if let id = scope.clipID, let range = project.edits.clips.first(where: { $0.id == id }),
           let first = words.firstIndex(where: { $0.id == range.startWordId }), let last = words.firstIndex(where: { $0.id == range.endWordId }) {
            let title = AIText.trim(range.title ?? "")
            clip = Self.fill(template("clipLine"), ["title": title.isEmpty ? "Untitled" : title, "start": n(words[first].start), "end": n(words[last].end)])
        } else { clip = template("noClip") }
        let video = project.media.source.video.map(OutputSizing.orientedSize) ?? PixelSize(width: 1920, height: 1080)
        let frame = Self.fill(template("frameLine"), ["width": String(video.width), "height": String(video.height), "aspect": aspect])
        let detectionLines = detections.prefix(maxDetections).map { detection in
            let reads = detection.text.map { Self.fill(template("detectionText"), ["text": AIText.prefix(AIText.trim($0), utf16: maxDetectionTextChars)]) } ?? ""
            return Self.fill(template("detectionLine"), ["label": detection.label, "kind": detection.kind.rawValue, "start": n(detection.start),
                "end": n(detection.end), "x": n(detection.rect.x), "y": n(detection.rect.y), "width": n(detection.rect.width),
                "height": n(detection.rect.height), "text": reads])
        }
        let tools = document[ai: "toolbox"].aiArray.map { tool in
            Self.fill(template("toolLine"), ["kind": tool[ai: "kind"].aiString ?? "", "group": tool[ai: "group"].aiString ?? "",
                                             "use": tool[ai: "use"].aiString ?? "", "fields": tool[ai: "fields"].aiString ?? ""])
        }.joined(separator: "\n")
        return Self.fill(template("instruction"), [
            "instruction": AIText.prefix(AIText.trim(instruction), utf16: maxInstructionChars), "selection": selection, "words": lines,
            "before": before, "after": after, "clip": clip, "frame": frame,
            "current": current.isEmpty ? template("nothingCurrent") : current.joined(separator: "\n"),
            "detections": detectionLines.isEmpty ? template("noDetections") : detectionLines.joined(separator: "\n"),
            "toolbox": tools])
    }

    /// The lines naming what the stretch already has: effects that overlap it, the clip's zooms in it, and corrections and
    /// cuts on its words.
    public func current(scope: AskClaudeScope, project: Project) -> [String] {
        let words = project.transcript?.words ?? []
        let n = Self.number
        func line(_ kind: String, _ start: Double, _ end: Double, _ detail: String) -> String {
            Self.fill(template("currentLine"), ["kind": kind, "start": n(start), "end": n(end), "detail": detail])
        }
        var lines: [String] = []
        for effect in ClipEffects.rendered(in: project, clipID: scope.clipID) where effect.end > scope.start && effect.start < scope.end {
            let detail = effect.text.map { " \"\($0)\"" } ?? effect.sound?.id.map { " \($0)" } ?? ""
            lines.append(line(effect.kind.rawValue, effect.start, effect.end, detail))
        }
        if let clip = scope.clipID {
            for cue in project.motionCues where cue.clipID == clip && cue.sourceEnd > scope.start && cue.sourceStart < scope.end {
                lines.append(line("zoom", cue.sourceStart, cue.sourceEnd, " \(n(cue.keyframes.map(\.scale).max() ?? 1))"))
            }
        }
        if let range = scope.words {
            let cut = Set(project.edits.cutWordIds)
            for index in range where index < words.count {
                if let fixed = project.edits.corrections[words[index].id] { lines.append(line("correction", words[index].start, words[index].end, " [\(index)] \"\(fixed)\"")) }
                if cut.contains(words[index].id) { lines.append(line("jumpCut", words[index].start, words[index].end, " [\(index)]")) }
            }
        }
        return lines
    }

    public func request(_ instruction: String, scope: AskClaudeScope, project: Project, detections: [AskClaudeDetection], aspect: String,
                        timeout: Duration, language: String?) -> LLMRequest {
        LLMRequest(feature: .askClaude, system: document[ai: "system"].aiString ?? "",
                   instruction: self.instruction(instruction, scope: scope, project: project, current: current(scope: scope, project: project),
                                                 detections: detections, aspect: aspect),
                   schemaName: document[ai: "output"][ai: "name"].aiString ?? "ask_claude_ops", schema: document[ai: "output"][ai: "schema"],
                   maxOutputTokens: document[ai: "generation"][ai: "maxOutputTokens"].aiInt ?? 4000, effort: .decision,
                   timeout: timeout, language: language, tag: "ask-claude")
    }
}

/// Claude's checked answer (ai.md §18.4): one operation per row, in reply order, with the choice Claude made where the
/// instruction was ambiguous and what the validator repaired.
public struct AskClaudeAnswer: Sendable, Equatable {
    public var summary: String
    public var operations: [ClipAutopilotOperation]
    /// The pre-picked answer for an ambiguous instruction, by operation id: "the face at the left".
    public var choices: [String: String]
    /// One line per repaired or dropped reply item.
    public var repairs: [String]

    /// The rows that need a paid click before they run: a voice rewrite, generated music.
    public var paid: [ClipAutopilotOperation] {
        operations.filter { if case .rewrite = $0.action { true } else if case .music = $0.action { true } else { false } }
    }
}

/// Checks a reply op by op, as the planner's validator does: a field outside its range is clamped, a missing one takes the
/// selection's value or a default, and an op that cannot act is dropped with a repair line (ai.md §18.4).
public struct AskClaudeValidator: Sendable {
    public let prompt: AskClaudePrompt
    public let scope: AskClaudeScope
    public let project: Project
    public let detections: [AskClaudeDetection]

    public init(prompt: AskClaudePrompt, scope: AskClaudeScope, project: Project, detections: [AskClaudeDetection]) {
        self.prompt = prompt; self.scope = scope; self.project = project; self.detections = detections
    }

    /// Bundled sound lengths in seconds; `shared/sfx/<id>.wav` holds exactly these (tools/media/gen_sfx.py).
    public static let soundSeconds: [String: Double] = ["whoosh": 0.45, "pop": 0.12, "ding": 0.8]
    static let soundAliases: [String: String] = ["swoosh": "whoosh", "swish": "whoosh", "woosh": "whoosh", "click": "pop", "boop": "pop",
                                                 "bloop": "pop", "bell": "ding", "chime": "ding", "ping": "ding", "ding-dong": "ding"]
    static let defaultSoundGainDb = -6.0
    static let stickerScale = 1.0
    static let zoomScale = 1.2

    public func answer(_ object: JSONValue) -> AskClaudeAnswer {
        var answer = AskClaudeAnswer(summary: AIText.prefix(AIText.trim(object[ai: "summary"].aiString ?? ""), utf16: 200), operations: [], choices: [:], repairs: [])
        var effectIDs = Set(project.clipEffects.map(\.id))
        var cutSoFar = Set(project.edits.cutWordIds)
        var corrected = Set<String>()
        let raw = object[ai: "ops"].aiArray
        if raw.count > prompt.maxOps { answer.repairs.append("Kept the first \(prompt.maxOps) of \(raw.count) changes.") }
        for (index, item) in raw.prefix(prompt.maxOps).enumerated() {
            let kind = AIText.trim(item[ai: "kind"].aiString ?? "")
            let reason = Self.scalars(AIText.trim(item[ai: "reason"].aiString ?? ""), prompt.maxReasonChars)
            let choice = Self.scalars(AIText.trim(item[ai: "choice"].aiString ?? ""), prompt.maxChoiceChars)
            let id = "ask-\(index + 1)-\(kind.isEmpty ? "op" : kind)"
            var note: String? = choice.isEmpty ? nil : choice
            func add(_ decision: ClipAutopilotOperation.Decision, _ action: ClipAutopilotOperation.Action) {
                answer.operations.append(ClipAutopilotOperation(id: id, decision: decision, action: action, reason: reason))
                if let note { answer.choices[id] = note }
            }
            func drop(_ why: String) { answer.repairs.append("Left out \(kind.isEmpty ? "a change" : kind): \(why).") }
            func effect(_ kind: ClipEffect.Kind, _ build: (inout ClipEffect) -> Void) -> ClipEffect? {
                guard let range = timeRange(item, kind: kind) else { return nil }
                var value = ClipEffect(id: ClipEffects.nextID(kind, existing: effectIDs), clipId: scope.clipID, kind: kind, start: range.lowerBound, end: range.upperBound)
                build(&value)
                guard (try? ClipEffects.validate(value, projectId: project.id)) != nil else { return nil }
                effectIDs.insert(value.id)
                return value
            }
            switch kind {
            case "bleep", "mute":
                guard let words = wordRange(item), case let ids = spokenIDs(words), !ids.isEmpty else { drop("no words of the selection"); continue }
                let all = project.transcript?.words ?? []
                let effectKind: ClipEffect.Kind = kind == "bleep" ? .bleep : .mute
                let value = ClipEffect(id: ClipEffects.nextID(effectKind, existing: effectIDs), clipId: scope.clipID, kind: effectKind,
                                       start: all[words.lowerBound].start, end: all[words.upperBound].end, wordIds: ids)
                effectIDs.insert(value.id)
                add(.bleep, .effect(value))
            case "blur", "pixelate":
                let target = region(item)
                if target.chosen, note == nil { note = target.note }
                guard let rect = target.rect else { drop("no region to cover"); continue }
                let tracking = trackingMode(item, target: target)
                guard let value = effect(kind == "blur" ? .blur : .pixelate, { $0.rect = rect; $0.tracking = tracking; $0.track = [] }) else { drop("no time in the selection"); continue }
                add(.blur, .effect(value))
            case "title", "lowerThird":
                let text = Self.scalars(AIText.trim(item[ai: "text"].aiString ?? "").replacingOccurrences(of: "\n", with: " "), prompt.maxTextChars)
                guard !text.isEmpty else { drop("no text"); continue }
                let position = positionValue(item, allowed: kind == "title" ? [.top, .center, .bottom] : [.bottomLeft, .bottomRight],
                                             fallback: kind == "title" ? .top : .bottomLeft)
                guard let value = effect(kind == "title" ? .title : .lowerThird, { $0.text = text; $0.position = position }) else { drop("no time in the selection"); continue }
                add(.overlay, .effect(value))
            case "sticker":
                let text = Self.withoutVariationSelectors(AIText.trim(item[ai: "text"].aiString ?? ""))
                guard prompt.stickers.contains(text) else { drop("not one of the bundled emoji"); continue }
                let position = positionValue(item, allowed: [.topLeft, .topRight, .bottomLeft, .bottomRight, .center], fallback: .topRight)
                let scale = Self.clamp(item[ai: "scale"].aiDouble, ClipEffect.scaleRange, fallback: Self.stickerScale)
                guard let value = effect(.sticker, { $0.text = text; $0.position = position; $0.scale = scale }) else { drop("no time in the selection"); continue }
                add(.overlay, .effect(value))
            case "arrow", "circle":
                let target = region(item)
                if target.chosen, note == nil { note = target.note }
                guard let rect = target.rect else { drop("nothing to point at"); continue }
                guard let value = effect(kind == "arrow" ? .arrow : .circle, { $0.rect = rect }) else { drop("no time in the selection"); continue }
                add(.overlay, .effect(value))
            case "progress":
                let position = positionValue(item, allowed: [.top, .bottom], fallback: .bottom)
                guard let value = effect(.progress, { $0.position = position }) else { drop("no time in the selection"); continue }
                add(.overlay, .effect(value))
            case "freeze":
                guard let range = timeRange(item, kind: .freeze) else { drop("no time in the selection"); continue }
                let length = min(ClipEffect.maximumFreezeSeconds, max(0.3, range.upperBound - range.lowerBound))
                let value = ClipEffect(id: ClipEffects.nextID(.freeze, existing: effectIDs), clipId: scope.clipID, kind: .freeze,
                                       start: range.lowerBound, end: range.lowerBound + length)
                effectIDs.insert(value.id)
                add(.freeze, .effect(value))
            case "sound":
                let named = AIText.trim(item[ai: "sound"].aiString ?? "").lowercased()
                let sound = Self.soundSeconds[named] != nil ? named : (Self.soundAliases[named] ?? "whoosh")
                if sound != named, note == nil { note = "a \(sound)" }
                let start = max(scope.start, min(scope.end, Self.seconds(item[ai: "start"]) ?? scope.start))
                let length = Self.soundSeconds[sound] ?? 0.45
                let gain = Self.defaultSoundGainDb
                let value = ClipEffect(id: ClipEffects.nextID(.sound, existing: effectIDs), clipId: scope.clipID, kind: .sound, start: start, end: start + length,
                                       sound: .init(source: .bundled, id: sound, durationSeconds: length, title: sound.capitalized, license: "cc0"), gainDb: gain)
                effectIDs.insert(value.id)
                add(.sound, .effect(value))
            case "speed":
                guard let range = timeRange(item, kind: nil) else { drop("no time in the selection"); continue }
                let rate = Self.clamp(item[ai: "rate"].aiDouble, 0.5...2.0, fallback: 1)
                guard abs(rate - 1) > 0.01 else { drop("the same speed"); continue }
                add(.stretch, .stretch(clipID: scope.clipID, start: range.lowerBound, end: range.upperBound, rate: rate))
            case "jumpCut":
                guard let words = wordRange(item) else { drop("no words of the selection"); continue }
                let all = project.transcript?.words ?? []
                let ids = words.map { all[$0].id }.filter { !cutSoFar.contains($0) }
                guard !ids.isEmpty else { drop("those words are already cut"); continue }
                cutSoFar.formUnion(ids)
                add(.cut, .edit(.cutSelection(ids: ids)))
            case "zoom":
                guard let clip = scope.clipID ?? clipContaining(scope) else { drop("a zoom needs a clip"); continue }
                guard let range = timeRange(item, kind: nil), range.upperBound - range.lowerBound >= MotionCue.minimumDuration else { drop("no time in the selection"); continue }
                let scale = Self.clamp(item[ai: "scale"].aiDouble, 1.05...MotionCue.maximumScale, fallback: Self.zoomScale)
                let cueIDs = Set(project.motionCues.map(\.id))
                var cueIndex = 1
                while cueIDs.contains("\(clip)-ask-\(cueIndex)") || answer.operations.contains(where: { if case .motion(let cue) = $0.action { cue.id == "\(clip)-ask-\(cueIndex)" } else { false } }) { cueIndex += 1 }
                let cue = MotionCue(id: "\(clip)-ask-\(cueIndex)", clipID: clip, sourceStart: range.lowerBound, sourceEnd: range.upperBound,
                                    keyframes: [MotionKeyframe(progress: 0, scale: scale), MotionKeyframe(progress: 1, scale: scale)])
                add(.zoom, .motion(cue))
            case "correction":
                guard let words = wordRange(item) else { drop("no word of the selection"); continue }
                let all = project.transcript?.words ?? []
                let word = all[words.lowerBound]
                let text = AIText.trim(item[ai: "text"].aiString ?? "")
                guard word.kind == .word, !corrected.contains(word.id), !text.isEmpty, text.unicodeScalars.count <= EditingLimits.maxCorrectionScalars,
                      text != (project.edits.corrections[word.id] ?? word.text) else { drop("no new spelling"); continue }
                corrected.insert(word.id)
                add(.correction, .edit(.correct(id: word.id, text: EditingPrimitives.nfc(text))))
            case "rewrite":
                guard let words = wordRange(item) else { drop("no words of the selection"); continue }
                let text = AIText.trim(item[ai: "text"].aiString ?? "")
                guard !text.isEmpty else { drop("no new wording"); continue }
                add(.rewrite, .rewrite(scope: .selection(words), text: text))
            case "translate":
                guard let words = wordRange(item) else { drop("no words of the selection"); continue }
                let language = AIText.trim(item[ai: "language"].aiString ?? "").lowercased()
                let text = AIText.trim(item[ai: "text"].aiString ?? "")
                guard language.range(of: #"\A[a-z]{2,3}(-[a-z0-9]{2,8})*\z"#, options: .regularExpression) != nil, !text.isEmpty else { drop("no language or translation"); continue }
                add(.translate, .translateCaptions(clipID: scope.clipID, startWord: words.lowerBound, endWord: words.upperBound, language: language, text: text))
            case "music":
                guard let clip = scope.clipID ?? clipContaining(scope) else { drop("music needs a clip"); continue }
                let mood = Self.scalars(AIText.trim(item[ai: "text"].aiString ?? ""), 200)
                guard !mood.isEmpty else { drop("no mood"); continue }
                let music = ClipAutopilotPlan.Music(title: Self.scalars(mood, 60), mood: mood, prompt: "Instrumental background music, \(mood), sits under a voice",
                                                    reason: reason, underVoiceDb: -20)
                add(.music, .music(ClipAutopilotMusicCue(clipID: clip, picked: music, alternatives: [], seconds: max(1, scope.end - scope.start))))
            case "duck":
                guard MusicProject.entry(for: scope.clipID, in: project) != nil else { drop("there is no music to duck"); continue }
                add(.duck, .musicDucking(clipID: scope.clipID, on: true))
            default:
                drop("not in the toolbox")
            }
        }
        return answer
    }

    // MARK: Fields

    static func scalars(_ text: String, _ limit: Int) -> String { String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit))) }
    static func seconds(_ value: JSONValue) -> Double? { value.aiDouble.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
    static func clamp(_ value: Double?, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        guard let value, value.isFinite, value != 0 else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
    static func withoutVariationSelectors(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value != 0xFE0F && $0.value != 0xFE0E }))
    }

    /// The reply's word range clamped to the selection; the whole selection when the reply gives none or an empty one.
    func wordRange(_ item: JSONValue) -> ClosedRange<Int>? {
        guard let selection = scope.words else { return nil }
        let start = item[ai: "startWord"].aiInt ?? -1, end = item[ai: "endWord"].aiInt ?? -1
        if start < 0 && end < 0 {
            if let first = Self.seconds(item[ai: "start"]), let last = Self.seconds(item[ai: "end"]), last > first {
                let words = project.transcript?.words ?? []
                let inside = selection.filter { words[$0].end > first && words[$0].start < last }
                if let lower = inside.first, let upper = inside.last { return lower...upper }
            }
            return selection
        }
        let lower = max(selection.lowerBound, start < 0 ? end : start), upper = min(selection.upperBound, end < 0 ? start : end)
        return lower <= upper ? lower...upper : nil
    }

    /// Spoken word ids in `range` (no events), for a bleep.
    func spokenIDs(_ range: ClosedRange<Int>) -> [String] {
        let words = project.transcript?.words ?? []
        return range.filter { words[$0].kind == .word }.map { words[$0].id }
    }

    /// The reply's seconds clamped to the selection; its words' times when it gives none; the selection otherwise. A freeze
    /// with no end holds 1 s.
    func timeRange(_ item: JSONValue, kind: ClipEffect.Kind?) -> ClosedRange<Double>? {
        var start = Self.seconds(item[ai: "start"]), end = Self.seconds(item[ai: "end"])
        if start == nil, end == nil, (item[ai: "startWord"].aiInt ?? -1) >= 0, let words = wordRange(item) {
            let all = project.transcript?.words ?? []
            start = all[words.lowerBound].start; end = all[words.upperBound].end
        }
        let lower = max(scope.start, min(scope.end, start ?? scope.start))
        var upper = min(scope.end, end ?? (kind == .freeze ? lower + 1 : scope.end))
        if kind == .freeze, upper <= lower { upper = min(scope.end, lower + 1) }
        return upper - lower >= 0.05 ? lower...upper : nil
    }

    func positionValue(_ item: JSONValue, allowed: [ClipEffect.Position], fallback: ClipEffect.Position) -> ClipEffect.Position {
        let raw = AIText.trim(item[ai: "position"].aiString ?? "")
        let value = ClipEffect.Position(rawValue: raw) ?? ClipEffect.Position.allCases.first { $0.rawValue.lowercased() == raw.lowercased().replacingOccurrences(of: " ", with: "") }
        return value.flatMap { allowed.contains($0) ? $0 : nil } ?? fallback
    }

    struct Region { var rect: ClipEffect.Rect?; var detection: AskClaudeDetection?; var chosen: Bool; var note: String? }

    /// The region an op covers: a detection label, "face" or "screen", or the reply's rect. Without any, the largest face
    /// (or text box) seen in the selection is pre-picked and named, so the row reads "Claude chose …".
    func region(_ item: JSONValue) -> Region {
        let target = AIText.trim(item[ai: "target"].aiString ?? "")
        let seen = detections.filter { $0.end >= scope.start && $0.start <= scope.end }
        if let found = seen.first(where: { $0.label.caseInsensitiveCompare(target) == .orderedSame }) {
            return Region(rect: found.rect, detection: found, chosen: false, note: nil)
        }
        let explicit = ClipEffect.Rect(x: item[ai: "x"].aiDouble ?? 0, y: item[ai: "y"].aiDouble ?? 0,
                                       width: item[ai: "width"].aiDouble ?? 0, height: item[ai: "height"].aiDouble ?? 0)
        if target.lowercased() == "screen" { return Region(rect: explicit.width > 0 && explicit.height > 0 ? explicit.clamped : .init(x: 0, y: 0, width: 1, height: 1), detection: nil, chosen: false, note: nil) }
        let wantsFace = target.lowercased() == "face"
        if !wantsFace, explicit.width > 0, explicit.height > 0, explicit.x.isFinite, explicit.y.isFinite { return Region(rect: explicit.clamped, detection: nil, chosen: false, note: nil) }
        let faces = seen.filter { $0.kind == .face }.sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
        let pool = wantsFace ? faces : (faces.isEmpty ? seen.filter { $0.kind == .text } : faces)
        guard let pick = pool.first else { return Region(rect: nil, detection: nil, chosen: false, note: nil) }
        let side = pick.rect.midX < 0.4 ? " at the left" : pick.rect.midX > 0.6 ? " at the right" : ""
        let name = pick.kind == .face ? "the face\(side)" : "the text \"\(Self.scalars(pick.text ?? "", 30))\""
        return Region(rect: pick.rect, detection: pick, chosen: pool.count > 1 || !wantsFace, note: name)
    }

    func trackingMode(_ item: JSONValue, target: Region) -> ClipEffect.Tracking {
        if let mode = ClipEffect.Tracking(rawValue: AIText.trim(item[ai: "tracking"].aiString ?? "")) { return mode }
        return target.detection?.kind == .face ? .face : .none
    }

    /// The clip whose words hold the whole selection, for a zoom or music asked on the full video.
    func clipContaining(_ scope: AskClaudeScope) -> String? {
        let words = project.transcript?.words ?? []
        return project.edits.clips.first { clip in
            guard let first = words.firstIndex(where: { $0.id == clip.startWordId }), let last = words.firstIndex(where: { $0.id == clip.endWordId }) else { return false }
            return words[first].start <= scope.start + 1e-6 && words[last].end >= scope.end - 1e-6
        }?.id
    }
}
