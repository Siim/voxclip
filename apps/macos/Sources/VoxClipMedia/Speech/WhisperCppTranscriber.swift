import Foundation
import Synchronization
import whisper
import VoxClipCore

/// Native engine adapter; transcription §9, architecture §7.1. No native context crosses an actor.
public actor WhisperCppTranscriber: Transcriber, SpeechCacheIdentityProviding, SpeechLanguageDetector {
    public nonisolated let engine: TranscriptEngine = .whispercpp
    private let catalog: BundledModelCatalog?
    private let locations: DataLocations
    private let logger: any Redacting
    private var context: OpaquePointer?
    private var contextKey: String?
    private var expiry: Task<Void, Never>?
    private var active = false
    public init(logger: any Redacting = RedactingLogger(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)) {
        catalog = (try? SharedResources.locate()).map { BundledModelCatalog(shared: $0) }
        locations = DataLocations()
        self.logger = logger
    }
    public init(catalog: BundledModelCatalog, locations: DataLocations, logger: any Redacting = RedactingLogger(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)) { self.catalog = catalog; self.locations = locations; self.logger = logger }
    isolated deinit { if let context { whisper_free(context) }; expiry?.cancel() }
    public nonisolated func capabilities(model: String?) -> TranscriberCapabilities { TranscriberCapabilities(timing: .dtw, verbatim: false, autoLanguage: true, onDevice: true) }
    public func supports(_ language: LanguageChoice, model: String?) async -> Bool {
        guard let model, let catalog, let descriptor = try? await catalog.model(id: model),
              let runtime = try? await catalog.runtime(id: model), runtime.kind == "asr" else { return false }
        switch language {
        case .auto: return runtime.forcedLanguage == nil && runtime.whisper?.multilingual == true && model.hasPrefix("whisper-large-v3-turbo-")
        case .forced(let code):
            let primary = SpeechText.primaryLanguage(code)
            return runtime.forcedLanguage.map { $0 == primary } ?? descriptor.languages.contains(primary)
        }
    }
    public func readiness(for plan: TranscriptionPlan) async -> Readiness {
        guard let model = plan.model, let catalog, let descriptor = try? await catalog.model(id: model) else { return .unavailable(reason: "Choose a catalogue model") }
        guard await supports(plan.language, model: model) else { return .unsupportedLanguage("This model cannot transcribe the selected language") }
        let store = ModelStore(catalog: catalog, locations: locations)
        let installed = (try? await store.installedModels()) ?? []
        let missing = ([model] + descriptor.requires).filter { !installed.contains($0) }
        var bytes: Int64 = 0
        for identifier in missing { bytes += (try? await catalog.model(id: identifier).totalBytes) ?? 0 }
        return missing.isEmpty ? .ready : .needsModels(ids: missing, bytes: bytes)
    }
    public func prepare(for plan: TranscriptionPlan, progress: @escaping @Sendable (Double) -> Void) async throws { try Task.checkCancellation() }
    public func cacheIdentity(for plan: TranscriptionPlan) async throws -> EngineRef {
        guard let model = plan.model, let catalog else { throw VoxClipError.modelMissing(plan.model ?? "Whisper") }
        let descriptor = try await catalog.model(id: model)
        return EngineRef(id: .whispercpp, modelId: model, modelSha256: descriptor.files.first(where: { $0.role == "model" })?.sha256, engineVersion: "whisper.cpp 1.9.5 (b5454)")
    }
    public func detectLanguage(_ request: TranscriptionRequest) async throws -> SpeechLanguageDetection {
        try Task.checkCancellation()
        guard !active else { throw VoxClipError.transcriptionFailed("This whisper engine is already transcribing") }
        active = true
        expiry?.cancel()
        defer {
            active = false
            expiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(120)); await self?.unloadIfIdle() } catch {}
            }
        }
        guard request.plan.engine == engine, request.plan.language == .auto,
              let modelID = request.plan.model, let catalog,
              await supports(.auto, model: modelID) else { throw SpeechErrorCopy.unsupported(engine, language: request.plan.language) }
        let descriptor = try await catalog.model(id: modelID)
        if case .needsModels(_, let bytes) = await readiness(for: request.plan) { throw SpeechErrorCopy.modelMissing(descriptor, bytes: bytes) }
        let runtime = try await catalog.runtime(id: modelID)
        guard let settings = runtime.whisper, let file = descriptor.files.first(where: { $0.role == "model" }) else { throw SpeechErrorCopy.modelMissing(descriptor) }
        let vad = try await catalog.model(id: settings.vadModel)
        guard let vadFile = vad.files.first else { throw SpeechErrorCopy.modelMissing(vad) }
        WhisperDiagnosticLog.install(logger: logger)
        let samples = try SpeechNativeAudio.normalized(SpeechNativeAudio.samples(request.audio.wav16k))
        let cancellation = WhisperCallbacks(progress: { _ in })
        return try await withTaskCancellationHandler {
            let units = try speechUnits(samples, model: path(vad, vadFile), cancellation: cancellation)
            guard let unit = units.first else { throw VoxClipError.noSpeech }
            let context = try loadContext(descriptor, file: file, settings: settings, dtw: request.plan.options.dtw)
            try cancellation.check()
            let detected = try detect(samples, unit: unit, context: context)
            try cancellation.check()
            return SpeechLanguageDetection(language: try await catalog.fromWhisperLanguage(detected.language), probability: detected.probability)
        } onCancel: { cancellation.cancelled.withLock { $0 = true } }
    }
    public func transcribe(_ request: TranscriptionRequest, progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> RawTranscript {
        try Task.checkCancellation()
        guard !active else { throw VoxClipError.transcriptionFailed("This whisper engine is already transcribing") }
        active = true
        expiry?.cancel()
        defer {
            active = false
            expiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(120)); await self?.unloadIfIdle() } catch {}
            }
        }
        guard request.plan.engine == engine, let modelID = request.plan.model, let catalog else { throw VoxClipError.modelMissing(request.plan.model ?? "Whisper") }
        guard await supports(request.plan.language, model: modelID) else { throw SpeechErrorCopy.unsupported(engine, language: request.plan.language) }
        let descriptor = try await catalog.model(id: modelID)
        if case .needsModels(_, let bytes) = await readiness(for: request.plan) { throw SpeechErrorCopy.modelMissing(descriptor, bytes: bytes) }
        let runtime = try await catalog.runtime(id: modelID)
        guard let settings = runtime.whisper, let modelFile = descriptor.files.first(where: { $0.role == "model" }) else { throw SpeechErrorCopy.modelMissing(descriptor) }
        let vad = try await catalog.model(id: settings.vadModel)
        guard let vadFile = vad.files.first else { throw SpeechErrorCopy.modelMissing(vad) }
        let samples = try SpeechNativeAudio.normalized(SpeechNativeAudio.samples(request.audio.wav16k))
        let cancellation = WhisperCallbacks(progress: progress)
        defer { cancellation.progress.cancel() }
        return try await withTaskCancellationHandler {
            WhisperDiagnosticLog.install(logger: logger)
            let units = try speechUnits(samples, model: path(vad, vadFile), cancellation: cancellation)
            guard !units.isEmpty else { throw VoxClipError.noSpeech }
            let dtw = request.plan.options.dtw
            let context = try loadContext(descriptor, file: modelFile, settings: settings, dtw: dtw)
            try cancellation.check()
            var language: String
            var probability: Double?
            switch request.plan.language {
            case .forced(let code): language = runtime.forcedLanguage ?? SpeechText.primaryLanguage(code)
            case .auto:
                let detected = try detect(samples, unit: units[0], context: context)
                guard detected.probability >= 0.5 else { throw SpeechErrorCopy.unsupported(engine, language: request.plan.language) }
                language = try await catalog.fromWhisperLanguage(detected.language)
                probability = detected.probability
                if language == "et" { throw SpeechErrorCopy.unsupported(engine, language: .forced(language)) }
            }
            let decodeLanguage = try await catalog.whisperLanguage(language)
            let prompt = settings.initialPromptByLanguage[language] ?? ""
            let total = Double(units.reduce(0) { $0 + $1.count })
            var finished = 0.0, group = 0
            var tokens: [RawToken] = []
            for unit in units {
                try cancellation.check()
                cancellation.position.withLock { $0 = (finished / total, Double(unit.count) / total) }
                var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
                parameters.n_threads = threads; parameters.greedy.best_of = 5
                parameters.translate = false; parameters.no_context = true; parameters.token_timestamps = true
                parameters.thold_pt = 0.01; parameters.thold_ptsum = 0.01
                parameters.max_len = 0; parameters.split_on_word = false; parameters.max_tokens = 0
                parameters.suppress_blank = true; parameters.suppress_nst = false
                parameters.temperature = 0; parameters.temperature_inc = 0.2
                parameters.entropy_thold = 2.4; parameters.logprob_thold = -1; parameters.no_speech_thold = 0.6
                parameters.print_progress = false; parameters.print_realtime = false; parameters.print_timestamps = false; parameters.print_special = false
                parameters.vad = false
                parameters.progress_callback = { _, _, percent, opaque in
                    guard let opaque else { return }
                    Unmanaged<WhisperCallbacks>.fromOpaque(opaque).takeUnretainedValue().report(percent)
                }
                parameters.progress_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()
                parameters.abort_callback = { opaque in
                    guard let opaque else { return true }
                    return Unmanaged<WhisperCallbacks>.fromOpaque(opaque).takeUnretainedValue().cancelled.withLock { $0 }
                }
                parameters.abort_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()
                let status = decodeLanguage.withCString { code in
                    prompt.withCString { initial in
                        parameters.language = code; parameters.initial_prompt = prompt.isEmpty ? nil : initial
                        parameters.carry_initial_prompt = !prompt.isEmpty
                        return samples.withUnsafeBufferPointer { whisper_full(context, parameters, $0.baseAddress! + unit.lowerBound, Int32(unit.count)) }
                    }
                }
                try cancellation.check()
                guard status == 0 else { throw VoxClipError.transcriptionFailed("whisper decode failed (\(status))") }
                for segment in 0..<whisper_full_n_segments(context) {
                    var pieces: [WhisperTokenPiece] = []
                    for index in 0..<whisper_full_n_tokens(context, segment) {
                        let token = whisper_full_get_token_data(context, segment, index)
                        guard token.id < whisper_token_eot(context), let text = whisper_full_get_token_text(context, segment, index) else { continue }
                        var count = 0; while text[count] != 0 { count += 1 }
                        let bytes = Data(bytes: text, count: count)
                        pieces.append(WhisperTokenPiece(bytes: bytes, start: Double(dtw && token.t_dtw >= 0 ? token.t_dtw : token.t0) / 100, end: Double(token.t1) / 100, confidence: Double(token.p)))
                    }
                    tokens += WhisperTokenMapper.tokens(pieces, group: group, offset: Double(unit.lowerBound) / 16000, duration: Double(unit.count) / 16000)
                    group += 1
                }
                finished += Double(unit.count)
            }
            cancellation.progress.report(TranscriptionProgress(stage: .transcribing, fraction: 1))
            await cancellation.progress.finish()
            return RawTranscript(engine: try await cacheIdentity(for: request.plan), grouping: GroupingRule(end: .nextWordStart, conf: .mean, bracketEvents: true), tokens: tokens, language: language, languageProbability: probability, verbatim: runtime.verbatim, timing: dtw ? .dtw : .tokenGrouped)
        } onCancel: { cancellation.cancelled.withLock { $0 = true } }
    }
    private var threads: Int32 { Int32(min(8, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))) }
    private func loadContext(_ model: ModelDescriptor, file: ModelFile, settings: SpeechModelRuntime.Whisper, dtw: Bool) throws -> OpaquePointer {
        let key = file.sha256 + (dtw ? "-dtw" : "-token")
        if contextKey != key {
            unload()
            var parameters = whisper_context_default_params()
            parameters.use_gpu = true
            parameters.flash_attn = !dtw
            parameters.dtw_token_timestamps = dtw
            switch settings.dtwAheadsPreset {
            case "BASE_EN": parameters.dtw_aheads_preset = WHISPER_AHEADS_BASE_EN
            case "SMALL_EN": parameters.dtw_aheads_preset = WHISPER_AHEADS_SMALL_EN
            default: parameters.dtw_aheads_preset = WHISPER_AHEADS_LARGE_V3_TURBO
            }
            context = path(model, file).withCString { whisper_init_from_file_with_params($0, parameters) }
            if context != nil { contextKey = key }
        }
        guard let context else { throw VoxClipError.transcriptionFailed("Could not load the whisper model") }
        return context
    }
    private func detect(_ samples: [Float], unit: Range<Int>, context: OpaquePointer) throws -> SpeechLanguageDetection {
        let count = min(unit.count, 480_000)
        var probabilities = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
        let detected = samples.withUnsafeBufferPointer { buffer -> Int32 in
            guard whisper_pcm_to_mel(context, buffer.baseAddress! + unit.lowerBound, Int32(count), threads) == 0 else { return -1 }
            return whisper_lang_auto_detect(context, 0, threads, &probabilities)
        }
        guard detected >= 0, let code = whisper_lang_str(detected) else { throw VoxClipError.transcriptionFailed("Whisper language detection failed") }
        return SpeechLanguageDetection(language: String(cString: code), probability: Double(probabilities[Int(detected)]))
    }
    private func path(_ model: ModelDescriptor, _ file: ModelFile) -> String { locations.models.appendingPathComponent("whispercpp").appendingPathComponent(model.id).appendingPathComponent(file.name).path }
    private func unloadIfIdle() { if !active { unload() } }
    private func unload() { if let context { whisper_free(context) }; context = nil; contextKey = nil }
    private func speechUnits(_ samples: [Float], model: String, cancellation: WhisperCallbacks) throws -> [Range<Int>] {
        try cancellation.check()
        var contextParameters = whisper_vad_default_context_params()
        contextParameters.n_threads = threads
        guard let vad = model.withCString({ whisper_vad_init_from_file_with_params($0, contextParameters) }) else { throw VoxClipError.transcriptionFailed("Could not load Silero VAD") }
        defer { whisper_vad_free(vad) }
        var parameters = whisper_vad_default_params()
        parameters.threshold = 0.30; parameters.min_speech_duration_ms = 250; parameters.min_silence_duration_ms = 2000
        parameters.max_speech_duration_s = Float.greatestFiniteMagnitude; parameters.speech_pad_ms = 400; parameters.samples_overlap = 0.10
        guard let segments = samples.withUnsafeBufferPointer({ whisper_vad_segments_from_samples(vad, parameters, $0.baseAddress, Int32($0.count)) }) else { throw VoxClipError.transcriptionFailed("Silero VAD failed") }
        defer { whisper_vad_free_segments(segments) }
        try cancellation.check()
        var units: [Range<Int>] = []
        for index in 0..<whisper_vad_segments_n_segments(segments) {
            let start = max(0, min(samples.count, Int((Double(whisper_vad_segments_get_segment_t0(segments, index)) * 160).rounded())))
            let end = max(start, min(samples.count, Int((Double(whisper_vad_segments_get_segment_t1(segments, index)) * 160).rounded())))
            guard end > start else { continue }
            if let previous = units.last, start <= previous.upperBound { units[units.count - 1] = previous.lowerBound..<max(previous.upperBound, end) }
            else { units.append(start..<end) }
        }
        return units
    }
}

/// C decode calls are synchronous; the actor retains this box until callbacks stop, and shared state is mutex-protected.
private final class WhisperCallbacks: Sendable {
    let cancelled = Mutex(false)
    let position = Mutex((0.0, 1.0))
    let progress: SpeechProgressLimiter<TranscriptionProgress>
    init(progress: @escaping @Sendable (TranscriptionProgress) -> Void) { self.progress = SpeechProgressLimiter(callback: progress) }
    func check() throws { if cancelled.withLock({ $0 }) || Task.isCancelled { throw VoxClipError.cancelled } }
    func report(_ percent: Int32) {
        let fraction = position.withLock { $0.0 + $0.1 * Double(percent) / 100 }
        progress.report(TranscriptionProgress(stage: .transcribing, fraction: min(1, max(0, fraction))))
    }
}
