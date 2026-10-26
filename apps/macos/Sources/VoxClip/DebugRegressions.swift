#if DEBUG
import SwiftUI
import Synchronization
import VoxClipCore

actor RegressionSettingsStore: SettingsStore {
    var saved: [SettingsDocument] = []
    let fails: Bool
    let delay: Bool
    let cachedUpdate: Bool
    init(fails: Bool = false, delay: Bool = false, cachedUpdate: Bool = false) { self.fails = fails; self.delay = delay; self.cachedUpdate = cachedUpdate }
    func load() async throws -> SettingsDocument {
        if fails { throw VoxClipError.projectUnreadable("settings") }
        if delay { try await Task.sleep(for: .milliseconds(20)) }
        var values: [String: JSONValue] = ["future.option": .string("preserved"), "editing.pauseBreath": .string("tight")]
        if cachedUpdate {
            values["update.latestVersion"] = .string("99.0.0")
            values["update.htmlURL"] = .string("https://github.com/Siim/voxclip/releases/tag/v99.0.0")
            values["update.lastCheckAt"] = .string(Date().ISO8601Format())
        }
        return SettingsDocument(values: values)
    }
    func save(_ settings: SettingsDocument) { saved.append(settings) }
    func flush() {}
}

@MainActor enum DebugRegressions {
    static func startup() async -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        let store = RegressionSettingsStore()
        let app = AppModel(settingsStore: store)
        app.set("general.transcriptTextSize", .number(20))
        await app.flushSettings()
        check("settings never save before loading", await store.saved.isEmpty)
        await app.start()
        check("settings merge early writes and preserve unknown keys", app.settingsLoaded && app.settings.values["future.option"] == .string("preserved") && app.number("general.transcriptTextSize", fallback: 17) == 20)
        check("loaded pause breath creates no edit notification", app.pauseBreathRevision == 0)
        await app.flushSettings()
        check("termination flush saves loaded settings", await store.saved.count == 1)
        let failedStore = RegressionSettingsStore(fails: true)
        let failed = AppModel(settingsStore: failedStore)
        await failed.start()
        failed.set("onboarding.completed", .bool(true))
        await failed.flushSettings()
        let failedSaves = await failedStore.saved
        check("failed settings loads never save", !failed.settingsLoaded && failedSaves.isEmpty)
        let concurrent = AppModel(settingsStore: RegressionSettingsStore(delay: true, cachedUpdate: true))
        concurrent.launch()
        await Task.yield()
        await concurrent.start()
        check("import startup waits for an in-flight settings load", concurrent.settingsLoaded)
        check("cached update survives the daily throttle", concurrent.update?.version == "99.0.0")
        let router = FileOpenRouter()
        var projects: [URL] = [], movies: [URL] = []
        router.projectOpener = { projects.append($0) }
        let movie = URL(fileURLWithPath: "/tmp/cold.mov"), project = URL(fileURLWithPath: "/tmp/cold.voxclip")
        router.receive([movie, project])
        check("cold project opens route without a scene", projects == [project] && movies.isEmpty)
        router.installMovieOpener { movies.append($0) }
        check("cold movie opens drain after action registration", movies == [movie])
        router.receive([movie, project])
        check("running opens do not require Welcome", movies.count == 2 && projects.count == 2)
        let configuration = KeyedNetwork.configuration()
        check("keyed requests never persist cache cookies or credentials", configuration.urlCache == nil && configuration.httpCookieStorage == nil && configuration.urlCredentialStorage == nil && !configuration.httpShouldSetCookies)
        check("version comes from the embedded plist", AppModel.version == Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        check("media missing copy has one reassurance", UserMessages.message(VoxClipError.mediaMissing("/private/take.mov")) == "Can't find take.mov. Edits are saved.")
        check("key rejected copy uses status", UserMessages.message(VoxClipError.keyRejected("ElevenLabs 401")) == "ElevenLabs rejected the key (401). Your video is still here.")
        check("export copy never doubles reassurance", UserMessages.message(VoxClipError.exportFailed("encoder stopped. Your edits are saved."), context: "export") == "Export stopped: encoder stopped. Your edits are saved.")
        check("cancellation is silent", UserMessages.message(VoxClipError.cancelled).isEmpty && UserMessages.message(LLMError.cancelled, context: "ai:OpenAI").isEmpty)
        let consentApp = AppModel(settingsStore: RegressionSettingsStore())
        consentApp.selectOnboardingConnector("openai", consent: true)
        check("onboarding never pre-consents API transcript uploads", !consentApp.bool("llm.cloudConsent.openai"))
        let rejected = !consentApp.selectOnboardingConnector("claude-code", consent: false)
        let accepted = consentApp.selectOnboardingConnector("claude-code", consent: true)
        check("onboarding CLI consent uses the first-use copy", rejected && accepted && consentApp.bool("llm.cloudConsent.claude-code") && consentApp.providers.first(where: { $0.id == "claude-code" })?.cliConsentCopy?.hasPrefix("VoxClip will run your installed Claude Code") == true)
        for provider in app.providers.filter({ ["claude-code", "codex"].contains($0.id) }) {
            let cli = provider.id == "claude-code" ? "Claude Code" : "Codex"
            let context = "ai:\(provider.label)"
            let missing = await app.safeError(LLMError.cliMissing, context: context)
            let signedOut = await app.safeError(LLMError.cliSignedOut, context: context)
            let limit = await app.safeError(LLMError.planLimit(message: nil), context: context)
            let failed = await app.safeError(LLMError.cliFailed("fixture"), context: context)
            check("CLI placeholders use the canonical name for \(provider.id)", missing.hasPrefix("\(cli) isn't installed.") && signedOut.hasPrefix("\(cli) isn't signed in.") && limit.hasPrefix("Your \(cli) plan's usage limit is reached.") && failed.hasPrefix("\(cli) stopped with an error:"))
        }
        check("Keychain errors have one reassurance", UserMessages.message(SecretError.status(-50)).components(separatedBy: "Your video and edits are still here.").count == 2)
        check("AI copy uses the selected model and catalogue hints", UserMessages.message(LLMError.contextTooLong, context: "ai:OpenAI", model: "test-model") == "This transcript is too long for test-model. Pick a model with a larger context. Your edits are saved." && UserMessages.message(LLMError.cliMissing, context: "ai:Codex", installHint: "Install the CLI.") == "Codex isn't installed. Install the CLI. Your edits are saved.")
        check("single-clip export never expands to checked clips", ExportSelection.targets(requestedIDs: ["one"], selectedClips: ["one", "two"]) == [.clip("one")])
        check("normal export selection remains explicit", ExportSelection.targets(requestedIDs: [], selectedClips: nil) == [.fullEdit] && ExportSelection.targets(requestedIDs: [], selectedClips: []) == [])
        check("empty export names have a safe fallback", ExportSelection.baseName(" ../../ ") == "VoxClip-export" && !ExportSelection.baseName("a/b.mov").contains("/"))
        check("folder expansion only expands a leading tilde", ExportSelection.folder("/tmp/a~b").path == "/tmp/a~b")
        return results
    }

    static func media(app: AppModel, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        let scratch = directory.appendingPathComponent("identity-check")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        struct Fixture: Decodable {
            struct Input: Decodable { let sizes: [Int] }
            struct Expected: Decodable { let contentKeys: [String] }
            let input: Input; let expected: Expected
        }
        let fixtureURL = app.shared!.root.appendingPathComponent("fixtures/editing/media/content-key.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        let url = scratch.appendingPathComponent("source.mov")
        for (size, expected) in zip(fixture.input.sizes, fixture.expected.contentKeys) {
            try Data((0..<size).map { UInt8(($0 * 31 + 7) % 251) }).write(to: url)
            let key = try await Task.detached { try JSONProjectStore.contentKey(for: url) }.value
            check("content key fixture \(size) bytes", key == expected)
        }
        let document = try await importedDocument(url, app: app)
        check("import uses a real content key and no private export path", document.project.media.source.contentKey == fixture.expected.contentKeys.last && document.project.export.folder == nil)
        let longName = scratch.appendingPathComponent(String(repeating: "a", count: 230) + ".mov")
        try Data([0, 1, 2]).write(to: longName)
        let longDocument = try await VoxClipDocument(importing: longName)
        check("long import names remain saveable", longDocument.project.title?.unicodeScalars.count == 200 && (try? JSONProjectStore.encode(longDocument.project)) != nil)
        let original = document.project.media.source
        var reference = original
        reference.relativePath = "source.mov"
        reference.absolutePath = scratch.appendingPathComponent("missing.mov").path
        let projectURL = scratch.appendingPathComponent("take.voxclip")
        var openedProject = document.project
        openedProject.media.source.relativePath = "source.mov"
        let opened = VoxClipDocument(project: openedProject)
        let changes = Mutex(0)
        let subscription = opened.objectWillChange.sink { changes.withLock { $0 += 1 } }
        defer { subscription.cancel() }
        opened.adoptOpenedLocation(projectURL)
        opened.updateLocation(projectURL)
        opened.replaceProject(openedProject)
        let openedEditor = EditorModel(document: opened, app: app, preview: DemoPreviewEngine())
        defer { openedEditor.close() }
        _ = try await openedEditor.resolveMediaIdentity()
        check("opening unchanged media leaves the document clean", !opened.isDocumentEdited && opened.project == openedProject)
        check("opening and verifying media emit no autosave notifications", changes.withLock { $0 } == 0)
        var movedProject = document.project
        movedProject.media.source = reference
        let resolved = try await app.projectStore.resolveSource(for: movedProject, projectURL: projectURL)
        check("moved project resolves its relative media identity", resolved == url)
        let movedDocument = VoxClipDocument(project: movedProject)
        movedDocument.adoptOpenedLocation(projectURL)
        let editor = EditorModel(document: movedDocument, app: app, preview: DemoPreviewEngine())
        defer { editor.close() }
        _ = try await editor.resolveMediaIdentity()
        check("relink revalidation adopts verified relative media", editor.mediaResolved && editor.sourceURL == url && app.openProjectKeys[movedProject.id] == reference.contentKey)
        check("a changed stored media path marks the document edited", movedDocument.isDocumentEdited)
        let resolvedProject = movedDocument.project
        _ = try await editor.resolveMediaIdentity()
        check("revalidating unchanged media does not change the project", movedDocument.project == resolvedProject && movedDocument.isDocumentEdited)
        let absolute = scratch.appendingPathComponent("absolute.mov")
        try Data(contentsOf: url).write(to: absolute)
        defer { try? FileManager.default.removeItem(at: absolute) }
        var both = movedProject
        both.media.source.absolutePath = absolute.path
        let preferred = try await app.projectStore.resolveSource(for: both, projectURL: projectURL)
        check("media resolution prefers a verified absolute path", preferred == absolute)
        try Data("wrong recording".utf8).write(to: url)
        do { _ = try await app.projectStore.resolveSource(for: movedProject, projectURL: projectURL); check("wrong media is never silently attached", false) }
        catch { check("wrong media is never silently attached", true) }
        document.updateLocation(projectURL)
        let snapshot = try document.snapshot(contentType: .voxclipProject)
        try JSONProjectStore.encode(snapshot).write(to: projectURL)
        check("destination-aware snapshot does not dirty the document just for a file URL", !document.isDocumentEdited && document.fileURL == projectURL)
        let saved = try JSONProjectStore.decode(Data(contentsOf: projectURL))
        check("saved snapshot rewrites relative media path", saved.media.source.relativePath == "source.mov")
        let unresolved = VoxClipDocument(project: movedProject)
        unresolved.adoptOpenedLocation(projectURL)
        check("unresolved media retains its relative relink hint on save", try unresolved.snapshot(contentType: .voxclipProject).media.source.relativePath == reference.relativePath)
        return results
    }

    static func editor(app: AppModel, project: Project) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        let voiceURL = app.shared!.root.appendingPathComponent("fixtures/voice-lab/passage-project.voxclip")
        var voiceProject = try JSONProjectStore.decode(Data(contentsOf: voiceURL))
        voiceProject.captions.styleId = "off"
        let voiceDocument = VoxClipDocument(project: voiceProject)
        let voiceModel = EditorModel(document: voiceDocument, app: app, preview: DemoPreviewEngine())
        defer { voiceModel.close() }
        voiceModel.mediaResolved = true
        voiceModel.refresh()
        check("active synthetic audio has no source-only cached plan", voiceModel.plan == nil && voiceModel.previewError?.contains("generated voice segments") == true)
        do { _ = try await voiceModel.renderRequest(); check("preview rejects active synthetic audio", false) }
        catch { check("preview rejects active synthetic audio", error as? VoiceLabProjectError == .unsupportedRendering) }
        let outside = ClipRange(id: "outside", startWordId: "w1", endWordId: "w2", title: "Source only")
        voiceProject.edits.clips.append(outside); voiceProject.edits.activeClipId = outside.id
        voiceDocument.replaceProject(voiceProject); voiceModel.refresh()
        check("clip excluding synthetic audio retains a render plan", voiceModel.plan != nil)
        do { _ = try await voiceModel.renderRequest(target: .fullEdit); check("full export ignores source-only active clip", false) }
        catch { check("full export ignores source-only active clip", error as? VoiceLabProjectError == .unsupportedRendering) }
        let outsideRequest = try await voiceModel.renderRequest(target: .clip(outside.id))
        check("explicit source-only clip reaches render request", outsideRequest.plan.outputSamples > 0)
        voiceProject.edits.activeClipId = nil
        voiceProject = try VoiceLabProject.setEnabled(false, id: "vl-passage", in: voiceProject)
        voiceDocument.replaceProject(voiceProject); voiceModel.refresh()
        check("disabled synthetic audio restores source render", try await voiceModel.renderRequest(target: .fullEdit).plan.outputSamples == 7000)
        let model = EditorModel(document: VoxClipDocument(project: project), app: app, preview: DemoPreviewEngine())
        defer { model.close() }
        model.mediaResolved = true
        model.refresh()
        model.error = nil
        model.apply(.restoreSelection(ids: []), name: "Empty selection")
        check("legitimate reducer no-ops are silent", model.error == nil && model.project == project)
        check("word index supports constant-time scope lookups", model.words.enumerated().allSatisfy { model.index($0.element.id) == $0.offset })
        check("singular summary copy", EditorModel.summaryText(EditSummary(cutWordCount: 1, cutPauseCount: 1, hasEdits: true)) == "1 word and 1 pause cut.")
        check("timecodes round across minute and hour boundaries", timecode(59.96) == "01:00.0" && timecode(3599.96) == "01:00:00.0" && timecode(.nan) == "00:00.0")
        model.plan = EditPlan(sampleRate: 48_000, totalSamples: 48_000, cuts: [MediaInterval(startSample: 0, endSample: 48_000)], kept: [])
        do { _ = try await model.renderRequest(); check("zero-sample export uses everythingCut", false) }
        catch { check("zero-sample export uses everythingCut", error as? VoxClipError == .everythingCut) }
        var changed = project
        changed.edits.pauseKeepSeconds = 0.3
        changed.share.captions["full"] = "stale caption"
        model.document.replaceProject(changed)
        var transcript = project.transcript!
        transcript.refined = true
        model.replaceTranscript(transcript)
        check("transcript replacement resets derived edits and stale share text", model.project.edits.clips.isEmpty && model.project.edits.activeClipId == nil && model.project.ai.results.isEmpty && model.project.share.captions.isEmpty && model.project.edits.pauseThresholdSeconds == 0.8 && model.project.edits.pauseKeepSeconds == 0.3)
        let first = model.words[0].id, second = model.words[1].id
        func planMatchesCore() -> Bool {
            guard let state = model.editState(), let segments = try? buildSegments(state, activeClip: state.activeClip),
                  let expected = try? buildEditPlan(segments, duration: model.sourceDuration, sampleRate: Double(model.project.media.source.audio?.sampleRate ?? 48_000), pauseKeepSeconds: state.pauseKeepSeconds) else { return false }
            return model.plan == expected && model.summary == state.summary
        }
        model.apply(.correct(id: first, text: "um"), name: "Correct filler")
        let corrected = model.fillerIDs.contains(first)
        model.apply(.cutSelection(ids: [first]), name: "Cut filler")
        let cut = !model.fillerIDs.contains(first)
        let cutPlan = planMatchesCore()
        model.apply(.restoreSelection(ids: [first]), name: "Restore filler")
        check("cached projections match Core after cut and restore", cutPlan && planMatchesCore())
        check("cached filler hints follow correction cut and restore", corrected && cut && model.fillerIDs.contains(first))
        model.apply(.correct(id: first, text: "ordinary"), name: "Correct ordinary word")
        check("correction changes invalidate cached filler hints", !model.fillerIDs.contains(first))
        model.apply(.correct(id: second, text: "um"), name: "Correct outside filler")
        model.apply(.addClip(ClipRange(id: "filler-scope", startWordId: first, endWordId: first, title: "Scope")), name: "Add filler scope")
        model.apply(.setActiveClip(clipId: "filler-scope"), name: "Scope filler hints")
        let scoped = !model.fillerIDs.contains(second)
        model.apply(.setActiveClip(clipId: nil), name: "Show full take")
        check("cached filler hints follow active clip scope", scoped && model.fillerIDs.contains(second))
        let local = try await app.modelLibrary.localModel(language: "et")
        check("local routing uses canonical catalogue model IDs", local.id == "taltech-et-verbatim-2604-q8_0")
        await app.modelLibrary.load()
        check("model list excludes unlisted catalogue fixtures", !app.modelLibrary.models.isEmpty && !app.modelLibrary.models.contains(where: { ["whisper-base.en-q5_1", "silero-vad-v6.2.0"].contains($0.id) }))
        app.modelLibrary.download(local)
        let initialProgress = app.modelLibrary.progress
        if let other = app.modelLibrary.models.first(where: { $0.id != local.id }) { app.modelLibrary.download(other) }
        check("model download ownership starts synchronously", initialProgress?.modelID == local.id && app.modelLibrary.progress?.modelID == local.id)
        app.modelLibrary.task?.cancel()
        var captionProject = model.project
        captionProject.captions.styleId = "off"
        model.document.replaceProject(captionProject)
        let uncut = EditorModel.uncutPlan(duration: model.sourceDuration)
        let off = try await model.buildCaptions(segments: try model.editState().map { try buildSegments($0, activeClip: $0.activeClip) }, plan: uncut, output: model.outputSpec(), forPreview: false, project: model.project, voiceLab: nil)
        check("captions-off requests do not need a layout pipeline", off == nil)
        if let style = app.styles.first {
            captionProject.captions.styleId = style.id
            model.document.replaceProject(captionProject)
            let tile = model.captionTileInput(style)
            check("caption tile handoff retains state frame language and overrides", tile.state == model.editState() && tile.frame == model.outputSpec().size && tile.language == model.project.transcript?.language && tile.overrides == model.project.captions.overrides)
            let layout = try await model.buildCaptions(segments: try model.editState().map { try buildSegments($0, activeClip: $0.activeClip) }, plan: uncut, output: model.outputSpec(), forPreview: false, project: model.project, voiceLab: nil)
            check("captioned exports use prepared layout", layout != nil)
        }
        return results
    }
}
#endif
