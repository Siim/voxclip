import Foundation
import Testing
@testable import VoxClipCore

@Suite("CLI native process lifecycle", .serialized)
struct CLIProcessRunnerTests {
    @Test(arguments: [false, true])
    func escapedPipeHolderCannotBlockTimeoutOrCancel(_ cancel: Bool) async throws {
        let directory = try CLITestDirectory()
        let script = try cliNativeScript("""
        /usr/bin/perl -e 'use POSIX qw(setsid); setsid(); open(my $pid, ">escaped.pid"); print $pid "$$"; close($pid); sleep 30' &
        trap '' TERM
        wait
        """, in: directory.url)
        let start = ContinuousClock.now
        let task = Task {
            try await FoundationProcessRunner().run(ProcessRequest(executable: script, arguments: [],
                workingDirectory: directory.url, environment: [:], timeout: cancel ? .seconds(60) : .milliseconds(250)))
        }
        defer {
            task.cancel()
            if let escaped = try? cliReadPID(directory.url.appendingPathComponent("escaped.pid")) { _ = kill(escaped, SIGKILL) }
        }
        try await cliWaitForFile(directory.url.appendingPathComponent("escaped.pid"))
        let ready = ContinuousClock.now
        if cancel { task.cancel() }
        await #expect(throws: cancel ? LLMError.cancelled : LLMError.timeout) { try await task.value }
        let finished = ContinuousClock.now
        #expect(finished >= ready && ready >= start)
        #expect(finished - start < .seconds(6))
    }

    @Test func completedLeaderDoesNotWaitForPipeHoldingGrandchild() async throws {
        let directory = try CLITestDirectory()
        let script = try cliNativeScript("/bin/sleep 30 &\necho $! > child.pid\nprintf done\nexit 0", in: directory.url)
        defer {
            if let child = try? cliReadPID(directory.url.appendingPathComponent("child.pid")) { _ = kill(child, SIGKILL) }
        }
        let start = ContinuousClock.now
        let result = try await FoundationProcessRunner().run(ProcessRequest(executable: script, arguments: [],
            workingDirectory: directory.url, environment: [:], timeout: .seconds(10)))
        #expect(result.exitCode == 0)
        #expect(result.stdout == Data("done".utf8))
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func termRespectingChildStopsPromptly() async throws {
        let directory = try CLITestDirectory()
        let start = ContinuousClock.now
        await #expect(throws: LLMError.timeout) {
            try await FoundationProcessRunner().run(ProcessRequest(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                workingDirectory: directory.url, environment: [:], timeout: .milliseconds(200)))
        }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(200))
        #expect(elapsed < .seconds(2))
    }

    @Test func spawnedChildHasEmptyBlockedSignalMask() async throws {
        let directory = try CLITestDirectory()
        let result = try await FoundationProcessRunner().run(ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "import signal; print(list(signal.pthread_sigmask(signal.SIG_BLOCK, [])))"],
            workingDirectory: directory.url, environment: [:], timeout: .seconds(5)))
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "[]\n")
    }

    @Test func argumentArrayPreservesShellMetacharacters() async throws {
        let directory = try CLITestDirectory()
        let script = try cliNativeScript("printf '%s\\n' \"$@\"", in: directory.url)
        let arguments = ["space here", "\"double\" 'single' \\", "$(touch must-not-exist)", "line\none", "世界"]
        let result = try await FoundationProcessRunner().run(ProcessRequest(executable: script, arguments: arguments,
            workingDirectory: directory.url, environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(5)))
        #expect(result.exitCode == 0)
        #expect(result.stdout == Data((arguments.joined(separator: "\n") + "\n").utf8))
        #expect(!FileManager.default.fileExists(atPath: directory.url.appendingPathComponent("must-not-exist").path))
    }

    @Test func drainsBothPipesWhileWritingLargeStdin() async throws {
        let directory = try CLITestDirectory()
        let script = try cliNativeScript("""
        /bin/dd if=/dev/zero bs=65536 count=4 2>/dev/null &
        ( /bin/dd if=/dev/zero bs=65536 count=4 2>/dev/null ) 1>&2 &
        /bin/cat >/dev/null
        wait
        printf finished
        """, in: directory.url)
        let result = try await FoundationProcessRunner().run(ProcessRequest(executable: script, arguments: [],
            workingDirectory: directory.url, environment: [:], stdin: Data(repeating: 65, count: 400_000),
            timeout: .seconds(5), maxOutputBytes: 300_000))
        #expect(result.exitCode == 0)
        #expect(result.stdout.count == 4 * 65536 + 8)
        #expect(result.stderr.count == 4 * 65536)
        #expect(result.stdout.suffix(8) == Data("finished".utf8))
    }

    @Test(arguments: [false, true])
    func enforcesIndependentOutputCaps(_ standardError: Bool) async throws {
        let directory = try CLITestDirectory()
        let redirect = standardError ? "1>&2" : ""
        let script = try cliNativeScript("( /bin/dd if=/dev/zero bs=65536 count=4 2>/dev/null ) \(redirect)", in: directory.url)
        await #expect(throws: LLMError.cliFailed("CLI output exceeded its byte limit.")) {
            try await FoundationProcessRunner().run(ProcessRequest(executable: script, arguments: [],
                workingDirectory: directory.url, environment: [:], timeout: .seconds(5), maxOutputBytes: 1024))
        }
    }

    @Test func earlyExitDoesNotSignalParentWithSIGPIPE() async throws {
        let directory = try CLITestDirectory()
        let script = try cliNativeScript("exit 0", in: directory.url)
        let result = try await FoundationProcessRunner().run(ProcessRequest(executable: script, arguments: [],
            workingDirectory: directory.url, environment: [:], stdin: Data(repeating: 65, count: 1_000_000), timeout: .seconds(5)))
        #expect(result.exitCode == 0)
    }

    @Test func timeoutEscalatesAndKillsEntireProcessGroup() async throws {
        let directory = try CLITestDirectory()
        let script = try cliNativeTree(in: directory.url)
        let start = ContinuousClock.now
        await #expect(throws: LLMError.timeout) {
            try await FoundationProcessRunner().run(ProcessRequest(executable: script, arguments: [],
                workingDirectory: directory.url, environment: [:], timeout: .milliseconds(400)))
        }
        #expect(ContinuousClock.now - start >= .seconds(3))
        try await cliAssertTreeTerminated(in: directory.url)
    }

    @Test func cancellationKillsProcessGroupAndReapsParent() async throws {
        let directory = try CLITestDirectory()
        let script = try cliNativeTree(in: directory.url)
        let task = Task {
            try await FoundationProcessRunner().run(ProcessRequest(executable: script, arguments: [],
                workingDirectory: directory.url, environment: [:], timeout: .seconds(60)))
        }
        defer { task.cancel() }
        try await cliWaitForFile(directory.url.appendingPathComponent("child.pid"))
        let parent = try cliReadPID(directory.url.appendingPathComponent("parent.pid"))
        #expect(getpgid(parent) == parent)
        task.cancel()
        await #expect(throws: LLMError.cancelled) { try await task.value }
        try await cliAssertTreeTerminated(in: directory.url)
    }

    @Test func cancellationBeforeSpawnDoesNotExecute() async throws {
        let directory = try CLITestDirectory()
        let script = try cliNativeScript("touch launched", in: directory.url)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await FoundationProcessRunner().run(ProcessRequest(executable: script, arguments: [],
                workingDirectory: directory.url, environment: [:], timeout: .seconds(5)))
        }
        await #expect(throws: LLMError.cancelled) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: directory.url.appendingPathComponent("launched").path))
    }

    @Test func missingExecutableAndNULArgumentsAreSafeFailures() async throws {
        let directory = try CLITestDirectory()
        let runner = FoundationProcessRunner()
        await #expect(throws: LLMError.cliMissing) {
            try await runner.run(ProcessRequest(executable: directory.url.appendingPathComponent("absent"), arguments: [],
                workingDirectory: directory.url, environment: [:], timeout: .seconds(5)))
        }
        await #expect(throws: LLMError.cliFailed("Invalid process arguments.")) {
            try await runner.run(ProcessRequest(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["bad\0argument"],
                workingDirectory: directory.url, environment: [:], timeout: .seconds(5)))
        }
    }

    @Test func appServerResponseEndsLongRunningProcess() async throws {
        let directory = try CLITestDirectory()
        let script = try cliNativeScript("""
        IFS= read -r initialize
        printf '{"id":1,"result":{}}\\n'
        IFS= read -r initialized
        IFS= read -r models
        printf '{"id":2,"result":{"data":[]}}\\n'
        /bin/sleep 60
        """, in: directory.url)
        var request = ProcessRequest(executable: script, arguments: [], workingDirectory: directory.url,
            environment: [:], stdin: Data("initialize\ninitialized\nmodel/list\n".utf8), timeout: .seconds(15))
        request.cliCompletionResponseID = 2
        request.cliInitializationResponseID = 1
        let start = ContinuousClock.now
        let result = try await FoundationProcessRunner().run(request)
        #expect(String(decoding: result.stdout, as: UTF8.self).contains("\"id\":2"))
        #expect(ContinuousClock.now - start < .seconds(5))
    }
}

private func cliNativeScript(_ body: String, in directory: URL, name: String = "fake-cli") throws -> URL {
    let script = directory.appendingPathComponent(name)
    try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    return script
}

private func cliNativeTree(in directory: URL) throws -> URL {
    _ = try cliNativeScript("""
    trap '' TERM
    echo $$ > child.pid
    while :; do /bin/sleep 1; done
    """, in: directory, name: "child")
    return try cliNativeScript("""
    trap '' TERM
    echo $$ > parent.pid
    ./child &
    wait
    """, in: directory)
}

private func cliWaitForFile(_ url: URL) async throws {
    for _ in 0..<200 {
        if let data = try? Data(contentsOf: url), !data.isEmpty { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Child process did not start")
    throw LLMError.timeout
}

private func cliReadPID(_ url: URL) throws -> Int32 {
    try #require(Int32(String(decoding: Data(contentsOf: url), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
}

private func cliAssertTreeTerminated(in directory: URL) async throws {
    let parent = try cliReadPID(directory.appendingPathComponent("parent.pid"))
    let child = try cliReadPID(directory.appendingPathComponent("child.pid"))
    for _ in 0..<200 {
        if kill(parent, 0) != 0 && kill(child, 0) != 0 { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(kill(parent, 0) != 0)
    #expect(kill(child, 0) != 0)
}
