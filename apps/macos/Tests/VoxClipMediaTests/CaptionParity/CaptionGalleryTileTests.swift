import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

/// A latch that a test opens by hand. Waiting ignores task cancellation, as a run waiting its turn on a shared actor does.
private final class CaptionTileLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock { () -> Bool in
                if !opened { waiters.append(continuation) }
                return opened
            }
            if ready { continuation.resume() }
        }
    }

    func open() {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true
            defer { waiters = [] }
            return waiters
        }
        for continuation in ready { continuation.resume() }
    }
}

/// Gallery tiles through the real CoreText renderer (captions §15.2–15.3, design §6.1).
@Suite(.serialized)
struct CaptionGalleryTileTests {
    /// The shared interview take, the transcript of the Mac UI scenes ("So um, today we ship uh the clipper. Thanks").
    private static func interview() throws -> Project {
        try FixtureLoader.decode(Project.self, at: "fixtures/projects/interview-take.voxclip")
    }

    /// The take after the scene's correction: "So" cut and "um," corrected to "corrected", as the r1d capture project
    /// stored it.
    private static func corrected() throws -> Project {
        var project = try interview()
        project.edits.cutWordIds = ["w1"]; project.edits.cutPauseIds = []; project.edits.corrections = ["w2": "corrected"]
        return project
    }

    /// What `EditorModel.captionTileInput` samples at the start of the take: up to six kept words, corrected.
    private static func tileWords(_ project: Project) -> [String] {
        let edits = project.edits
        return (project.transcript?.words ?? []).filter { !edits.cutWordIds.contains($0.id) }.prefix(6).map { edits.corrections[$0.id] ?? $0.text }
    }

    /// `CaptionHandoff.tile`'s layout call: the words at [0.4 i, 0.4 i + 0.35] with no emphasis, in the resolved style.
    private static func tileLayout(_ sample: [String], pipeline: CaptionPipeline, style: CaptionStyle, frame: PixelSize) async throws -> CaptionLayoutResult {
        let words = sample.enumerated().map { index, text in
            CaptionWord(id: "tile-\(index)", text: text, start: Double(index) * 0.4, end: Double(index) * 0.4 + 0.35)
        }
        let resolution = await pipeline.resolve(style, overrides: [:], frame: frame)
        return try await pipeline.layout(words: words, language: "en", style: resolution.style, position: nil, frame: frame,
                                         duration: Double(words.count) * 0.4 + 0.5)
    }

    private static func drawsSomething(_ raster: CaptionRaster) -> Bool {
        stride(from: 3, to: raster.rgba.count, by: 4).contains { raster.rgba[$0] != 0 }
    }

    @Test("The tile path's layout and raster calls succeed for every style over the corrected words")
    func tilePathRendersEveryStyle() async throws {
        let shared = try CaptionMediaFixtures.shared()
        let pipeline = try CaptionPipeline(shared: shared), rasterizer = CoreTextCaptionRasterizer(shared: shared)
        let styles = try CaptionStyleLibrary(shared: shared).styles
        #expect(styles.count == 19)
        var replaced = try Self.interview()
        replaced.edits.cutWordIds = []; replaced.edits.cutPauseIds = []; replaced.edits.corrections = ["w1": "corrected"]
        let samples = [Self.tileWords(try Self.corrected()), Self.tileWords(replaced)]
        #expect(samples == [["corrected", "today", "we", "ship", "uh", "the"], ["corrected", "um,", "today", "we", "ship", "uh"]])
        // The capture's frame (its 1280×720 source at the Source aspect) and both presets.
        let frames = [PixelSize(width: 1280, height: 720), PixelSize(width: 1080, height: 1920), PixelSize(width: 1920, height: 1080)]
        var failures: [String] = [], rendered = 0
        for sample in samples {
            for frame in frames {
                for style in styles {
                    let label = "\(style.id) \(frame.width)x\(frame.height) \(sample.joined(separator: " "))"
                    let layout: CaptionLayoutResult
                    do {
                        layout = try await Self.tileLayout(sample, pipeline: pipeline, style: style, frame: frame)
                    } catch {
                        failures.append("\(label): layout threw \(error)"); continue
                    }
                    do {
                        // CaptionHandoff.tile draws at 0.2 s.
                        let raster = try await rasterizer.rasterize(layout, time: 0.2, previewWidth: 320, reduceMotion: true)
                        if Self.drawsSomething(raster) { rendered += 1 } else { failures.append("\(label): empty overlay") }
                    } catch {
                        failures.append("\(label): rasterize threw \(error)")
                    }
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
        #expect(rendered == samples.count * frames.count * styles.count)
    }

    @Test("A cancelled tile run fails with CancellationError even when it resumes after the newer run has drawn")
    func cancelledTileRunResumesLate() async throws {
        let shared = try CaptionMediaFixtures.shared()
        let pipeline = try CaptionPipeline(shared: shared), rasterizer = CoreTextCaptionRasterizer(shared: shared)
        let style = try CaptionMediaFixtures.style("vox-highlight", shared: shared), frame = PixelSize(width: 1280, height: 720)
        for parkedAfterLayout in [false, true] {
            let parked = CaptionTileLatch(), resume = CaptionTileLatch()
            // The run for the tile's input before the correction waits its turn before one of its two calls.
            let older = Task {
                if !parkedAfterLayout { parked.open(); await resume.wait() }
                let layout = try await Self.tileLayout(["So", "um,", "today"], pipeline: pipeline, style: style, frame: frame)
                if parkedAfterLayout { parked.open(); await resume.wait() }
                return try await rasterizer.rasterize(layout, time: 0.2, previewWidth: 320, reduceMotion: true)
            }
            await parked.wait()
            // The correction changes the input: `.task(id:)` cancels that run and starts one that draws the new words.
            older.cancel()
            let layout = try await Self.tileLayout(["corrected", "today"], pipeline: pipeline, style: style, frame: frame)
            let newer = try await rasterizer.rasterize(layout, time: 0.2, previewWidth: 320, reduceMotion: true)
            #expect(Self.drawsSomething(newer))
            // The older run resumes last; its next call throws CancellationError, which `tile` returns as nil.
            resume.open()
            await #expect(throws: CancellationError.self, "parked after layout: \(parkedAfterLayout)") { try await older.value }
        }
    }

    @Test("The Core gallery sample renders a non-empty overlay for every style at both aspect presets")
    func coreSampleRendersEveryStyle() async throws {
        let shared = try CaptionMediaFixtures.shared(), resources = try CaptionResources.load(shared: shared)
        let pipeline = try CaptionPipeline(shared: shared), rasterizer = CoreTextCaptionRasterizer(shared: shared)
        let styles = try CaptionStyleLibrary(shared: shared).styles
        var untranscribed = try Self.corrected()
        untranscribed.transcript = nil
        // Inside "corrected", between pages, after the last page, and preview.text with no transcript.
        let scenes: [(project: Project, playhead: Double)] = [(try Self.corrected(), 0.4), (try Self.corrected(), 1.5),
                                                              (try Self.corrected(), 6.55), (untranscribed, 0)]
        var failures: [String] = [], rendered = 0
        for aspect in [AspectRatio.portrait, .landscape] {
            for (scene, playhead) in scenes {
                var project = scene
                project.export.aspect = aspect
                let source = project.media.source.video.map(OutputSizing.orientedSize) ?? PixelSize(width: 1920, height: 1080)
                let frame = try OutputSizing.outputSize(source: source, aspect: aspect)
                for style in styles {
                    let overrides = style.id == project.captions.styleId ? project.captions.overrides : [:]
                    let settings = CaptionLayoutInput.Settings(overrides: overrides, position: project.captions.position,
                                                               positionByAspect: project.captions.positionByAspect)
                    let sample = CaptionGallerySample.make(project: project, scope: .fullTake, playhead: playhead, style: style, wordsVisible: true,
                                                           resources: resources)
                    let label = "\(style.id) \(aspect.rawValue) at \(playhead): \(sample.words.map(\.text).joined(separator: " "))"
                    let input = CaptionLayoutInput(style: style.id, frame: .init(width: frame.width, height: frame.height),
                                                   language: sample.source == .preview ? "en" : project.transcript?.language ?? "und", duration: sample.duration, captions: settings,
                                                   words: sample.words)
                    do {
                        let layout = try await pipeline.layout(input: input, style: style)
                        let raster = try await rasterizer.rasterize(layout, time: sample.time, previewWidth: 320, reduceMotion: true)
                        if Self.drawsSomething(raster) { rendered += 1 } else { failures.append("\(label): empty overlay") }
                    } catch {
                        failures.append("\(label): \(error)")
                    }
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
        #expect(rendered == 2 * scenes.count * styles.count)
    }
}
