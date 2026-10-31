import Foundation

extension SettingsDocument {
    static func isKnownKey(_ key: String) -> Bool {
        defaults[key] != nil || ["llm.baseUrl.ollama", "llm.baseUrl.lmstudio"].contains(key) || layoutRanges[key] != nil ||
        ProjectValidation.matches(key, "(?:llm\\.model|llm\\.cloudConsent|voiceLab\\.providerConsent|voiceLab\\.monthlyCapUsd)\\.[a-z0-9]+(?:-[a-z0-9]+)*")
    }

    /// Settings → Voice Lab → "Warn me above $__ a month per provider"; nil means no cap (voice-lab §3.1).
    public func voiceLabMonthlyCap(for provider: String) -> Decimal? {
        guard case .string(let text) = values["voiceLab.monthlyCapUsd." + provider] else { return nil }
        return VoiceLabMoney.parse(text, wholeDigits: 9, fractionDigits: 2)
    }

    /// Stores the cap as a canonical decimal string, or removes it for nil. Throws `invalidInput` for a value the
    /// settings schema refuses: negative, more than two decimals or at least $1,000,000,000.
    public mutating func setVoiceLabMonthlyCap(_ cap: Decimal?, for provider: String) throws {
        let key = "voiceLab.monthlyCapUsd." + provider
        guard ProjectValidation.matches(provider, ProjectValidation.slugPattern) else { throw VoiceLabError.invalidInput }
        guard let cap else { values.removeValue(forKey: key); return }
        let text = VoiceLabMoney.canonical(cap)
        guard VoiceLabMoney.parse(text, wholeDigits: 9, fractionDigits: 2) != nil else { throw VoiceLabError.invalidInput }
        values[key] = .string(text)
    }

    /// The Mac editor's dragged layout sizes in pt (v2 shell, impl-plan item 18), kept for every project. They have
    /// no shared default: missing or null is the window-dependent platform default, and the app clamps to its own
    /// token range. Windows keeps `ui.rightColumnWidth` until WV1 moves it here.
    public static let layoutRanges: [String: ClosedRange<Double>] = [
        "ui.layout.explorerWidth": 160...480, "ui.layout.rightWidth": 240...720, "ui.layout.timelineHeight": 40...1200
    ]

    public static let defaults: [String: JSONValue] = [
        "general.appearance": .string("system"), "general.transcriptTextSize": .null, "ui.rightColumnWidth": .null,
        "general.showLowConfidence": .bool(false), "general.showPlaceholderWords": .bool(true), "general.openLastProject": .bool(false), "general.recentProjects": .array([]),
        "onboarding.completed": .bool(false), "editing.pauseBreath": .string("natural"), "captions.defaultStyleId": .string("vox-highlight"),
        "cache.limitGB": .number(5), "transcription.engineMode": .string("local"), "transcription.language": .string("auto"),
        "transcription.recentLanguages": .array([]), "transcription.elevenlabs.region": .string("default"), "transcription.cloudConsent.elevenlabs": .bool(false),
        "export.defaultAspect": .string("source"), "export.quality": .string("standard"), "export.srt": .bool(false), "export.folder": .null,
        "export.fileNamePattern": .string("{project}-{clip}-{aspect}"), "export.openFolderAfter": .bool(false), "update.autoCheck": .bool(true),
        "update.lastCheckAt": .null, "update.latestVersion": .null, "update.htmlURL": .null, "llm.connector": .string(""),
        "llm.cliPath.claude-code": .string(""), "llm.cliPath.codex": .string(""), "llm.clips.snapToLines": .bool(true),
        "llm.clips.lastPreset": .string("best"), "llm.tighten.strength": .string("normal"), "voiceLab.enabled": .bool(false),
        "voiceLab.labelPosition": .string("top-right"), "voiceLab.c2pa": .bool(true), "voiceLab.betaNoticeAccepted": .bool(false)
    ]

    public subscript(_ key: String) -> JSONValue? {
        get { values[key] ?? Self.defaults[key] }
        set { values[key] = newValue }
    }

    public func modelID(for provider: String) -> String? {
        guard case .string(let model) = values["llm.model." + provider] else { return nil }
        return model
    }

    public mutating func setModelID(_ model: String, for provider: String) { values["llm.model." + provider] = .string(model) }

    public func validate() throws {
        try ProjectValidation.require(schema == "voxclip-settings/1" && values["schema"] == nil, "Invalid settings schema")
        let enums: [String: [String]] = [
            "general.appearance": ["system", "light", "dark"], "editing.pauseBreath": ["tight", "natural", "relaxed"],
            "voiceLab.labelPosition": ["top-right", "top-left", "bottom-right", "bottom-left"],
            "transcription.engineMode": ["local", "apple", "elevenlabs", "ask"], "transcription.elevenlabs.region": ["default", "us", "eu", "in", "sg"],
            "export.defaultAspect": ["source", "16:9", "9:16", "1:1"], "export.quality": ["standard", "high"],
            "llm.clips.lastPreset": ["best", "hooks", "topics", "quotes", "custom"], "llm.tighten.strength": ["light", "normal", "strong"]
        ]
        for (key, value) in values {
            if let allowed = enums[key] {
                guard case .string(let text) = value, allowed.contains(text) else { throw VoxClipError.projectUnreadable("Invalid settings choice") }
                continue
            }
            if case .bool = Self.defaults[key] {
                guard case .bool = value else { throw VoxClipError.projectUnreadable("Invalid settings boolean") }
                continue
            }
            if ProjectValidation.matches(key, "(?:llm\\.cloudConsent|voiceLab\\.providerConsent)\\.[a-z0-9]+(?:-[a-z0-9]+)*") {
                guard case .bool = value else { throw VoxClipError.projectUnreadable("Invalid provider consent") }
                continue
            }
            if ProjectValidation.matches(key, "voiceLab\\.monthlyCapUsd\\.[a-z0-9]+(?:-[a-z0-9]+)*") {
                if value == .null { continue }
                guard case .string(let text) = value, VoiceLabMoney.parse(text, wholeDigits: 9, fractionDigits: 2) != nil else {
                    throw VoxClipError.projectUnreadable("Invalid Voice Lab cap")
                }
                continue
            }
            if ProjectValidation.matches(key, "llm\\.model\\.[a-z0-9]+(?:-[a-z0-9]+)*") {
                guard ProjectValidation.matches(String(key.dropFirst(10)), ProjectValidation.slugPattern), case .string(let text) = value else { throw VoxClipError.projectUnreadable("Invalid model setting") }
                try ProjectValidation.text(text, min: 1, max: 128)
                continue
            }
            switch key {
            case "cache.limitGB":
                guard case .number(let number) = value, [2, 5, 10, 20].contains(number) else { throw VoxClipError.projectUnreadable("Invalid cache limit") }
            case "general.transcriptTextSize":
                if value != .null { guard case .number(let number) = value else { throw VoxClipError.projectUnreadable("Invalid text size") }; try ProjectValidation.number(number, min: 13, max: 28) }
            case "ui.rightColumnWidth":
                if value != .null { guard case .number(let number) = value else { throw VoxClipError.projectUnreadable("Invalid column width") }; try ProjectValidation.number(number, min: 240, max: 720) }
            case "ui.layout.explorerWidth", "ui.layout.rightWidth", "ui.layout.timelineHeight":
                guard value != .null, let range = Self.layoutRanges[key] else { continue }
                guard case .number(let number) = value else { throw VoxClipError.projectUnreadable("Invalid layout size") }
                try ProjectValidation.number(number, min: range.lowerBound, max: range.upperBound)
            case "general.recentProjects", "transcription.recentLanguages":
                let items = try ProjectValidation.array(value)
                try ProjectValidation.require(items.count <= (key == "general.recentProjects" ? 20 : 10), "Too many recent entries")
                var seen = Set<String>()
                for item in items {
                    guard case .string(let text) = item else { throw VoxClipError.projectUnreadable("Invalid recent entry") }
                    try ProjectValidation.text(text, min: 1, pattern: key == "transcription.recentLanguages" ? "[a-z]{2,3}" : nil)
                    if key == "transcription.recentLanguages" { try ProjectValidation.require(seen.insert(text).inserted, "Duplicate language") }
                }
            case "export.folder", "update.lastCheckAt", "update.latestVersion", "update.htmlURL":
                if value == .null { continue }
                guard case .string(let text) = value else { throw VoxClipError.projectUnreadable("Invalid nullable setting") }
                if key == "export.folder" { try ProjectValidation.text(text, min: 1) }
                if key == "update.htmlURL" {
                    guard let url = URLComponents(string: text), url.scheme?.lowercased() == "https", url.host?.lowercased() == "github.com",
                          url.user == nil, url.password == nil else { throw VoxClipError.projectUnreadable("Invalid update URL") }
                }
                if key == "update.lastCheckAt" {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    try ProjectValidation.require(formatter.date(from: text) != nil || ISO8601DateFormatter().date(from: text) != nil, "Invalid update timestamp")
                }
            case "captions.defaultStyleId", "transcription.language", "export.fileNamePattern", "llm.connector", "llm.cliPath.claude-code", "llm.cliPath.codex", "llm.baseUrl.ollama", "llm.baseUrl.lmstudio":
                guard case .string(let text) = value else { throw VoxClipError.projectUnreadable("Invalid text setting") }
                if key == "captions.defaultStyleId" { try ProjectValidation.text(text, pattern: ProjectValidation.slugPattern) }
                if key == "transcription.language" { try ProjectValidation.text(text, pattern: "(?:auto|[a-z]{2,3})") }
                if key == "export.fileNamePattern" { try ProjectValidation.text(text, min: 1, max: 200) }
                if key.hasPrefix("llm.baseUrl.") { try ProjectValidation.require(text.hasPrefix("http://") || text.hasPrefix("https://"), "Invalid model server URL") }
            default: break
            }
        }
        do { _ = try JSONEncoder().encode(self) }
        catch { throw VoxClipError.projectUnreadable("Invalid settings values") }
    }
}
