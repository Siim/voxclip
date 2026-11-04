#if DEBUG
import AppKit
import AVFoundation
import SwiftUI
import VoxClipCore
@_spi(Testing) import VoxClipMedia

// `-rewriteSmoke <dir>`: the Rewrite flow driven through realistic stuck states before a build is handed over
// (doc/release.md). Each scenario opens the real `RewriteSession` on a small fixture with scripted stand-ins
// (DebugRewriteSmokeStubs.swift), clicks only what a user could click, and after every step reads the panel as it is
// drawn: its task model and, offscreen in a window that is never shown, its view and accessibility tree. The invariants
// I1–I7 are checked at every step (I8–I9 at the end of S10–S12) and written to rewrite-smoke.json and summary.txt.

@MainActor enum DebugRewriteSmoke {
    // MARK: Report

    struct Control: Encodable, Equatable {
        let id: String
        let title: String
        let enabled: Bool
        /// "model" (the task's actions), "evidence" (layout markers) or "ax" (the accessibility tree).
        let source: String
        let role: String
        /// It moves the Rewrite on: a primary, link, chip, Stop, confirm or an enabled row button.
        let acts: Bool
    }
    struct Snapshot: Encodable {
        var state = "closed"
        var headline = ""
        var sub: String?
        var cards: [String] = []
        var texts: [String] = []
        var controls: [Control] = []
        var textFields = 0
        var footer: String?
        var resolverRunning = false
        var paidTakes = 0
        var quotes: [String] = []
        /// The phrase quotes as the panel drew them (`voice.quote.{n}` evidence).
        var drawnQuotes: [String] = []
        /// Each take: "phrase 2 take 1: 1.4 s, passed" or its failure reason.
        var takes: [String] = []
        /// Each voice change's pre-pay timing: "2: estimate 0.9 s, slot 1.1 s, fits".
        var timings: [String] = []
    }
    struct Check: Encodable {
        let invariant: String
        let passed: Bool
        let detail: String
        /// A failure the stucktakes track has not fixed yet: reported, not counted.
        var knownFailing = false
    }
    struct Step: Encodable {
        let index: Int
        let action: String
        let snapshot: Snapshot
        let checks: [Check]
        var capture: String?
    }
    struct Scenario: Encodable {
        let id: String
        let title: String
        var steps: [Step] = []
        var completed = false
        var requests: [RewriteSmokeRequestRecord] = []
        var syntheses = 0
        var seconds = 0.0
        var error: String?
        /// Where the driver found nothing a user could click on.
        var stuck: String?
        var passed: Bool { error == nil && steps.allSatisfy { $0.checks.allSatisfy { $0.passed || $0.knownFailing } } }
    }
    struct Report: Encodable {
        let schema = "voxclip-rewrite-smoke/1"
        let build: String
        var scenarios: [Scenario] = []
        var allowedDisabled: [String: String] = DebugRewriteSmoke.allowedDisabled
        var knownFailing: [String: String] = DebugRewriteSmoke.knownFailing
        var seconds = 0.0
        var passed: Bool { scenarios.allSatisfy(\.passed) }
    }
    /// Invariants reported as known failures (`-rewriteSmokeKnownFailing I2,I7`): still printed, not counted in the exit code.
    nonisolated static let knownFailing: [String: String] = {
        guard let index = CommandLine.arguments.firstIndex(of: "-rewriteSmokeKnownFailing"), index + 1 < CommandLine.arguments.count else { return [:] }
        return Dictionary(uniqueKeysWithValues: CommandLine.arguments[index + 1].split(separator: ",").map { (String($0), "not fixed on this build yet") })
    }()
    /// `-rewriteSmokeLengths realistic|exact|both` (default both): the take-length passes, false for realistic lengths.
    nonisolated static let lengthPasses: [Bool] = {
        guard let index = CommandLine.arguments.firstIndex(of: "-rewriteSmokeLengths"), index + 1 < CommandLine.arguments.count else { return [false, true] }
        switch CommandLine.arguments[index + 1] {
        case "realistic": return [false]
        case "exact": return [true]
        default: return [false, true]
        }
    }()
    /// I2's explicit exceptions: a disabled control allowed to show, with why. Empty: every disabled control fails.
    nonisolated static let allowedDisabled: [String: String] = [:]

    // MARK: Entry

    static func run(app: AppModel, directory: URL) async -> Bool {
        let started = ProcessInfo.processInfo.systemUptime
        var report = Report(build: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "debug")
        let previous = app.settings
        defer { app.settings = previous }
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(true)
        let only = CommandLine.arguments.firstIndex(of: "-rewriteSmokeOnly").flatMap { index in
            index + 1 < CommandLine.arguments.count ? Set(CommandLine.arguments[index + 1].split(separator: ",").map(String.init)) : nil
        }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch {}
        // Realistic take lengths first, then every scenario again with takes that fill their slots exactly ("S4-exact").
        let runs = lengthPasses.flatMap { exact in
            scenarios.filter { (only?.contains($0.id) ?? true) && !(exact && $0.fixture.voice.exactFit) }.map { (exact, $0) }
        }
        for (exact, definition) in runs {
            let begun = ProcessInfo.processInfo.systemUptime
            let id = exact ? definition.id + "-exact" : definition.id
            var scenario = Scenario(id: id, title: definition.title + (exact ? " (takes fill their slots exactly)" : ""))
            let harness = Harness(app: app, directory: directory, scenario: id)
            var fixture = definition.fixture
            if exact { fixture.voice.exactFit = true }
            do {
                try await harness.open(fixture)
                try await definition.drive(harness)
            } catch Failure.missing(let control, let shown) {
                // A dead end: I1 and I5 report it; the scenario stops where a user would.
                harness.stuck = "no control \(control): \(shown)"
            } catch { harness.error = String(describing: error) }
            scenario.steps = harness.steps
            scenario.completed = harness.completed || (definition.mayEndUnchanged && harness.ended)
            scenario.error = harness.error
            scenario.stuck = harness.stuck
            scenario.requests = await harness.connector?.records ?? []
            scenario.syntheses = RewriteSmokeHTTP.script.withLock { $0.syntheses }
            if definition.requiresCompletion {
                let applied = harness.completed
                // S9 stops the fix that would have shortened its only change: Done with the words as recorded completes it.
                let ended = !applied && definition.mayEndUnchanged && harness.ended
                let check = Check(invariant: "I5", passed: applied || ended,
                    detail: applied ? "Rewrite applied" : ended ? "Rewrite ended with Done, the original words kept"
                        : "Rewrite not applied: " + (harness.steps.last.map { summary($0.snapshot) } ?? "no steps"))
                var checks = [check]
                // Takes that fill their slots keep the source video whatever length the scenario's realistic takes have.
                if let mode = exact && definition.video != nil ? .source : definition.video {
                    let modes = harness.appliedVideoModes
                    checks.append(Check(invariant: "I8", passed: modes.contains(mode),
                        detail: "applied video: " + (modes.isEmpty ? "none" : modes.map(\.rawValue).joined(separator: ", ")) + ", expected \(mode.rawValue)"))
                }
                if let voiced = definition.voiced {
                    let count = harness.appliedVideoModes.count
                    checks.append(Check(invariant: "I9", passed: count == voiced,
                        detail: "\(count) of \(voiced) voice change\(voiced == 1 ? "" : "s") applied in your voice"))
                }
                if var last = scenario.steps.popLast() {
                    last = Step(index: last.index, action: last.action, snapshot: last.snapshot, checks: last.checks + checks, capture: last.capture)
                    scenario.steps.append(last)
                }
            }
            harness.close()
            scenario.seconds = ProcessInfo.processInfo.systemUptime - begun
            report.scenarios.append(scenario)
        }
        report.seconds = ProcessInfo.processInfo.systemUptime - started
        write(report, to: directory)
        return report.passed
    }

    private static func write(_ report: Report, to directory: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) { try? data.write(to: directory.appendingPathComponent("rewrite-smoke.json"), options: .atomic) }
        // One result per check, as the UI process tests read them: "S3 step 4 I1: …".
        struct Result: Encodable { let name: String; let passed: Bool }
        let results = report.scenarios.flatMap { scenario in
            (scenario.error.map { [Result(name: "\(scenario.id) harness error: \($0)", passed: false)] } ?? [])
                + scenario.steps.flatMap { step in
                    step.checks.map { Result(name: "\(scenario.id) step \(step.index) \($0.invariant): \($0.detail)", passed: $0.passed) }
                }
        }
        if let data = try? encoder.encode(results) { try? data.write(to: directory.appendingPathComponent("results.json"), options: .atomic) }
        var lines = ["Rewrite smoke: \(report.passed ? "PASSED" : "FAILED") · \(report.scenarios.count) scenarios · \(String(format: "%.1f", report.seconds)) s"]
        for scenario in report.scenarios {
            let failures = scenario.steps.flatMap { step in step.checks.filter { !$0.passed }.map { (step, $0) } }
            let state = scenario.passed ? "ok" : "FAILED"
            lines.append("\(scenario.id) \(state) · \(scenario.title) · \(scenario.steps.count) steps · \(scenario.completed ? "applied" : "not applied") · \(String(format: "%.1f", scenario.seconds)) s")
            if let error = scenario.error { lines.append("  \(scenario.id): harness error: \(error)") }
            if let stuck = scenario.stuck { lines.append("  \(scenario.id): stopped, \(stuck)") }
            for (step, check) in failures {
                lines.append("  \(scenario.id) step \(step.index) (\(step.action)): \(check.invariant) \(check.knownFailing ? "FAILED (known)" : "FAILED"), \(check.detail)")
            }
        }
        let text = lines.joined(separator: "\n") + "\n"
        try? Data(text.utf8).write(to: directory.appendingPathComponent("summary.txt"), options: .atomic)
    }

    /// One line of what the panel shows: its headline, footer and the controls that act.
    static func summary(_ snapshot: Snapshot) -> String {
        guard snapshot.state != "closed" else { return "Rewrite closed" }
        let acting = snapshot.controls.filter { $0.acts && $0.enabled }.map { "[\($0.title)]" }
        let lines = snapshot.texts.filter { !$0.isEmpty }.prefix(3).map { "'\($0)'" }
        return "panel shows \(snapshot.headline.isEmpty ? "no headline" : "'\(snapshot.headline)'")"
            + (lines.isEmpty ? "" : ", " + lines.joined(separator: ", "))
            + (acting.isEmpty ? ", no control that acts" : ", controls " + acting.joined(separator: " "))
    }

    // MARK: Fixture

    /// A small take: words with natural gaps and sentence pauses, and 24 kHz source audio that has speech under each word.
    struct Fixture {
        var script = DebugRewriteSmoke.baseScript
        /// The first word of the Rewrite's selection (a clip-start fragment starts mid-sentence).
        var firstWord = 0
        var lastWord: Int? = nil
        var rewrites: [RewriteSmokeReply]
        var fits: [RewriteSmokeFit] = []
        var voice = RewriteSmokeVoiceScript()
    }
    nonisolated static let baseScript = "Today I want to show you how cloud tools edit video. First we record a short clip in one take. "
        + "Then we fix the words we got wrong. We keep the pauses that sound natural and remove the ones that drag. "
        + "The captions follow the words as they change, so nobody has to retype them. Every change is checked before anything is sent "
        + "to a voice service. Finally we export the clip and share it with our friends. That is the whole idea, and it only takes "
        + "a few minutes from start to finish."

    static func project(_ fixture: Fixture, root: URL, shared: SharedResources) async throws -> (Project, AudioEnvelope) {
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        project.id = UUID().uuidString.lowercased()
        project.voiceLab.segments = []; project.voiceLab.assets = []
        project.edits = ProjectEdits()
        let recording = try await recording(script: fixture.script, root: root)
        project.media.source.absolutePath = recording.movie.path
        project.media.source.relativePath = recording.movie.lastPathComponent
        project.media.source.sizeBytes = recording.sizeBytes
        project.media.source.contentKey = recording.contentKey
        project.media.source.video = MediaVideo(width: sourceVideoSize.width, height: sourceVideoSize.height, frameRate: 30, rotationDegrees: 0)
        project.media.source.durationSeconds = recording.duration
        project.media.source.audio?.sampleRate = recording.rate
        project.transcript?.words = recording.words
        project.transcript?.durationSeconds = recording.duration
        project.transcript?.language = "en"
        return (project, recording.envelope)
    }

    /// One script's synthetic recording: its words, audio envelope and source movie with the movie's content key.
    struct Recording {
        let words: [TimedWord]
        let duration: Double
        let rate: Int
        let movie: URL
        let sizeBytes: Int64
        let contentKey: String
        let envelope: AudioEnvelope
    }
    /// Recordings made this run, by data folder and script: every scenario and length pass on the same script opens the
    /// same movie instead of synthesizing, hashing and keying it again.
    private static var recordings: [String: Recording] = [:]

    static func recording(script: String, root: URL) async throws -> Recording {
        let cacheKey = root.standardizedFileURL.path + "\n" + script
        if let cached = recordings[cacheKey], FileManager.default.fileExists(atPath: cached.movie.path) { return cached }
        var words: [TimedWord] = []
        var time = 0.6
        for (index, text) in script.split(separator: " ").enumerated() {
            let length: Double = 0.1 + 0.045 * Double(text.count)
            words.append(TimedWord(id: "s\(index)", text: String(text), start: time, end: time + length))
            time += length + (text.hasSuffix(".") ? 0.6 : text.hasSuffix(",") ? 0.25 : 0.07)
        }
        let duration = (time + 1.0).rounded(.up)
        let rate = 24_000
        var pcm = [Float](repeating: 0, count: Int(duration) * rate)
        for index in pcm.indices {
            let seconds: Double = Double(index) / Double(rate)
            pcm[index] = Float(0.001 * sin(2 * Double.pi * 60 * seconds))
        }
        for word in words {
            let first = Int(word.start * Double(rate)), last = min(pcm.count, Int(word.end * Double(rate)))
            for index in first..<last {
                let seconds: Double = Double(index) / Double(rate)
                pcm[index] = Float(0.1 * sin(2 * Double.pi * 120 * seconds))
            }
        }
        // The source is a movie, as a recording is: Cut and Match video prepare their render offscreen from its frames.
        let movie = try await sourceMovie(pcm, rate: rate, seconds: Int(duration), root: root)
        let recording = Recording(words: words, duration: duration, rate: rate, movie: movie,
            sizeBytes: Int64((try? FileManager.default.attributesOfItem(atPath: movie.path)[.size] as? Int) ?? 0),
            contentKey: try JSONProjectStore.contentKey(for: movie),
            envelope: VoiceLabTakeProcessing.envelope(pcm, sampleRate: rate))
        recordings[cacheKey] = recording
        return recording
    }

    nonisolated static let sourceVideoSize = (width: 160, height: 90)

    /// A small synthetic recording: `seconds` of 160×90 H.264 at 30 fps (a grey frame with a bar that moves each second),
    /// interleaved with the fixture's PCM as 24 kHz LPCM. Written at run time into `root` (the smoke's temporary data
    /// folder), once per audio; nothing is read from or kept in the source tree.
    static func sourceMovie(_ pcm: [Float], rate: Int, seconds: Int, root: URL) async throws -> URL {
        let key = VoiceLabFingerprint.bytes(try VoiceTrainingAudio.wav(pcm, rate: rate)).prefix(16)
        let destination = root.appendingPathComponent("smoke-source-\(key).mov")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let (width, height) = sourceVideoSize
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 40_000, AVVideoMaxKeyFrameIntervalKey: 30, AVVideoExpectedSourceFrameRateKey: 30]])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(rate), channels: 1, interleaved: true) else {
            throw Failure.setup("no 16-bit PCM format")
        }
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format.formatDescription)
        audio.expectsMediaDataInRealTime = false
        writer.add(video); writer.add(audio)
        var frames: [CVPixelBuffer] = []
        for second in 0..<10 {
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
                  let buffer else { throw Failure.setup("no pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let row = CVPixelBufferGetBytesPerRow(buffer)
                let pixels = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<height {
                    for x in 0..<width {
                        let value: UInt8 = x / 16 == second ? 200 : 90
                        let offset = y * row + x * 4
                        pixels[offset] = value; pixels[offset + 1] = value; pixels[offset + 2] = value; pixels[offset + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            frames.append(buffer)
        }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let total = seconds * 30, samples = min(pcm.count, seconds * rate)
        var written = 0, frame = 0
        do {
            // Whichever input is behind in time and ready goes next, so the writer's interleaving never waits on the other.
            while written < samples || frame < total {
                guard writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                let audioTime: Double = Double(written) / Double(rate)
                let videoTime: Double = Double(frame) / 30
                let audioBehind = frame >= total || audioTime <= videoTime
                if written < samples, audio.isReadyForMoreMediaData, audioBehind || !video.isReadyForMoreMediaData {
                    let count = min(1_600, samples - written)
                    guard audio.append(try lpcm(pcm, from: written, count: count, rate: rate, format: format)) else {
                        throw writer.error ?? CocoaError(.fileWriteUnknown)
                    }
                    written += count
                } else if frame < total, video.isReadyForMoreMediaData {
                    guard adaptor.append(frames[(frame / 30) % frames.count], withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                        throw writer.error ?? CocoaError(.fileWriteUnknown)
                    }
                    frame += 1
                } else {
                    try await Task.sleep(for: .milliseconds(1))
                }
            }
            audio.markAsFinished(); video.markAsFinished()
            writer.endSession(atSourceTime: CMTime(value: Int64(seconds), timescale: 1))
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return destination
    }

    /// `count` samples of `pcm` from `start` as one 16-bit LPCM sample buffer.
    private static func lpcm(_ pcm: [Float], from start: Int, count: Int, rate: Int, format: AVAudioFormat) throws -> CMSampleBuffer {
        var bytes = Data(count: count * 2)
        bytes.withUnsafeMutableBytes { raw in
            for index in 0..<count {
                let value: Float = max(-1, min(1, pcm[start + index])) * 32_767
                raw.storeBytes(of: Int16(value).littleEndian, toByteOffset: index * 2, as: Int16.self)
            }
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
                  blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
                  flags: 0, blockBufferOut: &block) == noErr, let block,
              bytes.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                  dataLength: $0.count) }) == noErr else { throw Failure.setup("no audio block") }
        let timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
            presentationTimeStamp: CMTime(value: Int64(start), timescale: CMTimeScale(rate)), decodeTimeStamp: .invalid)
        return try CMSampleBuffer(dataBuffer: block, formatDescription: format.formatDescription, numSamples: count,
            sampleTimings: [timing], sampleSizes: [2])
    }

    // MARK: Harness

    enum Failure: Error, CustomStringConvertible {
        case missing(String, String)
        case setup(String)
        var description: String {
            switch self {
            case .missing(let control, let shown): "no control \(control): \(shown)"
            case .setup(let reason): reason
            }
        }
    }

    @MainActor final class Harness {
        let app: AppModel
        let directory: URL
        let scenario: String
        var editor: EditorModel?
        var session: RewriteSession?
        var connector: RewriteSmokeConnector?
        var original: Project?
        var steps: [Step] = []
        var error: String?
        var stuck: String?
        var completed = false
        /// The driver closed Rewrite from the panel's own control (Use, Apply or Done).
        var ended = false
        private var paid: Set<UUID> = []
        private var store: VoiceConsentStore?
        private var prices: VoiceLabPriceCatalog?
        /// Why the scripted voice could not be found, once.
        private var voiceProblem: String?
        private var window: NSWindow?
        private var host: NSHostingView<AnyView>?

        init(app: AppModel, directory: URL, scenario: String) { self.app = app; self.directory = directory; self.scenario = scenario }

        func open(_ fixture: Fixture) async throws {
            guard let shared = app.shared else { throw Failure.setup("shared resources missing") }
            RewriteSmokeHTTP.script.withLock { $0 = fixture.voice }
            let root = app.locations.root
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let (project, envelope) = try await DebugRewriteSmoke.project(fixture, root: root, shared: shared)
            original = project
            let editor = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
            editor.mediaResolved = true; editor.refresh()
            editor.waveform = WaveformData(fine: envelope.levels)
            self.editor = editor
            let connector = RewriteSmokeConnector(rewrites: fixture.rewrites, fits: fixture.fits)
            self.connector = connector
            let prices = try VoiceLabPriceCatalog(data: Data(contentsOf: shared.root.appendingPathComponent("catalog/voice-lab.json")))
            let last = fixture.lastWord ?? (project.transcript?.words.count ?? 1) - 1
            let session = RewriteSession(editor: editor, scope: .selection(fixture.firstWord...last), envelope: envelope,
                connector: RewriteConnector(connector: connector, model: "smoke", name: "Smoke AI", group: "local", plan: ""),
                prices: prices, consent: { true })
            editor.rewrite = session
            self.session = session
            // The consented voice ElevenLabs lists, as Make Your Voice leaves it.
            let store = VoiceConsentStore(locations: app.locations)
            let wav = try VoiceTrainingAudio.wav([Float](repeating: 0.1, count: 80_000), rate: 16_000)
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record.json"))) as? [String: Any] ?? [:]
            var statement = object["statement"] as? [String: Any] ?? [:]; statement["audioSha256"] = VoiceLabFingerprint.bytes(wav); object["statement"] = statement
            var speaker = object["speaker"] as? [String: Any] ?? [:]; speaker["threshold"] = 0.45; object["speaker"] = speaker
            let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: object))
            try await store.saveStatement(wav, recordID: record.id); try await store.save(record)
            self.store = store; self.prices = prices
            makeHost()
        }

        func close() {
            session?.close()
            editor?.close()
            window?.contentView = nil
            window = nil; host = nil
        }

        // MARK: Rendering

        private func makeHost() {
            guard let session, let editor else { return }
            let view = AnyView(DirectorPanel(task: session.task, model: editor).frame(width: 360).sceneAccent())
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(x: 0, y: 0, width: 360, height: 1_600)
            // Never ordered in: the panel lays out and its accessibility tree builds without a window on screen.
            let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 360, height: 1_600), styleMask: [.borderless],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = host
            self.window = window; self.host = host
        }

        private func layout() async {
            guard let host else { return }
            host.layoutSubtreeIfNeeded()
            await Task.yield()
            host.layoutSubtreeIfNeeded()
        }

        // MARK: Waiting

        /// Waits until the session has nothing in flight but a scripted reply the scenario holds.
        func settle(timeout: Double = 20) async {
            let start = ProcessInfo.processInfo.systemUptime
            var calm = 0
            while ProcessInfo.processInfo.systemUptime - start < timeout {
                try? await Task.sleep(for: .milliseconds(15))
                if await busy() { calm = 0 } else { calm += 1; if calm >= 5 { break } }
            }
            await ensureGeneration()
            recordFitting()
        }
        /// Each run drops the session's takes generation (`RewriteSession.invalidate`); Make Takes would find the voices
        /// again with the live client (`discoverVoices`). The scripted one stands in for it once a proposal shows.
        private func ensureGeneration() async {
            guard let session, session.isOpen, session.ownProposal != nil, !session.isProposing, let store, let prices,
                  session.generationIsCurrent(region: .default) else { return }
            if session.generation == nil {
                session.configureGeneration(client: .rewriteSmoke(prices: prices, spend: VoiceLabSpendLedger(locations: app.locations)),
                    store: store, speaker: .rewriteSmoke)
            } else if session.generation?.voices.isEmpty == false { return }
            await session.generation?.discover(language: "en")
            if let generation = session.generation, generation.voices.isEmpty || generation.selectedModelID == nil, voiceProblem == nil {
                voiceProblem = "the scripted ElevenLabs offered no voice or model: \(generation.problem)"
                error = voiceProblem
            }
            session.showProposal()
        }
        private func busy() async -> Bool {
            guard let session, session.isOpen else { return false }
            if await connector?.holding == true { return false }
            if case .running = session.task.state { return true }
            return session.isProposing || session.takesBusy || session.isReasking || session.wordingFit.running
                || session.wordingFit.measured?.preparing == true || session.takePlan?.lipsync.usingTakes == true
                || session.autoFix.work != nil
        }
        /// Tells the scripted ElevenLabs each prepared phrase's fitting length (the plan's windows are known now).
        private func recordFitting() {
            guard let plan = session?.takePlan else { return }
            var fitting: [String: Double] = [:]
            for phrase in plan.phrases {
                let window = phrase.window
                let duration: Double = window.end - window.start
                let reserve: Double = VoiceLabHardJoin.pauseSeconds(windowDuration: duration)
                let hard: Double = Double([window.leftSeam.kind, window.rightSeam.kind].filter { $0 == .hard }.count)
                let lead: Double = window.leftSeam.kind == .hard ? 0 : max(0, 0.05 - VoiceLabPatchConstants.TTS_TRIM_LEAD)
                // The stub's 50 ms quiet margins are trimmed as a take's lead and tail; a soft seam gives them back.
                let margins: Double = 0.05 * (2 - hard)
                fitting[RewriteSmokeHTTP.words(phrase.text)] = duration - hard * reserve + lead + margins
            }
            RewriteSmokeHTTP.script.withLock { $0.fitting.merge(fitting) { _, new in new } }
        }

        // MARK: Clicking

        /// Every control the task model offers now, with whether it moves the Rewrite on.
        func modelActions() -> [(PanelAction, String, Bool)] {
            guard let session, session.isOpen else { return [] }
            let task = session.task
            var actions: [(PanelAction, String, Bool)] = []
            if let stop = task.headline.stop { actions.append((stop, "stop", true)) }
            if let confirm = task.confirm {
                actions.append((confirm.confirm, "confirm", true)); actions.append((confirm.cancel, "confirm", true))
            } else {
                if let primary = task.footer.primary { actions.append((primary, "primary", true)) }
                if let link = task.footer.link { actions.append((link, "link", true)) }
            }
            for card in task.cards {
                if case .nextSteps(let steps) = card { actions += steps.chips.map { ($0.action, "chip", true) } }
            }
            if let context = task.contextAction { actions.append((context, "context", false)) }
            return actions
        }

        /// Clicks the first offered control whose id starts with one of `ids`, in that order of preference.
        @discardableResult func click(_ ids: [String], step: String? = nil) async throws -> String {
            let actions = modelActions()
            for id in ids {
                // The context row's Ask again starts the whole Rewrite over; it is never a way forward.
                if let (action, _, _) = actions.first(where: { $0.2 && $0.0.id.hasPrefix(id) }) {
                    let name = step ?? "click [\(action.title)]"
                    let paidBefore = paid
                    action.perform()
                    await settle()
                    try await observe(name, clicked: action.id, paidBefore: paidBefore)
                    return action.id
                }
            }
            let shown = steps.last.map { DebugRewriteSmoke.summary($0.snapshot) } ?? "nothing shown"
            throw Failure.missing(ids.joined(separator: " or "), shown)
        }

        /// A step the scenario takes itself (an edit, choosing a take's duration), then the observation.
        func act(_ name: String, clicked: String = "", _ perform: () async -> Void) async throws {
            let paidBefore = paid
            await perform()
            await settle()
            try await observe(name, clicked: clicked, paidBefore: paidBefore)
        }

        /// What a user does next to finish: confirm a paid step, choose a video duration, then the furthest-reaching
        /// control the panel offers. Stops when Rewrite closes or nothing can act.
        func finish(maximumSteps: Int = 12) async throws {
            for _ in 0..<maximumSteps {
                guard let session, session.isOpen else { completed = applied; ended = true; return }
                if await useAnywayIfOffered() { continue }
                if await chooseDurationIfNeeded() { continue }
                var order = ["approveTakeQuote", "discardChanges", "useTakes", "chooseTake", "takeQuote-", "prepareTakes", "makeTakes", "rewriteAgain",
                             "keepFixing", "withinSentence", "revoiceAll", "keepOriginal", "mergePhrases", "suggestion.", "tryAnother", "freshPrice",
                             "askAgain", "reviewTakes", "showTakes", "apply", "keepAll", "keepTextFixes", "tryAgain", "useTake"]
                // The resolver's [Choose yourself…] opens the chips once; [Done] ends the Rewrite as it stands.
                if !clicked.contains("chooseYourself") { order.append("chooseYourself") }
                order.append("closeRewrite")
                do { clicked.insert(try await click(order)) } catch {
                    if await rowActionIfOffered() { continue }
                    completed = applied; if !completed { throw error }; return
                }
            }
            completed = applied
        }

        /// The project took the Rewrite: Rewrite closed and the project's words or voice changed.
        var applied: Bool {
            guard let editor, let original else { return false }
            return session?.isOpen != true && (editor.project.voiceLab.segments.count > original.voiceLab.segments.count
                || editor.project.edits != original.edits || editor.project.transcript != original.transcript)
        }

        /// The video mode of each voice segment the Rewrite added.
        var appliedVideoModes: [VoiceLabVideoMode] {
            guard let editor, let original else { return [] }
            let before = Set(original.voiceLab.segments.map(\.id))
            return editor.project.voiceLab.segments.filter { !before.contains($0.id) }.compactMap { segment in
                segment.candidates.indices.contains(segment.selectedCandidateIndex) ? segment.candidates[segment.selectedCandidateIndex].recipe?.video.mode : nil
            }
        }

        /// The evidence controls the panel drew last.
        private var drawn: [Control] { steps.last?.snapshot.controls.filter { $0.source == "evidence" && $0.enabled } ?? [] }
        /// A passing take with a join advisory waits for its row's [Use anyway] (DirectorTakeRows), which the user clicks.
        private func useAnywayIfOffered() async -> Bool {
            guard let session, let plan = session.takePlan, !session.takesBusy else { return false }
            // The first offered take whose phrase has no usable take yet.
            let offers = drawn.filter { $0.id.hasPrefix("useAnyway.") }.compactMap { control -> ([Int], ClipTakePlan.Take)? in
                let parts = control.id.split(separator: ".").compactMap { Int($0) }
                guard parts.count == 2, plan.phrases.indices.contains(parts[0]),
                      plan.phrases[parts[0]].selected.map({ !$0.row.selectable || $0.row.requiresJoinAdvisoryAcceptance }) ?? true,
                      let take = plan.phrases[parts[0]].takes.first(where: { $0.number == parts[1] }) else { return nil }
                return (parts, take)
            }
            guard let (parts, take) = offers.first else { return false }
            try? await act("click [Use anyway] for phrase \(parts[0] + 1) take \(parts[1])", clicked: "useAnyway") {
                session.focusedTakePhrase = parts[0]
                session.mutateLipsync(phrase: parts[0]) { _ = plan.useAnyway(take: take.id, phrase: parts[0]) }
            }
            return true
        }
        /// A row's own control when no footer or chip offers a way on, as a user reaches for it: a phrase row's priced
        /// [Try another · $] or [Try another…] (DirectorTakeRows), then a row's [Keep original words] (PhraseTimingRecovery).
        private func rowActionIfOffered() async -> Bool {
            guard let session, !session.takesBusy, rowActions < 4 else { return false }
            rowActions += 1
            if let plan = session.takePlan {
                for phrase in plan.phrases {
                    if let action = session.pricedTakeAction(phrase: phrase.id), drawn.contains(where: { $0.id == action.id }) {
                        try? await act("click [\(action.title)] on phrase \(phrase.id + 1)", clicked: action.id) { action.perform() }
                        if session.task.confirm != nil { try? await click(["approveTakeQuote"]) }
                        return true
                    }
                }
                if let control = drawn.first(where: { $0.id.hasPrefix("priceAnother.") }), let phrase = Int(control.id.dropFirst(13)) {
                    try? await act("click [\(control.title)] on phrase \(phrase + 1)", clicked: "priceAnother") { session.priceAnotherTake(phrase: phrase) }
                    return true
                }
                if drawn.contains(where: { $0.id == "timing.original" }),
                   let phrase = plan.phrases.first(where: { session.takeNeedsWordingRecovery($0, plan: plan) }) {
                    let ordinals = session.takePhraseOrdinals(phrase)
                    try? await act("click [Keep original words] on phrase \(phrase.id + 1)", clicked: "timing.original") {
                        session.phraseTimingAction(.original, ordinals: ordinals)
                    }
                    return true
                }
            }
            if drawn.contains(where: { $0.id == "timing.original" }), let ordinal = session.blockedVoiceOrdinals.first {
                try? await act("click [Keep original words] on change \(ordinal)", clicked: "timing.original") {
                    session.task.phraseTimingAction?(ordinal, .original)
                }
                return true
            }
            return false
        }
        private var rowActions = 0
        private var clicked: Set<String> = []

        /// Chooses a duration for a phrase whose selected take passed but has none, as its radio would.
        private func chooseDurationIfNeeded() async -> Bool {
            guard let session, let plan = session.takePlan, !session.takesBusy else { return false }
            for phrase in plan.phrases where phrase.selected?.row.selectable == true && phrase.videoChoice == nil {
                let availability = plan.videoAvailability(phrase: phrase.id)
                guard let choice = [VoiceLabVideoMode.source, .cut, .retimed].first(where: availability.allows) else { continue }
                let title = choice == .source ? "Keep source video duration" : choice == .cut ? "Cut the video to this take" : "Match video to this take's duration"
                try? await act("choose '\(title)' for phrase \(phrase.id + 1)", clicked: "duration") {
                    // What the radio's action does (VideoDurationChoiceView in DirectorTakeRows).
                    session.mutateLipsync(phrase: phrase.id) {
                        guard plan.chooseVideo(choice, phrase: phrase.id) else { return }
                        Task { await plan.prepareVideoChoices(); await plan.lipsync.refresh() }
                    }
                }
                return true
            }
            return false
        }

        // MARK: Observing

        func observe(_ action: String, clicked: String = "", paidBefore: Set<UUID>? = nil, tag: (phrase: Int, tag: String)? = nil) async throws {
            await layout()
            var snapshot = Snapshot()
            let session = self.session
            if let session, session.isOpen {
                let task = session.task
                snapshot.state = switch task.state {
                case .choosingAI: "choosingAI"
                case .running: "running"
                case .proposal: "proposal"
                case .error: "error"
                case .changed: "changed"
                }
                snapshot.headline = task.headline.text
                snapshot.sub = task.headline.sub
                snapshot.cards = task.cards.map(\.id)
                var texts: [String] = [task.headline.text] + [task.headline.sub].compactMap { $0 }
                var asks = 0
                for card in task.cards {
                    switch card {
                    case .text(let text), .secondaryText(let text), .callout(let text): texts.append(text)
                    case .nextSteps(let steps):
                        if let line = steps.line { texts.append(line) }
                        if steps.ask != nil { asks += 1 }
                    case .ask: asks += 1
                    case .keyField: asks += 1
                    default: break
                    }
                }
                if let confirm = task.confirm { texts.append(confirm.question) }
                // Lines the takes card draws as plain text (DirectorTakeRows, RewriteSpeechContextReviewView).
                if task.cards.contains(.takes) {
                    texts += [session.generation?.problem, session.takePlan?.problem, session.speechContextProblem].compactMap { $0 }
                    if session.speechContextReview != nil { texts.append("Surrounding sentence review is open") }
                }
                snapshot.footer = task.footer.note
                if let note = task.footer.note { texts.append(note) }
                snapshot.controls = modelActions().map { action, role, acts in
                    Control(id: action.id, title: action.title, enabled: true, source: "model", role: role, acts: acts)
                }
                snapshot.timings = (session.ownProposal?.changes ?? []).filter { $0.kind == .voice }.map { change in
                    guard let timing = session.voiceReview(change.ordinal)?.timing else { return "\(change.ordinal): no timing" }
                    return "\(change.ordinal): estimate \(toFixed1(timing.estimateSeconds)) s, slot \(toFixed1(timing.slotSeconds)) s"
                        + " (\(toFixed1(timing.minimumSeconds ?? 0))–\(toFixed1(timing.maximumSeconds ?? 0))), \(timing.fits ? "fits" : "blocked")"
                }
                snapshot.takes = (session.takePlan?.phrases ?? []).flatMap { phrase in
                    phrase.takes.map { take in
                        let length = take.length.map { String(format: "%.2f s", $0) } ?? "no length"
                        let flags = "\(take.id == phrase.selectedID ? "selected" : "not selected"), words \(take.row.qa?.values.transcriptMatch.map { String(format: "%.2f", $0) } ?? "unchecked"), score \(take.row.qa?.values.speakerScore.map { String(format: "%.2f", $0) } ?? "none")"
                            + (take.row.hasJoinAdvisory ? ", join advisory: " + (TakeFailurePresentation.joinAdvisory(take.row, number: take.number) ?? "") + " jump \(take.row.qa?.values.lufsJumpLu ?? -1) seams \(take.row.qa?.joinSeams.map { "\($0.side) \($0.excessLu)" } ?? [])" : "")
                        let state = flags + ", " + (take.row.selectable ? (take.fits ? "passed, fits" : "passed, changes the duration")
                            : TakeFailurePresentation.reason(for: take.row) ?? "left out")
                        return "phrase \(phrase.id + 1) take \(take.number): \(length) of \(String(format: "%.2f s", phrase.originalLength)), \(state)"
                    } + [{
                        let availability = session.takePlan?.videoAvailability(phrase: phrase.id)
                        return "phrase \(phrase.id + 1) duration: \(phrase.videoChoice?.rawValue ?? "none chosen"); keep source: "
                            + (availability?.unchangedReason ?? "allowed") + "; match: " + (availability?.changedReason ?? "allowed")
                    }()]
                }
                snapshot.resolverRunning = task.headline.stop != nil
                    && (session.wordingFit.running || session.isReasking || session.wordingFit.measured?.preparing == true)
                    || session.autoFix.work != nil
                if let plan = session.takePlan {
                    snapshot.quotes = plan.phrases.map { phrase in
                        let words = EditingPrimitives.splitWords(phrase.text)
                        var quoted: [String] = []
                        for boundary in 0...words.count {
                            quoted += phrase.audioTags.filter { $0.beforeToken == boundary }.map { "[\($0.tag)]" }
                            if boundary < words.count { quoted.append(words[boundary]) }
                        }
                        return "Phrase \(phrase.id + 1): “" + quoted.joined(separator: " ") + "”"
                    }
                }
                // The view as drawn: layout evidence, editable fields and the accessibility tree.
                if let host {
                    for (name, text) in DebugRightColumn.texts(in: host).sorted(by: { $0.key < $1.key }) {
                        let disabled = text.hasPrefix(DirectorPanel.disabledPrefix)
                        let title = disabled ? String(text.dropFirst(DirectorPanel.disabledPrefix.count)) : text
                        if name.hasPrefix("director.button.") {
                            let id = String(name.dropFirst(16))
                            // The context row's Ask again and Close end or restart the Rewrite rather than move it on.
                            let passive = id == "close" || id == task.close.id || id == task.contextAction?.id || !Self.acts(id)
                            snapshot.controls.append(Control(id: id, title: title, enabled: !disabled,
                                source: "evidence", role: "button", acts: !passive))
                        } else if name.hasPrefix("voice.quote.") {
                            snapshot.drawnQuotes.append(text)
                        } else if name.hasPrefix("voice.phrase.") || name.hasSuffix(".line") {
                            texts.append(text)
                        }
                    }
                    // SwiftUI builds no accessibility tree without an assistive client, so the layout evidence stands in for it;
                    // a TextField is an editable NSTextField in the view tree.
                    let fields = Self.editableFields(in: host)
                    snapshot.textFields = max(asks, fields)
                } else { snapshot.textFields = asks }
                var seen: Set<String> = []
                snapshot.texts = texts.filter { !$0.isEmpty && seen.insert($0).inserted }
            }
            let current = paidTakes()
            snapshot.paidTakes = current.count
            var capture: String?
            let checks = invariants(snapshot, clicked: clicked, paidBefore: paidBefore ?? paid, current: current, tag: tag).map { check in
                var check = check
                check.knownFailing = !check.passed && DebugRewriteSmoke.knownFailing[check.invariant] != nil
                return check
            }
            if checks.contains(where: { !$0.passed }) { capture = savePNG(step: steps.count + 1) }
            paid = current
            steps.append(Step(index: steps.count + 1, action: action, snapshot: snapshot, checks: checks, capture: capture))
        }

        /// Row buttons that only listen, navigate or show more do not move the Rewrite on.
        /// Evidence controls that only choose a voice or open the expression chooser do not move the Rewrite on.
        static func acts(_ id: String) -> Bool {
            !["expression.", "voicePicker"].contains { id.hasPrefix($0) }
        }
        static func editableFields(in view: NSView) -> Int {
            guard !view.isHidden else { return 0 }
            let own = (view as? NSTextField).map { $0.isEditable ? 1 : 0 } ?? 0
            return own + view.subviews.reduce(0) { $0 + editableFields(in: $1) }
        }

        private func paidTakes() -> Set<UUID> {
            guard let plan = session?.takePlan, session?.isOpen == true else { return [] }
            return Set(plan.phrases.flatMap(\.takes).filter { $0.row.receipt != nil || !$0.row.acceptedRequestIDs.isEmpty }.map(\.id))
        }

        // MARK: Invariants

        private func invariants(_ snapshot: Snapshot, clicked: String, paidBefore: Set<UUID>, current: Set<UUID>,
                                tag: (phrase: Int, tag: String)?) -> [Check] {
            var checks: [Check] = []
            let open = snapshot.state != "closed"
            if open {
                let acting = snapshot.controls.filter { $0.acts && $0.enabled }
                checks.append(Check(invariant: "I1", passed: !acting.isEmpty || snapshot.resolverRunning,
                    detail: acting.isEmpty ? (snapshot.resolverRunning ? "resolver running" : DebugRewriteSmoke.summary(snapshot))
                        : "acts: " + acting.map(\.title).prefix(4).joined(separator: ", ")))
                let disabled = snapshot.controls.filter { !$0.enabled && DebugRewriteSmoke.allowedDisabled[$0.title] == nil }
                checks.append(Check(invariant: "I2", passed: disabled.isEmpty,
                    detail: disabled.isEmpty ? "no disabled control" : "disabled: " + disabled.map { "'\($0.title)'" }.joined(separator: ", ")
                        + (snapshot.texts.first(where: { $0.contains("first.") || $0.contains("Choose a take") }).map { " beside '\($0)'" } ?? "")))
                checks.append(Check(invariant: "I3", passed: snapshot.textFields <= 1,
                    detail: "\(snapshot.textFields) free-text field\(snapshot.textFields == 1 ? "" : "s")"))
                checks.append(footerCheck(snapshot))
            }
            let lost = paidBefore.subtracting(current)
            let confirmed = clicked == "discardChanges" || (!open && completedByUse)
            checks.append(Check(invariant: "I6", passed: lost.isEmpty || confirmed,
                detail: lost.isEmpty ? "\(current.count) paid takes kept" : "\(lost.count) paid take\(lost.count == 1 ? "" : "s") dropped"
                    + (confirmed ? " after an explicit confirm" : " without a confirm step")))
            if let tag {
                let shown = snapshot.quotes.indices.contains(tag.phrase) && snapshot.quotes[tag.phrase].contains("[\(tag.tag)]")
                let drawn = snapshot.drawnQuotes.contains { $0.hasPrefix("Phrase \(tag.phrase + 1):") && $0.contains("[\(tag.tag)]") }
                checks.append(Check(invariant: "I7", passed: shown && drawn,
                    detail: shown ? (drawn ? "[\(tag.tag)] in phrase \(tag.phrase + 1)'s quote" : "[\(tag.tag)] in the plan but not drawn in the quote")
                        : "phrase \(tag.phrase + 1)'s quote reads " + (snapshot.quotes.indices.contains(tag.phrase) ? snapshot.quotes[tag.phrase] : "nothing")))
            }
            return checks
        }
        private var completedByUse: Bool { applied }

        /// I4: the footer never prices or says phrases fit while the plan refused, and names nothing the panel doesn't.
        private func footerCheck(_ snapshot: Snapshot) -> Check {
            guard let session else { return Check(invariant: "I4", passed: true, detail: "closed") }
            let note = snapshot.footer ?? ""
            let refused = session.takePlanFailure != nil
            let priced = snapshot.controls.contains { $0.source == "model" && $0.role == "primary" && $0.title.contains("$") }
            let fits = note.range(of: #"\d+ phrases? fits?"#, options: .regularExpression) != nil
            if refused, priced || fits {
                return Check(invariant: "I4", passed: false, detail: "footer '\(note)'\(priced ? " with a price" : "") while the plan refused: "
                    + ClipTakePlan.copy(session.takePlanFailure!))
            }
            if fits, !session.blockedVoiceOrdinals.isEmpty || snapshot.texts.contains(where: { $0.contains("Too close") || $0.contains("too close") }) {
                return Check(invariant: "I4", passed: false, detail: "footer '\(note)' while a phrase is still blocked")
            }
            if let match = note.firstMatch(of: #/(\d+) phrases? fits?/#), let fitting = Int(match.1) {
                if fitting == 0 { return Check(invariant: "I4", passed: false, detail: "footer '\(note)' reports that nothing fits as a status") }
                if let shown = snapshot.headline.firstMatch(of: #/^(\d+) phrases? in your voice/#), let voiced = Int(shown.1), voiced != fitting {
                    return Check(invariant: "I4", passed: false, detail: "footer '\(note)' beside the headline '\(snapshot.headline)'")
                }
                if snapshot.cards.contains(where: { $0.hasPrefix("callout:") }) {
                    return Check(invariant: "I4", passed: false, detail: "footer '\(note)' beside the callout '\(snapshot.cards.first { $0.hasPrefix("callout:") }!.dropFirst(8))'")
                }
            }
            if let match = note.firstMatch(of: #/Phrase (\d+)/#) {
                let named = "hrase \(match.1)"
                let elsewhere = snapshot.texts.contains { $0 != note && $0.contains(named) } || snapshot.quotes.contains { $0.contains("Phrase \(match.1)") }
                if !elsewhere { return Check(invariant: "I4", passed: false, detail: "footer '\(note)' names a phrase the panel doesn't show") }
            }
            return Check(invariant: "I4", passed: true, detail: note.isEmpty ? "no footer note" : "footer '\(note)'")
        }

        private func savePNG(step: Int) -> String? {
            guard let host, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
            let name = "rewrite-smoke-\(scenario)-step\(step).png"
            do { try png.write(to: directory.appendingPathComponent(name)); return name } catch { return nil }
        }

        // MARK: Scenario steps

        /// Runs the Rewrite as opening it does, and records the proposal it shows.
        func start() async throws {
            guard let session else { return }
            session.actionTask = Task { _ = await session.run() }
            await settle()
            try await observe("open Rewrite and wait for the reply")
        }
    }

    // MARK: Scenarios

    struct Definition {
        let id: String
        let title: String
        var requiresCompletion = true
        /// I5 also passes when the Rewrite ends with Done and nothing changed (S9: Stop, then keep the words).
        var mayEndUnchanged = false
        /// I8: the applied take keeps, cuts or matches the video as this scenario's take length requires.
        var video: VoiceLabVideoMode? = nil
        /// I9: the Rewrite applied this many voice segments: no voice change was dropped on the way.
        var voiced: Int? = nil
        let fixture: Fixture
        let drive: @MainActor (Harness) async throws -> Void
    }

    static func replace(_ pairs: [(String, String)]) -> String {
        var text = baseScript
        for (old, new) in pairs { text = text.replacingOccurrences(of: old, with: new) }
        return text
    }

    /// Two voice changes a sentence apart, each about as long as the words it replaces.
    nonisolated static let twoChanges = [("record a short clip in one take", "film quick footage at once"),
                                         ("captions follow the words as they change", "subtitles track every line while it shifts")]

    /// A rewrite of most of the take: over the voice budget (voice-lab.md §8.2).
    nonisolated static let overBudget = "Today I want to walk you through how cloud tools change video. First we film a quick clip "
        + "in a single take. Then we correct each word we said wrong. We hold the breaks that feel right and cut the ones that drag. "
        + "The captions follow the words as they change, so nobody has to retype them. Every change is checked before anything is sent "
        + "to a voice service. Finally we export the clip and share it with our friends. That is the whole idea, and it only takes "
        + "a few minutes from start to finish."
    /// Every word but the last (words 0–92), S8's scope: its last word can be cut outside the Rewrite.
    static func allButLast(_ text: String) -> String { text.split(separator: " ").dropLast().joined(separator: " ") }

    static var scenarios: [Definition] { [
        Definition(id: "S1", title: "happy path: 2 changes, takes pass, Use",
            fixture: Fixture(rewrites: [.passage(replace(twoChanges))], voice: RewriteSmokeVoiceScript(offset: -0.2))) { harness in
            try await harness.start()
            try await harness.finish()
        },
        Definition(id: "S2", title: "two changes close together",
            fixture: Fixture(rewrites: [.passage(replace([("keep the pauses", "preserve all breaks"), ("remove the ones", "cut every one")]))],
                voice: RewriteSmokeVoiceScript(offset: 0.1))) { harness in
            try await harness.start()
            try await harness.click(["prepareTakes", "makeTakes"])
            // Placement merges nearby changes when it can; the user's refusal is a pair it could not merge. When this fixture's
            // pair merged, the plan refuses phrase 2 as the user saw it, as the layout audit's `rewrite-collision` variant does.
            if let session = harness.session, session.takePlanFailure == nil, session.changes.count >= 2 {
                try await harness.act("the takes plan refuses phrase 2 as too close to phrase 1 (scripted refusal)") {
                    session.takePlan?.invalidate(); session.takePlan = nil
                    session.takePlanOrdinals = session.changes.indices.map { $0 + 1 }
                    session.takePlanFailure = ClipTakePlan.Failure.placement(.collidesWithChange(0), index: session.changes.count - 1)
                    session.showProposal()
                }
            }
            try await harness.finish()
        },
        Definition(id: "S3", title: "the first takes too long for the slot, a shorter wording fits",
            fixture: Fixture(rewrites: [.passage(replace([twoChanges[0]]))], fits: [.fewerWords, .fewerWords, .fewerWords],
                voice: RewriteSmokeVoiceScript(lengthFactors: [1.6, 1.6]))) { harness in
            try await harness.start()
            try await harness.finish()
        },
        Definition(id: "S4", title: "word check hears a brand homophone ('Claude Code' as 'cloud code')",
            fixture: Fixture(rewrites: [.passage(replace([("cloud tools edit video", "Claude Code edits your whole video")]))],
                voice: RewriteSmokeVoiceScript(heard: ["claude code": "cloud code"]))) { harness in
            try await harness.start()
            try await harness.finish()
        },
        Definition(id: "S5", title: "surrounding sentence refused: a fragment at the clip start",
            fixture: Fixture(firstWord: 23, rewrites: [.passage(replace([("words we got wrong.", "bits."), twoChanges[1]])
                .split(separator: " ").dropFirst(23).joined(separator: " "))], fits: [.sameWords, .sameWords, .sameWords],
                voice: RewriteSmokeVoiceScript(offset: -0.1))) { harness in
            try await harness.start()
            if let session = harness.session, let ordinal = session.blockedVoiceOrdinals.first {
                try await harness.act("click [Use surrounding sentence] on change \(ordinal)", clicked: "surrounding") {
                    session.task.phraseTimingAction?(ordinal, .surrounding)
                }
                // The sentence starts before the clip's first word, so the review must refuse it. When this fixture's
                // placement neither reviewed nor refused it, the session shows the refusal as `reviewTimingSpeechContext` does.
                if session.speechContextProblem.isEmpty, session.speechContextReview == nil {
                    try await harness.act("the surrounding sentence is refused: it starts before the clip (scripted refusal)") {
                        session.speechContextOffer = nil; session.speechContextReview = nil; session.surroundingSentenceOrdinal = nil
                        session.speechContextProblem = RewriteSpeechContextReview.copy(RewriteSpeechContextReview.Failure.unsupported)
                        session.speechContextRefusedOrdinals = [ordinal]
                        session.showProposal()
                    }
                }
            }
            try await harness.finish()
        },
        Definition(id: "S6", title: "over the voice budget",
            fixture: Fixture(rewrites: [.passage(replace(twoChanges + [("sent to a voice service", "passed to any speech provider"),
                ("it only takes a few minutes", "it barely needs any real time")]))], voice: RewriteSmokeVoiceScript(offset: 0.15))) { harness in
            try await harness.start()
            try await harness.finish()
        },
        Definition(id: "S7", title: "add an expression while another phrase has paid takes, then remove it",
            fixture: Fixture(rewrites: [.passage(replace(twoChanges))], voice: RewriteSmokeVoiceScript(offset: -0.15))) { harness in
            try await harness.start()
            try await harness.click(["prepareTakes", "makeTakes"])
            try await harness.click(["takeQuote-"])
            if harness.session?.task.confirm != nil { try await harness.click(["approveTakeQuote"]) }
            guard let session = harness.session, let plan = session.takePlan, plan.phrases.count >= 2 else {
                throw Failure.setup("S7 needs two phrases with takes")
            }
            let phrase = plan.phrases[1]
            try await harness.act("click [+ Expression] on phrase 2, then [laughs]") {
                // The tag chooser's [laughs] calls the phrase card's `changed` with the tag added (AudioTagPhrase).
                let boundary = EditingPrimitives.splitWords(phrase.text).count
                session.updateAudioTags(phrase.audioTags + [VoiceLabAudioTag(beforeToken: boundary, tag: "laughs")], phrase: phrase)
            }
            try await harness.observe("read phrase 2's quote after adding [laughs]", tag: (1, "laughs"))
            if harness.session?.task.confirm != nil {
                try await harness.click(["discardChanges"], step: "answer the inline confirm with [Discard Changes]")
                try await harness.observe("read phrase 2's quote after the confirm", tag: (1, "laughs"))
            }
            try await harness.act("click [laughs ×] on phrase 2 to remove it") {
                guard let plan = session.takePlan, plan.phrases.count > 1 else { return }
                let current = plan.phrases[1]
                session.updateAudioTags(current.audioTags.filter { $0.tag != "laughs" }, phrase: current)
            }
            try await harness.finish()
        },
        Definition(id: "S8", title: "a Rewrite failure, then a reply made stale by an edit",
            fixture: Fixture(rewrites: [.failure, .held(.passage(replace([twoChanges[0]]))),
                .passage(replace([twoChanges[0]]).split(separator: " ").dropFirst().joined(separator: " "))],
                voice: RewriteSmokeVoiceScript(offset: 0.1))) { harness in
            try await harness.start()
            try await harness.click(["tryAgain"])
            guard let editor = harness.editor, let first = editor.project.transcript?.words.first else { throw Failure.setup("S8 has no words") }
            try await harness.act("cut the first word, inside the Rewrite, while the AI answers") {
                editor.apply(.cutSelection(ids: [first.id]), name: "Cut selection")
                await harness.connector?.release()
            }
            try await harness.finish()
        },
        Definition(id: "S9", title: "Stop in the middle of an automatic fix, then finish from the panel Stop leaves", mayEndUnchanged: true,
            fixture: Fixture(rewrites: [.passage(replace([("record a short clip in one take",
                "film an extraordinarily wonderful, unbelievably spectacular, astonishingly memorable documentary throughout one marathon session")]))],
                fits: [.held(.sameWords)])) { harness in
            try await harness.start()
            try await harness.click(["stopWordingFit", "stopReask", "stop"])
            await harness.connector?.release()
            await harness.settle()
            try await harness.observe("after Stop, the held reply arrives")
            try await harness.finish()
        },
        Definition(id: "S10", title: "a take shorter than its slot: the video is cut to it", video: .cut,
            fixture: Fixture(rewrites: [.passage(replace([twoChanges[1]]))], voice: RewriteSmokeVoiceScript(offset: -0.9))) { harness in
            try await harness.start()
            try await harness.finish()
        },
        // Match video is recorded as the zoom-cover recipe (VoiceLabRecipeBuilder).
        Definition(id: "S11", title: "a take longer than its slot: only matching the video fits it", video: .zoomCover,
            fixture: Fixture(rewrites: [.passage(replace([twoChanges[1]]))], voice: RewriteSmokeVoiceScript(offset: 0.7))) { harness in
            try await harness.start()
            try await harness.finish()
        },
        Definition(id: "S12", title: "Get Price while one change is held back by its estimate", voiced: 2,
            fixture: Fixture(rewrites: [.passage(replace([twoChanges[0], ("captions follow the words as they change",
                "subtitles carefully and patiently track every single spoken line, every little word and every tiny pause while all of them shift around")]))],
                fits: [.sameWords, .sameWords, .sameWords, .halfWords, .halfWords, .halfWords])) { harness in
            try await harness.start()
            try await harness.finish()
        },
        Definition(id: "S13", title: "happy path with takes that fill their slots exactly",
            fixture: Fixture(rewrites: [.passage(replace(twoChanges))], voice: RewriteSmokeVoiceScript(exactFit: true))) { harness in
            try await harness.start()
            try await harness.finish()
        },
    ] }
}
#endif
