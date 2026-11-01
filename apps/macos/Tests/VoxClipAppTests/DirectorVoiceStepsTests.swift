#if DEBUG
import AppKit
import SwiftUI
import Testing
@testable import VoxClipCore
@testable import VoxClip

@Suite("Inline Voice job", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil))
@MainActor struct DirectorVoiceStepsTests {
    private func open() async throws -> (AppModel, EditorModel) {
        let app = AppModel()
        app.settings.values["voiceLab.enabled"] = .bool(false)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(false)
        let shared = try SharedResources.locate()
        let url = shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")
        let project = try JSONProjectStore.decode(Data(contentsOf: url))
        await app.shell.attachForTesting(VoxClipDocument(project: project), selection: .fullTake)
        let editor = try #require(app.shell.editor)
        editor.mediaResolved = true; editor.refresh()
        return (app, editor)
    }
    @Test func firstUseOpensInThePanelAndDoesNotStartADownload() async throws {
        let (app, editor) = try await open(); defer { editor.close() }
        #expect(!PanelJob.available(in: editor).contains(.voice))
        editor.openVoiceJob()
        let session = app.voiceLabSession
        #expect(session.showEnrollment && session.flow.state == .firstUse)
        #expect(PanelJob.available(in: editor).contains(.voice))
        #expect(app.shell.panelJob(for: editor) == .voice)
        #expect(!session.enabled && app.speakerModelLibrary.task == nil && session.analysis?.isCancelled != false)
        app.shell.choosePanelJob(.captions, for: editor)
        #expect(app.shell.panelJob(for: editor) == .captions)
        editor.openVoiceJob()
        #expect(app.shell.panelJob(for: editor) == .voice)
    }
    @Test func installedCheckSkipsDownloadAndKeepsAllAgreementsExplicit() async throws {
        let (app, editor) = try await open(); defer { editor.close() }
        editor.openVoiceJob()
        let session = app.voiceLabSession
        app.speakerModelLibrary.model = try SpeakerModelCatalog(shared: SharedResources.locate()).entry
        app.speakerModelLibrary.installed = true
        session.flow.keyReady = true
        session.turnOnVoiceJob()
        #expect(session.enabled && app.bool("voiceLab.betaNoticeAccepted"))
        #expect(session.flow.state == .agree && app.speakerModelLibrary.task == nil)
        #expect(!session.ownVoice && !session.adult && !session.ownVideosOnly && !session.canRecord)
        session.displayName = "Example"; session.ownVoice = true; session.adult = true; session.ownVideosOnly = true
        #expect(session.canRecord)
        await session.prepareVoiceStatement()
        #expect(session.flow.state == .statement && session.statement?.text.contains("Example") == true)
        #expect(!session.recorder.recording && !session.hasStatementRecording && !session.verified)
        session.analysis?.cancel()
    }
    @Test func downloadRequiresItsInlineApprovalAndHasPublisherAndLicence() async throws {
        let (app, editor) = try await open(); defer { editor.close() }
        let library = app.speakerModelLibrary
        await library.load()
        library.download(approved: false)
        #expect(library.task == nil && library.progress == nil)
        let model = try #require(library.model)
        #expect(library.downloadLicence.contains(model.publisher))
        #expect(library.downloadLicence.contains(model.license))
        #expect(library.downloadLicence.contains("By downloading you accept"))
    }
    @Test func offGateAndMissingMediaExposeNoVoiceJob() async throws {
        let (_, editor) = try await open(); defer { editor.close() }
        #expect(!editor.hasVoiceJob && !PanelJob.available(in: editor).contains(.voice))
        editor.mediaResolved = false
        editor.openVoiceJob()
        #expect(!editor.hasVoiceJob)
        #expect(!VoiceLabGate.rewriteEnabled(enabled: false, noticeAccepted: false, internalBuild: false))
    }
}
#endif
