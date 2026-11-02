import Foundation

public struct ContextDemoProjectCommand: Equatable, Sendable {
    public let executable: URL
    public let arguments: [String]
    public let timeoutSeconds: Int

    public init(executable: URL, arguments: [String], timeoutSeconds: Int = 30) throws {
        let forbiddenExecutables: Set<String> = ["sh", "bash", "zsh", "fish", "csh", "tcsh", "env", "osascript", "curl", "wget", "ssh", "sudo"]
        let downloadArguments: Set<String> = ["install", "add", "update", "upgrade", "download", "fetch", "clone", "pull", "resolve", "restore"]
        let inlineCodeArguments: Set<String> = ["-c", "-e", "--eval", "--execute", "--command", "-command", "-encodedcommand"]
        guard executable.isFileURL, executable.path.hasPrefix("/"),
              executable.host == nil || executable.host == "" || executable.host == "localhost",
              executable.path.utf8.count <= 4096,
              !executable.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              executable.path == executable.standardizedFileURL.path,
              !forbiddenExecutables.contains(executable.lastPathComponent.lowercased()),
              (1...60).contains(timeoutSeconds), arguments.count <= 32,
              arguments.reduce(0, { $0 + $1.utf8.count }) <= 8192,
              !arguments.contains(where: { argument in
                  argument.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                      || downloadArguments.contains(argument.lowercased()) || inlineCodeArguments.contains(argument.lowercased())
              }) else { throw ContextDemoPreparationError.invalidCommand }
        self.executable = executable
        self.arguments = arguments
        self.timeoutSeconds = timeoutSeconds
    }

    public var reviewDescription: String {
        ([executable.path] + arguments).map { value in
            "‘\(value.replacingOccurrences(of: "‘", with: "\\u2018").replacingOccurrences(of: "’", with: "\\u2019"))’"
        }.joined(separator: " ")
    }
}

public struct ContextDemoProjectExecutionPlan: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let snapshot: ContextDemoProjectSnapshot
    public let revision: String
    public let commands: [ContextDemoProjectCommand]

    public static func prepare(snapshot: ContextDemoProjectSnapshot, revision: String,
                               commands: [ContextDemoProjectCommand]) throws -> Self {
        guard !revision.isEmpty, revision.utf8.count <= 512, (1...3).contains(commands.count),
              commands.reduce(0, { $0 + $1.timeoutSeconds }) <= 90 else {
            throw ContextDemoPreparationError.invalidPlan
        }
        return Self(id: UUID(), snapshot: snapshot, revision: revision, commands: commands)
    }

    public var reviewWarning: String {
        "These commands can execute arbitrary project code and hooks with your account’s permissions. "
        + "Only the listed manifest/README facts are checked for changes, not the whole repository. "
        + "No command is inferred from repository text. Dependencies must already be installed; "
        + "network-free behavior cannot be guaranteed by a process runner. Start any long-running preview yourself."
    }
}

public struct ContextDemoProjectExecutionApproval: Sendable {
    private let plan: ContextDemoProjectExecutionPlan
    private let approvedAt: Date

    public static func approve(plan: ContextDemoProjectExecutionPlan, currentRevision: String,
                               now: Date = Date()) throws -> Self {
        guard plan.revision == currentRevision else { throw ContextDemoPreparationError.stalePlan }
        return Self(plan: plan, approvedAt: now)
    }

    public func validate(plan: ContextDemoProjectExecutionPlan, currentRevision: String, now: Date = Date()) throws {
        guard self.plan == plan else { throw ContextDemoPreparationError.approvalRequired }
        guard plan.revision == currentRevision else { throw ContextDemoPreparationError.stalePlan }
        guard now >= approvedAt, now.timeIntervalSince(approvedAt) < 300 else {
            throw ContextDemoPreparationError.approvalExpired
        }
    }
}

public actor ContextDemoProjectExecutor {
    private let runner: any ProcessRunner
    private let inspector: ContextDemoProjectInspector
    private let now: @Sendable () -> Date
    private var operationID: UUID?
    private var active: (id: UUID, task: Task<[Int32], Error>)?

    public init(runner: any ProcessRunner, inspector: ContextDemoProjectInspector = ContextDemoProjectInspector(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.runner = runner
        self.inspector = inspector
        self.now = now
    }

    public func start(plan: ContextDemoProjectExecutionPlan, approval: ContextDemoProjectExecutionApproval,
                      currentRevision: @escaping @Sendable () async -> String) async throws -> [Int32] {
        try Task.checkCancellation()
        guard active == nil, operationID == nil else { throw ContextDemoPreparationError.invalidPlan }
        let token = UUID()
        operationID = token
        defer {
            if operationID == token { operationID = nil }
            if active?.id == token { active = nil }
        }
        let revision = await currentRevision()
        try Task.checkCancellation()
        guard operationID == token else { throw CancellationError() }
        try approval.validate(plan: plan, currentRevision: revision, now: now())
        let runner = runner, inspector = inspector, now = now
        let task = Task<[Int32], Error> {
            var exits: [Int32] = []
            for command in plan.commands {
                try Task.checkCancellation()
                try await inspector.validateCurrent(plan.snapshot)
                let revision = await currentRevision()
                try Task.checkCancellation()
                try approval.validate(plan: plan, currentRevision: revision, now: now())
                let result: ProcessResult
                do {
                    result = try await runner.run(ProcessRequest(executable: command.executable,
                        arguments: command.arguments, workingDirectory: plan.snapshot.directory,
                        environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(command.timeoutSeconds), maxOutputBytes: 262_144))
                } catch {
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    throw ContextDemoPreparationError.commandFailed
                }
                let finalRevision = await currentRevision()
                try Task.checkCancellation()
                try approval.validate(plan: plan, currentRevision: finalRevision, now: now())
                guard result.exitCode == 0 else { throw ContextDemoPreparationError.commandFailed }
                exits.append(result.exitCode)
            }
            return exits
        }
        active = (token, task)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func cancel() async {
        operationID = nil
        guard let active else { return }
        active.task.cancel()
        _ = await active.task.result
        if self.active?.id == active.id { self.active = nil }
    }
}
