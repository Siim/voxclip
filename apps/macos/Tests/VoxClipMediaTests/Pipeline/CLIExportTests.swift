import AVFoundation
import Foundation
import Darwin
import Synchronization
import Testing
import VoxClipCore
import VoxClipMedia

struct CLIResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: String
    let interruptLatency: Double?
    let watchdogFired: Bool
    let interruptReadinessObserved: Bool
    var json: [String: Any] { get throws { try #require(JSONSerialization.jsonObject(with: stdout) as? [String: Any]) } }

    struct InterruptTiming {
        let handler: UInt64
        let exportStart: UInt64
        let exit: UInt64
        let phases: [String: UInt64]

        var breakdown: String {
            func seconds(_ start: String, _ end: String) -> String {
                guard let first = phases[start], let last = phases[end], first > 0, last >= first else { return "notReached" }
                let elapsed: Double = Double(last - first) / 1e9
                return String(format: "%.6f", elapsed)
            }
            let intervals: [(String, String, String)] = [
                ("handler_to_cancel", "handler", "cancelRequest"),
                ("cancel_to_pumps", "cancelRequest", "pumpsStopped"),
                ("cancel_to_teardown", "cancelRequest", "teardownStart"),
                ("reader_teardown", "teardownStart", "readersStopped"),
                ("video_reader_cancel", "videoReaderCancelStart", "videoReaderCancelEnd"),
                ("audio_reader_cancel", "audioReaderCancelStart", "audioReaderCancelEnd"),
                ("writer_teardown", "writerCancelStart", "writerCancelEnd"),
                ("partial_delete", "writerCancelEnd", "partialDeleted"),
                ("resource_release", "partialDeleted", "exportReturned"),
                ("return_to_exit", "exportReturned", "exit")
            ]
            return intervals.map { (interval: (String, String, String)) -> String in
                "\(interval.0)=\(seconds(interval.1, interval.2))"
            }.joined(separator: " ")
        }
    }

    var internalInterruptTiming: InterruptTiming {
        get throws {
            let prefix = "VOXCLIP_TEST_INTERRUPT_TIMING "
            let lines = stderr.split(separator: "\n").filter { $0.hasPrefix(prefix) }
            let line = try #require(lines.count == 1 ? lines.first : nil, "Expected one CLI-owned interrupt timing record: \(stderr)")
            let fields = line.dropFirst(prefix.count).split(separator: " ")
            var phases: [String: UInt64] = [:]
            for field in fields {
                let pair = field.split(separator: "=", maxSplits: 1)
                try #require(pair.count == 2)
                let value = try #require(UInt64(pair[1]))
                try #require(phases.updateValue(value, forKey: String(pair[0])) == nil)
            }
            let handler = try #require(phases["handler"])
            let exportStart = try #require(phases["exportStart"])
            let exit = try #require(phases["exit"])
            try #require(handler > 0 && exit >= max(handler, exportStart))
            return InterruptTiming(handler: handler, exportStart: exportStart, exit: exit, phases: phases)
        }
    }

    var internalStopPathLatency: Double {
        get throws {
            let timing = try internalInterruptTiming
            try #require(timing.exportStart > 0 && timing.handler >= timing.exportStart,
                "The interrupt must arrive during the export")
            return Double(timing.exit - max(timing.handler, timing.exportStart)) / 1e9
        }
    }

}

private final class CLIProcessTiming: Sendable {
    private struct State {
        var interruptedAt: ContinuousClock.Instant?
        var watchdogFired = false
    }
    private let state = Mutex(State())
    func interrupted() { state.withLock { $0.interruptedAt = .now } }
    func watchdog() { state.withLock { $0.watchdogFired = true } }
    var watchdogFired: Bool { state.withLock { $0.watchdogFired } }
    func latency(to end: ContinuousClock.Instant) -> Double? {
        state.withLock { $0.interruptedAt }.map {
            let duration = $0.duration(to: end).components
            return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        }
    }
}

func runCLI(_ arguments: [String], directory: URL, interruptAfter: Double? = nil,
                    interruptTimeout: Double = 15, timeout: Double = 20, sharedRoot: URL? = nil,
                    recordInterruptTiming: Bool = true, interruptBeforeExport: Bool = false) throws -> CLIResult {
    var package = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { package.deleteLastPathComponent() }
    let stdoutURL = directory.appendingPathComponent("stdout-\(UUID().uuidString)")
    let stderrURL = directory.appendingPathComponent("stderr-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
    let stdout = try FileHandle(forWritingTo: stdoutURL)
    let stderr = try FileHandle(forWritingTo: stderrURL)
    defer { try? stdout.close(); try? stderr.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VOXCLIP_CLI"] ?? package.appendingPathComponent(".build/debug/voxclip-cli").path)
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    for key in ["VOXCLIP_ELEVENLABS_API_KEY", "VOXCLIP_ANTHROPIC_API_KEY", "VOXCLIP_OPENAI_API_KEY", "VOXCLIP_XAI_API_KEY", "VOXCLIP_GEMINI_API_KEY"] {
        environment.removeValue(forKey: key)
    }
    environment["VOXCLIP_LIVE_TESTS"] = "0"
    environment["VOXCLIP_TEST_DOWNLOAD"] = "0"
    environment["VOXCLIP_NO_KEYCHAIN"] = "1"
    environment["VOXCLIP_TEST_INTERRUPT_TIMING"] = interruptAfter != nil && recordInterruptTiming ? "1" : nil
    environment["VOXCLIP_TEST_PRE_EXPORT_PAUSE"] = interruptBeforeExport ? "1" : nil
    environment["VOXCLIP_DATA_DIR"] = directory.appendingPathComponent("data").path
    environment["VOXCLIP_SHARED_DIR"] = try (sharedRoot ?? FixtureLoader.sharedRoot(environment: [:])).path
    // Each subprocess owns its renderer scratch; concurrent Media tests must not
    // observe its temporary snapshots as their own allocations.
    let scratch = directory.appendingPathComponent("tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    environment["TMPDIR"] = scratch.path
    process.environment = environment
    process.standardOutput = stdout; process.standardError = stderr
    let partial: URL?
    if interruptAfter != nil && !interruptBeforeExport {
        let index = try #require(arguments.firstIndex(of: "--export"))
        try #require(index + 1 < arguments.count)
        partial = URL(fileURLWithPath: arguments[index + 1] + ".partial")
    } else { partial = nil }
    try process.run()
    let timing = CLIProcessTiming()
    let watchdog = DispatchWorkItem {
        if process.isRunning {
            timing.watchdog()
            kill(process.processIdentifier, SIGKILL)
        }
    }
    let interrupt = DispatchWorkItem {
        if process.isRunning {
            timing.interrupted()
            process.interrupt()
            DispatchQueue.global().asyncAfter(deadline: .now() + interruptTimeout, execute: watchdog)
        }
    }
    var readinessObserved = false
    if let interruptAfter {
        // Preparation has its own hang guard. The 15 s stop guard begins only
        // when SIGINT is actually sent, after readiness and the seeded offset.
        let readinessDeadline = ContinuousClock.now + .seconds(60)
        while process.isRunning {
            if let partial {
                readinessObserved = FileManager.default.fileExists(atPath: partial.path)
            } else {
                let data = try? Data(contentsOf: stderrURL)
                readinessObserved = data.map { String(decoding: $0, as: UTF8.self)
                    .contains("VOXCLIP_TEST_PRE_EXPORT_PAUSE ready\n") } ?? false
            }
            if readinessObserved { break }
            if ContinuousClock.now >= readinessDeadline {
                timing.watchdog()
                kill(process.processIdentifier, SIGKILL)
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if readinessObserved {
            DispatchQueue.global().asyncAfter(deadline: .now() + interruptAfter, execute: interrupt)
        }
    } else {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
    }
    process.waitUntilExit()
    let exitedAt = ContinuousClock.now
    interrupt.cancel(); watchdog.cancel()
    return CLIResult(status: process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus, stdout: try Data(contentsOf: stdoutURL),
        stderr: String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self), interruptLatency: timing.latency(to: exitedAt),
        watchdogFired: timing.watchdogFired, interruptReadinessObserved: readinessObserved)
}

func cliDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-cli-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func cliProject(source: URL, transcript: Transcript?, edits: ProjectEdits = ProjectEdits()) async throws -> Project {
    let probe = try await AVMediaProbe().probe(source)
    let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
    return Project(id: UUID().uuidString.lowercased(), createdAt: Date(), modifiedAt: Date(), savedBy: ProjectWriter(version: "9.8.7"),
        media: ProjectMedia(source: MediaReference(absolutePath: source.path,
            sizeBytes: try #require((attributes[.size] as? NSNumber)?.int64Value), durationSeconds: probe.durationSeconds,
            contentKey: try JSONProjectStore.contentKey(for: source), video: probe.video, audio: probe.audio)),
        transcript: transcript, edits: edits)
}

extension HeavyMediaTests {
@Test(.timeLimit(.minutes(1)), arguments: ["clip", "range", "stored", "media"])
func cliSelectsExportScopeBeforeCuttingFillers(_ scope: String) async throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try await NativeMediaFixtures.shared.file()
    let transcript = Transcript(words: [
        TimedWord(id: "a-start", text: "First", start: 0.05, end: 0.2),
        TimedWord(id: "a-filler", text: "um", start: 0.3, end: 0.4),
        TimedWord(id: "a-end", text: "clip", start: 0.5, end: 0.65),
        TimedWord(id: "b-start", text: "Second", start: 1.05, end: 1.2),
        TimedWord(id: "b-filler", text: "uh", start: 1.3, end: 1.4),
        TimedWord(id: "b-end", text: "clip", start: 1.5, end: 1.65)],
        durationSeconds: 2, engine: EngineRef(id: .elevenlabs, engineVersion: "synthetic-fixture"),
        rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
    let clips = [ClipRange(id: "a", startWordId: "a-start", endWordId: "a-end"),
                 ClipRange(id: "b", startWordId: "b-start", endWordId: "b-end")]
    let input = directory.appendingPathComponent(scope == "media" ? "transcript.json" : "take.voxclip")
    var arguments: [String]
    var expected = EditState(transcript: transcript)
    if scope == "media" {
        try ProjectJSON.encoder().encode(transcript).write(to: input)
        arguments = ["--open", source.path, "--transcript", input.path]
    } else {
        let project = try await cliProject(source: source, transcript: transcript,
            edits: ProjectEdits(clips: clips, activeClipId: "a"))
        try await JSONProjectStore(appVersion: "9.8.7").save(project, to: input)
        expected.clips = clips
        expected.activeClipId = scope == "stored" ? "a" : "b"
        arguments = ["--open", input.path]
        if scope == "clip" { arguments += ["--clip", "b"] }
        if scope == "range" { arguments += ["--range", "3:5"] }
    }
    let original = try Data(contentsOf: input)
    expected = EditReducer.reduce(expected, command: .cutFillers)
    #expect(expected.cutWordIds == (scope == "media" ? ["a-filler", "b-filler"] : scope == "stored" ? ["a-filler"] : ["b-filler"]))
    let plan = try EditPlan.build(transcript: transcript, editState: expected, activeClip: expected.activeClip,
        duration: 2, sampleRate: 48000)
    let output = directory.appendingPathComponent("out.mp4")
    let invocation = try runCLI(arguments + ["--cut-fillers", "--export", output.path, "--style", "off", "--json", "--quiet"], directory: directory)
    try #require(invocation.status == 0, "CLI exit \(invocation.status): \(invocation.stderr)")
    let result = try invocation.json
    #expect(result["audioSamples"] as? Int64 == plan.outputSamples)
    #expect(abs(try #require(result["durationSeconds"] as? Double) - Double(plan.outputSamples) / plan.sampleRate) < 1e-9)
    #expect(try Data(contentsOf: input) == original)
}

@Test(arguments: ["nosuch", "../x"], ["missing", "media", "all-cut", "project"])
func cliRejectsExplicitStylesBeforeOpeningInput(_ style: String, _ scenario: String) async throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let input: URL
    var arguments: [String] = []
    if scenario == "missing" { input = directory.appendingPathComponent("missing.mov") }
    else if scenario == "project" {
        input = directory.appendingPathComponent("unreadable.voxclip")
        try Data("not a project".utf8).write(to: input)
    } else {
        input = try await NativeMediaFixtures.shared.file()
        if scenario == "all-cut" {
            let transcript = Transcript(words: [TimedWord(id: "um", text: "um", start: 0.2, end: 0.4)],
                durationSeconds: 2, engine: EngineRef(id: .elevenlabs, engineVersion: "synthetic-fixture"),
                rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
            let transcriptURL = directory.appendingPathComponent("transcript.json")
            try ProjectJSON.encoder().encode(transcript).write(to: transcriptURL)
            arguments += ["--transcript", transcriptURL.path, "--cut-fillers"]
        }
    }
    let output = directory.appendingPathComponent("out.mp4")
    let invocation = try runCLI(arguments + ["--open", input.path, "--style", style, "--export", output.path, "--json", "--quiet"], directory: directory)
    #expect(invocation.status == 2)
    let error = try #require(invocation.json["error"] as? [String: Any])
    #expect(error["code"] as? String == "usageError")
    #expect(error["message"] as? String == (style == "nosuch" ? "Unknown caption style: nosuch" : "Invalid caption style ID"))
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("data").path))
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(try !FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.contains(".partial") || $0.contains(".rollback-") })
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func cliImportedPauseThresholdMatchesTranscriptRefinement(_ refined: Bool) async throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try await NativeMediaFixtures.shared.file()
    let transcript = Transcript(words: [TimedWord(id: "first", text: "First", start: 0.1, end: 0.3),
                                        TimedWord(id: "second", text: "second", start: 1.2, end: 1.4)],
        durationSeconds: 2, engine: EngineRef(id: .whispercpp, engineVersion: "synthetic-fixture"), refined: refined,
        rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
    let transcriptURL = directory.appendingPathComponent("transcript.json")
    try ProjectJSON.encoder().encode(transcript).write(to: transcriptURL)
    let invocation = try runCLI(["--open", source.path, "--transcript", transcriptURL.path, "--tighten-pauses",
        "--export", directory.appendingPathComponent("out.mp4").path, "--style", "off", "--json", "--quiet"], directory: directory)
    try #require(invocation.status == 0, "CLI exit \(invocation.status): \(invocation.stderr)")
    let result = try invocation.json
    #expect(result["audioSamples"] as? Int == (refined ? 67200 : 96000))
    #expect(abs(try #require(result["durationSeconds"] as? Double) - (refined ? 1.4 : 2)) < 1e-9)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func cliExportDrainsBothTracksWithoutDeadlock(_ hasWords: Bool) async throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcript = Transcript(words: hasWords ? [TimedWord(id: "hello", text: "Hello!", start: 0.2, end: 0.8)] : [],
                                durationSeconds: 2, engine: EngineRef(id: .elevenlabs, engineVersion: "synthetic-fixture"),
                                rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
    let transcriptURL = directory.appendingPathComponent("transcript.json")
    try ProjectJSON.encoder().encode(transcript).write(to: transcriptURL)
    let output = directory.appendingPathComponent("out.mp4")
    let source = try await NativeMediaFixtures.shared.file()
    let invocation = try runCLI(["export", "--open", source.path, "--transcript", transcriptURL.path,
        "--export", output.path, "--style", "off", "--json", "--quiet"], directory: directory)
    try #require(invocation.status == 0, "CLI exit \(invocation.status): \(invocation.stderr)")
    let result = try invocation.json
    #expect(result["frames"] as? Int == 60)
    #expect(result["audioSamples"] as? Int == 96000)
    #expect(result["ok"] as? Bool == true)
    #expect(try await AVMediaProbe().probe(output).isPlayable)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func cliRefusesAllCutWordsEvenWhenGapsRemain(_ scoped: Bool) async throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try await NativeMediaFixtures.shared.file()
    var words = [TimedWord(id: "um", text: "um", start: 0.2, end: 0.4),
                 TimedWord(id: "uh", text: "uh", start: 1, end: 1.2)]
    if scoped { words.append(TimedWord(id: "hello", text: "Hello", start: 1.6, end: 1.8)) }
    let transcript = Transcript(words: words, durationSeconds: 2,
        engine: EngineRef(id: .elevenlabs, engineVersion: "synthetic-fixture"),
        rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
    var state = EditReducer.reduce(EditState(transcript: transcript), command: .cutFillers)
    if scoped {
        state.clips = [ClipRange(id: "fillers", startWordId: "um", endWordId: "uh")]
        state.activeClipId = "fillers"
    }
    let plan = try EditPlan.build(transcript: transcript, editState: state, activeClip: state.activeClip,
                                  duration: 2, sampleRate: 48000)
    #expect(plan.outputSamples > 0)
    #expect(!state.summary.canExport)
    let transcriptURL = directory.appendingPathComponent("fillers.json")
    try ProjectJSON.encoder().encode(transcript).write(to: transcriptURL)
    let output = directory.appendingPathComponent("out.mp4")
    try Data("original".utf8).write(to: output)
    let result = try runCLI(["export", "--open", source.path, "--transcript", transcriptURL.path,
        "--cut-fillers", "--export", output.path, "--style", "off", "--json", "--quiet"] +
        (scoped ? ["--range", "0:1"] : []), directory: directory)
    #expect(result.status == 5)
    #expect((try result.json["error"] as? [String: Any])?["code"] as? String == "everythingCut")
    #expect(try Data(contentsOf: output) == Data("original".utf8))
    #expect(!FileManager.default.fileExists(atPath: output.path + ".partial"))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_MEDIA_FFPROBE"] != nil), .timeLimit(.minutes(3)))
func cliSixtySecondPortraitExportMatchesFFprobe() async throws {
    let source = try await NativeMediaFixtures.shared.file("benchmark.mov")
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcript = Transcript(durationSeconds: 60, engine: EngineRef(id: .elevenlabs, engineVersion: "synthetic-fixture"),
        rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
    let transcriptURL = directory.appendingPathComponent("transcript.json")
    try ProjectJSON.encoder().encode(transcript).write(to: transcriptURL)
    let output = directory.appendingPathComponent("portrait.mp4")
    let invocation = try runCLI(["export", "--open", source.path, "--transcript", transcriptURL.path,
        "--export", output.path, "--aspect", "9:16", "--style", "off", "--json", "--quiet"], directory: directory, timeout: 150)
    try #require(invocation.status == 0, "CLI exit \(invocation.status): \(invocation.stderr)")
    let result = try invocation.json
    #expect(result["frames"] as? Int == 1800)
    #expect(result["audioSamples"] as? Int == 2880000)
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VOXCLIP_MEDIA_FFPROBE"]))
    probe.arguments = ["-v", "error", "-show_entries", "stream=codec_name,profile,width,height,pix_fmt,color_space,color_transfer,color_primaries,sample_rate,channels,nb_frames,duration,r_frame_rate", "-of", "json", output.path]
    let pipe = Pipe()
    probe.standardOutput = pipe
    try probe.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    probe.waitUntilExit()
    try #require(probe.terminationStatus == 0)
    print("CLI_FFPROBE=\(String(decoding: data, as: UTF8.self))")
    let streams = try #require((JSONSerialization.jsonObject(with: data) as? [String: Any])?["streams"] as? [[String: Any]])
    let video = try #require(streams.first { $0["codec_name"] as? String == "h264" })
    #expect(video["profile"] as? String == "High")
    #expect(video["width"] as? Int == 1080 && video["height"] as? Int == 1920)
    #expect(video["pix_fmt"] as? String == "yuv420p")
    #expect(video["nb_frames"] as? String == "1800")
    #expect(video["r_frame_rate"] as? String == "30/1")
    #expect(video["duration"] as? String == "60.000000")
    for key in ["color_space", "color_transfer", "color_primaries"] { #expect(video[key] as? String == "bt709") }
    let audio = try #require(streams.first { $0["codec_name"] as? String == "aac" })
    #expect(audio["profile"] as? String == "LC")
    #expect(audio["sample_rate"] as? String == "48000")
    #expect(audio["channels"] as? Int == 2)
    #expect(audio["duration"] as? String == "60.000000")
}

@Test(.timeLimit(.minutes(1))) func cliInputFailuresUseJSONAndExitThree() async throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for (name, code) in [("tiny.webm", "unsupportedContainer"), ("absent.mov", "mediaMissing")] {
        let input = directory.appendingPathComponent(name)
        if name == "tiny.webm" { try Data([0x1A, 0x45, 0xDF, 0xA3]).write(to: input) }
        let invocation = try runCLI(["export", "--open", input.path, "--export", directory.appendingPathComponent("out.mp4").path,
            "--style", "off", "--json", "--quiet"], directory: directory)
        #expect(invocation.status == 3)
        let result = try invocation.json
        #expect(result["ok"] as? Bool == false)
        #expect((result["error"] as? [String: Any])?["code"] as? String == code)
        #expect(invocation.stderr.isEmpty)
    }
    let source = try await NativeMediaFixtures.shared.file()
    let invalid = directory.appendingPathComponent("invalid.json")
    try Data("{}".utf8).write(to: invalid)
    for transcript in [invalid, directory.appendingPathComponent("missing.json")] {
        let invocation = try runCLI(["export", "--open", source.path, "--export", directory.appendingPathComponent("out.mp4").path,
            "--transcript", transcript.path, "--style", "off", "--json", "--quiet"], directory: directory)
        #expect(invocation.status == 3)
        #expect(try invocation.json["ok"] as? Bool == false)
    }
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("out.mp4").path))
}

@Test(.timeLimit(.minutes(1))) func cliInvalidFlagsUseExitTwo() throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for arguments in [["export", "--unknown"], ["export", "--aspect", "4:3"], ["export", "--fps", "0"]] {
        let result = try runCLI(arguments, directory: directory)
        #expect(result.status == 2)
        #expect(result.stdout.isEmpty)
        #expect(!result.stderr.isEmpty)
    }
    for fps in ["0", "61", "nan", "inf", "-inf", "-1", "bad-value"] {
        let result = try runCLI(["export", "--fps", fps, "--json", "--quiet"], directory: directory)
        #expect(result.status == 2)
        let error = try #require(result.json["error"] as? [String: Any])
        #expect(error["code"] as? String == "usageError")
        #expect(error["message"] as? String == "--fps must be greater than zero and at most 60")
        #expect(result.stderr.isEmpty)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [
    [String](),
    ["--case", "case.json", "--tiles", "tiles.json"],
    ["--case", "case.json", "--sample", "-1"],
    ["--tiles", "tiles.json", "--sample", "0"],
    ["--case", "case.json", "--style", "vox-highlight"],
    ["--case", "case.json", "--layout-out", "layout.json"]
])
func cliCaptionHarnessRejectsAmbiguousArguments(_ arguments: [String]) throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("caption.png")
    let result = try runCLI(["render-caption", "--out", destination.path, "--json"] + arguments, directory: directory)
    #expect(result.status == 2)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Suite(.serialized) struct CLIInterruptTests {
@Test(.timeLimit(.minutes(5))) func cliInterruptTimingIsAbsentWithoutTestMode() async throws {
    let source = try await NativeMediaFixtures.shared.file("interrupt-aac.mov")
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcript = Transcript(durationSeconds: 60, engine: EngineRef(id: .elevenlabs, engineVersion: "synthetic-fixture"),
        rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
    let transcriptURL = directory.appendingPathComponent("transcript.json")
    try ProjectJSON.encoder().encode(transcript).write(to: transcriptURL)
    let output = directory.appendingPathComponent("out.mp4")
    let result = try runCLI(["export", "--open", source.path, "--transcript", transcriptURL.path,
        "--export", output.path, "--style", "off", "--json", "--quiet"], directory: directory,
        interruptAfter: 0.5, recordInterruptTiming: false)
    #expect(result.interruptReadinessObserved)
    #expect(!result.watchdogFired)
    #expect(result.status == 6)
    // The CLI itself prints nothing with --quiet, but on a paravirtualized hosted runner VideoToolbox writes
    // "IOServiceMatchingfailed for: AppleM2ScalerParavirtDriver" to stderr, so check only for the timing line.
    #expect(!result.stderr.contains("VOXCLIP_TEST_INTERRUPT_TIMING"))
    #expect((try result.json["error"] as? [String: Any])?["code"] as? String == "cancelled")
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(!FileManager.default.fileExists(atPath: output.path + ".partial"))
}

@Test(.timeLimit(.minutes(5))) func cliInterruptBeforeExportExitsSixWithoutCreatingOutput() async throws {
    let source = try await NativeMediaFixtures.shared.file("bars-tone.mov")
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcript = Transcript(durationSeconds: 2, engine: EngineRef(id: .elevenlabs, engineVersion: "synthetic-fixture"),
        rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
    let transcriptURL = directory.appendingPathComponent("transcript.json")
    try ProjectJSON.encoder().encode(transcript).write(to: transcriptURL)
    let output = directory.appendingPathComponent("early.mp4")
    let result = try runCLI(["export", "--open", source.path, "--transcript", transcriptURL.path,
        "--export", output.path, "--style", "off", "--json", "--quiet"], directory: directory,
        interruptAfter: 0.05, interruptBeforeExport: true)
    try #require(result.interruptReadinessObserved, "No readiness line before exit or the 60 s deadline: exit \(result.status), deadline \(result.watchdogFired), \(result.stderr)")
    try #require(!result.watchdogFired)
    try #require(result.status == 6)
    let timing = try result.internalInterruptTiming
    #expect(timing.exportStart == 0, "Cancellation must prevent exporter entry")
    let error = try #require(result.json["error"] as? [String: Any])
    #expect(error["code"] as? String == "cancelled")
    #expect(error["message"] as? String == "")
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(!FileManager.default.fileExists(atPath: output.path + ".partial"))
    let internalSeconds = Double(timing.exit - timing.handler) / 1e9
    let wallSeconds = try #require(result.interruptLatency)
    print("SIGINT_EARLY exportStart=0 internal=\(internalSeconds) wall=\(wallSeconds) watchdogs=0")
}

@Test(.timeLimit(.minutes(5))) func cliConcurrentInterruptWatchdogDeletesPartialAndUsesExitSix() async throws {
    let source = try await NativeMediaFixtures.shared.file("interrupt-aac.mov")
    let asset = AVURLAsset(url: source)
    #expect(try await asset.load(.duration).seconds == 60)
    let probe = try await AVMediaProbe().probe(source)
    #expect(probe.orientedSize == PixelSize(width: 1920, height: 1080))
    #expect(probe.videoCodec == "h264")
    let audioTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let format = try #require(try await audioTrack.load(.formatDescriptions).first)
    #expect(CMFormatDescriptionGetMediaSubType(format) == kAudioFormatMPEG4AAC)
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcript = Transcript(durationSeconds: 60, engine: EngineRef(id: .elevenlabs, engineVersion: "synthetic-fixture"),
        rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
    let transcriptURL = directory.appendingPathComponent("transcript.json")
    try ProjectJSON.encoder().encode(transcript).write(to: transcriptURL)
    let unrelated = directory.appendingPathComponent("interrupted-0.mp4.partial.sb-existing")
    try Data("preserve this file".utf8).write(to: unrelated)
    var latencies: [Double] = []
    var wallLatencies: [Double] = []
    var slowestLatency: Double = -1
    var slowestBreakdown: String = ""
    var random: UInt64 = 0x564f58434c495034
    for iteration in 0..<30 {
        var offsets: [Double] = []
        for _ in 0..<2 {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            offsets.append(2 * Double(random >> 11) / Double(UInt64.max >> 11))
        }
        let pair = try await withThrowingTaskGroup(of: (Int, CLIResult).self) { group in
            for pump in 0..<2 {
                let offset = offsets[pump]
                let output = directory.appendingPathComponent("interrupted-\(pump).mp4")
                group.addTask {
                    let result: CLIResult = try await withCheckedThrowingContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async {
                            continuation.resume(with: Result {
                                try runCLI(["export", "--open", source.path, "--transcript", transcriptURL.path,
                                    "--export", output.path, "--aspect", "9:16", "--style", "off", "--json", "--quiet"],
                                    directory: directory, interruptAfter: offset)
                            })
                        }
                    }
                    return (pump, result)
                }
            }
            var results: [(Int, CLIResult)] = []
            for try await result in group { results.append(result) }
            return results
        }
        for (pump, result) in pair {
            let output = directory.appendingPathComponent("interrupted-\(pump).mp4")
            try #require(result.interruptReadinessObserved, "Pair \(iteration), export \(pump): no partial before exit or the 60 s deadline: exit \(result.status), deadline \(result.watchdogFired), \(result.stderr)")
            try #require(!result.watchdogFired, "SIGINT watchdog fired in pair \(iteration), export \(pump)")
            try #require(result.status == 6, "SIGINT pair \(iteration), export \(pump), offset \(offsets[pump]): exit \(result.status), \(result.stderr)")
            let latency = try result.internalStopPathLatency
            let timing = try result.internalInterruptTiming
            let breakdown = "pair=\(iteration) export=\(pump) internal=\(latency) \(timing.breakdown)"
            if latency > 1 { print("SIGINT_SLOW \(breakdown)") }
            if latency > slowestLatency {
                slowestLatency = latency
                slowestBreakdown = breakdown
            }
            for phase in ["cancelRequest", "exportReturned"] {
                #expect(try #require(timing.phases[phase]) > 0, "Required stop phase \(phase) was not recorded")
            }
            for phase in ["cancelRequest", "teardownStart", "readersStopped", "writerCancelStart", "writerCancelEnd", "partialDeleted", "exportReturned"] {
                let stamp = try #require(timing.phases[phase])
                #expect(stamp == 0 || (stamp >= timing.handler && stamp <= timing.exit), "Invalid stop phase \(phase): \(result.stderr)")
            }
            #expect(latency <= 2)
            latencies.append(latency)
            wallLatencies.append(try #require(result.interruptLatency))
            let error = try #require(result.json["error"] as? [String: Any])
            #expect(error["code"] as? String == "cancelled")
            #expect(error["message"] as? String == "")
            #expect(!FileManager.default.fileExists(atPath: output.path))
            #expect(!FileManager.default.fileExists(atPath: output.path + ".partial"))
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(remaining.filter { $0.contains(".partial") || $0.hasPrefix("voxclip-export-") || $0.hasPrefix("Remaker-") } == [unrelated.lastPathComponent])
    }
    #expect(try Data(contentsOf: unrelated) == Data("preserve this file".utf8))
    let internalSummary = "internal_min=\(latencies.min() ?? 0) internal_max=\(latencies.max() ?? 0) internal_mean=\(latencies.reduce(0, +) / Double(latencies.count))"
    let wallSummary = "wall_min=\(wallLatencies.min() ?? 0) wall_max=\(wallLatencies.max() ?? 0) wall_mean=\(wallLatencies.reduce(0, +) / Double(wallLatencies.count))"
    let summary = "SIGINT_STRESS pairs=30 exports=\(latencies.count) watchdogs=0 \(internalSummary) \(wallSummary) slowest_\(slowestBreakdown)"
    print(summary)
    if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" {
        print("::notice title=SIGINT_STRESS::\(summary)")
    }
}
}

@Test func cliRejectsFoldersAndInputOverwritesBeforeReadingMedia() throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let victim = directory.appendingPathComponent("victim")
    try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: false)
    let sentinel = victim.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: sentinel)
    let absent = directory.appendingPathComponent("absent.mov").path
    for option in ["--export", "--srt", "--audio-out"] {
        var arguments = ["export", "--open", absent, "--json", "--quiet"]
        if option != "--export" { arguments += ["--export", directory.appendingPathComponent("out.mp4").path] }
        arguments += [option, victim.path]
        let result = try runCLI(arguments, directory: directory)
        #expect(result.status == 2)
        #expect((try result.json["error"] as? [String: Any])?["code"] as? String == "usageError")
        #expect((try result.json["error"] as? [String: Any])?["message"] as? String == "An output must be a file path, not a folder or special file")
        #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
    }
    for option in ["--export", "--srt", "--audio-out"] {
        let transcript = directory.appendingPathComponent("transcript.json")
        try Data("keep transcript".utf8).write(to: transcript)
        var arguments = ["export", "--open", absent, "--transcript", transcript.path, "--json"]
        if option != "--export" { arguments += ["--export", directory.appendingPathComponent("out.mp4").path] }
        let result = try runCLI(arguments + [option, transcript.path], directory: directory)
        #expect(result.status == 2)
        #expect((try result.json["error"] as? [String: Any])?["message"] as? String == "Output paths must not overwrite inputs or each other")
        #expect(try Data(contentsOf: transcript) == Data("keep transcript".utf8))
    }
    let project = directory.appendingPathComponent("take.voxclip")
    try Data("keep project".utf8).write(to: project)
    let result = try runCLI(["--open", project.path, "--export", project.path, "--json"], directory: directory)
    #expect(result.status == 2)
    #expect(try Data(contentsOf: project) == Data("keep project".utf8))
}

@Test(arguments: ["--export", "--srt", "--audio-out"], ["special", "missing-parent", "overlap", "partial-overlap"])
func cliOutputPreflightUsesPinnedUsageCopy(_ option: String, _ scenario: String) throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("absent.mov")
    let output = directory.appendingPathComponent("out.mp4")
    let selected: URL
    let expected: String
    switch scenario {
    case "special":
        selected = directory.appendingPathComponent("output.pipe")
        try #require(mkfifo(selected.path, 0o600) == 0)
        expected = "An output must be a file path, not a folder or special file"
    case "missing-parent":
        selected = directory.appendingPathComponent("missing/output")
        expected = "The output folder does not exist for \(Redactor(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path).redact(selected.path))"
    case "partial-overlap":
        selected = option == "--export" ? URL(fileURLWithPath: input.path + ".partial") : URL(fileURLWithPath: output.path + ".partial")
        expected = "Output paths must not overwrite inputs or each other"
    default:
        selected = input
        expected = "Output paths must not overwrite inputs or each other"
    }
    let source = scenario == "partial-overlap" && option == "--export" ? URL(fileURLWithPath: selected.path + ".partial") : input
    var arguments = ["--open", source.path, "--json", "--quiet"]
    if option != "--export" { arguments += ["--export", output.path] }
    let result = try runCLI(arguments + [option, selected.path], directory: directory)
    #expect(result.status == 2)
    let error = try #require(result.json["error"] as? [String: Any])
    #expect(error["code"] as? String == "usageError")
    #expect(error["message"] as? String == expected)
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("data").path))
}

@Test func cliUsageErrorsAndJSONFlagAreConsistent() async throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try await NativeMediaFixtures.shared.file()
    let transcriptURL = directory.appendingPathComponent("transcript.json")
    let transcript = Transcript(durationSeconds: 2, engine: EngineRef(id: .elevenlabs, engineVersion: "test"),
        rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
    try ProjectJSON.encoder().encode(transcript).write(to: transcriptURL)
    for arguments in [["--aspect", "bogus"], ["--style", "no-such-style"], ["--style", "../x"],
                      ["--clip", "nosuch"], ["--range", "0:5"], ["--range", "5:9"]] {
        let result = try runCLI(["--open", source.path, "--transcript", transcriptURL.path, "--export", directory.appendingPathComponent("out.mp4").path,
            "--json", "--quiet"] + arguments, directory: directory)
        #expect(result.status == 2)
        #expect((try result.json["error"] as? [String: Any])?["code"] as? String == "usageError")
    }
    let result = try runCLI(["probe", source.path], directory: directory)
    #expect(result.status == 0)
    #expect(result.stdout.isEmpty)
    let version = try runCLI(["version"], directory: directory)
    #expect(String(decoding: version.stdout, as: UTF8.self) == "VoxClip 0.1.0 (macos-arm64)\n")
}

@Test(.timeLimit(.minutes(1)), arguments: ["partial", "no-audio", "missing-parent", "unwritable-parent"])
func cliAudioFailuresLeaveTheVideoUnchanged(_ failure: String) async throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try await NativeMediaFixtures.shared.file(failure == "no-audio" ? "bars.mov" : "bars-tone.mov")
    let transcript = Transcript(durationSeconds: 2, engine: EngineRef(id: .elevenlabs, engineVersion: "synthetic-fixture"),
        rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
    let transcriptURL = directory.appendingPathComponent("transcript.json")
    try ProjectJSON.encoder().encode(transcript).write(to: transcriptURL)
    let output = directory.appendingPathComponent("out.mp4")
    try Data("original video".utf8).write(to: output)
    let audioFolder = directory.appendingPathComponent("audio")
    try FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: false)
    defer { chmod(audioFolder.path, 0o700) }
    let audio = failure == "missing-parent" ? directory.appendingPathComponent("missing/audio.wav") : audioFolder.appendingPathComponent("audio.wav")
    if failure != "missing-parent" { try Data("original audio".utf8).write(to: audio) }
    let reserved = URL(fileURLWithPath: audio.path + ".partial")
    if failure == "partial" { try FileManager.default.createDirectory(at: reserved, withIntermediateDirectories: false) }
    if failure == "unwritable-parent" { try #require(chmod(audioFolder.path, 0o500) == 0) }
    let result = try runCLI(["export", "--open", source.path, "--transcript", transcriptURL.path,
        "--export", output.path, "--audio-out", audio.path, "--style", "off", "--json", "--quiet"], directory: directory)
    #expect(result.status == (failure == "unwritable-parent" ? 5 : 2))
    if failure == "no-audio" {
        let error = try #require(result.json["error"] as? [String: Any])
        #expect(error["code"] as? String == "usageError")
        #expect(error["message"] as? String == "This video has no audio track, so --audio-out has nothing to write.")
    }
    #expect(try Data(contentsOf: output) == Data("original video".utf8))
    if failure == "missing-parent" { #expect(!FileManager.default.fileExists(atPath: audio.path)) }
    else { #expect(try Data(contentsOf: audio) == Data("original audio".utf8)) }
    if failure == "partial" { #expect(try reserved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true) }
    if failure == "missing-parent" || failure == "unwritable-parent" {
        let error = try #require(result.json["error"] as? [String: Any])
        let expectedPath = Redactor(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path).redact(audio.path)
        #expect((error["message"] as? String)?.contains(expectedPath) == true)
        #expect((error["message"] as? String)?.contains(".partial") == false)
    }
    try #require(chmod(audioFolder.path, 0o700) == 0)
    let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    // runCLI owns stdout-*, stderr-* and the subprocess's tmp scratch, which the CLI must leave empty.
    #expect(remaining.filter { !$0.hasPrefix("stdout-") && !$0.hasPrefix("stderr-") && $0 != "tmp" }.sorted() == ["audio", "out.mp4", "transcript.json"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("tmp").path).isEmpty)
    let expectedAudio = failure == "missing-parent" ? [] : failure == "partial" ? ["audio.wav", "audio.wav.partial"] : ["audio.wav"]
    #expect(try FileManager.default.contentsOfDirectory(atPath: audioFolder.path).sorted() == expectedAudio)
}

@Test(arguments: ["missing", "unreadable", "valid"], [false, true])
func cliProjectTranscriptFlagIsRejectedBeforeOpeningInput(_ projectKind: String, _ suppliedTranscript: Bool) throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let projectURL = directory.appendingPathComponent("take.VOXCLIP")
    if projectKind == "unreadable" { try Data("unchanged invalid project".utf8).write(to: projectURL) }
    if projectKind == "valid" { try FixtureLoader.data("fixtures/projects/interview-take.voxclip").write(to: projectURL) }
    let original = try? Data(contentsOf: projectURL)
    let transcriptURL = directory.appendingPathComponent("transcript.json")
    if suppliedTranscript {
        let transcript = Transcript(durationSeconds: 2, engine: EngineRef(id: .elevenlabs, engineVersion: "test"),
            rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
        try ProjectJSON.encoder().encode(transcript).write(to: transcriptURL)
    }
    let output = directory.appendingPathComponent("out.mp4")
    try Data("original output".utf8).write(to: output)
    let result = try runCLI(["--open", projectURL.path, "--transcript", transcriptURL.path,
        "--export", output.path, "--json", "--quiet"], directory: directory)
    #expect(result.status == 2)
    let error = try #require(result.json["error"] as? [String: Any])
    #expect(error["code"] as? String == "usageError")
    #expect(error["message"] as? String == "--transcript only applies when --open is a media file.")
    #expect((try? Data(contentsOf: projectURL)) == original)
    #expect(try Data(contentsOf: output) == Data("original output".utf8))
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("data").path))
}

@Test(arguments: ["media-clip", "project-clip-empty", "project-range-empty", "project-clip", "project-range"])
func cliRejectsUnknownScopeBeforeTranscription(_ scenario: String) async throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let input: URL
    let isClip = scenario.contains("clip")
    var wordCount = 0
    let source = try await NativeMediaFixtures.shared.file()
    if scenario == "media-clip" { input = source }
    else {
        let transcript = scenario.hasSuffix("empty") ? nil : Transcript(words: [TimedWord(id: "word", text: "Hello", start: 0.2, end: 0.4)],
            durationSeconds: 2, engine: EngineRef(id: .elevenlabs, engineVersion: "synthetic-fixture"),
            rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
        let project = try await cliProject(source: source, transcript: transcript)
        wordCount = project.transcript?.words.count ?? 0
        input = directory.appendingPathComponent("take.voxclip")
        try await JSONProjectStore(appVersion: "9.8.7").save(project, to: input)
    }
    let original = try Data(contentsOf: input)
    let output = directory.appendingPathComponent("out.mp4")
    try Data("original output".utf8).write(to: output)
    let result = try runCLI(["--open", input.path, "--export", output.path, "--json", "--quiet"] +
        (isClip ? ["--clip", "nosuch"] : ["--range", "\(wordCount):\(wordCount)"]), directory: directory)
    #expect(result.status == 2)
    let error = try #require(result.json["error"] as? [String: Any])
    #expect(error["code"] as? String == "usageError")
    #expect(error["message"] as? String == (isClip ? "The requested clip does not exist." : "Word range is outside the transcript."))
    #expect(try Data(contentsOf: input) == original)
    #expect(try Data(contentsOf: output) == Data("original output".utf8))
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("data").path))
}

@Test(arguments: ["clip", "range"], [false, true])
func cliMissingProjectMediaPrecedesInvalidScope(_ scope: String, _ scopeFirst: Bool) async throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try await NativeMediaFixtures.shared.file()
    var project = try await cliProject(source: source, transcript: nil)
    project.media.source.absolutePath = directory.appendingPathComponent("missing.mov").path
    let input = directory.appendingPathComponent("take.voxclip")
    try await JSONProjectStore(appVersion: "9.8.7").save(project, to: input)
    let original = try Data(contentsOf: input)
    let output = directory.appendingPathComponent("out.mp4")
    try Data("original output".utf8).write(to: output)
    let scopeArguments = scope == "clip" ? ["--clip", "nosuch"] : ["--range", "0:99"]
    let inputArguments = ["--open", input.path, "--export", output.path, "--json", "--quiet"]
    let invocation = try runCLI(scopeFirst ? scopeArguments + inputArguments : inputArguments + scopeArguments, directory: directory)
    #expect(invocation.status == 3)
    #expect((try invocation.json["error"] as? [String: Any])?["code"] as? String == "mediaMissing")
    #expect(try Data(contentsOf: input) == original)
    #expect(try Data(contentsOf: output) == Data("original output".utf8))
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("data").path))
}

@Test(.timeLimit(.minutes(1)), arguments: ["silent-no-transcript", "silent-all-cut", "srt-default", "srt-off", "project-srt-off", "project-silent-all-cut", "project-srt-all-cut"])
func cliRejectsUnusableSidecarsBeforeTranscriptionAndEditing(_ scenario: String) async throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let silent = scenario.contains("silent")
    let allCut = scenario.contains("all-cut")
    let source = try await NativeMediaFixtures.shared.file(silent ? "bars.mov" : "bars-tone.mov")
    let transcript = Transcript(words: [TimedWord(id: "um", text: "um", start: 0.2, end: 0.4)], durationSeconds: 2,
        engine: EngineRef(id: .elevenlabs, engineVersion: "synthetic-fixture"),
        rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
    let transcriptURL = directory.appendingPathComponent("transcript.json")
    try ProjectJSON.encoder().encode(transcript).write(to: transcriptURL)
    let output = directory.appendingPathComponent("out.mp4")
    let srt = directory.appendingPathComponent("out.srt")
    let audio = directory.appendingPathComponent("out.wav")
    for destination in [output, srt, audio] { try Data("original \(destination.pathExtension)".utf8).write(to: destination) }
    var arguments = ["export", "--export", output.path, "--json", "--quiet"]
    if scenario.hasPrefix("project") {
        let probe = try await AVMediaProbe().probe(source)
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let project = Project(id: UUID().uuidString.lowercased(), createdAt: Date(), modifiedAt: Date(), savedBy: ProjectWriter(version: "9.8.7"),
            media: ProjectMedia(source: MediaReference(absolutePath: source.path,
                sizeBytes: try #require((attributes[.size] as? NSNumber)?.int64Value), durationSeconds: probe.durationSeconds,
                contentKey: try JSONProjectStore.contentKey(for: source), video: probe.video, audio: probe.audio)),
            transcript: allCut ? transcript : nil, edits: ProjectEdits(cutWordIds: allCut ? ["um"] : []))
        let projectURL = directory.appendingPathComponent("take.voxclip")
        try await JSONProjectStore(appVersion: "9.8.7").save(project, to: projectURL)
        let original = try Data(contentsOf: projectURL)
        arguments += ["--open", projectURL.path]
        let result = try runCLI(arguments + (silent ? ["--audio-out", audio.path] : ["--srt", srt.path]), directory: directory)
        #expect(result.status == 2)
        let error = try #require(result.json["error"] as? [String: Any])
        #expect(error["code"] as? String == "usageError")
        #expect(error["message"] as? String == (silent ? "This video has no audio track, so --audio-out has nothing to write." : "Captions are off, so --srt has nothing to write. Choose a caption style with --style."))
        #expect(try Data(contentsOf: projectURL) == original)
    } else {
        arguments += ["--open", source.path]
        if allCut { arguments += ["--transcript", transcriptURL.path, "--cut-fillers"] }
        if scenario == "srt-off" { arguments += ["--style", "off"] }
        let result = try runCLI(arguments + (silent ? ["--audio-out", audio.path] : ["--srt", srt.path]), directory: directory)
        #expect(result.status == 2)
        let error = try #require(result.json["error"] as? [String: Any])
        #expect(error["code"] as? String == "usageError")
        #expect(error["message"] as? String == (silent ? "This video has no audio track, so --audio-out has nothing to write." : "Captions are off, so --srt has nothing to write. Choose a caption style with --style."))
    }
    for destination in [output, srt, audio] { #expect(try Data(contentsOf: destination) == Data("original \(destination.pathExtension)".utf8)) }
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("data").path))
    #expect(try !FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.contains(".partial") || $0.contains(".rollback-") })
}

@Test(.timeLimit(.minutes(1))) func cliStagesRoundedEditedAudioThroughSymlinkDestinations() async throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try await NativeMediaFixtures.shared.file("rounded-tail.mov")
    let probe = try await AVMediaProbe().probe(source)
    let transcript = Transcript(durationSeconds: probe.durationSeconds, engine: EngineRef(id: .elevenlabs, engineVersion: "synthetic-fixture"),
        rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
    let transcriptURL = directory.appendingPathComponent("transcript.json")
    try ProjectJSON.encoder().encode(transcript).write(to: transcriptURL)
    let output = directory.appendingPathComponent("out.mp4")
    let target = directory.appendingPathComponent("target.wav")
    try Data("original audio".utf8).write(to: target)
    let symlink = directory.appendingPathComponent("audio.wav")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
    let srtTarget = directory.appendingPathComponent("target.srt")
    try Data("original subtitles".utf8).write(to: srtTarget)
    let srtLink = directory.appendingPathComponent("subtitles.srt")
    try FileManager.default.createSymbolicLink(at: srtLink, withDestinationURL: srtTarget)
    for destination in [output, target, srtTarget] {
        try Data("stale partial".utf8).write(to: URL(fileURLWithPath: destination.path + ".partial"))
    }
    let result = try runCLI(["export", "--open", source.path, "--transcript", transcriptURL.path,
        "--export", output.path, "--audio-out", symlink.path, "--srt", srtLink.path,
        "--style", "vox-highlight", "--json", "--quiet"], directory: directory)
    try #require(result.status == 0, "CLI exit \(result.status): \(result.stderr)")
    #expect(try symlink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    #expect(try srtLink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    #expect(try Data(contentsOf: srtTarget).isEmpty)
    #expect(try result.json["srt"] as? String == srtTarget.path)
    #expect(try Data(contentsOf: target).count == 44 + 96624 * 8)
    #expect((try result.json)["audioSamples"] as? Int == 96624)
    let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(!remaining.contains { $0.hasPrefix(".voxclip-audio-") || $0.contains(".partial") || $0.contains(".rollback-") })
}

@Test(arguments: ["video", "srt", "audio"], ["directory", "symlink"])
func cliRejectsUnsafePartialTypes(_ outputKind: String, _ partialKind: String) throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let outputs = ["video": directory.appendingPathComponent("out.mp4"),
                   "srt": directory.appendingPathComponent("out.srt"),
                   "audio": directory.appendingPathComponent("out.wav")]
    for output in outputs.values { try Data("original".utf8).write(to: output) }
    let selected = try #require(outputs[outputKind])
    let partial = URL(fileURLWithPath: selected.path + ".partial")
    if partialKind == "directory" { try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: false) }
    else { try FileManager.default.createSymbolicLink(at: partial, withDestinationURL: selected) }
    let result = try runCLI(["export", "--open", directory.appendingPathComponent("missing.mov").path,
        "--export", try #require(outputs["video"]).path, "--srt", try #require(outputs["srt"]).path,
        "--audio-out", try #require(outputs["audio"]).path, "--style", "off", "--json", "--quiet"], directory: directory)
    #expect(result.status == 2)
    let error = try #require(result.json["error"] as? [String: Any])
    #expect(error["code"] as? String == "usageError")
    #expect(error["message"] as? String == "Choose a regular file for each .partial output; directories and links are not allowed.")
    for output in outputs.values { #expect(try Data(contentsOf: output) == Data("original".utf8)) }
    let values = try partial.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    #expect(partialKind == "directory" ? values.isDirectory == true : values.isSymbolicLink == true)
}

@Test(.timeLimit(.minutes(1)), arguments: ["mp4", "srt", "wav"])
func cliPublishFailurePreservesAllExistingDestinationsAndCopy(_ lockedExtension: String) async throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try await NativeMediaFixtures.shared.file()
    let transcript = Transcript(durationSeconds: 2, engine: EngineRef(id: .elevenlabs, engineVersion: "synthetic-fixture"),
        rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
    let transcriptURL = directory.appendingPathComponent("transcript.json")
    try ProjectJSON.encoder().encode(transcript).write(to: transcriptURL)
    let output = directory.appendingPathComponent("out.mp4")
    let srt = directory.appendingPathComponent("out.srt")
    let audio = directory.appendingPathComponent("out.wav")
    for destination in [output, srt, audio] { try Data("original \(destination.pathExtension)".utf8).write(to: destination) }
    let locked = directory.appendingPathComponent("out.\(lockedExtension)")
    try #require(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
    defer { chflags(locked.path, 0) }
    let result = try runCLI(["export", "--open", source.path, "--transcript", transcriptURL.path,
        "--export", output.path, "--srt", srt.path, "--audio-out", audio.path,
        "--style", "vox-highlight", "--json", "--quiet"], directory: directory)
    #expect(result.status == 5)
    for destination in [output, srt, audio] {
        #expect(try Data(contentsOf: destination) == Data("original \(destination.pathExtension)".utf8))
        #expect(!FileManager.default.fileExists(atPath: destination.path + ".partial"))
    }
    let error = try #require(result.json["error"] as? [String: Any])
    #expect(error["code"] as? String == "exportFailed")
    #expect((error["message"] as? String)?.contains("Your video and edits are unchanged.") == true)
    let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(!remaining.contains { $0.contains(".partial") || $0.contains(".rollback-") })
}

@Test func cliTranscriptionOutputsCannotOverwriteInputsOrFolders() throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.mov")
    try Data("preserve source".utf8).write(to: source)
    let folder = directory.appendingPathComponent("folder")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let project = directory.appendingPathComponent("project.voxclip")
    let scenarios = [["--out", source.path], ["--out", folder.path],
        ["--out", project.path, "--raw-out", source.path], ["--out", project.path, "--raw-out", project.path]]
    for arguments in scenarios {
        let result = try runCLI(["transcribe", "--open", source.path, "--engine", "whisper", "--json"] + arguments, directory: directory)
        #expect(result.status == 2)
        #expect((try result.json["error"] as? [String: Any])?["code"] as? String == "usageError")
        #expect(try Data(contentsOf: source) == Data("preserve source".utf8))
    }
    let removed = try runCLI(["extract-audio", source.path, "--out", source.path, "--json"], directory: directory)
    #expect(removed.status == 2)
    #expect(try Data(contentsOf: source) == Data("preserve source".utf8))
}

@Test(.timeLimit(.minutes(1)), arguments: ["big.mov", "counter.mov", "bars.mov"])
func cliExportsNativeCapCropAndColourFixtures(_ name: String) async throws {
    let source = try await NativeMediaFixtures.shared.file(name)
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcript = Transcript(durationSeconds: 2, engine: EngineRef(id: .elevenlabs, engineVersion: "synthetic-fixture"),
        rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
    let transcriptURL = directory.appendingPathComponent("transcript.json")
    try ProjectJSON.encoder().encode(transcript).write(to: transcriptURL)
    let destination = directory.appendingPathComponent("out.mp4")
    let portrait = name == "counter.mov"
    let invocation = try runCLI(["export", "--open", source.path, "--transcript", transcriptURL.path,
        "--export", destination.path, "--style", "off", "--aspect", portrait ? "9:16" : "source", "--json", "--quiet"], directory: directory)
    try #require(invocation.status == 0, "\(invocation.stderr)")
    let result = try invocation.json
    #expect(result["width"] as? Int == (portrait ? 1080 : 1920))
    #expect(result["height"] as? Int == (portrait ? 1920 : 1080))
    #expect(result["frames"] as? Int == 60)
    #expect(result["audioSamples"] as? Int == (name == "bars.mov" ? 0 : 96000))
    #expect(result["audioSampleRate"] as? Int == 48000)
    #expect(try await AVMediaProbe().probe(destination).isPlayable)
    // Exported bars colour is accepted by E2E case 8 under ADR-R22, not by decoded canonical RGB.
    if name == "bars.mov" { #expect(try await AVURLAsset(url: destination).loadTracks(withMediaType: .audio).isEmpty) }
    if portrait {
        var points = [(185, 1000), (895, 1000)]
        let scale = 1920.0 / 1080.0
        for bit in 0..<12 {
            let column = Int(((736.0 + Double(bit) * 40 - 656.25) * scale).rounded())
            points.append((column, Int((32 * scale).rounded())))
        }
        let frames = try await sampledFrames(destination, points: points)
        #expect(frames.count == 60)
        for frame in frames {
            #expect(frame.pixels[0].min()! > 200 && frame.pixels[1].min()! > 200)
            let code = frame.pixels.dropFirst(2).reduce(0) { ($0 << 1) | ($1[0] >= 128 ? 1 : 0) }
            #expect(code == Int((frame.time * 30).rounded()))
        }
    }
}
}
