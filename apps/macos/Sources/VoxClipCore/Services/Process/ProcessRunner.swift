import Foundation

/// Argument-array execution only; AI §6.10. Never add provider credentials to environment.
public struct ProcessRequest: Sendable, Equatable {
    public var executable: URL
    public var arguments: [String]
    public var workingDirectory: URL
    public var environment: [String: String]
    public var stdin: Data
    public var timeout: Duration
    public var maxOutputBytes: Int
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
/// mac-ai implements process lifecycle; skeleton never starts a process.
public actor FoundationProcessRunner: ProcessRunner {
    public init() {}
    public func run(_ request: ProcessRequest) async throws -> ProcessResult { throw VoxClipError.notImplemented("mac-ai") }
}
