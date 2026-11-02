import Foundation
import Observation
import VoxClipCore

@MainActor @Observable final class ContextDemoProjectLaunchSession {
    enum Phase: Equatable {
        case choosing, inspecting, inspected, ready, running, stopping, succeeded, failed, closed
    }

    struct CommandDraft: Identifiable, Equatable {
        let id = UUID()
        var executablePath = ""
        var argumentsJSON = "[]"
        var timeoutSeconds = 30

        func command() throws -> ContextDemoProjectCommand {
            guard executablePath.hasPrefix("/"), executablePath.utf8.count <= 4096,
                  argumentsJSON.utf8.count <= 16_384,
                  let data = argumentsJSON.data(using: .utf8),
                  let arguments = try? JSONDecoder().decode([String].self, from: data) else {
                throw ContextDemoPreparationError.invalidCommand
            }
            return try ContextDemoProjectCommand(executable: URL(fileURLWithPath: executablePath),
                arguments: arguments, timeoutSeconds: timeoutSeconds)
        }
    }

    private(set) var phase = Phase.choosing
    private(set) var directory: URL?
    private(set) var facts: ContextDemoProjectSnapshot?
    private(set) var commands = [CommandDraft()]
    private(set) var plan: ContextDemoProjectExecutionPlan?
    private(set) var message: String?
    @ObservationIgnored private let inspector: ContextDemoProjectInspector
    @ObservationIgnored private let executor: ContextDemoProjectExecutor
    @ObservationIgnored private var revision = UUID().uuidString
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var drain: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false

    init(runner: any ProcessRunner = FoundationProcessRunner(),
         inspector: ContextDemoProjectInspector = ContextDemoProjectInspector()) {
        self.inspector = inspector
        self.executor = ContextDemoProjectExecutor(runner: runner, inspector: inspector)
    }

    var busy: Bool { phase == .inspecting || phase == .running || phase == .stopping }
    var canInspect: Bool { directory != nil && !busy && !isClosed }
    var canReview: Bool { facts != nil && !busy && !isClosed }
    var canStart: Bool { phase == .ready && plan?.revision == revision && !isClosed }

    func chooseDirectory(_ url: URL?) {
        guard !isClosed else { return }
        stop()
        revision = UUID().uuidString
        directory = url
        facts = nil
        commands = [CommandDraft()]
        plan = nil
        message = nil
        if !busy { phase = .choosing }
    }

    func inspect() {
        guard canInspect, let directory else { return }
        invalidatePlan()
        facts = nil
        let expected = revision
        phase = .inspecting
        operation = Task { [weak self, inspector] in
            let scoped = directory.startAccessingSecurityScopedResource()
            defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
            do {
                let approval = try ContextDemoProjectReadApproval.approve(selectedDirectory: directory)
                let facts = try await inspector.inspect(approval: approval)
                try Task.checkCancellation()
                guard let self, self.revision == expected, !self.isClosed else { return }
                self.facts = facts
                self.phase = .inspected
                self.message = "Only the listed project facts were read. No command has been approved or run."
                self.operation = nil
            } catch {
                guard let self, self.revision == expected, !self.isClosed else { return }
                self.operation = nil
                self.fail(error)
            }
        }
    }

    func setCommand(_ id: UUID, executablePath: String, argumentsJSON: String, timeoutSeconds: Int) {
        guard !busy, !isClosed, let index = commands.firstIndex(where: { $0.id == id }) else { return }
        invalidatePlan()
        commands[index].executablePath = executablePath
        commands[index].argumentsJSON = argumentsJSON
        commands[index].timeoutSeconds = timeoutSeconds
    }

    func chooseScript(_ name: String, commandID: UUID) {
        guard facts?.packageScriptNames.contains(name) == true,
              let command = commands.first(where: { $0.id == commandID }),
              let data = try? JSONEncoder().encode(["run", name]),
              let json = String(data: data, encoding: .utf8) else { return }
        setCommand(commandID, executablePath: command.executablePath, argumentsJSON: json,
            timeoutSeconds: command.timeoutSeconds)
    }

    func addCommand() {
        guard !busy, !isClosed, commands.count < 3 else { return }
        invalidatePlan()
        commands.append(CommandDraft())
    }

    func removeCommand(_ id: UUID) {
        guard !busy, !isClosed, commands.count > 1, commands.contains(where: { $0.id == id }) else { return }
        invalidatePlan()
        commands.removeAll { $0.id == id }
    }

    func reviewCommands() {
        guard canReview, let facts else { return }
        invalidatePlan()
        do {
            plan = try ContextDemoProjectExecutionPlan.prepare(snapshot: facts, revision: revision,
                commands: commands.map { try $0.command() })
            phase = .ready
        } catch { fail(error) }
    }

    func start() {
        guard canStart, let plan else { return }
        do {
            let approval = try ContextDemoProjectExecutionApproval.approve(plan: plan, currentRevision: revision)
            let expected = revision
            phase = .running
            message = nil
            operation = Task { [weak self, executor] in
                let scoped = plan.snapshot.directory.startAccessingSecurityScopedResource()
                defer { if scoped { plan.snapshot.directory.stopAccessingSecurityScopedResource() } }
                do {
                    _ = try await executor.start(plan: plan, approval: approval, currentRevision: { [weak self] in
                        guard let self else { return "" }
                        return await self.revision
                    })
                    try Task.checkCancellation()
                    guard let self, self.revision == expected, !self.isClosed else { return }
                    self.operation = nil
                    self.plan = nil
                    self.phase = .succeeded
                    self.message = "Reviewed commands finished. Choose the running app window or enter its exact preview URL for a separate capture review."
                } catch {
                    guard let self, self.revision == expected, !self.isClosed else { return }
                    self.operation = nil
                    self.plan = nil
                    self.fail(error)
                }
            }
        } catch { fail(error) }
    }

    func stop() {
        guard !isClosed, phase != .stopping else { return }
        invalidatePlan()
        guard let operation else { return }
        phase = .stopping
        operation.cancel()
        drain = Task { [weak self, executor] in
            await executor.cancel()
            await operation.value
            guard let self else { return }
            self.operation = nil
            self.drain = nil
            self.phase = self.isClosed ? .closed : self.facts == nil ? .choosing : .inspected
            self.message = nil
        }
    }

    func close() {
        guard !isClosed else { return }
        stop()
        isClosed = true
        if !busy { phase = .closed }
    }

    private func invalidatePlan() {
        revision = UUID().uuidString
        plan = nil
        message = nil
        if !busy { phase = facts == nil ? .choosing : .inspected }
    }

    private func fail(_ error: Error) {
        if error is CancellationError {
            phase = facts == nil ? .choosing : .inspected
            message = nil
        } else {
            phase = .failed
            message = ContextDemoSession.message(for: error)
        }
    }
}
