import Foundation
import Testing
import VoxClipCore
@testable import VoxClip

@MainActor struct FailureLoggingTests {
    private enum DescribedFailure: Error, CustomStringConvertible {
        case interrupted
        var description: String { "PrivateInterview" }
    }

    private enum ReflectedFailure: Error, CustomReflectable {
        case interrupted
        var customMirror: Mirror {
            Mirror(self, children: ["PrivateInterview": "private reply"], displayStyle: .enum)
        }
    }

    @Test func aProjectOpenFailureWritesOnlyItsCategoryTypeAndCase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        let error = VoxClipError.mediaMissing("/private/Interview.mp4")

        let message = await app.safeError(error, context: .projectOpen)
        #expect(message.contains("Interview.mp4"))

        let log = try String(contentsOf: app.locations.logs.appendingPathComponent("voxclip.log"), encoding: .utf8)
        #expect(log.split(separator: "\n").map { $0.components(separatedBy: " [error] ").last }
            == ["project-open: type=VoxClipError case=mediaMissing"])
    }

    @Test func eachActionWritesItsOwnCategory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        let contexts: [(FailureContext, String)] = [
            (.importMedia, "import"), (.projectOpen, "project-open"), (.projectSave, "project-save"),
            (.relink, "relink"), (.preview, "preview"), (.transcribe, "transcribe"), (.export, "export"),
            (.share, "share"), (.rewrite, "rewrite"), (.llm, "llm"), (.askClaude, "ask-claude"),
            (.clipStyle, "clip-style"), (.makeIt, "make-it"), (.voiceLab, "voice-lab"),
            (.contextDemo, "context-demo"), (.settings, "settings"), (.models, "models"), (.music, "music"),
            (.editing, "editing"), (.startup, "startup"), (.update, "update")
        ]
        #expect(Set(contexts.map(\.0)) == Set(FailureContext.allCases))
        for (context, _) in contexts { await app.logFailure(LLMError.timeout, context: context) }

        let log = try String(contentsOf: app.locations.logs.appendingPathComponent("voxclip.log"), encoding: .utf8)
        #expect(log.split(separator: "\n").compactMap { $0.components(separatedBy: " [error] ").last }
            == contexts.map { _, category in "\(category): type=LLMError case=timeout" })
    }

    @Test func diagnosticsNeverUseCustomDescriptionsMirrorsDomainsOrPresentationContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        let custom = NSError(domain: "PrivateInterview.Domain", code: 1234,
                             userInfo: [NSLocalizedDescriptionKey: "Private interview at /private/Interview.mp4"])

        await app.logFailure(DescribedFailure.interrupted, context: .transcribe)
        await app.logFailure(ReflectedFailure.interrupted, context: .transcribe)
        await app.logFailure(custom, context: .projectSave)
        await app.logFailure(NSError(domain: NSCocoaErrorDomain, code: 513), context: .projectSave)
        let message = await app.safeError(LLMError.cliMissing, context: .settings, messageContext: "ai-test:PrivateInterview")
        #expect(message.contains("PrivateInterview"))
        #expect(await app.safeError(LLMError.cancelled, context: .llm).isEmpty)
        await app.logFailure(CancellationError(), context: .rewrite)

        let log = try String(contentsOf: app.locations.logs.appendingPathComponent("voxclip.log"), encoding: .utf8)
        #expect(log.split(separator: "\n").compactMap { $0.components(separatedBy: " [error] ").last } == [
            "transcribe: type=FailureLoggingTests.DescribedFailure",
            "transcribe: type=FailureLoggingTests.ReflectedFailure",
            "project-save: type=NSError",
            "project-save: type=NSError domain=NSCocoaErrorDomain code=513",
            "settings: type=LLMError case=cliMissing"
        ])
    }
}
