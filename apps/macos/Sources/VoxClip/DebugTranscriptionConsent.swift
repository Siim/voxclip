#if DEBUG
import AppKit
import Foundation
import SwiftUI
import Synchronization
import VoxClipCore
import VoxClipMedia

private actor TranscriptionConsentSettings: SettingsStore {
    private var document = SettingsDocument(values: ["update.autoCheck": .bool(false)])
    func load() -> SettingsDocument { document }
    func save(_ settings: SettingsDocument) { document = settings }
    func flush() {}
}

private final class ConsentScribeProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[String]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.host == "api.elevenlabs.io",
              ["/v1/user/subscription", "/v1/speech-to-text"].contains(url.path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        Self.requests.withLock { $0.append("\(request.httpMethod ?? "GET") \(url.path)") }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        let json = url.path == "/v1/user/subscription" ? "{}" : #"{"language_code":"en","language_probability":1,"words":[{"text":"Hello","start":0.1,"end":0.3,"type":"word","logprob":0}]}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor enum DebugTranscriptionConsent {
    static func run(fixture: Project) async throws -> [DebugUISuite.Result] {
        guard ProcessInfo.processInfo.environment["VOXCLIP_NO_KEYCHAIN"] == "1" else { throw CocoaError(.featureUnsupported) }
        setenv("VOXCLIP_ELEVENLABS_API_KEY", "consent-fixture", 1)
        defer { unsetenv("VOXCLIP_ELEVENLABS_API_KEY") }
        ConsentScribeProtocol.requests.withLock { $0.removeAll() }
        let configuration = KeyedNetwork.configuration()
        configuration.protocolClasses = [ConsentScribeProtocol.self]
        let session = URLSession(configuration: configuration)
        KeyedNetwork.auditSession.withLock { $0 = session }
        defer { KeyedNetwork.auditSession.withLock { $0 = nil }; session.invalidateAndCancel() }
        let store = TranscriptionConsentSettings()
        let app = AppModel(settingsStore: store)
        await app.start()
        app.set("transcription.engineMode", .string("elevenlabs"))
        app.set("transcription.language", .string("en"))
        var input = fixture
        input.transcript = nil
        guard let shared = app.shared else { throw VoxClipError.sharedResourcesMissing }
        let source = shared.root.appendingPathComponent("fixtures/media/fillers-chirp.mp4")
        let media = try await AVMediaProbe().probe(source)
        input.media.source.absolutePath = source.path
        input.media.source.durationSeconds = media.durationSeconds
        input.media.source.contentKey = SpeechSHA256.hex(Data(UUID().uuidString.utf8))
        input.edits = ProjectEdits()
        let editor = EditorModel(document: VoxClipDocument(project: input, demo: true), app: app, preview: DemoPreviewEngine())
        defer { editor.close() }
        let flow = editor.transcription
        flow.scribeSession = session
        await flow.open()
        var results: [DebugUISuite.Result] = []
        results.append(.init(name: "inline ElevenLabs waits for a priced click", passed: editor.window == nil && requests.isEmpty && flow.canStart && flow.primaryTitle.contains("Upload and Transcribe") && flow.primaryTitle.contains("$")))
        flow.notNow()
        results.append(.init(name: "Not now keeps video and stores no consent", passed: requests.isEmpty && editor.project == input && !app.bool("transcription.cloudConsent.elevenlabs")))
        let keyTest = await testSpeechKey(app: app)
        results.append(.init(name: "Settings Test uses only the account endpoint and stores no transcription consent", passed: keyTest == "Works." && requests == ["GET /v1/user/subscription"] && !app.bool("transcription.cloudConsent.elevenlabs")))
        await flow.open()
        flow.activate()
        await editor.workTask?.value
        results.append(.init(name: "priced click transcribes through the stub transport and stores consent", passed: requests.filter { $0 == "POST /v1/speech-to-text" }.count == 1 && editor.project.transcript?.words.first?.text == "Hello" && app.bool("transcription.cloudConsent.elevenlabs")))
        await app.flushSettings()
        let reopened = AppModel(settingsStore: store)
        await reopened.start()
        results.append(.init(name: "the priced click persists privacy consent across AppModel restart", passed: reopened.bool("transcription.cloudConsent.elevenlabs")))
        let sent = requests.count
        await flow.open(again: true)
        results.append(.init(name: "stored consent never bypasses another priced click", passed: requests.count == sent && !flow.isRunning))
        let spend = await app.transcriptionSpend.total()
        flow.activate()
        await editor.workTask?.value
        let afterCache = await app.transcriptionSpend.total()
        results.append(.init(name: "approved cached transcription makes no new request or charge", passed: requests.count == sent && afterCache.amount == spend.amount && flow.completion?.contains("no charge") == true))
        return results
    }

    private static var requests: [String] { ConsentScribeProtocol.requests.withLock { $0 } }
}
#endif
