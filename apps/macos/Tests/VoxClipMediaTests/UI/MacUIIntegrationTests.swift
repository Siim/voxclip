import AppKit
import Foundation
import Testing
import VoxClipCore
import XCTest
import Darwin

extension HeavyMediaTests {
@Suite("mac-ui", .serialized) struct MacUIIntegrationTests {
    @Test("Real transcription actions enforce first-use consent without opening a window") func transcriptionConsent() throws {
        let directory = try UIProcessHarness.run(mode: "-transcriptionConsentAudit", name: "transcription-consent")
        defer { UIProcessHarness.cleanTemporary(directory) }
        let report = try JSONDecoder().decode([UIProcessHarness.Result].self, from: Data(contentsOf: directory.appendingPathComponent("results.json")))
        #expect(report.count == 7)
        for result in report { #expect(result.passed && result.skipped == nil, Comment(rawValue: result.name)) }
    }
    @Test("Gallery selections reveal their complete paint without opening a window") func captionGalleryInteractions() throws {
        let directory = try UIProcessHarness.run(mode: "-captionGalleryAudit", name: "caption-gallery")
        defer { UIProcessHarness.cleanTemporary(directory) }
        let report = try JSONDecoder().decode([UIProcessHarness.Result].self, from: Data(contentsOf: directory.appendingPathComponent("results.json")))
        #expect(report.count == 64)
        for result in report { #expect(result.passed && result.skipped == nil, Comment(rawValue: result.name)) }
        struct Measurement: Decodable {
            let name: String
            let width: CGFloat
            let settled: Bool
        }
        let measurements = try JSONDecoder().decode([Measurement].self, from: Data(contentsOf: directory.appendingPathComponent("caption-gallery-interactions.json")))
        #expect(measurements.count == 20)
        #expect(Set(measurements.filter { $0.name.hasPrefix("last-") }.map(\.width)) == [300, 320, 360, 560])
        for measurement in measurements { #expect(measurement.settled, Comment(rawValue: measurement.name)) }
    }
    @Test("Right-column content fits without opening a window") func rightColumnLayout() throws {
        let directory = try UIProcessHarness.run(mode: "-layoutAudit", name: "layout")
        defer { UIProcessHarness.cleanTemporary(directory) }
        let report = try JSONDecoder().decode([UIProcessHarness.Result].self, from: Data(contentsOf: directory.appendingPathComponent("results.json")))
        #expect(report.count >= 315)
        for result in report { #expect(result.passed && result.skipped == nil, Comment(rawValue: result.name)) }
        struct Measurement: Decodable { let width: Double; let minimumWidth: Double; let proposedWidth: Double; let stageWidth: Double; let variant: String; let frameChoices: [String]; let viewOverflow: [String]; let accessibilityOverflow: [String] }
        let measurements = try JSONDecoder().decode([Measurement].self, from: Data(contentsOf: directory.appendingPathComponent("right-column-layout.json")))
        #expect(measurements.count == 108)
        let captures = try JSONDecoder().decode([String].self, from: Data(contentsOf: directory.appendingPathComponent("rewrite-captures.json")))
        #expect(captures.count == 48)
        for name in captures { #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)) }
        #expect(Set(measurements.map(\.width)) == [300, 320, 340, 360, 440, 560])
        for measurement in measurements {
            #expect(measurement.minimumWidth <= measurement.width + 0.5 && measurement.proposedWidth <= measurement.width + 0.5)
            #expect(measurement.stageWidth > 0 && measurement.stageWidth <= measurement.width - 31.5)
            #expect(measurement.viewOverflow.isEmpty && measurement.accessibilityOverflow.isEmpty)
            #expect(measurement.frameChoices == ["9:16", "1:1", "16:9", "Original"], Comment(rawValue: "\(measurement.variant) at \(measurement.width)"))
        }
        struct HeightMeasurement: Decodable {
            let width: Double
            let height: Double
            let variant: String
            let stage: CGRect
            let scrollFrames: [CGRect]
            let scrollClipping: [Bool]
            let viewOverflow: [String]
        }
        let heights = try JSONDecoder().decode([HeightMeasurement].self, from: Data(contentsOf: directory.appendingPathComponent("right-column-heights.json")))
        #expect(heights.count == 29)
        #expect(Set(heights.map(\.height)) == [475, 575, 675, 775])
        for measurement in heights {
            let viewport = try #require(measurement.scrollFrames.first)
            #expect(viewport.height > 0)
            #expect(measurement.scrollClipping.allSatisfy { $0 })
            #expect(measurement.viewOverflow.isEmpty, Comment(rawValue: "\(measurement.variant) at \(measurement.width)x\(measurement.height)"))
            if !measurement.variant.hasPrefix("rewrite") {
                #expect(viewport.maxY <= measurement.height - 15.5)
            }
            if measurement.width == 320 && measurement.height == 675 {
                let literalSize: CGSize = switch measurement.variant {
                case "9:16": CGSize(width: 180, height: 320)
                case "1:1": CGSize(width: 288, height: 288)
                // Every Rewrite state, including the Voice Lab takes states, opens Rewrite in a column under 760 high (design §5.1).
                case let variant where variant.hasPrefix("rewrite"): CGSize(width: 124 * 16.0 / 9, height: 124)
                default: CGSize(width: 288, height: 162)
                }
                #expect(abs(measurement.stage.width - literalSize.width) <= 0.5 && abs(measurement.stage.height - literalSize.height) <= 0.5,
                    Comment(rawValue: "Literal design stage size for \(measurement.variant): \(measurement.stage.size) vs \(literalSize)"))
            }
        }
        struct ResizeMeasurement: Decodable { let width: Double; let stage: CGRect; let elapsed: Double; let settled: Bool; let viewOverflow: [String] }
        let resizes = try JSONDecoder().decode([ResizeMeasurement].self, from: Data(contentsOf: directory.appendingPathComponent("right-column-resizes.json")))
        #expect(resizes.map(\.width) == [320, 300, 560])
        for resize in resizes {
            #expect(resize.settled && resize.elapsed < 2 && resize.viewOverflow.isEmpty)
            #expect(abs(resize.stage.width - (resize.width - 32)) <= 0.5 && abs(resize.stage.minX - 16) <= 0.5)
        }
    }
    @Test("Saved Voice Lab recipe uses native preview and App export", .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_UI_TESTS"] == "1")) func voiceRecipeWorkflow() async throws {
        let directory = ProcessInfo.processInfo.environment["VOXCLIP_UI_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("voice") } ?? FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-voice-app-\(UUID().uuidString)")
        defer { UIProcessHarness.cleanTemporary(directory) }
        let project = try await voiceCallerFixture(in: directory)
        _ = try UIProcessHarness.run(mode: "-voiceRecipeAudit", name: "voice", acceptNonzeroWithReport: "voice-recipe-results.json", preparedDirectory: directory)
        let report = try JSONDecoder().decode([UIProcessHarness.Result].self, from: Data(contentsOf: directory.appendingPathComponent("voice-recipe-results.json")))
        #expect(report.count >= 20)
        for result in report { #expect(result.passed, Comment(rawValue: result.name)) }
        let outputs = try JSONDecoder().decode([ExportResult].self, from: Data(contentsOf: directory.appendingPathComponent("exports.json")))
        try #require(outputs.count == 2)
        for (index, output) in outputs.enumerated() {
            let plan = try VoiceLabOutputPlanner.build(project, scope: index == 0 ? .full : .clip("included"))
            try verifyVoiceCallerOutput(output.outputURL, expected: plan)
            try await verifyVoiceCallerAudio(output.outputURL, expected: plan)
            #expect(try String(contentsOf: #require(output.srtURL), encoding: .utf8).lowercased().contains("new"))
        }
        for name in ["native-preview", "native-window"] {
            let image = try #require(NSBitmapImageRep(data: Data(contentsOf: directory.appendingPathComponent(name).appendingPathExtension("png"))))
            #expect(image.pixelsWide >= 300 && image.pixelsHigh >= 180)
        }
    }
    @Test("View-model assertions and offscreen snapshots", .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_UI_TESTS"] == "1")) func appSelfTest() throws {
        let directory = try UIProcessHarness.run(mode: "-uiSelfTest", name: "ui")
        defer { UIProcessHarness.cleanTemporary(directory) }
        let report = try JSONDecoder().decode([UIProcessHarness.Result].self, from: Data(contentsOf: directory.appendingPathComponent("results.json")))
        #expect(report.count >= 45)
        for result in report {
            if let reason = result.skipped { print("SKIP: \(result.name): \(reason)") }
            else { #expect(result.passed, Comment(rawValue: result.name)) }
        }
        for name in ["home-light", "home-dark", "editor-light", "editor-dark", "clips-light", "clips-dark", "settings-light", "onboarding-light", "onboarding-dark", "export-light", "export-dark", "toolbar-light-key", "toolbar-light-inactive", "toolbar-dark-key", "toolbar-dark-inactive"] {
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
        try verifyRedesignScenes(in: directory)
        print("mac-ui document screenshots: \(directory.path)")
    }
    /// The one-window shell from Home through clipping, with the twelve ADR-R29
    /// redesign captures shared by sceneAudit and captureDemo.
    /// A check the host can't run (no accessibility trust) reports why it skipped; the
    /// twelve captures still need an unlocked session.
    @Test("Native document scene moves from Home through clipping", .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_UI_TESTS"] == "1")) func documentScene() throws {
        let directory = try UIProcessHarness.run(mode: "-sceneAudit", name: "scene")
        defer { UIProcessHarness.cleanTemporary(directory) }
        let report = try JSONDecoder().decode([UIProcessHarness.Result].self, from: Data(contentsOf: directory.appendingPathComponent("scene-results.json")))
        #expect(report.count >= 46)
        for result in report { #expect(result.passed || result.skipped != nil, Comment(rawValue: result.name)) }
        if ProcessInfo.processInfo.environment["VOXCLIP_UI_REDUCED_EFFECTS"] == "1" {
            struct Effects: Decodable {
                let reduceMotion: Bool; let reduceTransparency: Bool
                let differingPixels: Int; let opaqueBackgroundPixels: Int; let frameIntervalSeconds: Double
            }
            let effects = try JSONDecoder().decode(Effects.self, from: Data(contentsOf: directory.appendingPathComponent("reduced-effects.json")))
            #expect(effects.reduceMotion && effects.reduceTransparency)
            #expect(effects.differingPixels == 0 && effects.opaqueBackgroundPixels >= 10)
            #expect(effects.frameIntervalSeconds >= 0.2)
        }
        try verifyRedesignScenes(in: directory)
        print("mac-ui native scene screenshots: \(directory.path)")
    }
    private func verifyRedesignScenes(in directory: URL) throws {
        let report = try JSONDecoder().decode([UIProcessHarness.Result].self, from: Data(contentsOf: directory.appendingPathComponent("redesign-scenes.json")))
        let names = ["live-home", "live-home-empty", "live-dragover", "live-editor-full", "live-editor-clip", "live-editor-1280", "live-editor-1280-blue", "live-editor-1180", "live-editor-300", "live-editor-560", "live-editor-960", "live-compact", "live-selection-bar", "live-suggested", "live-finding", "live-export-clip", "live-rewrite"]
        #expect(report.count == names.count)
        for name in names {
            let result = try #require(report.first { $0.name == "native scene \(name)" })
            if name == "live-editor-1280-blue", let reason = result.skipped {
                print("OWED: \(name): \(reason)")
                continue
            }
            #expect(result.passed && result.skipped == nil, Comment(rawValue: name))
            let image = try #require(NSBitmapImageRep(data: Data(contentsOf: directory.appendingPathComponent(name).appendingPathExtension("png"))))
            #expect(image.pixelsWide >= 600 && image.pixelsHigh >= 400)
            if name != "live-home" && name != "live-home-empty" && name != "live-dragover" {
                struct Bounds: Decodable { let editor: Bool; let collapsed: Bool; let column: CGRect; let content: CGRect; let failures: [String]; let elements: [Element] }
                struct Element: Decodable { let identifier: String; let frame: CGRect }
                let bounds = try JSONDecoder().decode(Bounds.self, from: Data(contentsOf: directory.appendingPathComponent("\(name)-bounds.json")))
                #expect(bounds.editor && bounds.failures.isEmpty, Comment(rawValue: name))
                #expect(bounds.collapsed == (name == "live-compact"), Comment(rawValue: name))
                if name == "live-editor-full" { #expect(abs(bounds.content.width - 1440) <= 1 && abs(bounds.content.height - 900) <= 1 && abs(bounds.column.width - 360) <= 1) }
                if name == "live-editor-1180" { #expect(abs(bounds.content.width - 1180) <= 1 && abs(bounds.content.height - 800) <= 1 && abs(bounds.column.width - 300) <= 1) }
                if name == "live-editor-1280" { #expect(!bounds.collapsed && abs(bounds.column.width - 320) <= 1) }
                if name == "live-editor-300" { #expect(!bounds.collapsed && abs(bounds.column.width - 300) <= 1) }
                if name == "live-editor-560" { #expect(!bounds.collapsed && abs(bounds.column.width - 560) <= 1) }
                if name == "live-editor-960" { #expect(!bounds.collapsed && abs(bounds.content.width - 960) <= 1 && abs(bounds.content.height - 600) <= 1) }
                if !bounds.collapsed { #expect(bounds.elements.contains { $0.identifier == "voxclip.viewer.time" }) }
            }
        }
        try verifyColumnSettlements(in: directory)
        try verifySelectedGallery(in: directory)
    }
    private func verifyColumnSettlements(in directory: URL) throws {
        struct Settlement: Decodable { let elapsed: Double; let settled: Bool; let stage: CGRect; let root: CGRect; let column: CGRect }
        for width: Double in [300, 560] {
            for suffix in ["", "-resize-64", "-resize-0"] {
                let name = "drag-\(Int(width))\(suffix)-settlement.json"
                let result = try JSONDecoder().decode(Settlement.self, from: Data(contentsOf: directory.appendingPathComponent(name)))
                #expect(result.settled && result.elapsed < 2, Comment(rawValue: name))
                #expect(abs(result.column.width - width) <= 1 && abs(result.stage.width - (width - 32)) <= 0.5)
                #expect(abs(result.root.minX - result.column.minX) <= 0.5 && abs(result.root.width - result.column.width) <= 0.5)
            }
        }
    }
    private func verifySelectedGallery(in directory: URL) throws {
        struct Choice: Decodable { let role: String; let frame: CGRect; let selected: Bool }
        struct Selection: Decodable { let style: String; let visible: Bool; let paint: CGRect; let viewport: CGRect; let choice: Choice; let header: CGRect? }
        let interactionScenes = ["live-editor-full", "live-editor-1280", "live-editor-300", "live-editor-560"]
        let interactionSelections = interactionScenes.flatMap { scene in ["first", "middle", "last", "external", "undo"].map { "\(scene)-\($0)" } }
        let initialSelections = ["live-editor-full", "live-editor-1280", "live-editor-1280-initial", "live-editor-clip", "live-editor-300", "live-editor-560"]
        for name in initialSelections + interactionSelections {
            let result = try JSONDecoder().decode(Selection.self, from: Data(contentsOf: directory.appendingPathComponent("\(name)-selected-gallery.json")))
            let viewport = result.viewport.insetBy(dx: -0.5, dy: -0.5)
            #expect(result.visible && !result.style.isEmpty && result.choice.role == "AXRadioButton", Comment(rawValue: name))
            #expect(viewport.contains(result.paint) && result.choice.selected, Comment(rawValue: name))
            if let header = result.header, header.union(result.paint).height + 24 <= result.viewport.height { #expect(viewport.contains(header)) }
        }
        for name in interactionScenes {
            let report = try JSONDecoder().decode([UIProcessHarness.Result].self,
                from: Data(contentsOf: directory.appendingPathComponent("\(name)-gallery-interaction-results.json")))
            #expect(report.count == (name == "live-editor-full" ? 12 : 8))
            for result in report { #expect(result.passed && result.skipped == nil, Comment(rawValue: result.name)) }
        }
        struct ShortSnapshot: Decodable { let paint: CGRect; let visible: CGRect; let pending: Bool }
        struct ShortMeasurement: Decodable { let settled: Bool; let snapshot: ShortSnapshot }
        let short = try JSONDecoder().decode([ShortMeasurement].self,
            from: Data(contentsOf: directory.appendingPathComponent("caption-gallery-short.json")))
        #expect(short.count == 2)
        for measurement in short {
            #expect(measurement.settled && !measurement.snapshot.pending)
            #expect(measurement.snapshot.paint.height > measurement.snapshot.visible.height)
            #expect(abs(measurement.snapshot.paint.minY - measurement.snapshot.visible.minY) <= 0.5)
        }
    }
    @Test("Native Save As boundary preserves portable media and edits", .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_UI_TESTS"] == "1")) func saveBoundary() throws {
        let directory = try UIProcessHarness.run(mode: "-saveBoundaryAudit", name: "save", acceptNonzeroWithReport: "save-boundary-results.json")
        defer { UIProcessHarness.cleanTemporary(directory) }
        let report = try JSONDecoder().decode([UIProcessHarness.Result].self, from: Data(contentsOf: directory.appendingPathComponent("save-boundary-results.json")))
        #expect(report.count >= 36)
        for result in report { #expect(result.passed, Comment(rawValue: result.name)) }
    }
    @Test("Settings command retains window and reacts to appearance", .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_UI_TESTS"] == "1")) func settingsLifecycle() throws {
        let directory = try UIProcessHarness.run(mode: "-settingsAudit", name: "settings", acceptNonzeroWithReport: "settings-results.json")
        defer { UIProcessHarness.cleanTemporary(directory) }
        let report = try JSONDecoder().decode([UIProcessHarness.Result].self, from: Data(contentsOf: directory.appendingPathComponent("settings-results.json")))
        #expect(report.count >= 16)
        for result in report { #expect(result.passed, Comment(rawValue: result.name)) }
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
    static func run(mode: String, name: String, acceptNonzeroWithReport: String? = nil, preparedDirectory: URL? = nil) throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let adjacent = Bundle(for: MacUIRenderPerformanceTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("VoxClip")
        let override = mode == "-uiPerformanceTest" ? environment["VOXCLIP_UI_PERFORMANCE_EXECUTABLE"] ?? environment["VOXCLIP_APP_EXECUTABLE"] : environment["VOXCLIP_APP_EXECUTABLE"]
        var executable = override.map { URL(fileURLWithPath: $0) } ?? adjacent
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw Failure.executableMissing }
        let shared = try SharedResources.locate().root
        let directory = preparedDirectory ?? environment["VOXCLIP_UI_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent(name) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-mac-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if mode == "-voiceRecipeAudit", !executable.path.contains(".app/Contents/MacOS/") {
            // The real exporter requires the app's actual version in provenance.
            // SwiftPM's bare executable has no bundle metadata, so give this test
            // an owned bundle using the production plist and the just-built app.
            var package = URL(fileURLWithPath: #filePath)
            for _ in 0..<4 { package.deleteLastPathComponent() }
            let contents = directory.appendingPathComponent("VoiceRecipe.app/Contents")
            let macOS = contents.appendingPathComponent("MacOS")
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: package.appendingPathComponent("Sources/VoxClip/Info.plist"), to: contents.appendingPathComponent("Info.plist"))
            let staged = macOS.appendingPathComponent("VoxClip")
            try FileManager.default.copyItem(at: executable, to: staged)
            for item in try FileManager.default.contentsOfDirectory(at: executable.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                where item.pathExtension == "framework" || item.pathExtension == "dylib" {
                try FileManager.default.createSymbolicLink(at: macOS.appendingPathComponent(item.lastPathComponent), withDestinationURL: item)
            }
            executable = staged
        }
        do {
        let data = directory.appendingPathComponent("data")
        defer { if preparedDirectory == nil, FileManager.default.fileExists(atPath: data.path) { try? FileManager.default.removeItem(at: data) } }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO", mode, directory.path]
        if mode == "-sceneAudit", environment["VOXCLIP_UI_REDUCED_EFFECTS"] == "1" { process.arguments! += ["-reducedEffects"] }
        if mode == "-demoCapture" { process.arguments! += ["-demoProject", shared.appendingPathComponent("fixtures/projects/interview-take.voxclip").path] }
        var childEnvironment = environment.filter { !$0.key.hasSuffix("_API_KEY") && !$0.key.hasSuffix("_TOKEN") }
        childEnvironment["VOXCLIP_SHARED_DIR"] = shared.path
        childEnvironment["VOXCLIP_NO_KEYCHAIN"] = "1"
        childEnvironment["VOXCLIP_DATA_DIR"] = data.path
        childEnvironment["VOXCLIP_LIVE_TESTS"] = "0"
        childEnvironment["VOXCLIP_TEST_DOWNLOAD"] = "0"
        process.environment = childEnvironment
        let logURL = directory.appendingPathComponent("app.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        process.standardOutput = log; process.standardError = log
        try process.run()
        let deadline = Date().addingTimeInterval(mode == "-uiSelfTest" ? 360 : 120)
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
        if process.terminationStatus != 0 {
            guard let report = acceptNonzeroWithReport,
                  let data = try? Data(contentsOf: directory.appendingPathComponent(report)),
                  let results = try? JSONDecoder().decode([Result].self, from: data),
                  results.contains(where: { !$0.passed }) else {
                reportFailure(directory)
                throw Failure.appFailed(process.terminationStatus)
            }
        }
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("failure.txt").path) else { throw Failure.outputMissing }
        return directory
        } catch {
            if environment["VOXCLIP_UI_EVIDENCE_DIR"] == nil { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
    }
    /// Hosted CI keeps no UI evidence, so name the failing checks and the end of the app log.
    private static func reportFailure(_ directory: URL) {
        var lines: [String] = []
        for report in ["results.json", "results-progress.json"] {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(report)),
                  let results = try? JSONDecoder().decode([Result].self, from: data) else { continue }
            lines += results.filter { !$0.passed }.prefix(20).map { "\(report) failed: \($0.name)" }
            break
        }
        if let log = try? String(contentsOf: directory.appendingPathComponent("app.log"), encoding: .utf8) {
            lines += log.split(separator: "\n").suffix(15).map { "app.log: \($0)" }
        }
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }
    static func cleanTemporary(_ directory: URL) {
        if ProcessInfo.processInfo.environment["VOXCLIP_UI_EVIDENCE_DIR"] == nil { try? FileManager.default.removeItem(at: directory) }
    }
}
