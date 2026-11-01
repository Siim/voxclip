#if DEBUG
import AppKit
import SwiftUI
import VoxClipCore

@MainActor enum DebugInlineConfirm {
    /// f22/f22b are part of -sceneAudit. These scenes never detect an AI or invoke a connector.
    static func captures(app: AppModel, directory: URL) async throws -> [DebugUISuite.Result] {
        guard let openAI = app.providers.first(where: { $0.id == "openai" }),
              let claude = app.providers.first(where: { $0.id == "claude-code" }) else { throw CocoaError(.coderInvalidValue) }
        let words = DirectorScope(kind: .clip(number: 1), wordCount: 86)
        let price = "VoxClip can't tell what this costs. Check OpenAI's pricing."
        for (name, provider, first, billed) in [("f22", openAI, false, true), ("f22b", claude, true, false), ("f22c", openAI, true, true)] {
            let row = ConnectorConfirmation()
            row.showForAudit(provider.confirmationPrompt(action: .rewrite, wordCount: 86, rewrite: words,
                price: billed ? price : "", firstUse: first, model: billed ? "GPT-5.6 Terra" : ""))
            for width in [652, 440] {
                try await DebugUISuite.snapshot(ConnectorConfirmationView(confirmation: row).environment(app),
                    name: "v2-inline-\(name)-\(width)", size: NSSize(width: width, height: width == 652 ? 150 : 220),
                    appearance: .darkAqua, directory: directory)
            }
        }
        return [.init(name: "captured inline connector f22/f22b/f22c scenes", passed: true)]
    }
}
#endif
