#if DEBUG
import Foundation
import SwiftUI
import AppKit
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
        app.settings.values["transcription.elevenlabs.region"] = .string("default")
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
        session.request(.subscription)
        let busy = !session.canRecord && session.confirmation == nil
        session.busy = false
        session.confirmation = nil
        let verification = try await localPlanApproval(session: session)
        session.confirmation = nil
        session.displayName = String(repeating: "o\u{303}", count: 31)
        let scalarLimit = !session.canRecord
        session.trainingReady = true
        app.speakerModelLibrary.installed = false
        session.message = nil

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
        session.flow.state = .firstUse
        let v0 = session.flow.state.rawValue == "V0" && !session.flow.keyReady
        session.flow.state = .agree
        let v1 = session.flow.state.rawValue == "V1"
        session.flow.state = .statement
        let v2 = session.flow.state.rawValue == "V2" && !session.recorder.recording
        let scenes = stateScenes(session: session)
        return scenes + [
            .init(name: "Voice job V0 key, V1 agreements and V2 inline recording states", passed: v0 && v1 && v2),
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
    /// Offscreen SwiftUI scenes: no windows, microphone, model download or provider task.
    static func stateScenes(session: VoiceLabSession) -> [DebugUISuite.Result] {
        let original = session.flow.state
        let wasBusy = session.busy
        defer { session.flow.state = original; session.busy = wasBusy }
        let headlines = ["Your voice", "Find your clear speech and agree", "Read the statement aloud", "Checking it's you…", "Ready to create your voice", "Creating your voice…", "Your voice is ready."]
        return VoiceEnrollmentFlow.State.allCases.enumerated().map { index, state in
            session.flow.state = state
            session.busy = state == .checking || state == .creating
            let host = NSHostingView(rootView: DirectorVoiceSteps(session: session, prepareOnAppear: false))
            host.frame = CGRect(x: 0, y: 0, width: 324, height: 160)
            host.layoutSubtreeIfNeeded()
            let text = DebugRightColumn.texts(in: host)["voice.headline"]
            let footer = DebugRightColumn.markers(in: host)["voice.footer"]
            let fits = footer.map { host.bounds.insetBy(dx: -0.5, dy: -0.5).contains($0) } ?? false
            return .init(name: "Voice job \(state.rawValue) renders its scene and pinned action (\(text ?? "missing"), footer \(String(describing: footer)))", passed: text == headlines[index] && fits)
        }
    }
    static func localPlanApproval(session: VoiceLabSession) async throws -> DebugUISuite.Result {
        let keys = VoiceLabNoDispatchKeys()
        let client = ElevenLabsVoiceLab(keys: keys, region: .default)
        let statement = VoiceConsentStatement(language: "en", text: "Offline statement fixture", nonce: [])
        let wav = try VoiceTrainingAudio.wav([Float](repeating: 0.1, count: 16_000), rate: 16_000)
        session.stageEnrollmentForTests(statement: statement, wav: wav, client: client)
        session.flow.plan = nil
        let requests = await keys.requests
        return .init(name: "Voice Lab has no paid action without a locally matched plan", passed: !session.canCreate && session.confirmation == nil && requests == 0)
    }
}
#endif
