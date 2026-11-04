#if DEBUG
import Foundation
import Synchronization
import VoxClipCore
@_spi(Testing) import VoxClipMedia

// The Rewrite smoke's scripted stand-ins (`-rewriteSmoke`, DebugRewriteSmoke.swift): an LLM connector that answers from a
// script, and ElevenLabs over a URL protocol whose takes have scripted lengths and word-check transcripts. Nothing leaves
// the Mac: every request either matches a script entry or fails.

/// One scripted LLM answer.
enum RewriteSmokeReply: Sendable {
    /// A Rewrite reply: the new passage and optional next actions.
    case passage(String, nextActions: [RewriteNextAction] = [])
    /// The request fails as a provider error would.
    case failure
    /// Waits until `RewriteSmokeConnector.release()` before answering with `then`.
    indirect case held(RewriteSmokeReply)
}

/// What the scripted connector was asked, for the report.
struct RewriteSmokeRequestRecord: Encodable, Sendable {
    let tag: String
    let feedback: Bool
}

actor RewriteSmokeConnector: LLMConnector {
    nonisolated let id: ConnectorID = .ollama
    /// Rewrite replies (`voice-rewrite`), in order; the last one repeats.
    private var rewrites: [RewriteSmokeReply]
    /// Fit replies (`voice-rewrite-fit`), in order. With none left a fit keeps every phrase's original words.
    private var fits: [RewriteSmokeFit]
    private(set) var records: [RewriteSmokeRequestRecord] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var holding = false
    init(rewrites: [RewriteSmokeReply], fits: [RewriteSmokeFit] = []) { self.rewrites = rewrites; self.fits = fits }

    func status() -> ConnectorStatus { .ready }
    func knownCLIAuthMethod() async -> String? { nil }
    func models(refresh: Bool) -> [LLMModel] { [LLMModel(id: "smoke", name: "Smoke", contextTokens: 128_000, source: .curated)] }
    func contextTokens(model: String) -> Int? { 128_000 }
    func send(_ request: LLMRequest, model: String) async throws -> RawCompletion {
        let feedback = request.instruction.contains("FEEDBACK") || (request.cachedBlock ?? "").contains("FEEDBACK")
            || request.instruction.contains("blocked") || request.instruction.contains("Merge")
        records.append(RewriteSmokeRequestRecord(tag: request.tag, feedback: feedback))
        switch request.tag {
        case "voice-rewrite":
            guard !rewrites.isEmpty else { throw LLMError.invalidOutput(reason: "The smoke script has no reply.") }
            let reply = rewrites.count > 1 ? rewrites.removeFirst() : rewrites[0]
            return try await answer(reply, model: model)
        case "voice-rewrite-fit":
            let phrases = Self.fitPhrases(request)
            let fit = fits.isEmpty ? .keepOriginal : fits.removeFirst()
            if case .held(let then) = fit {
                holding = true
                await withCheckedContinuation { continuation = $0 }
                holding = false
                return RawCompletion(text: then.reply(phrases), model: model, stop: .complete)
            }
            return RawCompletion(text: fit.reply(phrases), model: model, stop: .complete)
        default:
            throw LLMError.invalidOutput(reason: "The smoke script does not answer \(request.tag).")
        }
    }
    private func answer(_ reply: RewriteSmokeReply, model: String) async throws -> RawCompletion {
        switch reply {
        case .passage(let text, let actions):
            var object: [String: Any] = ["rewrite": text, "audioTags": []]
            object["nextActions"] = actions.map { ["label": $0.label, "instruction": $0.instruction, "ordinals": $0.ordinals] }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return RawCompletion(text: String(decoding: data, as: UTF8.self), model: model, stop: .complete)
        case .failure:
            throw LLMError.invalidOutput(reason: "Scripted provider failure.")
        case .held(let then):
            holding = true
            await withCheckedContinuation { continuation = $0 }
            holding = false
            return try await answer(then, model: model)
        }
    }
    func release() { continuation?.resume(); continuation = nil }
    var sendCount: Int { records.count }

    /// The fit request's phrases: "Phrase {ordinal}" and "Current proposal: {proposed}" (voice-rewrite-fit.json).
    static func fitPhrases(_ request: LLMRequest) -> [(ordinal: Int, proposed: String)] {
        let text = request.cachedBlock ?? request.instruction
        var result: [(Int, String)] = []
        var ordinal: Int?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("Phrase "), let value = Int(line.dropFirst(7).trimmingCharacters(in: .whitespaces)) { ordinal = value }
            if line.hasPrefix("Current proposal: "), let current = ordinal {
                result.append((current, String(line.dropFirst(18)))); ordinal = nil
            }
        }
        return result
    }
}

/// A scripted wording-fit reply.
indirect enum RewriteSmokeFit: Sendable {
    /// Every supplied phrase keeps its original words.
    case keepOriginal
    /// Every supplied phrase is reworded to the same words it had: the fit does not converge.
    case sameWords
    /// Every supplied phrase is reworded without its last word: shorter, as a measured fit asks.
    case fewerWords
    /// Every supplied phrase is reworded to the first half of its words: much shorter.
    case halfWords
    /// Waits for release, then answers as `then`.
    case held(RewriteSmokeFit)

    func reply(_ phrases: [(ordinal: Int, proposed: String)]) -> String {
        let rows: [[String: Any]] = phrases.map { phrase in
            switch self {
            case .keepOriginal, .held: ["ordinal": phrase.ordinal, "action": "keepOriginal", "text": ""]
            case .sameWords: ["ordinal": phrase.ordinal, "action": "reword", "text": phrase.proposed]
            case .fewerWords: ["ordinal": phrase.ordinal, "action": "reword",
                               "text": phrase.proposed.split(separator: " ").dropLast().joined(separator: " ")]
            case .halfWords:
                ["ordinal": phrase.ordinal, "action": "reword",
                 "text": phrase.proposed.split(separator: " ").prefix { _ in true }.prefix((phrase.proposed.split(separator: " ").count + 1) / 2).joined(separator: " ")]
            }
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["phrases": rows], options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// How the scripted ElevenLabs answers takes in one scenario.
/// Eleven v4 timing quirks a correct reply can have (MVP18, voice-lab §8.5), one per paid synthesis in order.
enum RewriteSmokeTimingQuirk: Sendable {
    /// Null `alignment`; `normalized_alignment` lowercases, leads with a space and ends with a newline.
    case normalizedOnly
    /// Curly apostrophes and a trailing newline in `alignment`.
    case curlyAndNewline
    /// `alignment` names another first word: refused, then timed from the take's own word check.
    case otherWords
}

struct RewriteSmokeVoiceScript: Sendable {
    /// Exact fit: each take fills its phrase's slot to the sample. Otherwise (realistic) a take is as long as the
    /// fixture's own speaker says its words (`naturalSeconds`) plus `offset`, so it rarely fills the slot exactly.
    var exactFit = false
    /// Seconds added to every realistic take: a scenario's voice runs a little slower or faster than the source.
    var offset = 0.0
    /// Each take's length as a multiple of its base length: the slot's (exact fit) or the spoken one (realistic).
    var lengthFactor = 1.0
    /// The first takes' factors, in order; `lengthFactor` after them.
    var lengthFactors: [Double] = []
    /// Word-check transcript substitutions, lowercased: "claude code" heard as "cloud code".
    var heard: [String: String] = [:]
    /// Quirky v4 timing for the first syntheses, in order.
    var quirks: [RewriteSmokeTimingQuirk] = []
    /// The length that fits each phrase, keyed by its words without tags; the harness fills it as the plan prepares.
    var fitting: [String: Double] = [:]
    /// Paid synthesis requests and word checks answered.
    var syntheses = 0
    var checks = 0
    var lastText = ""
    var lastDuration = 1.0
}

/// ElevenLabs as the take run reaches it (models, voices, synthesis with timestamps, speech to text), scripted.
final class RewriteSmokeHTTP: URLProtocol, @unchecked Sendable {
    static let script = Mutex(RewriteSmokeVoiceScript())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    /// A reworded phrase's fitting length before the plan records it: the known phrase sharing most of its words, whose
    /// window it keeps.
    static func scaled(_ text: String, from fitting: [String: Double]) -> Double {
        let words = Set(text.split(separator: " "))
        return fitting.max(by: { Set($0.key.split(separator: " ")).intersection(words).count
            < Set($1.key.split(separator: " ")).intersection(words).count })?.value ?? 1.2
    }
    /// How long the fixture's speaker says `text` (DebugRewriteSmoke.project): each word 0.1 s plus 45 ms a letter, the
    /// source's pauses between words, and the take's 50 ms quiet margins.
    static func naturalSeconds(_ text: String) -> Double {
        let words = Self.words(text).split(separator: " ").map(String.init)
        let spoken: Double = words.reduce(0) { $0 + 0.1 + 0.045 * Double($1.count) }
        let pauses: Double = words.dropLast().reduce(0) { $0 + ($1.hasSuffix(".") ? 0.6 : $1.hasSuffix(",") ? 0.25 : 0.07) }
        return spoken + pauses + 0.1
    }
    static func words(_ text: String) -> String {
        text.replacing(#/\[[^\]]*\]/#, with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    override func startLoading() {
        do {
            guard let url = request.url else { throw URLError(.badURL) }
            let data: Data
            switch (request.httpMethod ?? "GET", url.path) {
            case ("GET", "/v1/models"):
                data = Data(#"[{"model_id":"eleven_v3","name":"Speech","can_do_text_to_speech":true,"can_do_voice_conversion":false,"languages":[{"language_id":"en"}],"maximum_text_length_per_request":5000},{"model_id":"eleven_v4","name":"Eleven v4","can_do_text_to_speech":true,"languages":[{"language_id":"en"}],"maximum_text_length_per_request":5000}]"#.utf8)
            case ("GET", "/v2/voices"):
                data = Data(#"{"voices":[{"voice_id":"fixtureOwnVoice","name":"My voice","category":"cloned","is_owner":true}],"has_more":false}"#.utf8)
            case ("POST", "/v1/text-to-speech/fixtureOwnVoice/with-timestamps"), ("POST", "/v1/text-to-dialogue/with-timestamps"):
                let body = try JSONSerialization.jsonObject(with: Self.body(request)) as? [String: Any] ?? [:]
                let dialogue = url.path.hasPrefix("/v1/text-to-dialogue")
                let input = (body["inputs"] as? [[String: Any]])?.first
                let text = ((dialogue ? input?["text"] : body["text"]) as? String) ?? ""
                let duration = Self.script.withLock { script -> Double in
                    script.syntheses += 1
                    let fits = script.fitting[Self.words(text)] ?? script.fitting.first { Self.words(text).contains($0.key) }?.value
                        ?? Self.scaled(Self.words(text), from: script.fitting)
                    let factor = script.syntheses <= script.lengthFactors.count ? script.lengthFactors[script.syntheses - 1] : script.lengthFactor
                    let base: Double = script.exactFit ? fits : Self.naturalSeconds(text) + script.offset
                    script.lastText = Self.words(text); script.lastDuration = max(0.3, base * factor)
                    return script.lastDuration
                }
                data = try Self.synthesis(text: text, duration: duration, dialogue: dialogue)
            case ("POST", "/v1/speech-to-text"):
                let (text, duration) = Self.script.withLock { script -> (String, Double) in
                    script.checks += 1
                    var heard = script.lastText
                    for (said, misheard) in script.heard { heard = heard.replacing(said, with: misheard, maxReplacements: .max) }
                    for (said, misheard) in script.heard {
                        let capitalised = said.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
                        heard = heard.replacing(capitalised, with: misheard, maxReplacements: .max)
                    }
                    return (heard, script.lastDuration)
                }
                // The check hears the take mixed into its source context; the take sits in its middle. Words are timed over
                // that span, so the word check (which keeps the words inside the patch) hears each one.
                let mixed = Self.wavSeconds(try Self.body(request)) ?? duration
                let lead = max(0, (mixed - duration) / 2)
                let words = text.split(separator: " ").map(String.init)
                let stride = max(0.05, duration - 0.2) / Double(max(1, words.count))
                let timed = words.enumerated().map { index, word in
                    ["type": "word", "text": word, "start": lead + 0.1 + Double(index) * stride, "end": lead + 0.1 + Double(index + 1) * stride] as [String: Any]
                }
                data = try JSONSerialization.data(withJSONObject: ["language_code": "eng", "words": timed])
            default:
                throw URLError(.unsupportedURL)
            }
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]) else { throw URLError(.badServerResponse) }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    /// 24 kHz PCM16 of the fixture's voice for `duration`, spoken as the source is (DebugRewriteSmoke.project): its voiced
    /// tone under each word, its room tone in 70 ms gaps between words and 50 ms margins. Each character's timing lies
    /// inside its word. Its joins still differ from the source's by a few LU, so its takes pass with a join advisory.
    private static func synthesis(text: String, duration: Double, dialogue: Bool) throws -> Data {
        let margin = 0.05, gap = 0.07
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let letters = Double(max(1, words.reduce(0) { $0 + $1.count }))
        // The source's own pauses: longer after a sentence or a comma, so word timing across a sentence end holds.
        func pause(_ word: String) -> Double { word.hasSuffix(".") ? 0.6 : word.hasSuffix(",") ? 0.25 : gap }
        let pauses: Double = words.dropLast().reduce(0) { $0 + pause($1) }
        let speech: Double = max(0.05 * Double(words.count), duration - 2 * margin - pauses)
        var spans: [(start: Double, end: Double)] = []
        var time = margin
        for word in words {
            let length: Double = speech * Double(word.count) / letters
            spans.append((time, time + length)); time += length + pause(word)
        }
        var pcm = Data()
        let count = Int((duration * 24_000).rounded())
        pcm.reserveCapacity(count * 2)
        var span = 0
        for index in 0..<count {
            let seconds: Double = Double(index) / 24_000
            while span < spans.count - 1, seconds >= spans[span + 1].start { span += 1 }
            let voiced = spans.indices.contains(span) && seconds >= spans[span].start && seconds < spans[span].end
            let level: Double = voiced ? sin(2 * Double.pi * 120 * seconds) * 3_277 : sin(2 * Double.pi * 60 * seconds) * 33
            var value = Int16(level.rounded()).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        var characters: [String] = [], starts: [Double] = [], ends: [Double] = []
        for (offset, word) in words.enumerated() {
            if offset > 0 {
                characters.append(" "); starts.append(spans[offset - 1].end); ends.append(spans[offset].start)
            }
            let step: Double = (spans[offset].end - spans[offset].start) / Double(max(1, word.count))
            for (position, character) in word.enumerated() {
                characters.append(String(character))
                // The last letter ends exactly where the word does, so the space after it never starts before it ends.
                let end: Double = position == word.count - 1 ? spans[offset].end : spans[offset].start + Double(position + 1) * step
                starts.append(spans[offset].start + Double(position) * step); ends.append(end)
            }
        }
        var reply: [String: Any] = ["audio_base64": pcm.base64EncodedString(),
            "alignment": ["characters": characters, "character_start_times_seconds": starts, "character_end_times_seconds": ends]]
        let quirk = Self.script.withLock { state in state.quirks.isEmpty ? nil : state.quirks.removeFirst() }
        switch quirk {
        case .normalizedOnly?:
            characters = [" "] + characters.map { $0.lowercased() } + ["\n"]
            starts = [0] + starts + [duration]; ends = [0] + ends + [duration]
            reply["alignment"] = NSNull()
            reply["normalized_alignment"] = ["characters": characters, "character_start_times_seconds": starts, "character_end_times_seconds": ends]
        case .curlyAndNewline?:
            characters = characters.map { $0 == "'" ? "\u{2019}" : $0 } + ["\n"]
            starts.append(duration); ends.append(duration)
            reply["alignment"] = ["characters": characters, "character_start_times_seconds": starts, "character_end_times_seconds": ends]
        case .otherWords?:
            if let space = characters.firstIndex(of: " ") {
                characters.replaceSubrange(0..<space, with: Array(repeating: "x", count: space))
            }
            reply["alignment"] = ["characters": characters, "character_start_times_seconds": starts, "character_end_times_seconds": ends]
        case nil: break
        }
        if dialogue {
            reply["voice_segments"] = [["voice_id": "fixtureOwnVoice", "dialogue_input_index": 0, "character_start_index": 0,
                "character_end_index": characters.count, "start_time_seconds": 0, "end_time_seconds": duration]]
        }
        return try JSONSerialization.data(withJSONObject: reply)
    }

    /// The length of the first WAV in a (multipart) body: its `fmt ` byte rate and `data` size.
    private static func wavSeconds(_ body: Data) -> Double? {
        let bytes = [UInt8](body)
        func find(_ tag: String, from start: Int) -> Int? {
            let pattern = Array(tag.utf8)
            guard bytes.count >= pattern.count else { return nil }
            var index = start
            while index + pattern.count <= bytes.count {
                if Array(bytes[index..<index + pattern.count]) == pattern { return index }
                index += 1
            }
            return nil
        }
        func uint32(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 }
        guard let riff = find("RIFF", from: 0), let format = find("fmt ", from: riff), format + 20 < bytes.count,
              let data = find("data", from: format), data + 8 <= bytes.count else { return nil }
        let byteRate = uint32(format + 16)
        guard byteRate > 0 else { return nil }
        return Double(uint32(data + 4)) / Double(byteRate)
    }

    private static func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8_192)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

/// The voice check's embedder: every take is the speaker's own voice.
actor RewriteSmokeSpeaker: SpeakerEmbedder {
    nonisolated let modelID = "fixture-calibrated"
    nonisolated let dimension = 2
    func voicedSamples(_ pcm16k: [Float]) async throws -> [Float] { pcm16k }
    func embed(_ pcm16k: [Float]) async throws -> [Float] { [1, 0] }
}

struct RewriteSmokeKeys: KeyProvider {
    func key(for provider: String) async throws -> String? { "inert-smoke-key" }
}

extension ElevenLabsVoiceLab {
    /// The scripted client: every request goes to `RewriteSmokeHTTP`.
    static func rewriteSmoke(prices: VoiceLabPriceCatalog, spend: VoiceLabSpendLedger) -> ElevenLabsVoiceLab {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RewriteSmokeHTTP.self]
        return ElevenLabsVoiceLab(keys: RewriteSmokeKeys(), session: URLSession(configuration: configuration),
            prices: prices, spend: spend, enforceCapabilities: true)
    }
}

extension VoiceSpeakerCheck {
    static var rewriteSmoke: VoiceSpeakerCheck { VoiceSpeakerCheck(embedder: RewriteSmokeSpeaker(), calibratedThreshold: 0.45) }
}
#endif
