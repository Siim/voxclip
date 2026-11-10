import Foundation
import Synchronization
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

/// A speech service that answers only when the test says so: every lookup waits until `answer(_:)`, and a test that never
/// answers still releases its lookups when it ends (`answer(nil)` in a `defer`), so no continuation leaks.
private final class SpeechServiceGate: Sendable {
    private struct State { var waiting: [CheckedContinuation<Locale?, Never>] = []; var answer: Locale??; var asked = 0; var returned = 0 }
    private let state = Mutex(State())
    var asked: Int { state.withLock { $0.asked } }
    var returned: Int { state.withLock { $0.returned } }

    func resolve(_ locale: Locale) async -> Locale? {
        let found = await withCheckedContinuation { (continuation: CheckedContinuation<Locale?, Never>) in
            let ready = state.withLock { state -> Locale?? in
                state.asked += 1
                if let answer = state.answer { return answer }
                state.waiting.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
        state.withLock { $0.returned += 1 }
        return found
    }
    func answer(_ locale: Locale?) {
        let waiting = state.withLock { state -> [CheckedContinuation<Locale?, Never>] in
            state.answer = .some(locale)
            defer { state.waiting = [] }
            return state.waiting
        }
        waiting.forEach { $0.resume(returning: locale) }
    }
}

/// Apple Speech's locale lookup is bounded (design.md §7.1 "Engine", transcription §10.2): a speech service that never answers
/// makes Apple Speech not ready, never unsupported, and writes nothing to the locale ledger.
@Suite("Apple Speech's locale lookup bound")
struct AppleSpeechLocaleBoundTests {
    /// The bound the tests use; the app's is 15 s. The deadlines below are far longer, so a missing bound fails, not hangs.
    private static let bound = Duration.milliseconds(150)

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-apple-speech-bound-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func source(_ resolve: @escaping @Sendable (Locale) async -> Locale?) -> AppleSpeechLocaleSource {
        AppleSpeechLocaleSource(isAvailable: { true }, preferredLanguages: { ["en-GB"] }, resolve: resolve, bound: Self.bound)
    }
    /// A ledger already on disk, so "untouched" means its bytes, not only its absence.
    private func seededLedger(_ root: URL) throws -> (URL, Data) {
        let url = root.appendingPathComponent("apple-speech-locales.json")
        let bytes = Data(#"[{"locale":"de-DE","lastUsed":"2026-11-01T10:00:00.000Z"}]"#.utf8)
        try bytes.write(to: url)
        return (url, bytes)
    }

    @Test func aServiceThatNeverAnswersIsNotReadyWithinTheBoundAndLeavesTheLedger() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (ledger, bytes) = try seededLedger(root)
        let gate = SpeechServiceGate(); defer { gate.answer(nil) }
        let engine = AppleSpeechTranscriber(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]), localeSource: source(gate.resolve))
        let plan = TranscriptionPlan(engine: .appleSpeech, language: .forced("en"))
        let started = ContinuousClock.now
        let readiness = try await TestDeadline.value(Task { await engine.readiness(for: plan) }, "readiness with no answer", timeout: .seconds(20))
        let waited = ContinuousClock.now - started
        #expect(readiness == .unavailable(reason: "Apple Speech didn't answer. Try again, or choose On this Mac."))
        #expect(readiness == .unavailable(reason: AppleSpeechTranscriber.noAnswerReason))
        #expect(waited >= Self.bound)
        #expect(gate.asked == 1 && gate.returned == 0)
        // Not ready is not unsupported: the engine is still offered, and its steps stop with the no-answer copy.
        #expect(try await TestDeadline.value(Task { await engine.supports(.forced("en"), model: nil) }, "supports with no answer", timeout: .seconds(20)) == true)
        do {
            _ = try await TestDeadline.value(Task { try await engine.cacheIdentity(for: plan) }, "cache identity with no answer", timeout: .seconds(20))
            Issue.record("Expected no answer")
        } catch let error as VoxClipError {
            #expect(error == .transcriptionFailed("Apple Speech didn't answer"))
            #expect(error.code != .transcriptionLanguageUnsupported)
        }
        #expect(try Data(contentsOf: ledger) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["apple-speech-locales.json"])
    }

    @Test func aLateAnswerAfterTheBoundIsIgnored() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (ledger, bytes) = try seededLedger(root)
        let gate = SpeechServiceGate(); defer { gate.answer(nil) }
        // The lookup itself: the bound decides, and the answer that comes later is dropped.
        let decided = try await TestDeadline.value(Task {
            await AppleSpeechBoundedLookup.run(within: Self.bound) { await gate.resolve(Locale(identifier: "en-US")) }
        }, "bounded lookup", timeout: .seconds(20))
        #expect(decided == .noAnswer)
        // The engine: its readiness is shown as not ready, then the service answers; what was shown stays.
        let engine = AppleSpeechTranscriber(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]), localeSource: source(gate.resolve))
        let plan = TranscriptionPlan(engine: .appleSpeech, language: .forced("en"))
        let shown = try await TestDeadline.value(Task { await engine.readiness(for: plan) }, "readiness before the answer", timeout: .seconds(20))
        #expect(shown == .unavailable(reason: AppleSpeechTranscriber.noAnswerReason))
        gate.answer(Locale(identifier: "en-GB"))
        #expect(await TestDeadline.until(timeout: .seconds(20)) { gate.returned == 2 })
        #expect(shown == .unavailable(reason: AppleSpeechTranscriber.noAnswerReason))
        #expect(try Data(contentsOf: ledger) == bytes)
        // Asking again is a new lookup, and a service that answers now gives its locale.
        let identity = try await TestDeadline.value(Task { try await engine.cacheIdentity(for: plan) }, "cache identity after the answer", timeout: .seconds(20))
        #expect(identity?.locale == "en-GB")
        #expect(try Data(contentsOf: ledger) == bytes)
    }

    @Test func aNormalAnswerIsUnchanged() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path])
        let plan = TranscriptionPlan(engine: .appleSpeech, language: .forced("en"))
        let answers = AppleSpeechTranscriber(locations: locations, localeSource: source { $0.identifier(.bcp47) == "en-GB" ? $0 : nil })
        #expect(await answers.supports(.forced("en"), model: nil))
        #expect(try await answers.cacheIdentity(for: plan).locale == "en-GB")
        // No locale for the language is still unsupported, with its copy, and Estonian or Auto never asks the service.
        let none = SpeechServiceGate(); none.answer(nil)
        let unsupported = AppleSpeechTranscriber(locations: locations, localeSource: source(none.resolve))
        #expect(await unsupported.supports(.forced("en"), model: nil) == false)
        #expect(await unsupported.readiness(for: plan) == .unsupportedLanguage("Choose a supported Apple Speech locale"))
        do { _ = try await unsupported.cacheIdentity(for: plan); Issue.record("Expected unsupported language") }
        catch let error as VoxClipError { #expect(error.code == .transcriptionLanguageUnsupported) }
        let asked = none.asked
        #expect(await unsupported.supports(.forced("et"), model: nil) == false)
        #expect(await unsupported.supports(.auto, model: nil) == false)
        #expect(none.asked == asked)
        // Without the framework the engine is unsupported, and nothing is asked.
        let off = AppleSpeechTranscriber(locations: locations, localeSource: AppleSpeechLocaleSource(isAvailable: { false }, preferredLanguages: { ["en-GB"] },
            resolve: { _ in Issue.record("An unavailable framework must not be asked"); return nil }, bound: Self.bound))
        #expect(await off.readiness(for: plan) == .unsupportedLanguage("Choose a supported Apple Speech locale"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("apple-speech-locales.json").path))
    }

    @Test func theAppWaitsAtMostFifteenSeconds() {
        #expect(AppleSpeechLocaleSource.system.bound == .seconds(15))
    }
}
