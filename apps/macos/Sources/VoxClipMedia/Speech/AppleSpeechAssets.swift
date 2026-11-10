import Foundation
import Speech
import Synchronization
import VoxClipCore

enum AppleSpeechAssets {
    static func reserve(operation: @Sendable () async throws -> Bool) async throws {
        _ = try await operation()
    }

    static func map(_ error: any Error, locale: String) -> VoxClipError {
        if let error = error as? VoxClipError { return error }
        if error is CancellationError || Task.isCancelled { return .cancelled }
        let native = error as NSError
        if native.domain == SFSpeechError.errorDomain {
            switch native.code {
            case SFSpeechError.Code.insufficientResources.rawValue: return .diskFull("/", size: "space for the speech model")
            case SFSpeechError.Code.noModel.rawValue, SFSpeechError.Code.cannotAllocateUnsupportedLocale.rawValue:
                return SpeechErrorCopy.unsupported(.appleSpeech, language: .forced(locale))
            default: break
            }
        }
        return .speechAssetsUnavailable(locale, reason: "\(native.domain):\(native.code)")
    }

    static func prepare(locale: String, operation: @Sendable () async throws -> Void, reserve: @Sendable () async throws -> Void, release: @Sendable () async throws -> Void) async throws {
        do { try await operation() }
        catch {
            if let error = error as? VoxClipError { throw error }
            if error is CancellationError || Task.isCancelled { throw VoxClipError.cancelled }
            let native = error as NSError
            guard native.domain == SFSpeechError.errorDomain,
                  native.code == SFSpeechError.Code.assetLocaleNotAllocated.rawValue || native.code == SFSpeechError.Code.tooManyAssetLocalesAllocated.rawValue else {
                throw map(error, locale: locale)
            }
            do {
                if native.code == SFSpeechError.Code.tooManyAssetLocalesAllocated.rawValue { try await release() }
                try await reserve()
                try await operation()
            } catch { throw map(error, locale: locale) }
        }
    }

    static func release(_ identifier: String, reserved: [Locale], operation: @Sendable (Locale) async -> Bool) async throws {
        guard let locale = reserved.first(where: { $0.identifier(.bcp47) == identifier }), await operation(locale) else {
            throw VoxClipError.speechAssetsUnavailable(identifier, reason: "Unable to release the reserved locale")
        }
    }
}

/// How Apple Speech's locale lookup ended (transcription §10.2): a locale, no locale for the language, or no answer from the
/// system speech service within the bound. No answer is never "unsupported": it is not ready, and asking again may answer.
enum AppleSpeechLocaleLookup: Sendable, Equatable {
    case locale(Locale)
    case unsupported
    case noAnswer
}

/// Where Apple Speech's locales come from: the Speech framework, or a test's stub. `bound` caps one whole lookup, every
/// `resolve` it makes included, because `SpeechTranscriber.supportedLocale(equivalentTo:)` has no time limit of its own.
struct AppleSpeechLocaleSource: Sendable {
    var isAvailable: @Sendable () -> Bool
    var preferredLanguages: @Sendable () -> [String]
    var resolve: @Sendable (Locale) async -> Locale?
    var bound: Duration

    static let system = AppleSpeechLocaleSource(
        isAvailable: { Speech.SpeechTranscriber.isAvailable },
        preferredLanguages: { Locale.preferredLanguages },
        resolve: { await Speech.SpeechTranscriber.supportedLocale(equivalentTo: $0) },
        bound: .seconds(15))

    func lookup(_ language: LanguageChoice) async -> AppleSpeechLocaleLookup {
        guard isAvailable() else { return .unsupported }
        let preferred = preferredLanguages()
        let resolve = resolve
        return await AppleSpeechBoundedLookup.run(within: bound) {
            await AppleSpeechLocaleResolver.locale(for: language, preferredLanguages: preferred, resolve: resolve)
        }
    }
}

/// Runs a lookup that may never return, and answers within `bound`. The lookup runs unstructured, so a service that never
/// answers can't hold the caller (a task group would wait for it). The first of the answer, the bound and the caller's
/// cancellation decides; a later answer is dropped, so it can't change what was already returned.
enum AppleSpeechBoundedLookup {
    static func run(within bound: Duration, _ body: @escaping @Sendable () async -> Locale?) async -> AppleSpeechLocaleLookup {
        let once = AppleSpeechLookupOnce()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<AppleSpeechLocaleLookup, Never>) in
                once.start(continuation)
                once.add(Task { once.finish(await body().map(AppleSpeechLocaleLookup.locale) ?? .unsupported) })
                once.add(Task {
                    // The bound's own wait: a cancelled timer (the answer came first) decides nothing.
                    guard (try? await Task.sleep(for: bound)) != nil else { return }
                    once.finish(.noAnswer)
                })
            }
        } onCancel: { once.finish(.noAnswer) }
    }
}

private final class AppleSpeechLookupOnce: Sendable {
    private struct State {
        var continuation: CheckedContinuation<AppleSpeechLocaleLookup, Never>?
        var decided: AppleSpeechLocaleLookup?
        var tasks: [Task<Void, Never>] = []
    }
    private let state = Mutex(State())

    func start(_ continuation: CheckedContinuation<AppleSpeechLocaleLookup, Never>) {
        let decided = state.withLock { state -> AppleSpeechLocaleLookup? in
            if state.decided == nil { state.continuation = continuation }
            return state.decided
        }
        if let decided { continuation.resume(returning: decided) }
    }
    func add(_ task: Task<Void, Never>) {
        let cancel = state.withLock { state -> Bool in
            if state.decided == nil { state.tasks.append(task); return false }
            return true
        }
        if cancel { task.cancel() }
    }
    func finish(_ result: AppleSpeechLocaleLookup) {
        let (continuation, tasks) = state.withLock { state -> (CheckedContinuation<AppleSpeechLocaleLookup, Never>?, [Task<Void, Never>]) in
            guard state.decided == nil else { return (nil, []) }
            state.decided = result
            defer { state.continuation = nil; state.tasks = [] }
            return (state.continuation, state.tasks)
        }
        tasks.forEach { $0.cancel() }
        continuation?.resume(returning: result)
    }
}

enum AppleSpeechLocaleResolver {
    static func locale(for language: LanguageChoice, preferredLanguages: [String], resolve: @Sendable (Locale) async -> Locale?) async -> Locale? {
        guard case .forced(let code) = language, SpeechText.primaryLanguage(code) != "et" else { return nil }
        let primary = SpeechText.primaryLanguage(code)
        if code.contains("-") || code.contains("_") { return await resolve(Locale(identifier: code)) }
        for preferred in preferredLanguages where SpeechText.primaryLanguage(preferred) == primary {
            if let locale = await resolve(Locale(identifier: preferred)) { return locale }
        }
        return await resolve(Locale(identifier: primary))
    }
}
