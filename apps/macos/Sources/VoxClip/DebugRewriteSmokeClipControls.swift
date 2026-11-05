#if DEBUG
import AVFoundation
import Foundation
import VoxClipCore
import VoxClipMedia

/// S-clip-controls (design.md §6.9): a clip at 1.25× with the Muted look, exported with its subtitles through the real
/// exporter. The export must be the clip's edited length divided by 1.25, and the captions must land on the same words.
extension DebugRewriteSmoke {
    static var clipControlsScenarios: [Definition] { [
        Definition(id: "S-clip-controls", title: "a clip at 1.25\u{00D7} with the Muted look exports shorter with its captions aligned",
                   requiresCompletion: false,
                   fixture: Fixture(rewrites: [], voice: RewriteSmokeVoiceScript(exactFit: true))) { harness in
            try await exportFasterMutedClip(harness)
        },
    ] }

    @MainActor private static func exportFasterMutedClip(_ harness: Harness) async throws {
        guard let editor = harness.editor, let words = editor.project.transcript?.words, words.count > 20 else {
            throw Failure.setup("S-clip-controls has no words")
        }
        var project = editor.project
        project.edits.clips = [ClipRange(id: "clip-speed", startWordId: words[0].id, endWordId: words[40].id, title: "Speed")]
        project.edits.activeClipId = "clip-speed"
        project.captions.styleId = "vox-bold"
        editor.replace(project, name: "Make the clip")
        let plain = try await editor.renderRequest(target: .clip("clip-speed"))
        let changed = editor.setSpeed(1.25) && editor.setLook(.muted)
        let request = try await editor.renderRequest(target: .clip("clip-speed"))
        var checks = [Check(invariant: "C1", passed: changed && request.clipControls?.speed == 1.25 && request.clipControls?.look == .muted,
                            detail: "controls on the render: \(request.clipControls.map { "\($0.speed)× \($0.look.rawValue)" } ?? "none")")]
        let folder = harness.directory.appendingPathComponent("S-clip-controls", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let video = folder.appendingPathComponent("clip.mp4"), srt = folder.appendingPathComponent("clip.srt")
        defer { try? FileManager.default.removeItem(at: video) }
        let result = try await AVExporter().export(ExportJob(target: .clip("clip-speed"), render: request, outputURL: video,
                                                             writeSRT: true, srtURL: srt)) { _ in }
        let expected = plain.timeline.duration / 1.25
        let fileSeconds = try await AVURLAsset(url: video).load(.duration).seconds
        let frame = 1 / request.output.fps
        checks.append(Check(invariant: "C2", passed: abs(result.durationSeconds - expected) <= frame && abs(fileSeconds - expected) <= 2 * frame,
                            detail: String(format: "export %.3f s (file %.3f s) for a %.3f s clip at 1.25×, expected %.3f s",
                                           result.durationSeconds, fileSeconds, plain.timeline.duration, expected)))
        // Each subtitle cue is its caption page divided by the speed, and the last ends inside the video.
        let cues = Self.cueTimes(try String(contentsOf: srt, encoding: .utf8))
        let pages = request.captionLayout?.pages.map(\.page).filter { $0.end > $0.start } ?? []
        let aligned = !cues.isEmpty && cues.count == pages.count && zip(cues, pages).allSatisfy { cue, page in
            abs(cue.start - page.start / 1.25) <= 0.001 && abs(cue.end - page.end / 1.25) <= 0.001
        }
        let inside = (cues.last?.end ?? .infinity) <= result.durationSeconds + 0.001
        checks.append(Check(invariant: "C3", passed: aligned && inside,
                            detail: "\(cues.count) cues for \(pages.count) caption pages, last ends at \(cues.last.map { String(format: "%.3f", $0.end) } ?? "none") s"))
        harness.steps.append(Step(index: harness.steps.count + 1, action: "set 1.25× and Muted, then export the clip with subtitles",
                                  snapshot: Snapshot(), checks: checks))
    }

    /// "00:00:01,234 --> 00:00:02,000" lines as seconds.
    static func cueTimes(_ srt: String) -> [(start: Double, end: Double)] {
        func seconds(_ text: Substring) -> Double? {
            let parts = text.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == ":" || $0 == "," }).compactMap { Double($0) }
            guard parts.count == 4 else { return nil }
            return parts[0] * 3600 + parts[1] * 60 + parts[2] + parts[3] / 1000
        }
        return srt.split(separator: "\n").compactMap { line in
            let halves = line.components(separatedBy: " --> ")
            guard halves.count == 2, let start = seconds(Substring(halves[0])), let end = seconds(Substring(halves[1])) else { return nil }
            return (start, end)
        }
    }
}
#endif
