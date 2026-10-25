import Foundation
import Speech
import VoxClipCore

enum AppleSpeechAssets {
    static func map(_ error: any Error, locale: String) -> VoxClipError {
        if let error = error as? VoxClipError { return error }
        if error is CancellationError || Task.isCancelled { return .cancelled }
        let native = error as NSError
        if native.domain == SFSpeechError.errorDomain {
            switch native.code {
            case SFSpeechError.Code.insufficientResources.rawValue: return .diskFull("Apple Speech assets")
            case SFSpeechError.Code.noModel.rawValue, SFSpeechError.Code.cannotAllocateUnsupportedLocale.rawValue:
                return .transcriptionLanguageUnsupported(locale)
            default: break
            }
        }
        return .speechAssetsUnavailable("\(locale) (\(native.domain):\(native.code))")
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
            throw VoxClipError.speechAssetsUnavailable("Unable to release \(identifier)")
        }
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
