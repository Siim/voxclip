import Foundation
import Synchronization

/// Argument-array execution only; AI §6.10. Never add provider credentials to environment.
public struct ProcessRequest: Sendable, Equatable {
    public var executable: URL
    public var arguments: [String]
    public var workingDirectory: URL
    public var environment: [String: String]
    public var stdin: Data
    public var timeout: Duration
    public var maxOutputBytes: Int
    var cliCompletionResponseID: Int?
    var cliInitializationResponseID: Int?
    public init(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String], stdin: Data = Data(), timeout: Duration, maxOutputBytes: Int = 16 * 1024 * 1024) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.stdin = stdin
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
    }
}

/// Capped concurrent process output; AI §6.10. Never log raw output.
public struct ProcessResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Own process group, concurrent bounded pipes, cancellation and cleanup; AI §6.10.
public protocol ProcessRunner: Sendable { func run(_ request: ProcessRequest) async throws -> ProcessResult }
/// Native argument-array execution in an independently terminated process group.
public actor FoundationProcessRunner: ProcessRunner {
    public init() {}
    public func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let cancellation = CLIProcessCancellation()
        return try await withTaskCancellationHandler {
            if Task.isCancelled { throw LLMError.cancelled }
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try CLIProcessExecution.run(request, cancellation: cancellation)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

private final class CLIProcessCancellation: Sendable {
    private let value = Mutex(false)
    var isCancelled: Bool { value.withLock { $0 } }
    func cancel() { value.withLock { $0 = true } }
}

private enum CLIProcessExecution {
    private struct RPCResponse: Decodable { let id: Int?; let error: JSONValue? }

    static func run(_ request: ProcessRequest, cancellation: CLIProcessCancellation) throws -> ProcessResult {
        guard !cancellation.isCancelled else { throw LLMError.cancelled }
        guard request.timeout > .zero, request.maxOutputBytes >= 0 else {
            throw LLMError.cliFailed("Invalid process limits.")
        }
        let arguments = [request.executable.path] + request.arguments
        let environment = request.environment.map { "\($0.key)=\($0.value)" }
        guard !arguments.contains(where: { $0.contains("\0") }),
              !environment.contains(where: { $0.contains("\0") }),
              !request.environment.keys.contains(where: { $0.isEmpty || $0.contains("=") }),
              !request.workingDirectory.path.contains("\0") else {
            throw LLMError.cliFailed("Invalid process arguments.")
        }
        var descriptors: [Int32] = []
        defer { for descriptor in descriptors where descriptor >= 0 { _ = close(descriptor) } }
        func makePipe() throws -> (Int32, Int32) {
            var ends: [Int32] = [0, 0]
            guard pipe(&ends) == 0 else { throw LLMError.cliFailed("Unable to create CLI pipes.") }
            descriptors.append(contentsOf: ends)
            return (ends[0], ends[1])
        }
        func closeDescriptor(_ descriptor: Int32) {
            if let index = descriptors.firstIndex(of: descriptor) {
                _ = close(descriptor)
                descriptors[index] = -1
            }
        }
        let input = try makePipe()
        let output = try makePipe()
        let errors = try makePipe()
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw LLMError.cliFailed("Unable to initialize CLI file actions.")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw LLMError.cliFailed("Unable to initialize CLI process attributes.")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        sigdelset(&defaultSignals, SIGKILL)
        sigdelset(&defaultSignals, SIGSTOP)
        let setup = [
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)),
            posix_spawnattr_setpgroup(&attributes, 0),
            posix_spawnattr_setsigmask(&attributes, &signalMask),
            posix_spawnattr_setsigdefault(&attributes, &defaultSignals),
            posix_spawn_file_actions_adddup2(&actions, input.0, STDIN_FILENO),
            posix_spawn_file_actions_adddup2(&actions, output.1, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, errors.1, STDERR_FILENO),
            posix_spawn_file_actions_addchdir(&actions, request.workingDirectory.path),
        ]
        guard setup.allSatisfy({ $0 == 0 }) else { throw LLMError.cliFailed("Unable to configure CLI process.") }
        for descriptor in [input.1, output.0, errors.0] {
            guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else {
                throw LLMError.cliFailed("Unable to configure CLI pipes.")
            }
        }
        guard fcntl(input.1, F_SETNOSIGPIPE, 1) == 0 else {
            throw LLMError.cliFailed("Unable to configure CLI input.")
        }
        let argumentPointers = arguments.map { strdup($0) } + [nil]
        let environmentPointers = environment.map { strdup($0) } + [nil]
        defer {
            for pointer in argumentPointers { free(pointer) }
            for pointer in environmentPointers { free(pointer) }
        }
        var processID: pid_t = 0
        let spawnError = argumentPointers.withUnsafeBufferPointer { argumentBuffer in
            environmentPointers.withUnsafeBufferPointer { environmentBuffer in
                posix_spawn(&processID, request.executable.path, &actions, &attributes,
                            argumentBuffer.baseAddress!, environmentBuffer.baseAddress!)
            }
        }
        guard spawnError == 0 else {
            if spawnError == ENOENT { throw LLMError.cliMissing }
            throw LLMError.cliFailed("Unable to start CLI (error \(spawnError)).")
        }
        closeDescriptor(input.0)
        closeDescriptor(output.1)
        closeDescriptor(errors.1)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: request.timeout)
        let outputLimit = min(request.maxOutputBytes, 16 * 1024 * 1024)
        var stdout = Data()
        var stderr = Data()
        var inputOffset = 0
        var inputLimit = request.cliInitializationResponseID == nil ? request.stdin.count :
            request.stdin.firstIndex(of: 10).map { $0 + 1 } ?? request.stdin.count
        var inputOpen = true
        var outputOpen = true
        var errorsOpen = true
        var reaped = false
        var processStatus: Int32 = 0
        var failure: LLMError?
        var terminationStarted: ContinuousClock.Instant?
        var killedAt: ContinuousClock.Instant?
        var reapedAt: ContinuousClock.Instant?
        var responseOffset = 0
        defer {
            _ = kill(-processID, SIGKILL)
            if !reaped {
                while waitpid(processID, &processStatus, 0) < 0 && errno == EINTR {}
            }
        }
        func terminate(_ error: LLMError?) {
            if failure == nil { failure = error }
            if terminationStarted == nil {
                terminationStarted = clock.now
                _ = kill(-processID, SIGTERM)
            }
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !reaped || outputOpen || errorsOpen ||
                (terminationStarted != nil && killedAt == nil && kill(-processID, 0) == 0) {
            if cancellation.isCancelled { terminate(.cancelled) }
            else if !reaped && clock.now >= deadline && terminationStarted == nil { terminate(.timeout) }
            if let started = terminationStarted, clock.now - started >= .seconds(3), killedAt == nil {
                _ = kill(-processID, SIGKILL)
                killedAt = clock.now
            }
            if let reapedAt, terminationStarted == nil, clock.now - reapedAt >= .milliseconds(300) {
                _ = kill(-processID, SIGTERM)
                _ = kill(-processID, SIGKILL)
                closeDescriptor(output.0)
                closeDescriptor(errors.0)
                break
            }
            if let killedAt, clock.now - killedAt >= .milliseconds(500) {
                closeDescriptor(output.0)
                closeDescriptor(errors.0)
                break
            }
            if inputOpen && ((inputOffset == request.stdin.count && request.cliCompletionResponseID == nil) || terminationStarted != nil || reaped) {
                closeDescriptor(input.1)
                inputOpen = false
            }
            var polls = [
                pollfd(fd: outputOpen ? output.0 : -1, events: Int16(POLLIN), revents: 0),
                pollfd(fd: errorsOpen ? errors.0 : -1, events: Int16(POLLIN), revents: 0),
                pollfd(fd: inputOpen && inputOffset < inputLimit ? input.1 : -1, events: Int16(POLLOUT), revents: 0),
            ]
            if poll(&polls, nfds_t(polls.count), 20) < 0 && errno != EINTR {
                terminate(.cliFailed("Unable to read CLI pipes."))
            }
            for index in 0..<2 where polls[index].fd >= 0 && polls[index].revents != 0 {
                let count = read(polls[index].fd, &buffer, buffer.count)
                if count > 0 {
                    let currentCount = index == 0 ? stdout.count : stderr.count
                    let remaining = max(0, outputLimit - currentCount)
                    if index == 0 { stdout.append(contentsOf: buffer.prefix(min(count, remaining))) }
                    else { stderr.append(contentsOf: buffer.prefix(min(count, remaining))) }
                    if count > remaining { terminate(.cliFailed("CLI output exceeded its byte limit.")) }
                } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
                    closeDescriptor(polls[index].fd)
                    if index == 0 { outputOpen = false } else { errorsOpen = false }
                }
            }
            if inputOpen && polls[2].revents != 0 {
                let written = request.stdin.withUnsafeBytes { bytes in
                    write(input.1, bytes.baseAddress!.advanced(by: inputOffset), min(64 * 1024, inputLimit - inputOffset))
                }
                if written > 0 { inputOffset += written }
                else if written < 0 && errno != EAGAIN && errno != EINTR {
                    closeDescriptor(input.1)
                    inputOpen = false
                }
            }
            if let responseID = request.cliCompletionResponseID {
                while let newline = stdout[responseOffset...].firstIndex(of: 10) {
                    let line = stdout.subdata(in: responseOffset..<newline)
                    responseOffset = newline + 1
                    if let response = try? JSONDecoder().decode(RPCResponse.self, from: line) {
                        if response.id == request.cliInitializationResponseID {
                            if response.error != nil { terminate(nil) }
                            else { inputLimit = request.stdin.count }
                        }
                        if response.id == responseID { terminate(nil) }
                    }
                }
            }
            if !reaped {
                let waited = waitpid(processID, &processStatus, WNOHANG)
                if waited == processID { reaped = true; reapedAt = clock.now }
                else if waited < 0 && errno != EINTR {
                    reaped = true
                    terminate(.cliFailed("Unable to wait for CLI process."))
                }
            }
        }
        if cancellation.isCancelled { throw LLMError.cancelled }
        if let failure { throw failure }
        let signal = processStatus & 0x7f
        let exitCode = signal == 0 ? (processStatus >> 8) & 0xff : 128 + signal
        return ProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }
}
