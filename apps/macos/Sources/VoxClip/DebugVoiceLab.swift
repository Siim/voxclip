#if DEBUG
import Foundation
import VoxClipCore

@MainActor enum DebugVoiceLab {
    static func run(app: AppModel) async throws -> [DebugUISuite.Result] {
        let original = app.settings
        defer { app.settings = original }
        app.settings.values["voiceLab.enabled"] = .bool(false)
        let session = VoiceLabSession(app: app)
        let off = !session.enabled && !session.canRecord && !session.canCreate
        session.request(.subscription)
        let offRequest = session.confirmation == nil
        app.settings.values["voiceLab.enabled"] = .bool(true)
        let noVoice = session.records.isEmpty && session.planMessage != nil && !session.canCreate
        session.displayName = "Example"
        let missingAttestations = !session.canRecord
        session.ownVoice = true; session.adult = true; session.ownVideosOnly = true
        let ready = session.canRecord
        session.busy = true
        session.request(.verify)
        let busy = !session.canRecord && session.confirmation == nil
        session.busy = false
        session.request(.verify)
        let confirmation = session.confirmation == .verify && !session.verified
        session.confirmation = nil
        session.displayName = String(repeating: "o\u{303}", count: 31)
        let scalarLimit = !session.canRecord
        session.verified = true; session.trainingReady = true
        await session.prepareCreation()
        let unavailable = session.confirmation == nil && session.message == VoiceConsentError.speakerUnavailable.localizedDescription
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
            .init(name: "Voice Lab Release off has no Settings entry", passed: !VoiceLabGate.settingsVisible(enabled: false, internalBuild: false)),
            .init(name: "Voice Lab no-voice Settings state", passed: noVoice),
            .init(name: "Voice Lab requires all attestations", passed: missingAttestations && ready),
            .init(name: "Voice Lab busy state disables actions", passed: busy),
            .init(name: "Voice Lab verification waits for explicit approval", passed: confirmation),
            .init(name: "Voice Lab display name uses Unicode scalars", passed: scalarLimit),
            .init(name: "Voice Lab refuses uncalibrated enrollment", passed: unavailable),
            .init(name: "Voice Lab active and pending voice states", passed: active && pending),
            .init(name: "Voice Lab provider Keychain accounts", passed: accounts),
            .init(name: "Voice Lab label position settings", passed: position),
            .init(name: "Voice Lab consent copy contains account training notice", passed: VoiceLabSession.noticeCopy.contains("not retroactive") && VoiceLabSession.providerCopy.contains("traced to your account"))
        ]
    }
}
#endif
