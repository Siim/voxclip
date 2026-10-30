#if DEBUG
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// Development builds read an unset Voice Lab switch and beta notice as on, only for the user's own settings file
/// (voice-lab §5). These tests never load or save settings.
@Suite("Voice Lab development defaults", .serialized)
@MainActor struct VoiceLabDevelopmentDefaultTests {
    @Test func unsetKeysReadAsOnInTheAppsOwnDevelopmentSettings() {
        #expect(RewriteEntryPolicy.buildEnabled)
        let app = AppModel(developmentDefaults: true)
        #expect(app.bool("voiceLab.enabled") && app.bool("voiceLab.betaNoticeAccepted"))
        #expect(app.voiceLabSession.enabled && app.voiceLabRewriteEnabled)
        // The overlay is not a settings value, so a save writes neither key.
        #expect(app.settings.values["voiceLab.enabled"] == nil && app.settings.values["voiceLab.betaNoticeAccepted"] == nil)
    }

    @Test(arguments: [false, true]) func explicitValuesWinOverTheDevelopmentDefault(value: Bool) {
        let app = AppModel(developmentDefaults: true)
        app.settings.values["voiceLab.enabled"] = .bool(value)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(value)
        #expect(app.bool("voiceLab.enabled") == value && app.bool("voiceLab.betaNoticeAccepted") == value)
        #expect(app.voiceLabRewriteEnabled == value)
    }

    @Test func turningVoiceLabOffStoresAnExplicitFalseThatSticks() {
        let app = AppModel(developmentDefaults: true)
        #expect(app.set("voiceLab.enabled", .bool(false)))
        #expect(app.settings.values["voiceLab.enabled"] == .bool(false))
        #expect(!app.bool("voiceLab.enabled") && !app.voiceLabSession.enabled && !app.voiceLabRewriteEnabled)
        #expect(app.settings.values["voiceLab.betaNoticeAccepted"] == nil && app.bool("voiceLab.betaNoticeAccepted"))
    }

    @Test func injectedAndDefaultModelsKeepTheShippedDefault() {
        let models = [AppModel(), AppModel(settingsStore: RegressionSettingsStore()),
                      AppModel(settingsStore: RegressionSettingsStore(), developmentDefaults: true)]
        for app in models {
            #expect(app.unsetDefaults.isEmpty)
            #expect(!app.bool("voiceLab.enabled") && !app.bool("voiceLab.betaNoticeAccepted"))
            #expect(!app.voiceLabSession.enabled && !app.voiceLabRewriteEnabled)
        }
    }

    @Test func onlyTheVoiceLabKeysHaveADevelopmentDefault() {
        let app = AppModel(developmentDefaults: true)
        #expect(app.unsetDefaults == VoiceLabGate.developmentDefaults(internalBuild: true))
        #expect(!app.bool("voiceLab.providerConsent.elevenlabs") && app.bool("voiceLab.c2pa", fallback: true))
        #expect(app.string("voiceLab.labelPosition", fallback: "top-right") == "top-right")
    }
}
#endif
