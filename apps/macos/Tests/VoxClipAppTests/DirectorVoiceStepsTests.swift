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
        #expect(!session.recorder.recording && !session.hasStatementRecording)
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
    @Test func pricedActionRejectsEarlyReturnAndRepeats() {
        let appeared = Date(timeIntervalSince1970: 1_000)
        for elapsed in [0.0, 0.49] {
            #expect(!VoiceLabSession.permitsPaidActivation(keyboard: true, command: false, repeated: false, appeared: appeared, now: appeared.addingTimeInterval(elapsed)))
        }
        #expect(VoiceLabSession.permitsPaidActivation(keyboard: true, command: false, repeated: false, appeared: appeared, now: appeared.addingTimeInterval(0.5)))
        #expect(VoiceLabSession.permitsPaidActivation(keyboard: true, command: true, repeated: false, appeared: appeared, now: appeared))
        #expect(VoiceLabSession.permitsPaidActivation(keyboard: false, command: false, repeated: false, appeared: appeared, now: appeared))
        #expect(!VoiceLabSession.permitsPaidActivation(keyboard: true, command: true, repeated: true, appeared: appeared, now: appeared.addingTimeInterval(1)))
    }
    @Test func allSevenScenesKeepTheirPrimaryInsideTheSmallestPanel() throws {
        let app = AppModel()
        let results = DebugVoiceLab.stateScenes(session: app.voiceLabSession)
        #expect(results.count == 7)
        for result in results { #expect(result.passed, Comment(rawValue: result.name)) }
    }

    @Test func clipConsentKeepsItsActionInTheCompactPanelWithoutARecordingStep() throws {
        let app = AppModel(); let session = app.voiceLabSession
        session.flow.state = .agree; session.trainingSource = .project
        let host = NSHostingView(rootView: DirectorVoiceSteps(session: session, prepareOnAppear: false))
        host.frame = CGRect(x: 0, y: 0, width: 324, height: 160)
        host.layoutSubtreeIfNeeded()
        let markers = DebugRightColumn.markers(in: host)
        let action = try #require(markers["voice.use-audio"])
        let footer = try #require(markers["voice.footer"])
        #expect(host.bounds.insetBy(dx: -0.5, dy: -0.5).contains(footer))
        #expect(footer.insetBy(dx: -0.5, dy: -0.5).contains(action))
        #expect(DebugRightColumn.texts(in: host)["voice.use-audio"] == "Use Clip Audio")
        #expect(!session.recorder.recording && session.statement == nil && !session.hasStatementRecording)
    }

    @Test func firstUseKeepsTheDownloadLicenceAndActionInsideTheSmallestPanel() throws {
        let app = AppModel(); let session = app.voiceLabSession
        app.speakerModelLibrary.model = try SpeakerModelCatalog(shared: SharedResources.locate()).entry
        app.speakerModelLibrary.installed = false
        session.flow.keyChecked = true; session.flow.keyReady = true
        let host = NSHostingView(rootView: DirectorVoiceSteps(session: session, prepareOnAppear: false))
        host.frame = CGRect(x: 0, y: 0, width: 324, height: 160)
        host.layoutSubtreeIfNeeded()
        let footer = try #require(DebugRightColumn.markers(in: host)["voice.footer"])
        #expect(footer.height > 60 && host.bounds.insetBy(dx: -0.5, dy: -0.5).contains(footer))
    }

}
#endif
