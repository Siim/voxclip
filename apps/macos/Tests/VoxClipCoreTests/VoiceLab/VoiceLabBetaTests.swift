import Testing
import VoxClipCore

@Suite struct VoiceLabBetaTests {
    @Test(arguments: 0..<8)
    func enabledNoticeAndBuildMatrix(bits: Int) {
        let enabled = bits & 1 != 0, notice = bits & 2 != 0, internalBuild = bits & 4 != 0
        #expect(VoiceLabGate.settingsVisible(enabled: enabled, internalBuild: internalBuild))
        #expect(VoiceLabGate.rewriteEnabled(enabled: enabled, noticeAccepted: notice, internalBuild: internalBuild) == (enabled && (notice || internalBuild)))
    }
}
