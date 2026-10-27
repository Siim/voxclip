import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import VoxClipCore

/// Builds inputs from shared/fixtures/voice-lab/request-cases.json and reads requests as its README describes.
enum VoiceLabRequestFixtures {
    struct Part: Equatable {
        let headers: [String]
        let body: Data
    }

    static func document() throws -> [String: Any] {
        let document = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/voice-lab/request-cases.json")) as? [String: Any])
        #expect(document["schema"] as? String == "voxclip-voice-lab-requests/1")
        return document
    }
    static func wav(rate: Int, frames: Int, fill: Int = 0, junkBytes: Int = 0, channels: Int = 1) -> Data {
        func le(_ value: Int, _ width: Int) -> [UInt8] { (0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
        var bytes = Array("RIFF".utf8) + le(0, 4) + Array("WAVE".utf8)
        if junkBytes > 0 { bytes += Array("JUNK".utf8) + le(junkBytes, 4) + [UInt8](repeating: 0, count: junkBytes + junkBytes % 2) }
        bytes += Array("fmt ".utf8) + le(16, 4) + le(1, 2) + le(channels, 2) + le(rate, 4) + le(rate * 2, 4) + le(2, 2) + le(16, 2)
        bytes += Array("data".utf8) + le(frames * 2, 4)
        if fill == 0 { bytes += [UInt8](repeating: 0, count: frames * 2) }
        else {
            let sample = le(fill, 2)
            bytes.reserveCapacity(bytes.count + frames * 2)
            for _ in 0..<frames { bytes.append(sample[0]); bytes.append(sample[1]) }
        }
        bytes.replaceSubrange(4..<8, with: le(bytes.count - 8, 4))
        return Data(bytes)
    }
    static func wav(_ spec: [String: Any]) throws -> Data {
        wav(rate: try #require(spec["rate"] as? Int), frames: try #require(spec["frames"] as? Int), fill: spec["fill"] as? Int ?? 0,
            junkBytes: spec["junkBytes"] as? Int ?? 0, channels: spec["mutation"] as? String == "stereo" ? 2 : 1)
    }
    static func date(_ text: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try #require(formatter.date(from: text))
    }
    static func cloneRequest(_ input: [String: Any], defaults: [String: Any] = [:]) throws -> VoiceLabCloneRequest {
        func value<T>(_ key: String) throws -> T { try #require((input[key] ?? defaults[key]) as? T) }
        var samples: [VoiceLabCloneSample] = []
        for spec in try #require(input["samples"] as? [[String: Any]]) {
            let raw = try #require(spec["role"] as? String)
            let role = try #require(VoiceLabCloneSampleRole(rawValue: raw))
            samples += Array(repeating: VoiceLabCloneSample(role: role, wav: try wav(spec)), count: spec["count"] as? Int ?? 1)
        }
        return VoiceLabCloneRequest(displayName: try value("displayName"), language: try value("language"), samples: samples,
                                    createdAt: try date(try value("createdAt")), removeBackgroundNoise: try value("removeBackgroundNoise"))
    }
    /// URLProtocol may present an upload as a stream rather than `httpBody`.
    static func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try #require(request.httpBodyStream)
        stream.open(); defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { return body }
            body.append(contentsOf: buffer.prefix(count))
        }
    }
    /// Splits a multipart body at the given boundary; each part keeps its raw header lines in order.
    static func parts(_ body: Data, boundary: String) throws -> [Part] {
        let lineBreak = Data("\r\n".utf8), delimiter = Data("--\(boundary)".utf8)
        try #require(body.starts(with: delimiter + lineBreak))
        var cursor = body.startIndex + delimiter.count + lineBreak.count
        var parts: [Part] = []
        while true {
            let end = try #require(body.range(of: lineBreak + delimiter, in: cursor..<body.endIndex))
            let part = body[cursor..<end.lowerBound]
            let split = try #require(part.range(of: lineBreak + lineBreak))
            let headers = String(decoding: part[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            parts.append(Part(headers: headers, body: Data(part[split.upperBound...])))
            cursor = end.upperBound
            if body[cursor...].starts(with: Data("--".utf8)) { return parts }
            cursor += lineBreak.count
        }
    }
}

struct RecordedRequest: Sendable {
    let request: URLRequest
    let body: Data
}

final class RequestRecorder: Sendable {
    let paid = Mutex<[RecordedRequest]>([])
}

@Suite("Voice Lab request cases", .timeLimit(.minutes(1)))
struct VoiceLabRequestCaseTests {
    private let key = "synthetic-voice-lab-key"
    private let createPolicy = OwnVoicePolicy(recordID: "record-1", recordActive: true, providerConsentGranted: true, statementVerified: true, speakerMatched: true)

    private enum Call {
        case clone(VoiceLabCloneRequest)
        case speech(text: String, model: String, voice: String, language: String, options: VoiceLabSpeechOptions)
        case conversion(audio: Data, model: String, voice: String, language: String, seed: UInt32, cleanAudioOn: Bool)
    }

    /// Serves the shared discovery replies, records each paid request, and answers it with a valid synthetic reply.
    /// The lab uses the shared multipart boundary, so whole request bodies can be compared.
    private func recordingService(_ document: [String: Any]) async throws -> (ElevenLabsVoiceLab, RequestRecorder) {
        let boundary = try #require(document["multipartBoundary"] as? String)
        let discovery = try #require(document["discovery"] as? [String: Any])
        let models = try JSONSerialization.data(withJSONObject: try #require(discovery["models"]))
        let voices = try JSONSerialization.data(withJSONObject: try #require(discovery["voices"]))
        let subscription = try JSONSerialization.data(withJSONObject: try #require(discovery["subscription"]))
        let recorder = RequestRecorder()
        let base = SpeechStubHTTP.register { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/v1/models": return (200, [:], models)
            case "/v2/voices": return (200, [:], voices)
            case "/v1/user/subscription": return (200, [:], subscription)
            default: break
            }
            let body = try VoiceLabRequestFixtures.body(request)
            recorder.paid.withLock { $0.append(RecordedRequest(request: request, body: body)) }
            if path == "/v1/voices/add" { return (200, [:], Data("{\"voice_id\":\"created123\",\"requires_verification\":false}".utf8)) }
            if path.hasPrefix("/v1/voice-changer/") { return (200, ["Content-Type": "application/octet-stream"], Data(count: 4_800)) }
            let text = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["text"] as? String ?? ""
            let alignment: [String: Any] = ["characters": [text], "character_start_times_seconds": [0], "character_end_times_seconds": [0.05]]
            return (200, ["Content-Type": "application/json"], try JSONSerialization.data(withJSONObject: [
                "audio_base64": Data(count: 4_800).base64EncodedString(), "alignment": alignment] as [String: Any]))
        }
        let lab = ElevenLabsVoiceLab(keys: SpeechTestKeys(value: key), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)),
                                     region: .default, logger: SpeechTestLogger())
        await lab.useMultipartBoundary(boundary)
        return (lab, recorder)
    }
    private func discover(_ lab: ElevenLabsVoiceLab) async throws {
        _ = try await lab.models(); _ = try await lab.voices(); _ = try await lab.plan()
    }
    /// Builds a call from a case input, with an optional quote mutation row applied.
    private func makeCall(_ operation: String, _ source: [String: Any], mutation: [String: Any] = [:]) throws -> Call {
        var input = source
        let field = mutation["field"] as? String ?? "same"
        if let value = mutation["value"] { input[field] = value }
        func text(_ key: String) throws -> String { try #require(input[key] as? String) }
        func seed() throws -> UInt32 {
            let value = try #require(input["seed"] as? Int)
            return try #require(UInt32(exactly: value))
        }
        switch operation {
        case "createClone":
            var specs = try #require(input["samples"] as? [[String: Any]])
            if let swap = mutation["swap"] as? [Int], field == "sampleOrder" { specs.swapAt(swap[0], swap[1]) }
            if let swap = mutation["swap"] as? [Int], field == "sampleRole" {
                let role = specs[swap[0]]["role"]
                specs[swap[0]]["role"] = specs[swap[1]]["role"]
                specs[swap[1]]["role"] = role
            }
            input["samples"] = specs
            var request = try VoiceLabRequestFixtures.cloneRequest(input)
            if field == "sampleByte", let index = mutation["index"] as? Int {
                var samples = request.samples, wav = samples[index].wav
                wav[wav.index(before: wav.endIndex)] ^= 1
                samples[index] = VoiceLabCloneSample(role: samples[index].role, wav: wav)
                request = VoiceLabCloneRequest(displayName: request.displayName, language: request.language, samples: samples,
                                               createdAt: request.createdAt, removeBackgroundNoise: request.removeBackgroundNoise)
            }
            return .clone(request)
        case "textToSpeech":
            return .speech(text: try text("text"), model: try text("modelId"), voice: try text("voiceId"), language: try text("language"),
                           options: VoiceLabSpeechOptions(seed: try seed(), previousText: input["previousText"] as? String,
                                                          nextText: input["nextText"] as? String))
        default:
            let audio = try #require(input["audio"] as? [String: Any])
            return .conversion(audio: try VoiceLabRequestFixtures.wav(audio), model: try text("modelId"), voice: try text("voiceId"),
                               language: try text("language"), seed: try seed(), cleanAudioOn: try #require(input["cleanAudioOn"] as? Bool))
        }
    }
    private func prepare(_ call: Call, on lab: ElevenLabsVoiceLab, requestID: UUID) async throws -> VoiceLabQuote {
        switch call {
        case .clone(let request):
            return try await lab.prepareClone(request, policy: createPolicy, requestID: requestID)
        case .speech(let text, let model, let voice, let language, let options):
            return try await lab.prepareSynthesis(text: text, modelID: model, voice: .stock(voiceID: voice), language: language,
                                                  options: options, requestID: requestID)
        case .conversion(let audio, let model, let voice, let language, let seed, let cleanAudioOn):
            return try await lab.prepareConversion(audio: audio, modelID: model, voice: .stock(voiceID: voice), language: language,
                                                   seed: seed, cleanAudioOn: cleanAudioOn, requestID: requestID)
        }
    }
    private func dispatch(_ call: Call, on lab: ElevenLabsVoiceLab, requestID: UUID, quote: VoiceLabQuote) async throws {
        let authorization = VoiceLabAuthorization(quote: quote, approved: true)
        switch call {
        case .clone(let request):
            _ = try await lab.createOwnClone(request, policy: createPolicy, requestID: requestID, authorization: authorization)
        case .speech(let text, let model, let voice, let language, let options):
            _ = try await lab.synthesize(text: text, modelID: model, voice: .stock(voiceID: voice), language: language, options: options,
                                         requestID: requestID, authorization: authorization)
        case .conversion(let audio, let model, let voice, let language, let seed, let cleanAudioOn):
            _ = try await lab.convert(audio: audio, modelID: model, voice: .stock(voiceID: voice), language: language, seed: seed,
                                      cleanAudioOn: cleanAudioOn, requestID: requestID, authorization: authorization)
        }
    }
    private func compare(_ recorded: RecordedRequest, with expected: [String: Any], boundary: String, _ name: String) throws {
        let request = recorded.request, url = try #require(request.url)
        #expect(request.httpMethod == expected["method"] as? String, "\(name)")
        #expect(url.path == expected["path"] as? String, "\(name)")
        let query = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        #expect(Dictionary(uniqueKeysWithValues: query) == expected["query"] as? [String: String], "\(name)")
        for (field, value) in try #require(expected["headers"] as? [String: String]) {
            let actual = request.value(forHTTPHeaderField: field)
            if field == "xi-api-key" { #expect(actual == key && value == "[REDACTED]", "\(name)") }
            else { #expect(actual == value, "\(name) \(field)") }
        }
        if let json = expected["json"] as? NSDictionary {
            #expect(try JSONSerialization.jsonObject(with: recorded.body) as? NSDictionary == json, "\(name)")
            return
        }
        // The whole body must match byte for byte; the parts show where a difference is.
        #expect(recorded.body.count == expected["bodyLength"] as? Int, "\(name) body length")
        #expect(SHA256.hash(data: recorded.body).map { String(format: "%02x", $0) }.joined() == expected["bodySha256"] as? String, "\(name) body")
        let parts = try VoiceLabRequestFixtures.parts(recorded.body, boundary: boundary)
        let wanted = try #require(expected["multipart"] as? [[String: Any]])
        #expect(parts.count == wanted.count, "\(name)")
        for (index, (part, want)) in zip(parts, wanted).enumerated() {
            let label = "\(name) part \(index)"
            #expect(part.headers == want["headers"] as? [String], "\(label)")
            if let value = want["value"] as? String { #expect(part.body == Data(value.utf8), "\(label)") }
            else { #expect(SHA256.hash(data: part.body).map { String(format: "%02x", $0) }.joined() == want["sha256"] as? String, "\(label)") }
        }
    }

    @Test func requestGoldensMatchSharedCases() async throws {
        let document = try VoiceLabRequestFixtures.document()
        let cases = try #require(document["cases"] as? [[String: Any]])
        let boundary = try #require(document["multipartBoundary"] as? String)
        #expect(cases.count == 21)
        for row in cases {
            let name = try #require(row["case"] as? String), operation = try #require(row["operation"] as? String)
            let (lab, recorder) = try await recordingService(document)
            try await discover(lab)
            let call = try makeCall(operation, try #require(row["input"] as? [String: Any]))
            let id = UUID()
            try await dispatch(call, on: lab, requestID: id, quote: try await prepare(call, on: lab, requestID: id))
            let paid = recorder.paid.withLock { $0 }
            try #require(paid.count == 1, "\(name)")
            try compare(paid[0], with: try #require(row["request"] as? [String: Any]), boundary: boundary, name)
        }
    }

    @Test func quoteMutationsBindNewFields() async throws {
        let document = try VoiceLabRequestFixtures.document()
        let cases = try #require(document["cases"] as? [[String: Any]])
        let rows = try #require(document["quoteMutations"] as? [[String: Any]])
        #expect(rows.count == 18)
        for row in rows {
            let name = try #require(row["case"] as? String), allowed = try #require(row["allowed"] as? Bool)
            let invalid = row["error"] as? String == "invalidInput"
            let base = try #require(cases.first { $0["case"] as? String == row["base"] as? String })
            let operation = try #require(base["operation"] as? String), input = try #require(base["input"] as? [String: Any])
            let (lab, recorder) = try await recordingService(document)
            try await discover(lab)
            let id = UUID()
            let quote = try await prepare(try makeCall(operation, input), on: lab, requestID: id)
            do {
                try await dispatch(try makeCall(operation, input, mutation: row), on: lab, requestID: id, quote: quote)
                #expect(allowed, "\(name)")
            } catch VoiceLabError.consentRequired { #expect(!allowed && !invalid, "\(name)") }
            catch VoiceLabError.invalidInput { #expect(!allowed && invalid, "\(name)") }
            #expect(recorder.paid.withLock { $0.count } == (allowed ? 1 : 0), "\(name)")
        }
    }

    @Test func cloneInputsFollowSharedTable() async throws {
        let document = try VoiceLabRequestFixtures.document()
        let defaults = try #require(document["cloneDefaults"] as? [String: Any])
        let rows = try #require(document["cloneInputs"] as? [[String: Any]])
        #expect(rows.count == 42)
        let (lab, recorder) = try await recordingService(document)
        try await discover(lab)
        for row in rows {
            let name = try #require(row["case"] as? String), valid = try #require(row["valid"] as? Bool)
            let request = try VoiceLabRequestFixtures.cloneRequest(row, defaults: defaults)
            do { _ = try await lab.prepareClone(request, policy: createPolicy, requestID: UUID()); #expect(valid, "\(name)") }
            catch VoiceLabError.invalidInput { #expect(!valid, "\(name)") }
        }
        #expect(recorder.paid.withLock { $0.count } == 0)
    }

    /// Display names and §8.5 context trim with `properties.isWhitespace`, which must be exactly the shared White_Space list.
    @Test func whiteSpaceMatchesSharedList() throws {
        let document = try VoiceLabRequestFixtures.document()
        let shared = try #require(document["whiteSpace"] as? [Int])
        #expect(shared.count == 25)
        let platform = (UInt32(0)...0x10FFFF).filter { Unicode.Scalar($0)?.properties.isWhitespace == true }.map(Int.init)
        #expect(platform == shared)
    }

    /// Display names refuse General Category Cc, which Unicode fixes as U+0000–U+001F and U+007F–U+009F.
    @Test func controlCharactersAreGeneralCategoryCc() {
        let platform = (UInt32(0)...0x10FFFF).filter { Unicode.Scalar($0)?.properties.generalCategory == .control }
        #expect(platform == Array(UInt32(0x00)...0x1F) + Array(UInt32(0x7F)...0x9F))
    }
}
