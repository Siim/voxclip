import Foundation

/// One clip as the caption pick request shows it: `C1`, `C2`… in clip order (AI §17).
public struct CaptionPickClip: Sendable, Equatable {
    public var id: String
    public var title: String?
    public var seconds: Double
    public var text: String
    public init(id: String, title: String?, seconds: Double, text: String) { self.id = id; self.title = title; self.seconds = seconds; self.text = text }
}

/// shared/prompts/caption-pick.json rendered into one request (AI §17). Pure: the same inputs give the same strings
/// on both platforms (shared/fixtures/clip-style/caption-pick.json).
public struct CaptionPickPrompt: Sendable {
    public let document: JSONValue

    public init(document: JSONValue) throws {
        guard document[ai: "schemaVersion"].aiInt == 1, document[ai: "promptVersion"].aiInt == 1,
              document[ai: "system"].aiString != nil, document[ai: "output"][ai: "schema"] != .null else { throw VoxClipError.sharedResourcesMissing }
        self.document = document
    }

    public static func load(shared: SharedResources) throws -> CaptionPickPrompt {
        try CaptionPickPrompt(document: JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: shared.root.appendingPathComponent("prompts/caption-pick.json"))))
    }

    public var maxClips: Int { document[ai: "limits"][ai: "maxClips"].aiInt ?? 24 }
    public var maxClipChars: Int { document[ai: "limits"][ai: "maxClipChars"].aiInt ?? 600 }
    public var maxReasonChars: Int { document[ai: "limits"][ai: "maxReasonChars"].aiInt ?? 120 }

    /// A clip's length in the request: whole seconds, halves rounded up; 0 for a negative or non-finite length.
    public static func wholeSeconds(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0, seconds < 1e9 else { return 0 }
        return Int(floor(seconds + 0.5))
    }

    /// The label a clip carries in the request and the reply: `C1` for the first clip.
    public static func label(_ index: Int) -> String { "C\(index + 1)" }

    /// The instruction for `clips` (at most `maxClips`, in order) and the styles the AI may choose from.
    public func instruction(clips: [CaptionPickClip], candidates: [CaptionStyle], presetLabel: String) -> String {
        let request = document[ai: "request"]
        let styleLine = request[ai: "styleLine"].aiString ?? "- {id}: {name}. {description}"
        let clipLine = request[ai: "clipLine"].aiString ?? "{clip} ({seconds} s) {title}: {text}"
        let styles = candidates.map { style in
            styleLine.replacingOccurrences(of: "{id}", with: style.id).replacingOccurrences(of: "{name}", with: style.name)
                .replacingOccurrences(of: "{description}", with: style.description)
        }.joined(separator: "\n")
        let lines = clips.prefix(maxClips).enumerated().map { index, clip in
            clipLine.replacingOccurrences(of: "{clip}", with: Self.label(index))
                .replacingOccurrences(of: "{seconds}", with: String(Self.wholeSeconds(clip.seconds)))
                .replacingOccurrences(of: "{title}", with: AIText.trim(clip.title ?? "").isEmpty ? "Untitled" : AIText.trim(clip.title ?? ""))
                .replacingOccurrences(of: "{text}", with: AIText.prefix(AIText.trim(clip.text), utf16: maxClipChars))
        }.joined(separator: "\n")
        return (request[ai: "instruction"].aiString ?? "")
            .replacingOccurrences(of: "{preset}", with: presetLabel)
            .replacingOccurrences(of: "{styles}", with: styles)
            .replacingOccurrences(of: "{clips}", with: lines)
    }

    public func request(clips: [CaptionPickClip], candidates: [CaptionStyle], presetLabel: String, timeout: Duration, language: String?) -> LLMRequest {
        LLMRequest(feature: .captionPick, system: document[ai: "system"].aiString ?? "",
                   instruction: instruction(clips: clips, candidates: candidates, presetLabel: presetLabel),
                   schemaName: document[ai: "output"][ai: "name"].aiString ?? "caption_picks", schema: document[ai: "output"][ai: "schema"],
                   maxOutputTokens: document[ai: "generation"][ai: "maxOutputTokens"].aiInt ?? 2000, effort: .decision,
                   timeout: timeout, language: language, tag: "caption-pick \(min(clips.count, maxClips)) clips")
    }

    /// The reply's valid picks by clip id. A pick is dropped when its clip label is unknown or repeated, or when its
    /// style is not one of `candidates`; a reason is trimmed to `maxReasonChars` characters.
    public func picks(_ object: JSONValue, clips: [CaptionPickClip], candidates: Set<String>) -> (picks: [String: ClipCaptionPick], dropped: Int) {
        let labels = Dictionary(uniqueKeysWithValues: clips.prefix(maxClips).enumerated().map { (Self.label($0.offset), $0.element.id) })
        var picks: [String: ClipCaptionPick] = [:], dropped = 0
        for item in object[ai: "picks"].aiArray {
            guard let label = item[ai: "clip"].aiString.map(AIText.trim), let id = labels[label], picks[id] == nil,
                  let style = item[ai: "style"].aiString.map(AIText.trim), candidates.contains(style), style != "auto" else { dropped += 1; continue }
            let reason = AIText.trim(item[ai: "reason"].aiString ?? "")
            picks[id] = ClipCaptionPick(styleId: style, reason: String(String.UnicodeScalarView(reason.unicodeScalars.prefix(maxReasonChars))))
        }
        return (picks, dropped)
    }
}

/// Asks the chosen connector for a caption style per clip while the clip style's captions are Auto (design.md §6.6).
/// A style the user fixed is never sent and never overridden.
public struct CaptionPicker: Sendable {
    public let runner: LLMRunner
    public let prompt: CaptionPickPrompt
    public let catalog: LLMCatalog

    public init(runner: LLMRunner, prompt: CaptionPickPrompt, catalog: LLMCatalog) { self.runner = runner; self.prompt = prompt; self.catalog = catalog }

    /// `style` with the AI's picks recorded, or `style` unchanged when its captions are not Auto (no request is sent)
    /// or there are no clips or candidates.
    public func pick(_ style: ClipStyle, clips: [CaptionPickClip], library: [CaptionStyle], styles: ClipStyleCatalog,
                     connector: any LLMConnector, model: String, language: String?) async throws -> (style: ClipStyle, dropped: Int) {
        guard case .auto = style.captions, !clips.isEmpty else { return (style, 0) }
        let candidates = styles.captionCandidates(library, for: style)
        guard !candidates.isEmpty else { return (style, 0) }
        let request = prompt.request(clips: clips, candidates: candidates, presetLabel: styles.preset(style.preset).label,
                                     timeout: catalog.timeout(for: connector.id, feature: .captionPick), language: language)
        let result = try await runner.run(request, on: connector, model: model)
        let parsed = prompt.picks(result.object, clips: clips, candidates: Set(candidates.map(\.id)))
        return (style.pruned(clipIDs: Set(clips.map(\.id))).recording(parsed.picks), parsed.dropped + result.droppedItems)
    }
}
