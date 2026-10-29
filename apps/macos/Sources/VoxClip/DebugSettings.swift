#if DEBUG
import Foundation
import VoxClipCore

@MainActor enum DebugSettings {
    static func run(directory: URL) async throws -> [DebugUISuite.Result] {
        let scratch = directory.appendingPathComponent("settings-validation")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": scratch.path])
        let store = JSONSettingsStore(locations: locations)
        var initial = SettingsDocument()
        initial.values["update.autoCheck"] = .bool(false)
        try await store.save(initial); try await store.flush()
        let app = AppModel(settingsStore: store)
        await app.start()
        let key = "export.fileNamePattern", value = "{project}-{clip}"
        let draft = SettingTextDraft(value)
        let delayed = app.settings.values[key] == nil
        let valid = draft.commit(key: key, app: app)
        draft.text = String(repeating: "x", count: 201)
        let tooLong = !draft.commit(key: key, app: app) && app.string(key) == value && app.settingErrors[key] != nil
        draft.text = ""
        let empty = !draft.commit(key: key, app: app) && app.string(key) == value && app.settingErrors[key] != nil
        app.set("general.appearance", .string("dark"))
        await app.flushSettings()
        let saved = try await JSONSettingsStore(locations: locations).load()
        let voiceLab = try await DebugVoiceLab.run(app: app)
        return voiceLab + [
            .init(name: "settings drafts do not write until commit", passed: delayed && valid),
            .init(name: "too-long settings show an inline error and keep the last value", passed: tooLong),
            .init(name: "empty settings show an inline error and keep the last value", passed: empty),
            .init(name: "invalid drafts never poison later settings saves", passed: saved.values[key] == .string(value) && saved.values["general.appearance"] == .string("dark")),
            .init(name: "settings failures use settings-specific copy", passed: UserMessages.message(VoxClipError.projectUnreadable("fixture"), context: "Settings could not be saved.") == "Settings could not be saved. Your video and edits are still here.")
        ]
    }
}
#endif
