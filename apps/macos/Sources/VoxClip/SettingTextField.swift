import SwiftUI
import VoxClipCore

@MainActor @Observable final class SettingTextDraft {
    var text: String
    init(_ text: String) { self.text = text }
    @discardableResult func commit(key: String, app: AppModel) -> Bool { app.set(key, .string(text)) }
}

@MainActor struct SettingTextField: View {
    let title: String
    let key: String
    let fallback: String
    let app: AppModel
    @State private var draft: SettingTextDraft
    @FocusState private var focused: Bool
    init(_ title: String, key: String, fallback: String, app: AppModel) {
        self.title = title; self.key = key; self.fallback = fallback; self.app = app
        _draft = State(initialValue: SettingTextDraft(app.string(key, fallback: fallback)))
    }
    var body: some View {
        @Bindable var draft = draft
        VStack(alignment: .leading, spacing: 4) {
            TextField(title, text: $draft.text).focused($focused)
                .accessibilityIdentifier("setting.\(key)")
                .onSubmit { draft.commit(key: key, app: app) }
                .onChange(of: focused) { _, focused in if !focused { draft.commit(key: key, app: app) } }
            if let error = app.settingErrors[key] { Text(error).font(.caption).foregroundStyle(DesignValues.color("status.dangerForeground")).accessibilityLabel("\(title): \(error)") }
        }
        .onChange(of: app.settings.values[key]) { _, _ in if !focused { draft.text = app.string(key, fallback: fallback) } }
    }
}
