#if DEBUG
import Foundation
import VoxClipCore
import VoxClipMedia

private actor VoiceLabNoDispatchKeys: KeyProvider {
    private(set) var requests = 0
    func key(for provider: String) -> String? { requests += 1; return nil }
}

@MainActor enum DebugVoiceLab {
    static func run(app: AppModel) async throws -> [DebugUISuite.Result] {
        let original = app.settings
        let originalModel = app.speakerModelLibrary.model
        let originalInstalled = app.speakerModelLibrary.installed
        defer {
            app.settings = original
            app.speakerModelLibrary.model = originalModel
            app.speakerModelLibrary.installed = originalInstalled
        }
        app.settings.values["voiceLab.enabled"] = .bool(false)
        let session = VoiceLabSession(app: app)
        let off = !session.enabled && !session.canRecord && !session.canCreate
        session.request(.subscription)
        let offRequest = session.confirmation == nil
        app.settings.values["voiceLab.enabled"] = .bool(true)
        let noVoice = session.records.isEmpty && session.planMessage != nil && !session.canCreate
        session.displayName = "Example"
        session.statement = VoiceConsentStatement(language: "en", text: "Offline statement fixture", nonce: [])
        app.speakerModelLibrary.model = try SpeakerModelCatalog(shared: SharedResources.locate()).entry
        app.speakerModelLibrary.installed = true
        let attestationStates = (0..<8).map { bits in
            session.ownVoice = bits & 1 != 0
            session.adult = bits & 2 != 0
            session.ownVideosOnly = bits & 4 != 0
            return session.canRecord
        }
        session.busy = true
        session.request(.verify)
        let busy = !session.canRecord && session.confirmation == nil
        session.busy = false
        let verification = try await verificationApproval(session: session)
        session.confirmation = nil
        session.displayName = String(repeating: "o\u{303}", count: 31)
        let scalarLimit = !session.canRecord
        session.verified = true; session.trainingReady = true
        app.speakerModelLibrary.installed = false
        session.message = nil
        session.request(.create)
        await session.prepareCreation()
        let unavailable = !session.canCreate && session.confirmation == nil && session.message == VoiceConsentError.speakerUnavailable.localizedDescription
        let shared = try SharedResources.locate()
        var record = try JSONDecoder().decode(VoiceConsentRecord.self, from: Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record.json")))
        session.records = [record]
        let active = session.records.first?.status == .active
        record.status = .verificationRequired; session.records = [record]
        let pending = session.records.first?.status == .verificationRequired
        let accounts = SecretStore.account(for: "fal") == "fal-api-key" && SecretStore.account(for: "syncso") == "syncso-api-key" && SecretStore.account(for: "elevenlabs") == "elevenlabs-api-key"
        app.settings.values["voiceLab.labelPosition"] = .string("bottom-left")
        let position = app.voiceLabLabelPosition == .bottomLeft
        return [
            .init(name: "Voice Lab beta off refuses all actions", passed: off && offRequest),
            .init(name: "Voice Lab Settings stays discoverable with beta off", passed: VoiceLabGate.settingsVisible(enabled: false, internalBuild: false)),
            .init(name: "Voice Lab no-voice Settings state", passed: noVoice),
            .equal("Voice Lab requires all attestations (ownVoice/adult/ownVideosOnly bit masks 0...7)", expected: [false, false, false, false, false, false, false, true], actual: attestationStates),
            .init(name: "Voice Lab busy state disables actions", passed: busy),
            verification,
            .init(name: "Voice Lab display name uses Unicode scalars", passed: scalarLimit),
            .init(name: "Voice Lab refuses uncalibrated enrollment", passed: unavailable),
            .init(name: "Voice Lab active and pending voice states", passed: active && pending),
            .init(name: "Voice Lab provider Keychain accounts", passed: accounts),
            .init(name: "Voice Lab label position settings", passed: position),
            .init(name: "Voice Lab consent copy contains account training notice", passed: VoiceLabSession.noticeCopy.contains("not retroactive") && VoiceLabSession.providerCopy.contains("traced to your account"))
        ]
    }
    static func verificationApproval(session: VoiceLabSession) async throws -> DebugUISuite.Result {
        let keys = VoiceLabNoDispatchKeys()
        let client = ElevenLabsVoiceLab(keys: keys, region: .default)
        let statement = VoiceConsentStatement(language: "en", text: "Offline statement fixture", nonce: [])
        let wav = try VoiceTrainingAudio.wav([Float](repeating: 0.1, count: 16_000), rate: 16_000)
        session.stageVerificationForTests(statement: statement, wav: wav, client: client)
        let preparation = session.request(.verify)
        var actual = ["preparation task": preparation != nil, "busy before": session.busy,
            "confirmation before": session.confirmation != nil, "verified before": session.verified]
        await preparation?.value
        let requests = await keys.requests
        actual["busy after"] = session.busy
        actual["Verify confirmation after"] = session.confirmation == .verify
        actual["verified after"] = session.verified
        actual["credential requested"] = requests != 0
        return .equal("Voice Lab verification waits for explicit approval", expected: [
            "preparation task": true, "busy before": true, "confirmation before": false, "verified before": false,
            "busy after": false, "Verify confirmation after": true, "verified after": false, "credential requested": false
        ], actual: actual)
    }
}
#endif
