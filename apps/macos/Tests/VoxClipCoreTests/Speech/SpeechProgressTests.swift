import Foundation
import Synchronization
import Testing
@testable import VoxClipCore

@Suite("Speech progress trailing delivery")
struct SpeechProgressTests {
    @Test func runtimeVersionUsesOnlyMajorAndMinor() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #expect(SpeechRuntimeVersion.macOS == "\(version.majorVersion).\(version.minorVersion)")
    }

    @Test func idleTranscribingStageIsDeliveredAfterUploadBurst() async throws {
        let events = Mutex<[(TranscriptionProgress, ContinuousClock.Instant)]>([])
        let reporter = SpeechProgressLimiter<TranscriptionProgress> { value in events.withLock { $0.append((value, .now)) } }
        defer { reporter.cancel() }
        for index in 0..<1000 { reporter.report(TranscriptionProgress(stage: .uploading, fraction: Double(index) / 1000)) }
        reporter.report(TranscriptionProgress(stage: .transcribing, fraction: nil))
        // Wait for the trailing delivery instead of a fixed sleep, so a loaded machine cannot fail the test.
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline, events.withLock({ $0.last?.0.stage }) != .transcribing {
            try await Task.sleep(for: .milliseconds(10))
        }
        let values = events.withLock { $0 }
        #expect(values.count >= 2 && values.count <= 3)
        #expect(values.first?.0.stage == .uploading)
        #expect(values.last?.0.stage == .transcribing && values.last?.0.fraction == nil)
        for index in 1..<values.count { #expect(values[index - 1].1.duration(to: values[index].1) >= .milliseconds(95)) }
    }

    @Test func finishFlushesFinalFraction() async {
        let values = Mutex<[Double]>([])
        let reporter = SpeechProgressLimiter<Double> { fraction in values.withLock { $0.append(fraction) } }
        reporter.report(0)
        reporter.report(0.5)
        reporter.report(1)
        await reporter.finish()
        #expect(values.withLock { $0 } == [0, 1])
    }
}
