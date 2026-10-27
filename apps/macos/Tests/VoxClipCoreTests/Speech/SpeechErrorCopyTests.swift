import Foundation
import Testing
@testable import VoxClipCore

@Suite("Speech error copy", .timeLimit(.minutes(1)))
struct SpeechErrorCopyTests {
    @Test(arguments: [
        (VoxClipError.modelMissing("Whisper Small English", size: "59.24 MB"), "Download the Whisper Small English model (59.24 MB) to transcribe on this Mac."),
        (.modelChecksumMismatch("model.bin"), "model.bin did not match its checksum. Try the download again."),
        (.keyMissing("elevenlabs"), "Add your ElevenLabs key in Settings to use it."),
        (.keyRejected("ElevenLabs", status: 401), "ElevenLabs rejected the key (401). Your video is still here."),
        (.keyPermissionMissing, "This ElevenLabs key can't use speech to text. Allow the speech_to_text permission for the key on elevenlabs.io."),
        (.quotaExceeded("ElevenLabs"), "Your ElevenLabs credits or key quota are used up."),
        (.rateLimited("elevenlabs"), "ElevenLabs is busy. Try again in a minute."),
        (.mediaTooLong("10:00:01"), "ElevenLabs accepts up to 10 hours. This take is 10:00:01."),
        (.transcriptionLanguageUnsupported("Whisper", language: "et"), "Whisper can't transcribe et."),
        (.speechAssetsUnavailable("en-US", reason: "installation failed"), "macOS couldn't install its en-US speech model: installation failed."),
        (.transcriptionFailed("decode failed (7)"), "Transcription stopped: decode failed (7). Your video is still here."),
        (.providerError("unexpected response shape", provider: "ElevenLabs", status: 200), "ElevenLabs answered 200: unexpected response shape"),
        (.diskFull("/Volumes/Media", size: "1.5 GB"), "There isn't enough free space on /Volumes/Media. Free up 1.5 GB and try again.")
    ])
    func exactSpeechTemplatesAndParameterRoundTrip(_ error: VoxClipError, _ expected: String) throws {
        #expect(error.errorDescription == expected)
        let decoded = try JSONDecoder().decode(VoxClipError.self, from: JSONEncoder().encode(error))
        #expect(decoded == error)
        #expect(decoded.errorDescription == expected)
    }

    @Test(arguments: [
        (VoxClipError.unsupportedContainer("mkv"), "unsupportedContainer: mkv. Your video and edits are unchanged."),
        (.decodeFailed("codec"), "decodeFailed: codec. Your video and edits are unchanged."),
        (.keyMissing("Anthropic"), "keyMissing: Anthropic. Your video and edits are unchanged."),
        (.keyRejected("OpenAI"), "keyRejected: OpenAI. Your video and edits are unchanged."),
        (.quotaExceeded("Google"), "quotaExceeded: Google. Your video and edits are unchanged."),
        (.rateLimited("xAI"), "rateLimited: xAI. Your video and edits are unchanged."),
        (.providerError("Unexpected failure"), "providerError: Unexpected failure. Your video and edits are unchanged."),
        (.providerError("Invalid response", provider: "ElevenLabs"), "providerError: Invalid response. Your video and edits are unchanged."),
        (.diskFull("Export"), "diskFull: Export. Your video and edits are unchanged."),
        (.exportFailed("encoder"), "exportFailed: encoder. Your video and edits are unchanged.")
    ])
    func otherDomainCopyIsUnchanged(_ error: VoxClipError, _ expected: String) {
        #expect(error.errorDescription == expected)
    }

    @Test(arguments: [(0.0, "0:00:00"), (59.9, "0:00:59"), (3600.0, "1:00:00"), (36001.0, "10:00:01"), (3723.9, "1:02:03")])
    func durationMatchesWindows(_ seconds: Double, _ expected: String) {
        #expect(SpeechErrorCopy.duration(seconds) == expected)
    }

    @Test(arguments: [(1.0, "1 bytes"), (999999.1, "1000000 bytes"), (1000000.0, "1 MB"), (59240000.0, "59.24 MB"), (1500000000.0, "1.5 GB")])
    func sizeMatchesWindows(_ bytes: Double, _ expected: String) {
        #expect(SpeechErrorCopy.bytes(bytes) == expected)
    }

    @Test(arguments: [(401, "invalid", "ElevenLabs rejected the key (401). Your video is still here."),
                      (403, "denied", "This ElevenLabs key can't use speech to text. Allow the speech_to_text permission for the key on elevenlabs.io."),
                      (429, "busy", "ElevenLabs is busy. Try again in a minute."),
                      (400, "credit quota", "Your ElevenLabs credits or key quota are used up."),
                      (422, #"{"detail":[{"msg":"invalid synthetic-key"}]}"#, "ElevenLabs answered 422: invalid [REDACTED]"),
                      (500, #"{"detail":"Please try again"}"#, "ElevenLabs answered 500: Please try again"),
                      (400, "invalid", "ElevenLabs answered 400: The request could not be completed.")])
    func providerCopyUsesStatusAndRedactedDetail(_ status: Int, _ body: String, _ expected: String) {
        #expect(ElevenLabsTranscriber.providerError(status: status, data: Data(body.utf8), key: "synthetic-key").errorDescription == expected)
    }

    @Test func malformedSuccessAndUploadSizeCarryExactCopy() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: "synthetic-key"), session: URLSession(configuration: SpeechStubHTTP.configuration()), catalog: try SpeechTestFiles.catalog())
        do { _ = try await engine.mapResponse(Data("{}".utf8), diarize: false); Issue.record("Expected malformed response") }
        catch let error as VoxClipError { #expect(error.errorDescription == "ElevenLabs answered 200: unexpected response shape") }
        var request = try SpeechTestFiles.request(root)
        request.audio.durationSeconds = 3723.9
        let output = try FileHandle(forWritingTo: request.audio.wav16k)
        try output.truncate(atOffset: 3_000_000_001)
        try output.close()
        do { _ = try await engine.transcribe(request) { _ in }; Issue.record("Expected upload size limit") }
        catch let error as VoxClipError { #expect(error.errorDescription == "ElevenLabs accepts up to 10 hours. This take is 1:02:03.") }
    }
}
