import Foundation
import Darwin
import Testing
import VoxClipCore
@testable import VoxClipMedia

struct CaptionImageComparisonTests {
    private static let python = ProcessInfo.processInfo.environment["VOXCLIP_CAPTION_PYTHON"] ?? "python3"
    private static let pythonAvailable: Bool = {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        probe.arguments = [python, "-I", "-c", "import numpy"]
        probe.standardOutput = FileHandle.nullDevice; probe.standardError = FileHandle.nullDevice
        do { try probe.run(); probe.waitUntilExit(); return probe.terminationStatus == 0 }
        catch { return false }
    }()

    private func image(width: Int = 64, height: Int = 32, alpha: UInt8 = 255) -> CaptionRaster {
        var bytes = Data(count: width * height * 4)
        for offset in stride(from: 3, to: bytes.count, by: 4) { bytes[offset] = alpha }
        return .init(width: width, height: height, bytesPerRow: width * 4, rgba: bytes)
    }

    private func cases() -> [(String, CaptionRaster, CaptionRaster, Bool)] {
        let baseline = image()
        var cases: [(String, CaptionRaster, CaptionRaster, Bool)] = []
        cases.append(("empty", image(alpha: 0), image(alpha: 0), true))
        cases.append(("one-empty", baseline, image(alpha: 0), false))
        for red: UInt8 in [18, 19] {
            var changed = baseline
            for offset in stride(from: 0, to: changed.rgba.count, by: 4) { changed.rgba[offset] = red }
            cases.append(("mean-\(red)", baseline, changed, red == 18))
        }
        for count in [96, 97] {
            var changed = baseline
            for pixel in 0..<count { changed.rgba[pixel * 4] = 40 }
            cases.append(("floor-\(count)", baseline, changed, count == 96))
        }
        for count in [163, 164] {
            let original = image(width: 128, height: 64)
            var changed = original
            for pixel in 0..<count { changed.rgba[pixel * 4] = 40 }
            cases.append(("share-\(count)", original, changed, count == 163))
        }
        for difference: UInt8 in [128, 129] {
            var changed = baseline
            changed.rgba[0] = difference
            cases.append(("max-\(difference)", baseline, changed, difference == 128))
        }
        cases.append(("near-transparent", image(alpha: 1), image(alpha: 2), true))
        var alphaA = image(alpha: 0), alphaB = alphaA
        for row in 8..<24 {
            for column in 8..<40 {
                alphaA.rgba[(row * 64 + column) * 4 + 3] = 128
                alphaB.rgba[(row * 64 + column + 1) * 4 + 3] = 128
            }
        }
        cases.append(("ssim-shift", alphaA, alphaB, false))
        cases.append(("corner-padding", image(width: 1, height: 1, alpha: 128), image(width: 1, height: 1, alpha: 132), true))
        return cases
    }

    @Test("Swift image verdicts always enforce the 16.5 metric boundaries")
    func swiftVerdicts() throws {
        let identical = image()
        let equal = try CaptionImageComparison.compare(identical, identical)
        #expect(equal.matches && equal.mean == 0 && equal.maximum == 0 && equal.pixelsOver32 == 0)
        #expect(equal.pixels == identical.width * identical.height && equal.alphaSSIM == nil)
        for (name, first, second, passes) in cases() {
            let comparison = try CaptionImageComparison.compare(first, second)
            #expect(comparison.matches == passes, "Swift: \(name)")
            if name == "ssim-shift" { #expect(comparison.alphaSSIM! < 0.98) }
            if name == "near-transparent" { #expect(comparison.alphaSSIM == nil) }
        }
    }

    @Test("Swift metrics match isolated Python when numpy is available",
          .enabled(if: pythonAvailable || ProcessInfo.processInfo.environment["CI"] != nil,
                   "Python cross-check skipped: set VOXCLIP_CAPTION_PYTHON to an interpreter with numpy available under -I"))
    func pythonParity() throws {
        guard Self.pythonAvailable else {
            Issue.record("CI requires \(Self.python) -I -c 'import numpy' to succeed; install tools/captions/requirements.txt and set VOXCLIP_CAPTION_PYTHON")
            return
        }
        let shared = try CaptionMediaFixtures.shared()
        let script = shared.root.deletingLastPathComponent().appendingPathComponent("tools/captions/compare_overlays.py")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-caption-comparison-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cases = cases()
        var failures = 0
        for (name, first, second, passes) in cases {
            let comparison = try CaptionImageComparison.compare(first, second)
            let firstURL = root.appendingPathComponent("\(name)-a.png"), secondURL = root.appendingPathComponent("\(name)-b.png")
            let firstImage = try CaptionGoldenWriter.write(first, to: firstURL, sample: nil, style: nil, time: 0)
            let secondImage = try CaptionGoldenWriter.write(second, to: secondURL, sample: nil, style: nil, time: 0)
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [Self.python, "-I", script.path,
                firstURL.path, secondURL.path, "--frame", "\(first.width)", "\(first.height)",
                "--a-crop", "\(firstImage.crop.x)", "\(firstImage.crop.y)",
                "--b-crop", "\(secondImage.crop.x)", "\(secondImage.crop.y)"]
            process.standardOutput = output; process.standardError = output
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            var reaped = false
            defer {
                if !reaped && process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    if exited.wait(timeout: .now() + .seconds(5)) == .success { process.waitUntilExit() }
                }
            }
            try process.run()
            let response = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            reaped = true
            var matches = process.terminationStatus == (passes ? 0 : 1)
            #expect(matches, "Python: \(name): \(response)")
            if let start = response.firstIndex(of: "{"), let end = response[start...].firstIndex(of: "}"),
               let metrics = try? JSONSerialization.jsonObject(with: Data(response[start...end].utf8)) as? [String: Any] {
                if name == "empty" || name == "one-empty" {
                    let emptyMatches = name == "empty" ? metrics["empty"] as? Bool == true : metrics["error"] as? String == "one image is empty"
                    #expect(emptyMatches, "Python empty-image verdict: \(name)")
                    matches = matches && emptyMatches
                } else if let mean = metrics["mean"] as? Double, let maximum = metrics["max"] as? Int {
                    let meanMatches = abs(mean - comparison.mean) <= 0.000051
                    let maximumMatches = maximum == comparison.maximum
                    #expect(meanMatches, "Python mean: \(name)")
                    #expect(maximumMatches, "Python maximum: \(name)")
                    matches = matches && meanMatches && maximumMatches
                    if let actual = comparison.alphaSSIM {
                        let ssimMatches = (metrics["ssimAlpha"] as? Double).map { abs($0 - actual) <= 0.000006 } ?? false
                        #expect(ssimMatches, "Python alpha SSIM: \(name)")
                        matches = matches && ssimMatches
                    }
                } else {
                    Issue.record("Incomplete Python metrics for \(name): \(response)")
                    matches = false
                }
            } else {
                Issue.record("Missing Python metrics for \(name): \(response)")
                matches = false
            }
            if !matches { failures += 1 }
        }
        if failures == 0 { print("Caption image comparison: \(cases.count) synthetic pairs match Python") }
        else { print("Caption image comparison: \(failures) of \(cases.count) synthetic pairs failed the Python cross-check") }
    }
}
