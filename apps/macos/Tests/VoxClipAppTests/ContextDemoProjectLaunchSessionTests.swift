#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

private actor ContextDemoProjectCommandProbe: ProcessRunner {
    private(set) var requests: [ProcessRequest] = []
    private(set) var cancellationSeen = false
    private var release: TestContinuation<Void>?
    let suspended: Bool
    let exitCode: Int32

    init(suspended: Bool = false, exitCode: Int32 = 0) {
        self.suspended = suspended
        self.exitCode = exitCode
    }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        requests.append(request)
        if suspended {
            await withTaskCancellationHandler {
                await withTestDeadline { release = $0 }
            } onCancel: {
                Task { await self.markCancellation() }
            }
        }
        try Task.checkCancellation()
        return ProcessResult(exitCode: exitCode, stdout: Data(), stderr: Data())
    }

    private func markCancellation() { cancellationSeen = true }
    func finishDraining() { release?.resume(); release = nil }
}

@MainActor @Suite("Context demo project command UI lifecycle", .serialized)
struct ContextDemoProjectLaunchSessionTests {
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("demo-command-ui-\(UUID())", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"scripts":{"build":"untrusted build instructions","preview":"untrusted preview instructions"}}"#.utf8)
            .write(to: directory.appendingPathComponent("package.json"))
        return directory
    }

    private func eventually(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<2_000 {
            if await condition() { return }
            await Task.yield()
        }
        let satisfied = await condition()
        try #require(satisfied)
    }

    private func inspected(_ directory: URL, runner: ContextDemoProjectCommandProbe) async throws -> ContextDemoProjectLaunchSession {
        let session = ContextDemoProjectLaunchSession(runner: runner)
        session.chooseDirectory(directory)
        session.inspect()
        try await eventually { session.phase == .inspected }
        return session
    }

    private func command(_ session: ContextDemoProjectLaunchSession, arguments: String = #"["run","build"]"#, timeout: Int = 30) throws {
        let draft = try #require(session.commands.first)
        session.setCommand(draft.id, executablePath: "/usr/local/bin/npm", argumentsJSON: arguments, timeoutSeconds: timeout)
    }

    @Test func selectionInspectionAndReviewNeverExecuteBeforeExplicitStart() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = ContextDemoProjectCommandProbe()
        let session = ContextDemoProjectLaunchSession(runner: runner)
        session.chooseDirectory(directory)
        #expect(session.facts == nil && session.plan == nil && !session.canStart)
        #expect(await runner.requests.isEmpty)
        session.start()
        session.inspect()
        try await eventually { session.phase == .inspected }
        #expect(await runner.requests.isEmpty)
        try command(session, arguments: #"["run","build","--","two words",""]"#, timeout: 17)
        session.reviewCommands()
        #expect(session.canStart)
        let plan = try #require(session.plan)
        #expect(plan.snapshot.directory == directory.standardizedFileURL)
        #expect(plan.commands.first?.arguments == ["run", "build", "--", "two words", ""])
        #expect(await runner.requests.isEmpty)
        session.start()
        session.start()
        try await eventually { session.phase == .succeeded }
        let requests = await runner.requests
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.executable.path == "/usr/local/bin/npm")
        #expect(request.workingDirectory == plan.snapshot.directory)
        #expect(request.arguments == plan.commands[0].arguments)
        #expect(request.environment == ["PATH": "/usr/bin:/bin"])
        #expect(request.timeout == .seconds(17) && request.maxOutputBytes == 262_144)
        #expect(request.stdin.isEmpty && !session.canStart && session.plan == nil)
        session.close()
    }

    @Test func inspectedScriptSelectionNeverInfersExecutableOrApprovesCommands() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = ContextDemoProjectCommandProbe()
        let session = try await inspected(directory, runner: runner)
        let draft = try #require(session.commands.first)
        #expect(draft.executablePath.isEmpty && draft.argumentsJSON == "[]")
        session.chooseScript("not-inspected", commandID: draft.id)
        #expect(session.commands.first == draft)
        session.chooseScript("preview", commandID: draft.id)
        let selected = try #require(session.commands.first)
        #expect(selected.executablePath.isEmpty)
        #expect(try JSONDecoder().decode([String].self, from: Data(selected.argumentsJSON.utf8)) == ["run", "preview"])
        session.reviewCommands()
        #expect(session.phase == .failed && !session.canStart)
        #expect(await runner.requests.isEmpty)
        session.close()
    }

    @Test func commandEditsInvalidateExactReviewAndRejectUnsafeOrMalformedChoices() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = ContextDemoProjectCommandProbe()
        let session = try await inspected(directory, runner: runner)
        try command(session)
        session.reviewCommands()
        #expect(session.canStart)
        try command(session, arguments: #"["run","preview"]"#)
        #expect(!session.canStart && session.plan == nil)
        for arguments in ["not JSON", #"{"arg":"run"}"#, #"["install"]"#, #"["--eval","code"]"#] {
            try command(session, arguments: arguments)
            session.reviewCommands()
            session.start()
            #expect(session.phase == .failed && session.plan == nil)
        }
        let draft = try #require(session.commands.first)
        session.setCommand(draft.id, executablePath: "/bin/sh", argumentsJSON: "[]", timeoutSeconds: 30)
        session.reviewCommands()
        #expect(!session.canStart && session.message == ContextDemoPreparationError.invalidCommand.userMessage)
        #expect(await runner.requests.isEmpty)
        session.close()
    }

    @Test func commandAndTotalTimeBoundsAreEnforcedBeforeStart() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = ContextDemoProjectCommandProbe()
        let session = try await inspected(directory, runner: runner)
        for _ in 0..<5 { session.addCommand() }
        #expect(session.commands.count == 3)
        for draft in session.commands {
            session.setCommand(draft.id, executablePath: "/usr/bin/true", argumentsJSON: "[]", timeoutSeconds: 60)
        }
        session.reviewCommands()
        #expect(!session.canStart && session.message == ContextDemoPreparationError.invalidPlan.userMessage)
        for draft in session.commands {
            session.setCommand(draft.id, executablePath: "/usr/bin/true", argumentsJSON: "[]", timeoutSeconds: 30)
        }
        session.reviewCommands()
        #expect(session.canStart)
        session.removeCommand(session.commands[0].id)
        #expect(session.plan == nil && session.commands.count == 2)
        #expect(await runner.requests.isEmpty)
        session.close()
    }

    @Test func changedProjectFactsFailBeforeRunnerReceivesAnything() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = ContextDemoProjectCommandProbe()
        let session = try await inspected(directory, runner: runner)
        try command(session)
        session.reviewCommands()
        try Data(#"{"scripts":{"build":"changed"}}"#.utf8).write(to: directory.appendingPathComponent("package.json"))
        session.start()
        try await eventually { session.phase == .failed }
        #expect(session.message == ContextDemoPreparationError.projectChanged.userMessage)
        #expect(await runner.requests.isEmpty)
        session.close()
    }

    @Test func stopKeepsOwnershipUntilRunnerDrainsAndRequiresAnotherReview() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = ContextDemoProjectCommandProbe(suspended: true)
        let session = try await inspected(directory, runner: runner)
        try command(session)
        session.reviewCommands()
        session.start()
        try await eventually { await runner.requests.count == 1 }
        session.stop()
        try await eventually { await runner.cancellationSeen }
        #expect(session.phase == .stopping && !session.canInspect && !session.canReview && !session.canStart)
        session.start()
        session.inspect()
        #expect(await runner.requests.count == 1)
        await runner.finishDraining()
        try await eventually { session.phase == .inspected }
        #expect(session.plan == nil && session.message == nil)
        session.start()
        #expect(await runner.requests.count == 1)
        session.close()
    }

    @Test func replacingDirectoryDrainsOldCommandWithoutPublishingOldSuccess() async throws {
        let directory = try fixture(), replacement = try fixture()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: replacement)
        }
        let runner = ContextDemoProjectCommandProbe(suspended: true)
        let session = try await inspected(directory, runner: runner)
        try command(session)
        session.reviewCommands()
        session.start()
        try await eventually { await runner.requests.count == 1 }
        session.chooseDirectory(replacement)
        #expect(session.directory == replacement && session.facts == nil && session.plan == nil)
        #expect(session.phase == .stopping)
        await runner.finishDraining()
        try await eventually { session.phase == .choosing }
        #expect(session.message == nil && session.directory == replacement)
        #expect(await runner.requests.count == 1)
        session.close()
    }

    @Test func closeDrainsAndNeverAllowsNewInspectionOrExecution() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = ContextDemoProjectCommandProbe(suspended: true)
        let session = try await inspected(directory, runner: runner)
        try command(session)
        session.reviewCommands()
        session.start()
        try await eventually { await runner.requests.count == 1 }
        session.close()
        #expect(session.phase == .stopping)
        session.chooseDirectory(directory)
        session.reviewCommands()
        session.inspect()
        session.start()
        await runner.finishDraining()
        try await eventually { session.phase == .closed }
        #expect(await runner.requests.count == 1)
        #expect(!session.canStart && !session.canInspect && session.message == nil)
    }

    @Test func nonzeroExitStopsTheRemainingReviewedCommands() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = ContextDemoProjectCommandProbe(exitCode: 1)
        let session = try await inspected(directory, runner: runner)
        try command(session)
        session.addCommand()
        let draft = try #require(session.commands.last)
        session.setCommand(draft.id, executablePath: "/usr/bin/true", argumentsJSON: "[]", timeoutSeconds: 30)
        session.reviewCommands()
        session.start()
        try await eventually { session.phase == .failed }
        #expect(session.message == ContextDemoPreparationError.commandFailed.userMessage)
        #expect(await runner.requests.count == 1)
        #expect(session.plan == nil && !session.canStart)
        session.close()
    }
}
#endif
