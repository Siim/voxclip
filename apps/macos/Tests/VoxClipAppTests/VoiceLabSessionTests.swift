#if DEBUG
import AVFoundation
import Foundation
import Testing
@testable import VoxClipCore
@_spi(Testing) @testable import VoxClipMedia
@testable import VoxClip

@Suite("Headless Voice Lab session", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; no windows or provider requests are opened."))
@MainActor struct VoiceLabSessionTests {
    @Test(arguments: [2, 3], [false, true]) func recoveryOperationAccessibilityIdentifiesEachVoiceAndAction(count: Int, sharedSuffix: Bool) throws {
        let shared = try SharedResources.locate()
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-30T12:00:00Z"))
        let fixture = try Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record.json"))
        let records = try (1...count).map { index in
            var json = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
            json["recordId"] = UUID().uuidString.lowercased()
            json["voiceName"] = "My voice (VoxClip)"
            let prefix = ["A", "B", "C"][index - 1]
            json["voiceId"] = sharedSuffix ? "voice-\(prefix)123456" : "owned-voice-00000\(index)"
            json["createdAt"] = "2026-10-30T12:00:00Z"
            return try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let voices = VoiceLabSettings.accessibilityContexts(records: records, operations: [], shared: shared)
        for record in records {
            let context = try #require(voices["record-\(record.id)"])
            for request in [VoiceLabSession.Request.delete(record.id), .removeLocal(record.id)] {
                #expect(VoiceLabSettings.requestAccessibilityLabel(request, contexts: voices) == "\(request.title) \(context)")
            }
        }
        for action in ["Delete voice", "Retry deletion", "Remove from VoxClip only", "Retry saving consent record", "Remove unfinished voice"] {
            let labels = try records.enumerated().map { index, record in
                let context = try #require(voices["record-\(record.id)"])
                let label = VoiceLabSettings.actionAccessibilityLabel(action, context: context)
                let identifier = sharedSuffix ? "voice ID \(record.voiceId)" : "voice ID ending 00000\(index + 1)"
                #expect(label == "\(action) My voice (VoxClip), created 30 October 2026, \(identifier)")
                return label
            }
            #expect(Set(labels).count == count)
        }
        var operations = (1...count).map { index in
            var operation = VoiceOperation(id: UUID(), kind: .create, recordID: "attempt-\(index)", region: .default, at: date)
            operation.expectedVoiceName = "My voice (VoxClip)"
            if index == count { operation.remoteVoiceID = "remote-123456" }
            return operation
        }
        operations.append(VoiceOperation(id: UUID(), kind: .create, recordID: "unnamed", region: .default, at: date))
        let contexts = VoiceLabSettings.accessibilityContexts(records: [], operations: operations, shared: shared)
        for operation in operations {
            let context = try #require(contexts["operation-\(operation.id)"])
            let request = VoiceLabSession.Request.stopLooking(operation.id)
            #expect(VoiceLabSettings.requestAccessibilityLabel(request, contexts: contexts) == "\(request.title) \(context)")
        }
        let stop = VoiceLabSession.Request.stopLooking(operations[0].id).title
        for action in ["Retry", "Remove unfinished voice", stop] {
            let labels = try operations.enumerated().map { index, operation in
                let context = try #require(contexts["operation-\(operation.id)"])
                let label = VoiceLabSettings.actionAccessibilityLabel(action, context: context)
                let name = index == count ? "Unnamed voice" : "My voice (VoxClip)"
                let suffix = index == count - 1 ? "voice ID ending 123456" : "attempt \(index + 1)"
                #expect(label == "\(action) \(name), created 30 October 2026, \(suffix)")
                return label
            }
            #expect(Set(labels).count == operations.count)
        }
        let single = VoiceLabSettings.accessibilityContexts(records: [records[0]], operations: [], shared: shared)
        #expect(single["record-\(records[0].id)"] == "My voice (VoxClip), created 30 October 2026")
    }
    @Test func stoppingIdentitylessRecoveryIsExplicitLocalAndDefaultsToCancel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceConsentStore(locations: locations(root))
        let shared = try SharedResources.locate()
        let wav = try VoiceTrainingAudio.wav([Float](repeating: 0.1, count: 5 * 48_000))
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record.json"))) as? [String: Any])
        var statement = try #require(json["statement"] as? [String: Any])
        statement["audioSha256"] = VoiceLabFingerprint.bytes(wav); json["statement"] = statement
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: json))
        try await store.saveStatement(wav, recordID: record.id)
        let operation = try await store.beginClaimedCreation(record: record.assigningVoice("pending", requiresVerification: true), requestID: UUID(), region: .default, at: Date())
        _ = try await store.transition(operation.id, to: .dispatched, at: Date())
        try await store.requireRecoveryReview(operation.id)
        await store.releaseOperation(operation.id)
        let app = AppModel(); app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(false)
        let session = VoiceLabSession(app: app, store: store)
        await session.load(recover: false)
        let action = VoiceLabSession.Request.stopLooking(operation.id)
        #expect(action.title == "I've checked my ElevenLabs account — stop looking" && action.defaultIsCancel)
        session.request(action)
        #expect(session.confirmation == action && session.operations.first?.finished == false)
        await session.approve(action)
        #expect(session.operations.first?.remoteStateUnknown == true && session.operations.first?.finished == true)
        #expect(!app.bool("voiceLab.providerConsent.elevenlabs"))
        #expect(session.message?.contains("remote state is unknown") == true)
        session.stopRecovery()
    }
    @Test(arguments: 0..<8) func recordingRequiresEveryAttestationWithACalibratedSpeaker(bits: Int) throws {
        let app = AppModel()
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.speakerModelLibrary.model = try SpeakerModelCatalog(shared: SharedResources.locate()).entry
        app.speakerModelLibrary.installed = true
        let session = VoiceLabSession(app: app)
        session.statement = VoiceConsentStatement(language: "en", text: "Offline statement fixture", nonce: [])
        session.displayName = "Example"
        session.ownVoice = bits & 1 != 0
        session.adult = bits & 2 != 0
        session.ownVideosOnly = bits & 4 != 0
        #expect(session.speakerReady)
        #expect(session.canRecord == (bits == 7))
    }
    @Test func nativeCheckFailuresPrintExpectedAndActualValues() {
        let result = DebugUISuite.Result.equal("fixture", expected: true, actual: false)
        #expect(!result.passed)
        #expect(result.name == "fixture; expected: true; actual: false")
        #expect(DebugUISuite.Result.equal("fixture", expected: true, actual: true).name == "fixture")
    }
    @Test(arguments: ElevenLabsRegion.allCases)
    func nativeConsentLogicRunsHeadlesslyWithoutRecordingOrDispatch(region: ElevenLabsRegion) async throws {
        let app = AppModel()
        app.settings.values["transcription.elevenlabs.region"] = .string(region.rawValue)
        let settings = app.settings
        let model = app.speakerModelLibrary.model
        let installed = app.speakerModelLibrary.installed
        let results = try await DebugVoiceLab.run(app: app)
        #expect(results.count == 12)
        for result in results { #expect(result.passed, Comment(rawValue: result.name)) }
        #expect(app.settings == settings)
        #expect(app.speakerModelLibrary.model?.id == model?.id)
        #expect(app.speakerModelLibrary.installed == installed)
    }
    @Test func recoveryExplainsTheRequiredCreatorKeyAndKeepsTheOperation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceConsentStore(locations: locations(root))
        let shared = try SharedResources.locate()
        let data = try Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record.json"))
        let wav = try VoiceTrainingAudio.wav([Float](repeating: 0.1, count: 5 * 48_000))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var statement = try #require(json["statement"] as? [String: Any])
        statement["audioSha256"] = VoiceLabFingerprint.bytes(wav); json["statement"] = statement
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: json))
        try await store.saveStatement(wav, recordID: record.id)
        let draft = record.assigningVoice("pending", requiresVerification: true)
        let operation = try await store.beginClaimedCreation(record: draft, requestID: UUID(), region: .default, at: Date())
        _ = try await store.transition(operation.id, to: .dispatched, at: Date())
        await store.releaseOperation(operation.id)
        let reconciler = VoiceOperationReconciler(store: store, regionIsCurrent: { _ in false }) { region in
            ElevenLabsVoiceLab(keys: VoiceLabAppKeys(), region: region)
        }
        let app = AppModel(); let session = VoiceLabSession(app: app, store: store, reconciler: reconciler)
        await session.load(force: true)
        #expect(session.message == "Recovery needs the ElevenLabs key that started this voice.")
        #expect(session.operations.count == 1 && session.operations.first?.finished == false)
        session.stopRecovery()
    }
    @Test func createdDateUsesTheFixedMonthTable() throws {
        #expect(VoiceLabSettings.createdDate("2026-10-26T12:00:00Z", shared: try SharedResources.locate()) == "26 October 2026")
        #expect(VoiceLabSettings.createdDate("invalid", shared: try SharedResources.locate()) == "Date unavailable")
    }
    @Test func deletionNeverUsesTheDestructiveDefault() {
        #expect(VoiceLabSession.Request.delete("voice").defaultIsCancel)
        for request: VoiceLabSession.Request in [.subscription, .verify, .create] { #expect(!request.defaultIsCancel) }
    }
    @Test func unavailableSpeakerCheckPreventsRecordingAndPaidApproval() async {
        let app = AppModel(); app.settings.values["voiceLab.enabled"] = .bool(true)
        let session = VoiceLabSession(app: app)
        session.displayName = "Example"; session.ownVoice = true; session.adult = true; session.ownVideosOnly = true
        #expect(!session.canRecord)
        await session.beginStatement()
        #expect(!session.recorder.recording && session.statement == nil)
        session.request(.verify)
        #expect(session.confirmation == nil)
        await session.approve(.verify)
        #expect(session.message == VoiceConsentError.speakerUnavailable.localizedDescription)
        #expect(!app.bool("voiceLab.providerConsent.elevenlabs"))
        for available in [false, true] {
            for language in ["en", "et", "fr"] {
                #expect(VoiceLabGate.canCheckOwnVoice(speakerAvailable: available, calibratedThreshold: 0.45, language: language) == (available && language == "en"))
            }
        }
        for threshold: Double? in [nil, .nan, -.infinity, -1, 1.1] {
            #expect(!VoiceLabGate.canCheckOwnVoice(speakerAvailable: true, calibratedThreshold: threshold, language: "en"))
        }
    }
    @Test(arguments: ["missing-model", "et", "fr", "uncalibrated"], [false, true])
    func unavailableSpeakerReasonDoesNotWaitForAttestationsOrPaidSteps(condition: String, attested: Bool) async throws {
        let app = AppModel()
        app.settings.values["voiceLab.enabled"] = .bool(true)
        let model = try SpeakerModelCatalog(shared: SharedResources.locate()).entry
        if condition == "uncalibrated" {
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
            object["threshold"] = NSNull()
            app.speakerModelLibrary.model = try JSONDecoder().decode(SpeakerModel.self, from: JSONSerialization.data(withJSONObject: object))
        } else { app.speakerModelLibrary.model = model }
        app.speakerModelLibrary.installed = condition != "missing-model"
        let session = VoiceLabSession(app: app)
        session.displayName = "Example"
        session.ownVoice = attested; session.adult = attested; session.ownVideosOnly = attested
        let language = ["et", "fr"].contains(condition) ? condition : "en"
        let statement = VoiceConsentStatement(language: language, text: "Offline statement fixture", nonce: [])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceLabAppHTTP.self]
        let client = ElevenLabsVoiceLab(keys: VoiceLabNoPaidKeys(), session: URLSession(configuration: configuration))
        let wav = try VoiceTrainingAudio.wav([Float](repeating: 0.1, count: 5 * 48_000))
        session.stageVerificationForTests(statement: statement, wav: wav, client: client)
        let reason = VoiceConsentError.speakerUnavailable.localizedDescription
        #expect(!session.speakerReady && !session.canRecord && !session.canCreate)
        #expect(session.speakerMessage == reason)
        await session.beginStatement()
        #expect(!session.recorder.recording && session.message == reason)
        for action: VoiceLabSession.Request in [.verify, .create] {
            session.stageVerificationForTests(statement: statement, wav: wav, client: client)
            let task = session.request(action)
            #expect(task == nil && session.confirmation == nil)
            await task?.value
            await session.approve(action)
            #expect(session.message == reason && !session.busy)
            #expect(!app.bool("voiceLab.providerConsent.elevenlabs"))
        }
        await session.prepareCreation()
        #expect(session.confirmation == nil && session.message == reason)
        session.stopRecovery()
    }
    @Test func startupAndSettingsFlushDoNotAwaitRemoteRecovery() async {
        let app = AppModel(), barrier = SessionRecoveryBarrier()
        app.voiceRecoveryForTests = { await barrier.pause() }
        await app.start()
        await barrier.wait()
        #expect(!app.loadingSettings)
        await app.flushSettings()
        barrier.resume()
        await barrier.finished()
        #expect(barrier.cancelled)
    }
    private func locations(_ root: URL) -> DataLocations {
        DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path])
    }
    @Test func reopeningAndCancellingAfterSuccessPreservesTheActiveVoice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceConsentStore(locations: locations(root))
        let session = VoiceLabSession(app: AppModel(), store: store)
        let wav = try VoiceTrainingAudio.wav([Float](repeating: 0.1, count: 5 * 48_000))
        let shared = try SharedResources.locate()
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record.json"))) as? [String: Any])
        json["recordId"] = session.recordID
        var statement = try #require(json["statement"] as? [String: Any])
        statement["audioSha256"] = VoiceLabFingerprint.bytes(wav); json["statement"] = statement
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: json))
        try await store.saveStatement(wav, recordID: record.id); try await store.save(record)
        session.verified = true; session.trainingReady = true
        session.finishCreation()
        #expect(session.recordID != record.id && !session.verified && !session.trainingReady && session.statement == nil)
        session.showEnrollment = true
        await session.cancelEnrollment()
        #expect(try await store.load(record.id) == record)
        #expect(try await store.statement(recordID: record.id) == wav)
        await #expect(throws: VoiceConsentError.inactive) { try await store.withdrawCreation(recordID: record.id) }
        try FileManager.default.removeItem(at: store.root.appendingPathComponent("\(record.id)/statement.wav"))
        let restarted = VoiceConsentStore(locations: locations(root))
        await #expect(throws: (any Error).self) { try await restarted.reconcileAbandonedEnrollments() }
        #expect(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("\(record.id)/record.json").path))
    }
    @Test func enablingBetaLoadsExistingRecordsBeforeAccountApproval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceConsentStore(locations: locations(root))
        let wav = try VoiceTrainingAudio.wav([Float](repeating: 0.1, count: 5 * 48_000))
        let shared = try SharedResources.locate()
        let data = try Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record.json"))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var statement = try #require(json["statement"] as? [String: Any])
        statement["audioSha256"] = VoiceLabFingerprint.bytes(wav); json["statement"] = statement
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: json))
        try await store.saveStatement(wav, recordID: record.id); try await store.save(record)
        let app = AppModel()
        app.settings.values["voiceLab.enabled"] = .bool(false)
        let session = VoiceLabSession(app: app, store: store)
        await session.refreshEnabledState()
        #expect(session.records.isEmpty && session.subscription == nil && session.confirmation == nil)
        app.settings.values["voiceLab.enabled"] = .bool(true)
        await session.refreshEnabledState()
        #expect(session.records == [record] && session.visibleRecords == [record])
        #expect(session.subscription == nil && session.confirmation == .subscription)
        session.confirmation = nil
        app.settings.values["voiceLab.enabled"] = .bool(false)
        await session.refreshEnabledState()
        #expect(session.records.isEmpty)
        app.settings.values["voiceLab.enabled"] = .bool(true)
        await session.refreshEnabledState()
        #expect(session.records == [record] && session.subscription == nil)
    }
    @Test func cancelBeforeServicesExistDeletesTheRecordedStatement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceConsentStore(locations: locations(root))
        let app = AppModel(); let session = VoiceLabSession(app: app, store: store)
        let wav = try VoiceTrainingAudio.wav([Float](repeating: 0.1, count: 5 * 48_000))
        try await store.saveStatement(wav, recordID: session.recordID)
        session.showEnrollment = true
        await session.cancelEnrollment()
        #expect(!session.showEnrollment)
        #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("\(session.recordID)/statement.wav").path))
    }
    @Test func withheldCalibrationNeverAdvertisesSpeakerAvailability() throws {
        let app = AppModel()
        let entry = try SpeakerModelCatalog(shared: SharedResources.locate()).entry
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        object["threshold"] = NSNull()
        app.speakerModelLibrary.model = try JSONDecoder().decode(SpeakerModel.self, from: JSONSerialization.data(withJSONObject: object))
        app.speakerModelLibrary.installed = true
        let session = VoiceLabSession(app: app)
        #expect(app.speakerModelLibrary.model?.calibratedThreshold() == nil)
        #expect(session.speakerMessage == VoiceConsentError.speakerUnavailable.localizedDescription)
    }
    @Test func saveFailureCanBeWithdrawnFromTheSheetWithoutServices() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceConsentStore(locations: locations(root), fault: { step in
            if step == .saveRecord { throw CocoaError(.fileWriteUnknown) }
        })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceLabAppHTTP.self]
        let client = ElevenLabsVoiceLab(keys: VoiceLabAppKeys(), session: URLSession(configuration: configuration))
        let reconciler = VoiceOperationReconciler(store: store, client: client)
        let app = AppModel(); let session = VoiceLabSession(app: app, store: store, reconciler: reconciler)
        let wav = try VoiceTrainingAudio.wav([Float](repeating: 0.1, count: 5 * 48_000))
        let shared = try SharedResources.locate()
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record.json"))) as? [String: Any])
        json["recordId"] = session.recordID
        var statement = try #require(json["statement"] as? [String: Any]); statement["audioSha256"] = VoiceLabFingerprint.bytes(wav); json["statement"] = statement
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: json))
        try await store.saveStatement(wav, recordID: record.id)
        let operation = try await store.beginClaimedCreation(record: record.assigningVoice("pending", requiresVerification: true), requestID: UUID(), region: .default, at: Date())
        _ = try await store.transition(operation.id, to: .dispatched, at: Date())
        _ = try await store.transition(operation.id, to: .created, at: Date(), remoteVoiceID: record.voiceId, requiresVerification: false)
        await store.releaseOperation(operation.id)
        await #expect(throws: (any Error).self) { try await reconciler.reconcile(force: true) }
        session.unsavedRecord = record; session.showEnrollment = true
        await session.cancelEnrollment()
        #expect(session.unsavedRecord == nil && !session.showEnrollment)
        #expect(try await store.operations().isEmpty)
        #expect(try await store.load(record.id).status == .deleted)
        #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("\(record.id)/statement.wav").path))
    }
    @Test func journalRowsRemainVisibleWithoutARecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceConsentStore(locations: locations(root))
        let app = AppModel(); let session = VoiceLabSession(app: app, store: store)
        let wav = try VoiceTrainingAudio.wav([Float](repeating: 0.1, count: 5 * 48_000))
        let shared = try SharedResources.locate()
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record.json"))) as? [String: Any])
        var statement = try #require(json["statement"] as? [String: Any]); statement["audioSha256"] = VoiceLabFingerprint.bytes(wav); json["statement"] = statement
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: json))
        try await store.saveStatement(wav, recordID: record.id); try await store.save(record)
        let operation = try await store.beginDeletion(record.id, region: .default, at: Date())
        try FileManager.default.removeItem(at: store.root.appendingPathComponent("\(record.id)/record.json"))
        await session.load(recover: false)
        #expect(session.records.isEmpty)
        #expect(session.operations.map(\.id) == [operation.id])
        #expect(session.operations.first?.displayState == "Removing…")
    }
}

/// voice-lab.md §6.2 and §6.5.2: the training source the sheet offers, headlessly and with no provider request.
@Suite("Headless Voice Lab training source", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; no windows or provider requests are opened."))
@MainActor struct VoiceLabTrainingSourceTests {
    /// 50 s at 8 kHz: four 8 s bursts of tone 2.5 s apart over a quiet floor.
    private static let bursts: [ClosedRange<Double>] = [1...9, 11.5...19.5, 22...30, 32.5...40.5]
    private func take(in folder: URL) throws -> URL {
        let rate = 8_000.0, frames = 50 * 8_000
        let url = folder.appendingPathComponent("take.wav")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<frames {
            let time = Double(index) / rate
            samples[index] = Float(sin(2 * Double.pi * 220 * time) * (Self.bursts.contains { $0.contains(time) } ? 0.2 : 0.0005))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return url
    }
    private func project(bursts: Int, language: String = "et", events: Bool = false) throws -> Project {
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-project.voxclip")))
        project.voiceLab = ProjectVoiceLab(segments: [], assets: project.voiceLab.assets)
        var words: [TimedWord] = []
        for (index, burst) in Self.bursts.prefix(bursts).enumerated() {
            words.append(TimedWord(id: "w\(index)a", text: "one", kind: events ? .event : .word, start: burst.lowerBound, end: burst.lowerBound + 4, conf: 0.95))
            words.append(TimedWord(id: "w\(index)b", text: "two", kind: events ? .event : .word, start: burst.lowerBound + 4.1, end: burst.upperBound, conf: 0.95))
        }
        project.transcript?.words = words
        project.transcript?.language = language
        return project
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-training-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func session() throws -> (AppModel, VoiceLabSession) {
        let app = AppModel()
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.speakerModelLibrary.model = try SpeakerModelCatalog(shared: SharedResources.locate()).entry
        app.speakerModelLibrary.installed = true
        return (app, VoiceLabSession(app: app))
    }

    @Test func projectAudioIsTheDefaultAndAnEstonianProjectRecordsAnEnglishStatement() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, session) = try session()
        session.openEnrollment(project: .init(project: try project(bursts: 4), name: "Interview", source: try take(in: root)))
        #expect(session.showEnrollment && session.trainingSource == .project && session.projectAudio == .finding)
        #expect(session.offersProjectAudio && session.projectChoiceEnabled && session.projectAudioLine == "Finding clear speech in Interview…")
        #expect(session.enrollmentLanguage == "en" && session.speakerReady)
        await session.analysis?.value
        guard case .found(let selection) = session.projectAudio else { Issue.record("The analysis did not finish"); return }
        #expect(selection.status == .ok && selection.availableMs == 32_000 && selection.selected.count == 4)
        #expect(session.trainingSource == .project && session.projectAudioUsable)
        #expect(session.projectAudioLine == "32 s of clear speech found in Interview")
        #expect(VoiceLabSession.projectChoice == "Use this project's audio (recommended)" && VoiceLabSession.readAloudChoice == "Record a read-aloud (about 90 s)")
        session.verified = true
        #expect(session.canCreate)
        session.chooseTrainingSource(.readAloud)
        #expect(session.trainingSource == .readAloud && !session.canCreate)
        session.chooseTrainingSource(.project)
        #expect(session.trainingSource == .project)
        session.finishCreation()
        #expect(session.projectAudio == .noProject && session.trainingSource == .readAloud && session.analysis == nil)
    }
    @Test func tooLittleOrNoSpeechSelectsTheReadAloud() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, session) = try session()
        let url = try take(in: root)
        for (project, line) in [(try project(bursts: 2), "This project has only 16 s of clear speech. Record a read-aloud instead."),
                                (try project(bursts: 4, events: true), "This project has no clear speech to use. Record a read-aloud instead.")] {
            session.showEnrollment = false
            session.openEnrollment(project: .init(project: project, name: "Interview", source: url))
            await session.analysis?.value
            #expect(session.trainingSource == .readAloud && !session.projectAudioUsable && !session.projectChoiceEnabled)
            #expect(session.offersProjectAudio && session.projectAudioLine == line)
            session.chooseTrainingSource(.project)
            #expect(session.trainingSource == .readAloud)
        }
    }
    @Test func missingProjectTranscriptOrMediaOffersOnlyTheReadAloudOrSaysWhy() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, session) = try session()
        var untranscribed = try project(bursts: 4); untranscribed.transcript = nil
        let unreadable = VoiceLabSession.projectUnreadableCopy
        #expect(unreadable == "VoxClip can't read this project's audio. Record a read-aloud instead.")
        let cases: [(VoiceLabSession.TrainingProject?, String, Bool)] = [
            (nil, "Open a project to use its audio instead.", false),
            (.init(project: untranscribed, name: "Interview", source: try take(in: root)), "Transcribe this project to use its audio instead.", false),
            (.init(project: try project(bursts: 4), name: "Interview", source: nil), unreadable, true),
            (.init(project: try project(bursts: 4), name: "Interview", source: root.appendingPathComponent("missing.mov")), unreadable, true),
        ]
        for (project, line, offered) in cases {
            session.showEnrollment = false
            session.openEnrollment(project: project)
            await session.analysis?.value
            #expect(session.trainingSource == .readAloud && session.projectAudioLine == line && session.offersProjectAudio == offered)
            #expect(!session.projectChoiceEnabled)
        }
    }
    @Test(arguments: [false, true]) func speakerMismatchBlocksProjectAudioAndKeepsTheVerifiedStatement(radio: Bool) async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, session) = try session()
        session.openEnrollment(project: .init(project: try project(bursts: 4), name: "Interview", source: try take(in: root)))
        await session.analysis?.value
        let statement = VoiceConsentStatement(language: "en", text: "Offline statement fixture", nonce: [])
        session.statement = statement; session.verified = true
        let mismatch = "Some of this project's audio doesn't sound like the voice in your consent statement. Record a read-aloud instead."
        await session.creationFailed(VoiceConsentError.speakerMismatch)
        #expect(session.projectMismatch && session.message == mismatch && session.projectAudioLine == "32 s of clear speech found in Interview")
        #expect(!session.projectChoiceEnabled && !session.canCreate && session.verifiedCopy == VoiceLabSession.readAloudNextCopy)
        // Record a Read-Aloud and the read-aloud radio leave the same state: the project option stays off and says why.
        if radio { session.chooseTrainingSource(.readAloud) } else { session.useReadAloud() }
        #expect(session.trainingSource == .readAloud && session.projectMismatch && session.message == nil)
        #expect(!session.projectChoiceEnabled && session.projectAudioLine == mismatch)
        session.chooseTrainingSource(.project)
        #expect(session.trainingSource == .readAloud && session.verified && session.statement == statement)
        await session.creationFailed(VoiceConsentError.speakerMismatch)
        #expect(session.message == VoiceConsentError.speakerMismatch.localizedDescription)
        session.finishCreation()
        #expect(!session.projectMismatch)
    }
    /// §6.5.2: the status after verification offers a choice only when the project option can be taken.
    @Test func verifiedStatusNamesAChoiceOnlyWhenThereIsOne() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, session) = try session()
        let url = try take(in: root)
        session.openEnrollment(project: .init(project: try project(bursts: 4), name: "Interview", source: url))
        #expect(session.verifiedCopy == "Statement verified. Choose your training audio next.")
        await session.analysis?.value
        #expect(session.verifiedCopy == VoiceLabSession.chooseTrainingCopy)
        for project: VoiceLabSession.TrainingProject? in [nil, .init(project: try project(bursts: 2), name: "Interview", source: url),
                                                          .init(project: try project(bursts: 4), name: "Interview", source: nil)] {
            session.showEnrollment = false
            session.openEnrollment(project: project)
            session.message = VoiceLabSession.chooseTrainingCopy
            await session.analysis?.value
            #expect(session.verifiedCopy == "Statement verified. Record your training read-aloud next.")
            if project?.source != nil { #expect(session.message == VoiceLabSession.readAloudNextCopy) }
        }
    }
    /// A failed cut falls back to the read-aloud with the line under the choice, not the same sentence twice.
    @Test func unreadableCutFallsBackToTheReadAloudOnce() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, session) = try session()
        let url = try take(in: root)
        session.openEnrollment(project: .init(project: try project(bursts: 4), name: "Interview", source: url))
        await session.analysis?.value
        session.statement = VoiceConsentStatement(language: "en", text: "Offline statement fixture", nonce: [])
        session.verified = true
        #expect(session.canCreate)
        try FileManager.default.removeItem(at: url)
        await session.prepareCreation()
        #expect(session.projectAudio == .unreadable && session.trainingSource == .readAloud && session.confirmation == nil)
        #expect(session.message == nil && session.projectAudioLine == VoiceLabSession.projectUnreadableCopy && !session.projectChoiceEnabled)
        session.stopRecovery()
    }
    @Test func cancellingDuringTheAnalysisIgnoresItsResult() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, session) = try session()
        session.openEnrollment(project: .init(project: try project(bursts: 4), name: "Interview", source: try take(in: root)))
        let first = session.analysis
        #expect(session.projectAudio == .finding && first != nil)
        await session.cancelEnrollment()
        #expect(!session.showEnrollment && session.projectAudio == .noProject && session.analysis == nil && session.projectName.isEmpty)
        var untranscribed = try project(bursts: 4); untranscribed.transcript = nil
        session.openEnrollment(project: .init(project: untranscribed, name: "Other", source: nil))
        await first?.value
        #expect(session.projectAudio == .untranscribed && session.trainingSource == .readAloud && session.projectName == "Other")
        session.stopRecovery()
    }
    /// The editor's media is offered only when the editor reads it; a demo never trains a voice.
    @Test func editorProjectOffersItsMediaOnlyWhenReadable() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let (app, session) = try session()
        let url = try take(in: root)
        var value = try project(bursts: 4); value.media.source.absolutePath = url.path
        let demo = EditorModel(document: VoxClipDocument(project: value, demo: true), app: app, preview: DemoPreviewEngine())
        demo.mediaResolved = true
        #expect(VoiceLabSession.trainingProject(editor: demo, name: "Interview").source == nil)
        let editor = EditorModel(document: VoxClipDocument(project: value), app: app, preview: DemoPreviewEngine())
        #expect(VoiceLabSession.trainingProject(editor: editor, name: "Interview").source == nil)
        editor.mediaResolved = true
        let resolved = VoiceLabSession.trainingProject(editor: editor, name: "Interview")
        #expect(resolved.source?.path == url.path && resolved.name == "Interview" && resolved.project.transcript?.language == "et")
        session.openEnrollment(project: resolved)
        await session.analysis?.value
        #expect(session.projectAudioUsable && session.trainingSource == .project)
        editor.mediaUnreadable = true
        #expect(VoiceLabSession.trainingProject(editor: editor, name: "Interview").source == nil)
    }
    /// VoxClip never trains on generated audio: an export labelled AI modified offers only the read-aloud.
    @Test func mediaLabelledAIModifiedIsNotTrainingAudio() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, session) = try session()
        func box(_ kind: String, _ body: Data) -> Data {
            var data = Data(withUnsafeBytes(of: UInt32(8 + body.count).bigEndian, Array.init)); data.append(Data(kind.utf8)); data.append(body); return data
        }
        let uuid = Data([0xbe, 0x7a, 0xcf, 0xcb, 0x97, 0xa9, 0x42, 0xe8, 0x9c, 0x71, 0x99, 0x94, 0x91, 0xe3, 0xaf, 0xac])
        let export = root.appendingPathComponent("export.mp4")
        try (box("ftyp", Data("isom".utf8) + Data(count: 4)) + box("moov", Data()) + box("uuid", uuid + VoiceLabDisclosureWriter.xmpPacket())).write(to: export)
        session.openEnrollment(project: .init(project: try project(bursts: 4), name: "Interview", source: export))
        await session.analysis?.value
        #expect(session.projectAudio == .generated && session.trainingSource == .readAloud && !session.projectChoiceEnabled && session.offersProjectAudio)
        #expect(session.projectAudioLine == "This project's media is labelled AI modified, so it can't train your voice. Record a read-aloud instead.")
    }
    /// A voice is bound to its statement language, so an Estonian project's Rewrite panel explains instead of offering one.
    @Test func rewriteExplainsWhenTheProjectLanguageHasNoSpeakerCheck() throws {
        let (app, session) = try session()
        #expect(session.voicesUnavailable(projectLanguage: "et") && session.voicesUnavailable(projectLanguage: "fr"))
        #expect(!session.voicesUnavailable(projectLanguage: "en") && !session.voicesUnavailable(projectLanguage: nil))
        #expect(VoiceLabSession.languageUnavailableCopy == "Your voice can't be used in this project's language yet. It works in English projects.")
        app.speakerModelLibrary.model = nil
        #expect(!session.voicesUnavailable(projectLanguage: "et"))
    }
    @Test func confirmationNamesTheProjectSpeechAndTheRewriteEntryDropsTheEstimate() {
        #expect(VoiceLabSession.creationCopy(projectName: "Interview", keptSeconds: 47.99, cost: "≈ $0.00") ==
            "Checks your plan, then sends the consent recording and 47 s of speech from Interview to create your own voice. No video is sent. ≈ $0.00")
        #expect(VoiceLabSession.creationCopy(projectName: nil, keptSeconds: 47.99, cost: "≈ $0.00") ==
            "Checks your plan, then sends the consent recording and training audio to create your own voice. No video is sent. ≈ $0.00")
        #expect(RewriteTakesView.createVoiceTitle == "Create Your Voice…")
    }
    @Test func statementLanguageNeedsACalibratedSpeakerCheck() throws {
        let model = try SpeakerModelCatalog(shared: SharedResources.locate()).entry
        let calibrated: (String) -> Bool = { model.calibratedThreshold(language: $0) != nil }
        for (candidate, expected) in [("et", "en"), ("et-EE", "en"), ("en-GB", "en"), ("fr", "en"), ("", "en")] {
            #expect(VoiceLabSession.statementLanguage(candidate, calibrated: calibrated) == expected)
        }
        #expect(VoiceLabSession.statementLanguage(nil, calibrated: calibrated) == "en")
        #expect(VoiceLabSession.statementLanguage("et-EE", calibrated: { $0 == "et" }) == "et")
    }
}

@MainActor private final class SessionRecoveryBarrier {
    private var arrived = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    private var done = false
    var cancelled = false
    func pause() async {
        await withCheckedContinuation { release = $0; arrived = true; arrival?.resume(); arrival = nil }
        cancelled = Task.isCancelled; done = true; completion?.resume(); completion = nil
    }
    func wait() async { if !arrived { await withCheckedContinuation { arrival = $0 } } }
    func resume() { release?.resume(); release = nil }
    func finished() async { if !done { await withCheckedContinuation { completion = $0 } } }
}

private struct VoiceLabAppKeys: KeyProvider {
    func key(for provider: String) async throws -> String? { "synthetic-journal-ui-key" }
}
private struct VoiceLabNoPaidKeys: KeyProvider {
    func key(for provider: String) async throws -> String? {
        Issue.record("Unavailable speaker checks must not reach credentials or provider calls")
        return nil
    }
}
private final class VoiceLabAppHTTP: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        #expect(request.httpMethod == "DELETE")
        let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"status":"ok"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
