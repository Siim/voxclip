import Foundation
import AVFoundation
import Speech
import VoxClipCore

/// Native engine adapter; transcription §10, architecture §7.1. No native context crosses an actor.
public actor AppleSpeechTranscriber: Transcriber, SpeechCacheIdentityProviding {
    public nonisolated let engine: TranscriptEngine = .appleSpeech
    private let locations: DataLocations
    private var active = false
    public init() { locations = DataLocations() }
    public init(locations: DataLocations) { self.locations = locations }
    public nonisolated func capabilities(model: String?) -> TranscriberCapabilities { TranscriberCapabilities(timing: .runGrouped, verbatim: false, autoLanguage: false, onDevice: true) }
    public func supports(_ language: LanguageChoice, model: String?) async -> Bool {
        await locale(for: language) != nil
    }
    public func readiness(for plan: TranscriptionPlan) async -> Readiness {
        guard let locale = await locale(for: plan.language) else { return .unsupportedLanguage("Choose a supported Apple Speech locale") }
        let transcriber = module(locale)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: return .ready
        case .supported, .downloading: return .needsSystemAssets(locale: locale.identifier(.bcp47))
        case .unsupported: return .unsupportedLanguage(locale.identifier(.bcp47))
        @unknown default: return .unavailable(reason: "Apple speech assets are unavailable")
        }
    }
    public func prepare(for plan: TranscriptionPlan, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard plan.engine == engine else { throw VoxClipError.transcriptionLanguageUnsupported("Apple Speech") }
        let reporter = SpeechProgressLimiter(callback: progress)
        defer { reporter.cancel() }
        guard let locale = await locale(for: plan.language) else { throw VoxClipError.transcriptionLanguageUnsupported("Apple Speech") }
        try await AppleSpeechAssets.prepare(locale: locale.identifier(.bcp47), operation: {
            try await self.prepareAssets(locale, reporter: reporter)
        }, reserve: { try await self.reserve(locale) }, release: { try await self.releaseOldest(excluding: locale) })
        await reporter.finish()
    }
    private func prepareAssets(_ locale: Locale, reporter: SpeechProgressLimiter<Double>) async throws {
        let transcriber = module(locale)
        try Task.checkCancellation()
        let status = await AssetInventory.status(forModules: [transcriber])
        if status == .unsupported { throw VoxClipError.transcriptionLanguageUnsupported(locale.identifier(.bcp47)) }
        if status == .installed { return }
        try await reserve(locale)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let fraction = installation.progress
            let monitor = Task {
                while !Task.isCancelled { reporter.report(fraction.fractionCompleted); try await Task.sleep(for: .milliseconds(100)) }
            }
            defer { monitor.cancel() }
            try await installation.downloadAndInstall()
            reporter.report(1)
        }
    }
    public func cacheIdentity(for plan: TranscriptionPlan) async throws -> EngineRef {
        guard let locale = await locale(for: plan.language) else { throw VoxClipError.transcriptionLanguageUnsupported("Apple Speech") }
        return EngineRef(id: .appleSpeech, engineVersion: "macOS \(SpeechRuntimeVersion.macOS) Speech", locale: locale.identifier(.bcp47))
    }
    public func transcribe(_ request: TranscriptionRequest, progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> RawTranscript {
        try Task.checkCancellation()
        guard !active else { throw VoxClipError.transcriptionFailed("This Apple Speech engine is already transcribing") }
        active = true
        defer { active = false }
        guard request.plan.engine == engine, let locale = await locale(for: request.plan.language) else { throw VoxClipError.transcriptionLanguageUnsupported("Apple Speech") }
        guard request.audio.durationSeconds.isFinite, request.audio.durationSeconds > 0 else { throw VoxClipError.noSpeech }
        await AppleSpeechLocaleUsage.shared.begin(locale.identifier(.bcp47))
        defer {
            Task { await AppleSpeechLocaleUsage.shared.end(locale.identifier(.bcp47)) }
        }
        let reporter = SpeechProgressLimiter(callback: progress)
        defer { reporter.cancel() }
        try await prepare(for: request.plan) { reporter.report(TranscriptionProgress(stage: .preparing, fraction: $0)) }
        for attempt in 0..<2 {
            do {
                let raw = try await analyze(request, locale: locale) { reporter.report($0) }
                try touch(locale)
                await reporter.finish()
                return raw
            } catch {
                if Task.isCancelled || error is CancellationError { throw VoxClipError.cancelled }
                let native = error as NSError
                if attempt == 0, native.localizedDescription.lowercased().contains("authoriz"),
                   Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil {
                    let authorized = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) } }
                    if authorized { continue }
                }
                if let error = error as? VoxClipError { throw error }
                throw VoxClipError.transcriptionFailed("Apple Speech (\(native.domain):\(native.code))")
            }
        }
        throw VoxClipError.transcriptionFailed("Apple Speech authorization")
    }
    private func locale(for language: LanguageChoice) async -> Locale? {
        guard Speech.SpeechTranscriber.isAvailable else { return nil }
        return await AppleSpeechLocaleResolver.locale(for: language, preferredLanguages: Locale.preferredLanguages) {
            await Speech.SpeechTranscriber.supportedLocale(equivalentTo: $0)
        }
    }
    private func module(_ locale: Locale) -> Speech.SpeechTranscriber {
        Speech.SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }
    private struct LedgerEntry: Codable { var locale: String; var lastUsed: Date }
    private var ledgerURL: URL { locations.root.appendingPathComponent("apple-speech-locales.json") }
    private func ledger() -> [LedgerEntry] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([LedgerEntry].self, from: Data(contentsOf: ledgerURL))) ?? []
    }
    private func touch(_ locale: Locale) throws {
        var entries = ledger().filter { $0.locale != locale.identifier(.bcp47) }
        entries.append(LedgerEntry(locale: locale.identifier(.bcp47), lastUsed: Date()))
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: ledgerURL, options: .atomic)
    }
    private func reserve(_ locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        guard !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else { return }
        if reserved.count >= AssetInventory.maximumReservedLocales { try await releaseOldest(excluding: locale) }
        guard try await AssetInventory.reserve(locale: locale) else { throw VoxClipError.speechAssetsUnavailable("Unable to reserve \(locale.identifier(.bcp47))") }
        try touch(locale)
    }
    private func releaseOldest(excluding locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        let running = await AppleSpeechLocaleUsage.shared.running()
        guard let oldest = ledger().sorted(by: { $0.lastUsed < $1.lastUsed }).first(where: { entry in entry.locale != locale.identifier(.bcp47) && !running.contains(entry.locale) && reserved.contains(where: { $0.identifier(.bcp47) == entry.locale }) }) else { throw VoxClipError.speechAssetsUnavailable("All reserved speech locales are in use") }
        try await AppleSpeechAssets.release(oldest.locale, reserved: reserved) { await AssetInventory.release(reservedLocale: $0) }
    }
    private func analyze(_ request: TranscriptionRequest, locale: Locale, progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> RawTranscript {
        let transcriber = module(locale)
        let natural = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: natural) else { throw VoxClipError.transcriptionFailed("No compatible Apple audio format") }
        let caf = request.audio.wav16k.deletingLastPathComponent().appendingPathComponent("apple-\(Int(format.sampleRate))-\(format.channelCount).caf")
        try convert(request.audio.wav16k, to: caf, format: format)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        return try await withTaskCancellationHandler {
            let file = try AVAudioFile(forReading: caf)
            try await analyzer.prepareToAnalyze(in: file.processingFormat)
            let collector = Task { () throws -> [RawToken] in
                var tokens: [RawToken] = [], group = 0
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    let runs = result.text.runs.map { run in AppleSpeechRun(text: String(result.text[run.range].characters), start: run.audioTimeRange?.start.seconds, end: run.audioTimeRange?.end.seconds, confidence: run.transcriptionConfidence) }
                    tokens += AppleSpeechRunMapper.tokens(runs, language: locale.identifier(.bcp47), group: group)
                    group += 1
                    progress(TranscriptionProgress(stage: .transcribing, fraction: min(1, max(0, result.range.end.seconds / request.audio.durationSeconds))))
                }
                return tokens
            }
            do {
                if let last = try await analyzer.analyzeSequence(from: file) { try await analyzer.finalizeAndFinish(through: last) }
                else { await analyzer.cancelAndFinishNow() }
                let tokens = try await collector.value
                try Task.checkCancellation()
                guard !tokens.isEmpty else { throw VoxClipError.noSpeech }
                return RawTranscript(engine: try await cacheIdentity(for: request.plan), grouping: GroupingRule(end: .lastToken, conf: .min, bracketEvents: false), tokens: tokens, language: locale.identifier(.bcp47), verbatim: false, timing: .runGrouped)
            } catch { collector.cancel(); await analyzer.cancelAndFinishNow(); throw error }
        } onCancel: { Task { await analyzer.cancelAndFinishNow() } }
    }
    func convert(_ source: URL, to destination: URL, format: AVAudioFormat) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("apple-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try autoreleasepool { try writeConvertedAudio(source, to: temporary, format: format) }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }
    private func writeConvertedAudio(_ source: URL, to destination: URL, format: AVAudioFormat) throws {
        let file = try AVAudioFile(forReading: source)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32768),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65536) else { throw VoxClipError.decodeFailed("Apple audio conversion") }
        let target = try AVAudioFile(forWriting: destination, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        while true {
            try Task.checkCancellation()
            var error: NSError?, readError: (any Error)?
            let status = converter.convert(to: output, error: &error) { packets, inputStatus in
                do {
                    if file.framePosition >= file.length { inputStatus.pointee = .endOfStream; return nil }
                    try file.read(into: input, frameCount: min(32768, packets))
                    inputStatus.pointee = .haveData
                    return input
                } catch { readError = error; inputStatus.pointee = .endOfStream; return nil }
            }
            if let readError { throw readError }
            if let error { throw error }
            if output.frameLength > 0 { try target.write(from: output) }
            if status == .endOfStream { break }
            if status == .error { throw VoxClipError.decodeFailed("Apple audio conversion") }
        }
    }
}

private actor AppleSpeechLocaleUsage {
    static let shared = AppleSpeechLocaleUsage()
    private var uses: [String: Int] = [:]
    func begin(_ locale: String) { uses[locale, default: 0] += 1 }
    func end(_ locale: String) { uses[locale, default: 0] -= 1 }
    func running() -> Set<String> { Set(uses.filter { $0.value > 0 }.map(\.key)) }
}

public struct AppleSpeechRun: Sendable {
    public let text: String
    public let start: Double?
    public let end: Double?
    public let confidence: Double?
    public init(text: String, start: Double?, end: Double?, confidence: Double?) { self.text = text; self.start = start; self.end = end; self.confidence = confidence }
}

public enum AppleSpeechRunMapper {
    public static func tokens(_ runs: [AppleSpeechRun], language: String, group: Int) -> [RawToken] {
        let cjk = ["zh", "ja", "yue"].contains(SpeechText.primaryLanguage(language))
        var boundary = false, first = true
        var tokens: [RawToken] = []
        for run in runs {
            let text = SpeechText.trim(run.text)
            if text.isEmpty { boundary = true; continue }
            let startsWord = first || boundary || run.text.unicodeScalars.first.map(SpeechText.isWhitespace) == true || cjk && !SpeechText.isPunctuation(text)
            tokens.append(RawToken(text: text, joinsPrevious: !startsWord, start: run.start, end: run.end, conf: run.confidence, group: group))
            boundary = false; first = false
        }
        return tokens
    }
}
