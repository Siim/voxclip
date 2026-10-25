import AppKit
import Foundation
import Testing
import VoxClipCore
import XCTest
import Darwin

@Suite("mac-ui", .serialized) struct MacUIIntegrationTests {
    @Test("View-model assertions and offscreen snapshots", .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_UI_TESTS"] == "1")) func appSelfTest() throws {
        let directory = try UIProcessHarness.run(mode: "-uiSelfTest", name: "ui")
        defer { UIProcessHarness.cleanTemporary(directory) }
        let report = try JSONDecoder().decode([UIProcessHarness.Result].self, from: Data(contentsOf: directory.appendingPathComponent("results.json")))
        #expect(report.count >= 45)
        for result in report {
            if let reason = result.skipped { print("SKIP: \(result.name): \(reason)") }
            else { #expect(result.passed, Comment(rawValue: result.name)) }
        }
        for name in ["welcome-light", "editor-light", "editor-dark", "settings-light", "onboarding-light", "onboarding-dark", "export-light", "export-dark", "toolbar-light-key", "toolbar-light-inactive", "toolbar-dark-key", "toolbar-dark-inactive"] {
            let image = try #require(NSBitmapImageRep(data: Data(contentsOf: directory.appendingPathComponent(name).appendingPathExtension("jpg"))))
            #expect(image.pixelsWide >= 500 && image.pixelsHigh >= 200)
            #expect(image.representation(using: .png, properties: [:])!.count > 5000)
            if name == "export-light" { #expect(image.pixelsHigh >= 600) }
        }
        print("mac-ui screenshots: \(directory.path)")
    }
    @Test("Document window keeps transcript and preview visible", .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_UI_TESTS"] == "1")) func demoWindow() throws {
        let directory = try UIProcessHarness.run(mode: "-demoCapture", name: "window")
        defer { UIProcessHarness.cleanTemporary(directory) }
        struct Layout: Decodable { let transcriptWidth: Double; let previewWidth: Double }
        let layout = try JSONDecoder().decode(Layout.self, from: Data(contentsOf: directory.appendingPathComponent("editor-layout.json")))
        #expect(layout.transcriptWidth >= 439)
        #expect(layout.previewWidth >= 299 && layout.previewWidth <= 561)
        struct ToolbarExtent: Decodable { let label: String; let width: Double; let attached: Bool }
        let toolbar = try JSONDecoder().decode([ToolbarExtent].self, from: Data(contentsOf: directory.appendingPathComponent("settings-minimum-toolbar.json")))
        #expect(toolbar.contains { $0.label == "Navigation Tab Bar" && $0.attached && $0.width >= 440 })
        for name in ["demo-editor", "demo-welcome", "demo-settings"] {
            let image = try #require(NSBitmapImageRep(data: Data(contentsOf: directory.appendingPathComponent("\(name).jpg"))))
            #expect(image.pixelsWide >= 500 && image.pixelsHigh >= 200)
        }
        print("mac-ui document screenshots: \(directory.path)")
    }
    @Test("Log sink redacts before persisting") func redactedFileSink() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-log-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = RedactingLogger(homeDirectory: "/Users/example", directory: directory)
        await logger.register(secret: "test-only-not-a-real-key")
        await logger.write(LogEntry(level: .info, category: "UI", message: "/Users/example has test-only-not-a-real-key"))
        let saved = try String(contentsOf: directory.appendingPathComponent("voxclip.log"), encoding: .utf8)
        #expect(!saved.contains("test-only-not-a-real-key"))
        #expect(!saved.contains("/Users/example"))
        #expect(saved.contains("[REDACTED]"))
    }
    @Test("Core default logger redacts without creating files") func defaultLoggerHasNoSink() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-no-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = RedactingLogger(homeDirectory: directory.path)
        await logger.register(secret: "test-only-not-a-real-key")
        await logger.write(LogEntry(level: .warn, category: "import", message: "test-only-not-a-real-key"))
        #expect(await logger.redact("test-only-not-a-real-key") == "[REDACTED]")
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
    @Test("Updates reject stale, preview and unsafe releases") func updateValidation() throws {
        let safe = try #require(URL(string: "https://github.com/Siim/voxclip/releases/tag/v0.2.0"))
        let unsafe = try #require(URL(string: "https://example.org/download"))
        #expect(UpdateChecker.available(version: "v0.2.0", htmlURL: safe, downloadURL: nil, currentVersion: "0.1.0")?.version == "0.2.0")
        #expect(UpdateChecker.available(version: "v0.1.0", htmlURL: safe, downloadURL: nil, currentVersion: "0.1.0") == nil)
        #expect(UpdateChecker.available(version: "v0.2.0", htmlURL: unsafe, downloadURL: nil, currentVersion: "0.1.0") == nil)
        #expect(UpdateChecker.available(version: "v0.2.0", htmlURL: safe, downloadURL: nil, currentVersion: "0.1.0", prerelease: true) == nil)
    }
}

final class MacUIRenderPerformanceTests: XCTestCase {
    func testTenThousandWordEditToDisplay() throws {
        guard ProcessInfo.processInfo.environment["VOXCLIP_UI_TESTS"] == "1" else { throw XCTSkip("Offscreen AppKit tests require VOXCLIP_UI_TESTS=1 and a macOS WindowServer") }
        guard ProcessInfo.processInfo.environment["VOXCLIP_UI_PERFORMANCE_EXECUTABLE"] != nil else {
            throw XCTSkip("Debug timings are diagnostic. Build with swift build -c release -Xswiftc -DDEBUG and set VOXCLIP_UI_PERFORMANCE_EXECUTABLE to its VoxClip executable.")
        }
        let directory = try UIProcessHarness.run(mode: "-uiPerformanceTest", name: "performance")
        defer { UIProcessHarness.cleanTemporary(directory) }
        struct Metrics: Decodable {
            let wordCount: Int
            let cutMedianMS: Double
            let cutP95MS: Double
            let cutMaximumMS: Double
            let scrollP95MS: Double
            let storageRebuildsDuringCuts: Int
        }
        let metrics = try JSONDecoder().decode(Metrics.self, from: Data(contentsOf: directory.appendingPathComponent("transcript-performance.json")))
        XCTAssertEqual(metrics.wordCount, 10_000)
        XCTAssertLessThan(metrics.cutMaximumMS, 50)
        XCTAssertLessThan(metrics.scrollP95MS, 1000 / 60)
        XCTAssertEqual(metrics.storageRebuildsDuringCuts, 0)
        let report = try JSONDecoder().decode([UIProcessHarness.Result].self, from: Data(contentsOf: directory.appendingPathComponent("results.json")))
        for result in report {
            if let reason = result.skipped { print("SKIP: \(result.name): \(reason)") }
            else { XCTAssertTrue(result.passed, result.name) }
        }
        print("10000-word cut median=\(metrics.cutMedianMS)ms p95=\(metrics.cutP95MS)ms max=\(metrics.cutMaximumMS)ms; scroll p95=\(metrics.scrollP95MS)ms")
    }
}

private enum UIProcessHarness {
    struct Result: Decodable { let name: String; let passed: Bool; let skipped: String? }
    enum Failure: Error { case executableMissing, timedOut, appFailed(Int32), outputMissing }
    static func run(mode: String, name: String) throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let adjacent = Bundle(for: MacUIRenderPerformanceTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("VoxClip")
        let override = mode == "-uiPerformanceTest" ? environment["VOXCLIP_UI_PERFORMANCE_EXECUTABLE"] ?? environment["VOXCLIP_APP_EXECUTABLE"] : environment["VOXCLIP_APP_EXECUTABLE"]
        let executable = override.map { URL(fileURLWithPath: $0) } ?? adjacent
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw Failure.executableMissing }
        let shared = try SharedResources.locate().root
        let directory = environment["VOXCLIP_UI_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent(name) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-mac-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
        let data = directory.appendingPathComponent("data")
        defer { if FileManager.default.fileExists(atPath: data.path) { try? FileManager.default.removeItem(at: data) } }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO", mode, directory.path]
        if mode == "-demoCapture" { process.arguments! += ["-demoProject", shared.appendingPathComponent("fixtures/projects/interview-take.voxclip").path] }
        var childEnvironment = environment.filter { !$0.key.hasSuffix("_API_KEY") && !$0.key.hasSuffix("_TOKEN") }
        childEnvironment["VOXCLIP_SHARED_DIR"] = shared.path
        childEnvironment["VOXCLIP_NO_KEYCHAIN"] = "1"
        childEnvironment["VOXCLIP_DATA_DIR"] = data.path
        process.environment = childEnvironment
        let logURL = directory.appendingPathComponent("app.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        process.standardOutput = log; process.standardError = log
        try process.run()
        let deadline = Date().addingTimeInterval(mode == "-uiSelfTest" ? 240 : 120)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw Failure.timedOut
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.appFailed(process.terminationStatus) }
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("failure.txt").path) else { throw Failure.outputMissing }
        return directory
        } catch {
            if environment["VOXCLIP_UI_EVIDENCE_DIR"] == nil { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
    }
    static func cleanTemporary(_ directory: URL) {
        if ProcessInfo.processInfo.environment["VOXCLIP_UI_EVIDENCE_DIR"] == nil { try? FileManager.default.removeItem(at: directory) }
    }
}
