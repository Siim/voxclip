#if DEBUG
import AppKit
import SwiftUI
import Testing
@testable import VoxClip
@testable import VoxClipCore

@Suite("Inline audio expression layout", .serialized, .offlineFixtures)
@MainActor struct AudioTagPhraseTests {
    @Test(arguments: [300.0, 320.0, 560.0])
    func tagsWrapWithoutAWindow(width: Double) {
        _ = NSApplication.shared
        let text = "And yeah I'm still going and I'm definitely not running but I can tell you what happened next"
        let tags = [VoiceLabAudioTag(beforeToken: 2, tag: "laughs"), .init(beforeToken: 8, tag: "short pause"),
                    .init(beforeToken: 18, tag: "sighs")]
        let host = NSHostingView(rootView: AudioTagPhrase(text: text, tags: tags, phrase: 1) { _ in }
            .padding(8).frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 400)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= width + 0.5)
        #expect(host.fittingSize.height > 30)
        #expect(DebugRightColumn.viewOverflow(host).isEmpty)
    }
}
#endif
