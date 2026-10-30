import AVFoundation
import Darwin
import Foundation
import Synchronization
import Testing
import VoxClipCore
@testable import VoxClipMedia

extension HeavyMediaTests {
@Test func retryKeepsUserPartialOutsidePrivateWorkspace() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-private-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("take.mp4")
    let oldPartial = root.appendingPathComponent("take.mp4.partial")
    let userBytes = Data("user file at an old partial path".utf8)
    try userBytes.write(to: oldPartial)
    let staging = try ExportSafety.preparePartial(for: destination)
    #expect((try? Data(contentsOf: oldPartial)) == userBytes)
    #expect(staging.deletingLastPathComponent() != root)
    #expect(staging.deletingLastPathComponent().lastPathComponent.hasPrefix(".voxclip-export-"))
    let mode = try FileManager.default.attributesOfItem(atPath: staging.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o700)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).contains("take.mp4.partial"))
}

@Test func errorExitCodesMatchTheCompleteCLIContract() {
    let groups: [Int32: [VoxClipError]] = [
        1: [.modelChecksumMismatch("test"), .keyRejected("test"), .quotaExceeded("test"), .rateLimited("test"),
            .offline, .providerError("test"), .llmInvalidOutput, .localeUnsupported("test"), .notImplemented("test")],
        3: [.unsupportedContainer("test"), .mediaMissing("test"), .noAudioTrack, .decodeFailed("test"),
            .projectUnreadable("test"), .projectTooNew, .sharedResourcesMissing, .ffmpegLicenceGate],
        4: [.noSpeech, .keyPermissionMissing, .mediaTooLong("test"), .transcriptionLanguageUnsupported("test"),
            .speechAssetsUnavailable("test"), .transcriptionFailed("test")],
        5: [.everythingCut, .diskFull("test"), .encoderUnavailable, .exportFailed("test")],
        6: [.cancelled],
        7: [.keyMissing("test"), .modelMissing("test"), .cliNotInstalled("test"), .cliNotSignedIn("test")]
    ]
    for (exitCode, errors) in groups {
        for error in errors { #expect(error.exitCode == exitCode) }
    }
    #expect(Set(groups.values.flatMap { $0 }.map(\.code)) == Set(VoxClipErrorCode.allCases))
}

@Test func stoppedPumpsNeverFinishCancelledWriterInputs() {
    let pumps = ExportPumpState()
    var finished = 0
    pumps.finishInput { finished += 1 }
    pumps.stop()
    pumps.finishInput { finished += 1 }
    #expect(finished == 1)
}

@Test func stoppedAppendRetriesPreserveTheFirstPumpFailure() {
    let pumps = ExportPumpState()
    pumps.stop(VoxClipError.diskFull("test"))
    pumps.stop(CancellationError())
    #expect(throws: VoxClipError.diskFull("test")) { try pumps.checkRunning() }
}

@Test func pumpAppendAccountingCoversSuccessfulAndThrowingOperations() throws {
    let pumps = ExportPumpState()
    #expect(try pumps.append { pumps.appendsInFlight == 1 })
    #expect(pumps.appendsInFlight == 0)
    #expect(throws: CancellationError.self) {
        try pumps.append {
            #expect(pumps.appendsInFlight == 1)
            throw CancellationError()
        }
    }
    #expect(pumps.appendsInFlight == 0)
    pumps.stop()
    #expect(throws: CancellationError.self) { try pumps.append { Issue.record("Append ran after stop"); return true } }
    #expect(pumps.appendsInFlight == 0)
}

private final class PumpPullCounts: Sendable {
    struct Counts {
        var afterStop = [0, 0]
        var buffersAfterStop = [0, 0]
        var inFlight = [0, 0]
        var maximumInFlight = [0, 0]
        var started = [0, 0]
        var appendsAtWriterCancellation: [Int] = []
        var pullsAtReaderCancellation: [Int] = []
    }
    private let state = Mutex(Counts())
    var counts: Counts { state.withLock { $0 } }
    func record(_ event: ExportPumpEvent) {
        state.withLock {
            switch event {
            case .pullStarted(let pump, let stopped):
                $0.started[pump] += 1
                $0.afterStop[pump] += stopped ? 1 : 0
                $0.inFlight[pump] += 1
                $0.maximumInFlight[pump] = max($0.maximumInFlight[pump], $0.inFlight[pump])
            case .pullEnded(let pump): $0.inFlight[pump] -= 1
            case .sampleRead(let pump, let stopped): $0.buffersAfterStop[pump] += stopped ? 1 : 0
            case .readerWillCancel(let pump): $0.pullsAtReaderCancellation.append($0.inFlight[pump])
            case .writerWillCancel(let appendsInFlight): $0.appendsAtWriterCancellation.append(appendsInFlight)
            }
        }
    }
}

@Suite(.serialized) struct ExportStopTests {
@Test(.timeLimit(.minutes(2)), arguments: [0, 1, 2])
func exportPumpsStopAtSampleBoundaries(_ stoppedPump: Int) async throws {
    let source = try await NativeMediaFixtures.shared.file("interrupt-aac.mov")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-pump-failure-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let plan = EditPlan(sampleRate: 48000, totalSamples: 2880000,
                        kept: [MediaInterval(startSample: 0, endSample: 2880000)])
    let render = RenderRequest(sourceURL: source, plan: plan,
        output: OutputSpec(size: PixelSize(width: 1080, height: 1920), fps: 30, videoBitrate: 8_000_000))
    for iteration in 0..<10 {
        let failedAt = Mutex<ContinuousClock.Instant?>(nil)
        let pulls = PumpPullCounts()
        let exporter = AVExporter(appendCheck: { pump, count in
            if pump == stoppedPump && count >= (pump == 0 ? 10 : 48000) {
                failedAt.withLock { $0 = .now }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
            }
        }, pumpObserver: { pulls.record($0) })
        let output = root.appendingPathComponent("failed.mp4")
        let task = Task { try await exporter.export(ExportJob(render: render, outputURL: output)) { _ in } }
        if stoppedPump == 2 {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while pulls.counts.started.contains(0), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(pulls.counts.started.allSatisfy { $0 > 0 })
            failedAt.withLock { $0 = .now }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await awaitStoppedExport(task, stoppedAt: { failedAt.withLock { $0 } }) }
        } else {
            await #expect(throws: VoxClipError.diskFull(root.path)) { try await awaitStoppedExport(task, stoppedAt: { failedAt.withLock { $0 } }) }
        }
        let latency = try #require(failedAt.withLock { $0 }).duration(to: .now)
        let counts = pulls.counts
        #expect(latency <= .seconds(2))
        #expect(counts.afterStop.allSatisfy { $0 <= 1 })
        #expect(counts.maximumInFlight.allSatisfy { $0 <= 1 })
        #expect(counts.pullsAtReaderCancellation.allSatisfy { $0 == 0 })
        #expect(counts.appendsAtWriterCancellation == [0])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        print("PUMP_STOP pump=\(stoppedPump) iteration=\(iteration) afterStop=\(counts.afterStop) maxInFlight=\(counts.maximumInFlight) cancelAppends=\(counts.appendsAtWriterCancellation) duration=\(latency)")
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [0, 1])
func cancellationAbandonsAnUnreturningPull(_ blockedPump: Int) async throws {
    try await checkCancellationOfBlockedPull(blockedPump, decodeAfterStop: false)
}

@Test(.timeLimit(.minutes(1)), arguments: [0, 1])
func cancellationDiscardsARealBufferReturnedAfterStop(_ blockedPump: Int) async throws {
    try await checkCancellationOfBlockedPull(blockedPump, decodeAfterStop: true)
}

private func checkCancellationOfBlockedPull(_ blockedPump: Int, decodeAfterStop: Bool) async throws {
    let source = try await NativeMediaFixtures.shared.file()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-blocked-pull-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let blocked = Mutex(false)
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    let pulls = PumpPullCounts()
    let stoppedAt = Mutex<ContinuousClock.Instant?>(nil)
    let block: @Sendable (Int) -> Void = { pump in
        if pump == blockedPump {
            blocked.withLock { $0 = true }
            gate.wait()
        }
    }
    let exporter = AVExporter(appendCheck: { _, _ in #expect(stoppedAt.withLock { $0 } == nil) },
        pumpObserver: { pulls.record($0) }, pullCheck: decodeAfterStop ? nil : block,
        decodeCheck: decodeAfterStop ? block : nil)
    let plan = EditPlan(sampleRate: 48000, totalSamples: 96000,
        kept: [MediaInterval(startSample: 0, endSample: 96000)])
    let render = RenderRequest(sourceURL: source, plan: plan,
        output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 1_000_000))
    let task = Task { try await exporter.export(ExportJob(render: render, outputURL: root.appendingPathComponent("out.mp4"))) { _ in } }
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !blocked.withLock({ $0 }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    #expect(blocked.withLock { $0 })
    let requestedAt = Mutex<ContinuousClock.Instant?>(.now)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await awaitStoppedExport(task, stoppedAt: { requestedAt.withLock { $0 } }) }
    let latency = try #require(requestedAt.withLock { $0 }).duration(to: .now)
    stoppedAt.withLock { $0 = .now }
    #expect(latency <= .seconds(2))
    #expect(pulls.counts.inFlight[blockedPump] == 1)
    #expect(pulls.counts.appendsAtWriterCancellation == [0])
    #expect(pulls.counts.pullsAtReaderCancellation.allSatisfy { $0 == 0 })
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    gate.signal()
    let releaseDeadline = ContinuousClock.now.advanced(by: .seconds(2))
    while (pulls.counts.inFlight != [0, 0] || pulls.counts.pullsAtReaderCancellation.count != 2), ContinuousClock.now < releaseDeadline {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(pulls.counts.inFlight == [0, 0])
    #expect(pulls.counts.pullsAtReaderCancellation.count == 2)
    #expect(pulls.counts.pullsAtReaderCancellation.allSatisfy { $0 == 0 })
    #expect(pulls.counts.buffersAfterStop[blockedPump] == (decodeAfterStop ? 1 : 0))
    print("BLOCKED_PULL pump=\(blockedPump) decodedAfterStop=\(decodeAfterStop) duration=\(latency)")
}
}

@Test func diskFullErrorsPreserveNativeErrorChains() {
    let destination = URL(fileURLWithPath: "/tmp/out.mp4")
    for native in [NSError(domain: AVFoundationErrorDomain, code: AVError.diskFull.rawValue),
                   NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError),
                   NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))] {
        let wrapped = NSError(domain: "ExportTest", code: 1, userInfo: [NSUnderlyingErrorKey: native])
        #expect(ExportSafety.failure(wrapped, destination: destination) == .diskFull("/tmp"))
    }
    let native = NSError(domain: NSOSStatusErrorDomain, code: -12345)
    let wrapped = NSError(domain: AVFoundationErrorDomain, code: -11800, userInfo: [NSUnderlyingErrorKey: native])
    guard case .exportFailed(let details) = ExportSafety.failure(wrapped, destination: destination) else {
        Issue.record("Expected diagnostic export failure"); return
    }
    #expect(details.contains("AVFoundationErrorDomain(-11800)"))
    #expect(details.contains("NSOSStatusErrorDomain(-12345)"))
}

@Test(arguments: [false, true])
func publicationFailureRestoresReplacedFilesAndRemovesNewOutputs(_ existingVideo: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-publish-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let outputs = try ["mp4", "srt", "wav"].map { suffix in
        let destination = root.appendingPathComponent("out.\(suffix)")
        return (partial: try ExportSafety.preparePartial(for: destination), destination: destination)
    }
    for (index, output) in outputs.enumerated() {
        if index > 0 || existingVideo { try Data("original \(index)".utf8).write(to: output.destination) }
        try Data("new \(index)".utf8).write(to: output.partial)
    }
    try #require(chflags(outputs[2].destination.path, UInt32(UF_IMMUTABLE)) == 0)
    defer { chflags(outputs[2].destination.path, 0) }
    #expect(throws: (any Error).self) { try ExportSafety.publishAll(outputs) }
    for (index, output) in outputs.enumerated() {
        if index > 0 || existingVideo { #expect(try Data(contentsOf: output.destination) == Data("original \(index)".utf8)) }
        else { #expect(!FileManager.default.fileExists(atPath: output.destination.path)) }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == (existingVideo ? ["out.mp4", "out.srt", "out.wav"] : ["out.srt", "out.wav"]))
}

@Test func cancelledPublicationPreservesDestinationsAndDeletesPartials() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-publish-cancel-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("out.mp4")
    let partial = try ExportSafety.preparePartial(for: destination)
    try Data("original".utf8).write(to: destination)
    try Data("staged".utf8).write(to: partial)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try ExportSafety.publishAll([(partial, destination)])
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try Data(contentsOf: destination) == Data("original".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["out.mp4"])
}

@Test(arguments: [0, 1])
func failedRestoreKeepsItsBackupAndAttemptsEveryOtherRestore(_ failedIndex: Int) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-restore-failure-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let outputs = try ["mp4", "srt", "wav"].map { suffix in
        let destination = root.appendingPathComponent("out.\(suffix)")
        return (partial: try ExportSafety.preparePartial(for: destination), destination: destination)
    }
    for (index, output) in outputs.enumerated() {
        try Data("original \(index)".utf8).write(to: output.destination)
        try Data("new \(index)".utf8).write(to: output.partial)
    }
    var keptBackup: URL?
    var restored: [URL] = []
    do {
        try ExportSafety.publishAll(outputs, events: { phase, destination in
            if phase == .willPublish && destination == outputs[2].destination { throw POSIXError(.ENOSPC) }
            if phase == .willRollback {
                if destination == outputs[failedIndex].destination {
                    let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                        .filter { $0.lastPathComponent.hasPrefix(".voxclip-export-") }
                    keptBackup = try directories.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
                        .first { $0.lastPathComponent.hasPrefix(destination.lastPathComponent + ".rollback-") }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
                restored.append(destination)
            }
        })
        Issue.record("Expected failed restore")
    } catch {
        let backup = try #require(keptBackup)
        let backupDirectory = backup.deletingLastPathComponent()
        let backupPath = backupDirectory.lastPathComponent + "/" + backup.lastPathComponent
        let message = "Couldn't put back \(outputs[failedIndex].destination.lastPathComponent). The previous version is saved as \(backupPath)."
        #expect(error as? VoxClipError == .exportFailed(message))
        #expect((error as? VoxClipError)?.errorDescription == message)
        #expect((error as? VoxClipError)?.exitCode == 5)
        #expect((error as? VoxClipError)?.requiresExportRecovery == true)
        #expect(try Data(contentsOf: backup) == Data("original \(failedIndex)".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: backupDirectory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let lease = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: backupDirectory.appendingPathComponent(".voxclip-owner.json"))) as? [String: Any])
        #expect(lease["recovery"] as? Bool == true)
        #expect(restored == [outputs[1 - failedIndex].destination])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() ==
            (["out.mp4", "out.srt", "out.wav", backupDirectory.lastPathComponent]).sorted())
    }
    for (index, output) in outputs.enumerated() {
        #expect(try Data(contentsOf: output.destination) == Data("\(index == failedIndex ? "new" : "original") \(index)".utf8))
    }
}

@Test(arguments: [false, true])
func cancellationAfterPublicationRestoresExistingAndRemovesNewDestinations(_ existing: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-published-cancel-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let outputs = try ["mp4", "srt", "wav"].map { suffix in
        let destination = root.appendingPathComponent("out.\(suffix)")
        return (partial: try ExportSafety.preparePartial(for: destination), destination: destination)
    }
    for output in outputs {
        if existing { try Data("original".utf8).write(to: output.destination) }
        try Data("new".utf8).write(to: output.partial)
    }
    let task = Task {
        try ExportSafety.publishAll(outputs, events: { phase, destination in
            if phase == .didPublish && destination == outputs[0].destination { withUnsafeCurrentTask { $0?.cancel() } }
        })
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    if existing {
        for output in outputs { #expect(try Data(contentsOf: output.destination) == Data("original".utf8)) }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == (existing ? ["out.mp4", "out.srt", "out.wav"] : []))
}

@Test func exportDestinationsRefuseDirectoriesBeforePreparingAndPublishing() async throws {
    let root = URL(fileURLWithPath: "/tmp/voxclip-safety-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let victim = root.appendingPathComponent("victim")
    try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: false)
    let sentinel = victim.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: sentinel)
    let request = RenderRequest(sourceURL: root.appendingPathComponent("missing.mov"), plan: EditPlan(sampleRate: 48000, totalSamples: 48000,
        kept: [MediaInterval(startSample: 0, endSample: 48000)]),
        output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 2_000_000))
    await #expect(throws: (any Error).self) {
        _ = try await AVExporter().export(ExportJob(render: request, outputURL: victim)) { _ in Issue.record("Prepared unsafe destination") }
    }
    await #expect(throws: (any Error).self) { try await AVExporter().writeEditedAudio(request, to: victim) }
    let partial = root.appendingPathComponent("staged")
    try Data("new".utf8).write(to: partial)
    #expect(throws: (any Error).self) { try ExportSafety.publish(partial, to: victim) }
    #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
    #expect(try Data(contentsOf: partial) == Data("new".utf8))
}
}
