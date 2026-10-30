import Testing
import VoxClipCore

@Suite struct VoiceLabBetaTests {
    @Test(arguments: 0..<8)
    func enabledNoticeAndBuildMatrix(bits: Int) {
        let enabled = bits & 1 != 0, notice = bits & 2 != 0, internalBuild = bits & 4 != 0
        #expect(VoiceLabGate.settingsVisible(enabled: enabled, internalBuild: internalBuild))
        #expect(VoiceLabGate.rewriteEnabled(enabled: enabled, noticeAccepted: notice, internalBuild: internalBuild) == (enabled && (notice || internalBuild)))
    }

    @Test func onlyDevelopmentBuildsReadUnsetVoiceLabKeysAsOn() {
        #expect(VoiceLabGate.developmentDefaults(internalBuild: false).isEmpty)
        let expected: [String: JSONValue] = ["voiceLab.enabled": .bool(true), "voiceLab.betaNoticeAccepted": .bool(true)]
        #expect(VoiceLabGate.developmentDefaults(internalBuild: true) == expected)
        // The shipped default stays off: the overlay never changes the settings schema defaults.
        #expect(SettingsDocument.defaults["voiceLab.enabled"] == .bool(false))
        #expect(SettingsDocument.defaults["voiceLab.betaNoticeAccepted"] == .bool(false))
    }
}
