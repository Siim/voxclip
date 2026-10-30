import AVFoundation
import Foundation
import Speech
import Synchronization
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

@Suite("Apple speech asset safety")
struct AppleSpeechSafetyTests {
    @Test(arguments: [false, true])
    func existingOrNewReservationBothContinueAssetPreparation(_ newlyReserved: Bool) async throws {
        let prepared = Mutex(0)
        try await AppleSpeechAssets.prepare(locale: "en-US", operation: {
            try await AppleSpeechAssets.reserve { newlyReserved }
            prepared.withLock { $0 += 1 }
        }, reserve: { Issue.record("A successful reservation must not retry") }, release: { Issue.record("An existing reservation must not release a locale") })
        #expect(prepared.withLock { $0 } == 1)
    }

    @Test
    func reservationLimitStillReleasesAStaleLocaleAndRetries() async throws {
        let calls = Mutex(0), releases = Mutex(0), reserves = Mutex(0)
        let limit = NSError(domain: SFSpeechError.errorDomain, code: SFSpeechError.Code.tooManyAssetLocalesAllocated.rawValue)
        try await AppleSpeechAssets.prepare(locale: "en-US", operation: {
            try await AppleSpeechAssets.reserve {
                let attempt = calls.withLock { $0 += 1; return $0 }
                if attempt == 1 { throw limit }
                return false
            }
        }, reserve: { reserves.withLock { $0 += 1 } }, release: { releases.withLock { $0 += 1 } })
        #expect(calls.withLock { $0 } == 2)
        #expect(releases.withLock { $0 } == 1)
        #expect(reserves.withLock { $0 } == 1)
    }

    @Test(arguments: [VoxClipError.transcriptionLanguageUnsupported("en"), .speechAssetsUnavailable("en")])
    func voxClipCaseIndexCollisionsDoNotRecover(_ failure: VoxClipError) async throws {
        let code = (failure as NSError).code
        #expect([SFSpeechError.Code.assetLocaleNotAllocated.rawValue, SFSpeechError.Code.tooManyAssetLocalesAllocated.rawValue].contains(code))
        let recoveries = Mutex(0)
        await #expect(throws: failure) {
            try await AppleSpeechAssets.prepare(locale: "en-US", operation: { throw failure },
                reserve: { recoveries.withLock { $0 += 1 } }, release: { recoveries.withLock { $0 += 1 } })
        }
        #expect(recoveries.withLock { $0 } == 0)
    }

    @Test func cocoaCaseIndexDoesNotBecomeSpeechNoModel() async throws {
        let failure = NSError(domain: NSCocoaErrorDomain, code: SFSpeechError.Code.noModel.rawValue)
        #expect(AppleSpeechAssets.map(failure, locale: "en-US").code == .speechAssetsUnavailable)
        do {
            try await AppleSpeechAssets.prepare(locale: "en-US", operation: { throw failure },
                reserve: { Issue.record("A Cocoa error must not reserve assets") }, release: { Issue.record("A Cocoa error must not release assets") })
            Issue.record("Expected mapped asset failure")
        } catch let error as VoxClipError { #expect(error.code == .speechAssetsUnavailable) }
    }

    @Test(arguments: [(SFSpeechError.Code.insufficientResources.rawValue, VoxClipErrorCode.diskFull),
                     (SFSpeechError.Code.noModel.rawValue, .transcriptionLanguageUnsupported),
                     (SFSpeechError.Code.cannotAllocateUnsupportedLocale.rawValue, .transcriptionLanguageUnsupported),
                     (SFSpeechError.Code.moduleOutputFailed.rawValue, .speechAssetsUnavailable)])
    func actualSpeechErrorsUseMappingTable(_ code: Int, _ expected: VoxClipErrorCode) {
        #expect(AppleSpeechAssets.map(NSError(domain: SFSpeechError.errorDomain, code: code), locale: "en-US").code == expected)
    }

    @Test(arguments: ["release", "reserve", "retry"])
    func retryFailuresUseTheSameMapper(_ stage: String) async throws {
        let calls = Mutex(0)
        let first = NSError(domain: SFSpeechError.errorDomain, code: SFSpeechError.Code.tooManyAssetLocalesAllocated.rawValue)
        let retry = NSError(domain: SFSpeechError.errorDomain, code: SFSpeechError.Code.insufficientResources.rawValue)
        do {
            try await AppleSpeechAssets.prepare(locale: "en-US", operation: {
                let attempt = calls.withLock { $0 += 1; return $0 }
                if attempt == 1 { throw first }
                if stage == "retry" { throw retry }
            }, reserve: { if stage == "reserve" { throw retry } }, release: { if stage == "release" { throw retry } })
            Issue.record("Expected mapped retry failure")
        } catch let error as VoxClipError { #expect(error.code == .diskFull) }
        #expect(calls.withLock { $0 } == (stage == "retry" ? 2 : 1))
    }

    @Test func assetRecoveryRetriesOnlyOnce() async throws {
        let calls = Mutex(0), reserves = Mutex(0), releases = Mutex(0)
        let failure = NSError(domain: SFSpeechError.errorDomain, code: SFSpeechError.Code.tooManyAssetLocalesAllocated.rawValue)
        do {
            try await AppleSpeechAssets.prepare(locale: "en-US", operation: { calls.withLock { $0 += 1 }; throw failure },
                reserve: { reserves.withLock { $0 += 1 } }, release: { releases.withLock { $0 += 1 } })
            Issue.record("Expected second failure")
        } catch let error as VoxClipError { #expect(error.code == .speechAssetsUnavailable) }
        #expect(calls.withLock { $0 } == 2)
        #expect(reserves.withLock { $0 } == 1 && releases.withLock { $0 } == 1)
    }

    @Test(arguments: [false, true])
    func releaseUsesTheActualReservedLocaleAndChecksResult(_ succeeds: Bool) async throws {
        let actual = Locale(identifier: "en_US")
        #expect(actual != Locale(identifier: "en-US"))
        do {
            try await AppleSpeechAssets.release("en-US", reserved: [actual]) { locale in
                #expect(locale == actual)
                #expect(locale.identifier == "en_US")
                return succeeds
            }
            #expect(succeeds)
        } catch let error as VoxClipError {
            #expect(!succeeds)
            #expect(error.code == .speechAssetsUnavailable)
        }
    }

    @Test func preferredSupportedRegionWinsBeforeBareFallback() async {
        let seen = Mutex<[String]>([])
        let locale = await AppleSpeechLocaleResolver.locale(for: .forced("en"), preferredLanguages: ["fr-FR", "en-NZ", "en-US", "en-AU"]) { candidate in
            seen.withLock { $0.append(candidate.identifier(.bcp47)) }
            return candidate.identifier(.bcp47) == "en-US" ? Locale(identifier: "en_US") : nil
        }
        #expect(locale?.identifier(.bcp47) == "en-US")
        #expect(seen.withLock { $0 } == ["en-NZ", "en-US"])
    }

    @Test func unsupportedPreferredRegionFallsBackToBareLanguage() async {
        let seen = Mutex<[String]>([])
        let locale = await AppleSpeechLocaleResolver.locale(for: .forced("en"), preferredLanguages: ["en-NZ"]) { candidate in
            seen.withLock { $0.append(candidate.identifier) }
            return candidate.identifier == "en" ? Locale(identifier: "en_AU") : nil
        }
        #expect(locale?.identifier(.bcp47) == "en-AU")
        #expect(seen.withLock { $0 } == ["en-NZ", "en"])
    }

    @Test func explicitRegionDoesNotUseLanguagePreferences() async {
        let seen = Mutex<[String]>([])
        let locale = await AppleSpeechLocaleResolver.locale(for: .forced("en-GB"), preferredLanguages: ["en-US"]) { candidate in
            seen.withLock { $0.append(candidate.identifier(.bcp47)) }
            return Locale(identifier: "en_GB")
        }
        #expect(locale?.identifier(.bcp47) == "en-GB")
        #expect(seen.withLock { $0 } == ["en-GB"])
    }

    @Test func cancelledAppleCAFConversionPreservesThePreviousEntry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-caf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("apple-16000-1.caf")
        let earlier = Data("earlier complete cache entry".utf8)
        try earlier.write(to: destination)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let source = root.appendingPathComponent("source.wav")
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
            buffer.frameLength = 16000
            try file.write(from: buffer)
        }
        let started = AsyncStream<Void>.makeStream()
        let engine = AppleSpeechTranscriber(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        let conversion = Task {
            for await _ in started.stream { break }
            try await engine.convert(source, to: destination, format: format)
        }
        conversion.cancel()
        started.continuation.yield(())
        started.continuation.finish()
        await #expect(throws: CancellationError.self) { try await conversion.value }
        #expect(try Data(contentsOf: destination) == earlier)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["apple-16000-1.caf", "source.wav"])
    }

    @Test func appleCAFReplacesOnlyAfterSuccessfulConversion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-caf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav"), destination = root.appendingPathComponent("apple-16000-1.caf")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
            buffer.frameLength = 16000
            try file.write(from: buffer)
        }
        let earlier = Data("earlier complete cache entry".utf8)
        try earlier.write(to: destination)
        let engine = AppleSpeechTranscriber(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        do { try await engine.convert(root.appendingPathComponent("missing.wav"), to: destination, format: format); Issue.record("Expected read failure") }
        catch { #expect(try Data(contentsOf: destination) == earlier) }
        try await engine.convert(source, to: destination, format: format)
        #expect(try AVAudioFile(forReading: destination).length == 16000)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(names == ["apple-16000-1.caf", "source.wav"])
    }
}
