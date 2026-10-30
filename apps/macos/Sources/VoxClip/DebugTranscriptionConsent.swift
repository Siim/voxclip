#if DEBUG
import AppKit
import Foundation
import SwiftUI
import Synchronization
import VoxClipCore
import VoxClipMedia

private actor TranscriptionConsentSettings: SettingsStore {
    private var document = SettingsDocument()
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
        let actions = DebugButtonActions()
        DebugButtonActions.current = actions
        defer { DebugButtonActions.current = nil }
        var sheet = TranscriptionSheet(model: editor, scribeSession: session)
        sheet.inlineConsentForAudit = true
        let controller = NSHostingController(rootView: sheet)
        controller.sizingOptions = []
        let host = controller.view
        host.frame = CGRect(x: 0, y: 0, width: 560, height: 1000)
        let settingsController = NSHostingController(rootView: ProviderKeyRow(provider: "elevenlabs", label: "ElevenLabs", app: app))
        settingsController.sizingOptions = []
        let settings = settingsController.view
        settings.frame = CGRect(x: 0, y: 0, width: 720, height: 300)
        await settle(host)
        await settle(settings)
        var results: [DebugUISuite.Result] = []
        try actions.press("transcription.start")
        await settle(host)
        results.append(.init(name: "real Transcribe action opens consent without a Scribe request", passed:
            requests.isEmpty && actions.entries["transcription.consent.continue"] != nil && editor.project.transcript == nil))
        guard actions.entries["transcription.consent.cancel"] != nil else { return results }
        try actions.press("transcription.consent.cancel")
        await settle(host)
        results.append(.init(name: "real consent Cancel leaves Not transcribed and never uploads", passed:
            requests.isEmpty && editor.project == input && SidebarStyle.fullTakeMeta(editor) == "Not transcribed" && !app.bool("transcription.cloudConsent.elevenlabs")))

        try actions.press("provider.elevenlabs.test")
        for _ in 0..<100 {
            if !requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        await settle(settings)
        results.append(.init(name: "real Settings Test uses account-only request without transcription consent", passed:
            requests == ["GET /v1/user/subscription"] && !app.bool("transcription.cloudConsent.elevenlabs") && editor.project.transcript == nil))

        try actions.press("transcription.start")
        await settle(host)
        results.append(.init(name: "repeated real Transcribe still waits for Continue", passed:
            requests == ["GET /v1/user/subscription"] && actions.entries["transcription.consent.continue"] != nil))
        try actions.press("transcription.consent.continue")
        for _ in 0..<500 {
            if editor.project.transcript != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        await editor.workTask?.value
        results.append(.init(name: "real Continue runs extraction, Scribe transport and transcript import exactly once", passed:
            requests.filter { $0 == "POST /v1/speech-to-text" }.count == 1 && editor.project.transcript?.words.first?.text == "Hello" && app.bool("transcription.cloudConsent.elevenlabs")))
        await app.flushSettings()
        let reopened = AppModel(settingsStore: store)
        await reopened.start()
        results.append(.init(name: "real Continue persists consent across AppModel restart", passed:
            reopened.bool("transcription.cloudConsent.elevenlabs")))
        results.append(.init(name: "consent integration hosts remain window-free", passed: host.window == nil && settings.window == nil))
        return results
    }

    private static var requests: [String] { ConsentScribeProtocol.requests.withLock { $0 } }
    private static func settle(_ host: NSView) async {
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
#endif
