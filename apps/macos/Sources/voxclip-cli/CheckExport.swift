import Foundation
import ArgumentParser
import Synchronization
import VoxClipCore
import VoxClipMedia

/// The export self-check (ADR-R49), headless: the export transcribed again on this Mac and compared word for word with the
/// clip's edit, its tracks and each revoiced or rewritten phrase measured for sync, its loudness metered against ADR-R47's
/// target and every caption card and the title checked against the frame's safe-zone bands.
struct Check: AsyncParsableCommand {
    /// The exit status when any check warns (architecture §9.3).
    static let warningExitCode: Int32 = 8

    static let configuration = CommandConfiguration(
        abstract: "Check an export against the project clip it came from: words, sync, loudness and captions.",
        discussion: "Exit 0 when every check is ok or skipped, 8 when any warns. The audio is transcribed with a local engine only (the project's Whisper or Apple speech, or an installed Whisper model); without one the words are skipped.")
    @Option(help: "The project the export came from.") var project: String
    @Option(help: "The clip: its number in the project's clip list (1 is the first) or its ID.") var clip: String
    @Argument(help: "The exported MP4.") var export: String
    @Option(help: "16:9, 9:16, 1:1 or source, as exported; read from the export's frame when left out.") var aspect: String?
    @Option(help: "Caption style ID or off, when the export was given --style.") var style: String?
    @Option(help: "social (the default) or off: the loudness the export ran with.") var loudness: String?
    @Flag(help: "Print one final JSON object on stdout.") var json = false
    @Flag(help: "Suppress human-readable progress on stderr.") var quiet = false

    mutating func validate() throws {
        if let aspect, AspectRatio(rawValue: aspect) == nil { throw ValidationError("--aspect must be source, 16:9, 9:16 or 1:1") }
        if let loudness, ExportLoudness(rawValue: loudness) == nil { throw ValidationError("--loudness must be social or off") }
    }

    mutating func run() async throws {
        let options = self
        let passed = Mutex(true)
        try await CLIExecution.run(command: "check", json: json) {
            let (value, outcome) = try await CLIWorkflow.check(options)
            passed.withLock { $0 = outcome.report.passed }
            if !options.json { print(CLIWorkflow.checkSummary(outcome)) }
            return value
        }
        if !passed.withLock({ $0 }) { throw ExitCode(Self.warningExitCode) }
    }
}

extension CLIWorkflow {
    static func check(_ options: Check) async throws -> (JSONValue, ExportChecker.Outcome) {
        let projectURL = URL(fileURLWithPath: options.project).standardizedFileURL
        let exportURL = URL(fileURLWithPath: options.export).standardizedFileURL
        guard FileManager.default.fileExists(atPath: exportURL.path) else { throw VoxClipError.mediaMissing(exportURL.lastPathComponent) }
        let project = try await JSONProjectStore().load(from: projectURL)
        let clips = project.edits.clips
        let clip: ClipRange
        if let number = Int(options.clip), clips.indices.contains(number - 1) { clip = clips[number - 1] }
        else if let named = clips.first(where: { $0.id == options.clip }) { clip = named }
        else { throw ValidationError("The requested clip does not exist.") }
        let aspect: String
        if let given = options.aspect { aspect = given } else { aspect = try await exportedAspect(exportURL) }
        var arguments = ["--open", projectURL.path, "--export", exportURL.path, "--clip", clip.id, "--aspect", aspect, "--quiet"]
        if let style = options.style { arguments += ["--style", style] }
        let loudness = options.loudness.flatMap(ExportLoudness.init(rawValue:)) ?? .social
        let prepared = try await prepare(try Export.parse(arguments), input: projectURL.path, checkingOutputs: false)
        let hearing = await ExportChecker.localHearing(transcript: prepared.project.transcript, locations: DataLocations(),
                                                       shared: try SharedResources.locate())
        let outcome = try await checkExport(exportURL, prepared: prepared, hearing: hearing, loudness: loudness)
        return (success("check", fields: ["output": .string(exportURL.path), "clipId": .string(clip.id), "check": checkJSON(outcome)]), outcome)
    }

    /// The export's frame as an aspect: 9:16, 16:9 or 1:1 when it is one, else the source's.
    static func exportedAspect(_ url: URL) async throws -> String {
        guard let size = try await AVMediaProbe().probe(url).video.map({ ($0.width, $0.height) }), size.0 > 0, size.1 > 0 else { return AspectRatio.source.rawValue }
        if 16 * size.0 == 9 * size.1 { return AspectRatio.portrait.rawValue }
        if 9 * size.0 == 16 * size.1 { return AspectRatio.landscape.rawValue }
        return size.0 == size.1 ? AspectRatio.square.rawValue : AspectRatio.source.rawValue
    }

    /// One export checked against what `prepare` made for it.
    static func checkExport(_ url: URL, prepared: PreparedExport, hearing: ExportChecker.Hearing?, loudness: ExportLoudness) async throws -> ExportChecker.Outcome {
        let edit = try ExportCheckExpectation.edit(render: prepared.render, state: prepared.state)
        let scratch = DataLocations().root.appendingPathComponent("Scratch/export-check", isDirectory: true)
        return try await ExportChecker(hearing: hearing, scratch: scratch).check(export: url, render: prepared.render, edit: edit, loudness: loudness)
    }

    /// The `check` object: `passed`, the engine that heard the export, the wall time, and each check's result keyed by its
    /// name (status, reason, items and its own numbers).
    static func checkJSON(_ outcome: ExportChecker.Outcome) -> JSONValue {
        func rounded(_ value: Double) -> JSONValue { .number((value * 1000).rounded() / 1000) }
        var fields: [String: JSONValue] = ["passed": .bool(outcome.report.passed), "seconds": rounded(outcome.totalSeconds),
                                           "hearSeconds": rounded(outcome.hearSeconds),
                                           "engine": outcome.engine.map { .string($0.rawValue) } ?? .null,
                                           "model": outcome.model.map(JSONValue.string) ?? .null]
        for result in outcome.report.results {
            guard let data = try? JSONEncoder().encode(result), case .object(var encoded)? = try? JSONDecoder().decode(JSONValue.self, from: data) else { continue }
            encoded.removeValue(forKey: "check")
            fields[result.check.rawValue] = .object(encoded)
        }
        return .object(fields)
    }

    /// The human-readable report: one line per check, then one per finding.
    static func checkSummary(_ outcome: ExportChecker.Outcome) -> String {
        func time(_ seconds: Double) -> String { String(format: "%d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60)) }
        var lines: [String] = []
        for result in outcome.report.results {
            var line = "\(result.check.rawValue): \(result.status.rawValue)"
            if let matched = result.matched, let total = result.total { line += ", \(matched)/\(total) words as edited" }
            if let lufs = result.integratedLufs { line += String(format: ", %.1f LUFS", lufs) }
            if let peak = result.truePeakDbtp { line += String(format: ", %.1f dBTP", peak) }
            if let reason = result.reason { line += " (\(reason))" }
            lines.append(line)
            for item in result.items {
                var detail = "  \(time(item.time)) \(item.kind.rawValue)"
                if let expected = item.expected { detail += " \"\(expected)\"" }
                if item.kind == .mismatch || item.kind == .cutOff { detail += item.heard.map { " heard \"\($0)\"" } ?? " not heard" }
                if let value = item.value { detail += String(format: " %.3f", value) }
                if let band = item.band { detail += " in the \(band.rawValue) band" }
                lines.append(detail)
            }
        }
        lines.append(outcome.report.passed ? "passed" : "warnings")
        return lines.joined(separator: "\n")
    }
}

/// The autopilot's checks: one per exported clip, each started as its export is written and run one after another (the
/// local engine hears one file at a time) beside the other clips' plans and exports. The engine is chosen once.
final class ClipChecks: Sendable {
    private let hearing: Task<ExportChecker.Hearing?, Never>
    private let clock: ClaudeModeClock
    private let state = Mutex<(last: Task<Void, Never>?, results: [Int: Task<JSONValue, Never>])>((nil, [:]))

    init(transcript: Transcript?, clock: ClaudeModeClock) {
        self.clock = clock
        hearing = Task {
            guard let shared = try? SharedResources.locate() else { return nil }
            return await ExportChecker.localHearing(transcript: transcript, locations: DataLocations(), shared: shared)
        }
    }

    func start(rank: Int, export: URL, prepared: CLIWorkflow.PreparedExport, loudness: ExportLoudness) {
        let hearing = hearing, clock = clock
        state.withLock { state in
            let previous = state.last
            let task = Task { () -> JSONValue in
                await previous?.value
                clock.begin(.check, clip: rank)
                defer { clock.end(.check, clip: rank) }
                do {
                    let outcome = try await CLIWorkflow.checkExport(export, prepared: prepared, hearing: await hearing.value, loudness: loudness)
                    return CLIWorkflow.checkJSON(outcome)
                } catch {
                    return .object(["passed": .bool(false), "error": .string(CLIExecution.redactor().redact(error.localizedDescription))])
                }
            }
            state.last = Task { _ = await task.value }
            state.results[rank] = task
        }
    }

    /// The clip's check, once it has run; nil when it was not started.
    func result(rank: Int) async -> JSONValue? {
        guard let task = state.withLock({ $0.results[rank] }) else { return nil }
        return await task.value
    }
}
