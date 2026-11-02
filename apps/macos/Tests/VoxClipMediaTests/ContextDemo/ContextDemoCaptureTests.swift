import Darwin
import Foundation
import ScreenCaptureKit
import Testing
import VoxClipCore
@testable import VoxClipMedia

@MainActor private final class DemoCaptureBackendFake: ContextDemoCaptureBackend {
    var permission: ContextDemoCaptureAvailability = .available
    var candidates: [ContextDemoCaptureTarget] = [demoCaptureTarget()]
    var state = ContextDemoCaptureSnapshot()
    var enumerationCount = 0
    var beginCount = 0
    var stopCount = 0
    var releaseCount = 0
    var beginsImmediately = true
    var finishesImmediately = true
    var failureAfterFileCreation: ContextDemoCaptureError?
    var onBegin: (() -> Void)?
    var outputURL: URL?
    var beginGeometry: (Int, Int)?
    var initialBytes = Data([0, 0, 0, 24] + Array("ftypmp42".utf8) + [0, 0, 0, 0])

    func availability() -> ContextDemoCaptureAvailability { permission }
    func windows() async throws -> [ContextDemoCaptureTarget] { enumerationCount += 1; return candidates }
    func begin(window: ContextDemoCaptureTarget, output: URL, width: Int, height: Int) async throws {
        beginCount += 1; outputURL = output; beginGeometry = (width, height)
        try initialBytes.write(to: output)
        state.startAcknowledged = true
        onBegin?()
        if let failureAfterFileCreation { throw failureAfterFileCreation }
        state.started = beginsImmediately
    }
    func snapshot() -> ContextDemoCaptureSnapshot { state }
    func stop() {
        stopCount += 1; state.stopped = true
        if finishesImmediately { state.finished = true }
    }
    func release() { releaseCount += 1 }
}

@MainActor private final class DemoCaptureTimingFake: ContextDemoCaptureTiming {
    var now = 100.0
    var onPause: (() -> Void)?
    func pause() async throws {
        try Task.checkCancellation()
        now += 0.05
        onPause?()
        await Task.yield()
    }
}

@MainActor private final class DemoCaptureInspectorFake: ContextDemoRecordingInspecting {
    var metadata = ContextDemoRecordingMetadata(duration: 1, width: 640, height: 480)
    var onInspect: (() -> Void)?
    var inspectionCount = 0
    func inspect(_ url: URL) async throws -> ContextDemoRecordingMetadata {
        inspectionCount += 1; onInspect?()
        return metadata
    }
}

private func demoCaptureTarget(windowID: UInt32 = 42, processID: Int32 = 123,
                               launch: Date = Date(timeIntervalSince1970: 1),
                               width: Double = 640, height: Double = 480) -> ContextDemoCaptureTarget {
    ContextDemoCaptureTarget(windowID: windowID, processID: processID, bundleIdentifier: "com.example.Demo",
        applicationName: "Demo", windowTitle: "Approved window", processLaunchDate: launch,
        widthPoints: width, heightPoints: height, pixelScale: 1)
}

@Suite("Native context capture boundary", .offlineFixtures) @MainActor
struct ContextDemoCaptureTests {
    private let projectID = "11111111-1111-4111-8111-111111111111"

    private func request(window: ContextDemoWindowBinding? = demoCaptureTarget().binding,
                         revision: Int = 0, seconds: Double = 2,
                         actions: [ContextDemoReviewedAction] = []) -> ContextDemoCaptureRequest {
        ContextDemoCaptureRequest(id: "request-one", planId: "plan-one", revision: revision,
            target: ContextDemoTarget(kind: .desktopApp, displayName: "Demo", locator: "com.example.Demo"),
            durationSeconds: seconds, window: window, actions: actions)
    }

    private func fixture() -> (ContextDemoCaptureService, DemoCaptureBackendFake, DemoCaptureTimingFake,
                              DemoCaptureInspectorFake, URL) {
        let backend = DemoCaptureBackendFake(), timing = DemoCaptureTimingFake(), inspector = DemoCaptureInspectorFake()
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("voxclip-context-fake-\(UUID().uuidString)")
        return (ContextDemoCaptureService(backend: backend, inspector: inspector, timing: timing,
            store: ContextDemoAssetStore(rootURL: root)), backend, timing, inspector, root)
    }

    @Test func initializationAndReviewNeverStartOrCreateOutput() async throws {
        let (service, backend, _, _, root) = fixture()
        #expect(service.availability() == .available)
        #expect(backend.enumerationCount == 0 && backend.beginCount == 0)
        _ = try await service.prepare(request: request(), projectId: projectID)
        #expect(backend.beginCount == 0)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func missingPermissionNeverEnumeratesOrStarts() async throws {
        let (service, backend, _, _, root) = fixture()
        backend.permission = .screenRecordingPermissionRequired
        await #expect(throws: ContextDemoCaptureError.permissionRequired) { try await service.targets() }
        await #expect(throws: ContextDemoCaptureError.permissionRequired) {
            try await service.prepare(request: request(), projectId: projectID)
        }
        #expect(backend.enumerationCount == 0 && backend.beginCount == 0)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func appWithMultipleWindowsRequiresExactUserSelection() async throws {
        let (service, backend, _, _, _) = fixture()
        backend.candidates.append(demoCaptureTarget(windowID: 43))
        await #expect(throws: ContextDemoCaptureError.ambiguousTarget) {
            try await service.prepare(request: request(window: nil), projectId: projectID)
        }
        let reviewed = try await service.prepare(request: request(), projectId: projectID)
        #expect(reviewed.target.windowID == 42 && backend.beginCount == 0)
    }

    @Test func noWholeDesktopOrTitleFallbackWhenApprovedWindowDisappears() async throws {
        let (service, backend, _, _, _) = fixture()
        backend.candidates = [demoCaptureTarget(windowID: 43)]
        await #expect(throws: ContextDemoCaptureError.targetUnavailable) {
            try await service.prepare(request: request(), projectId: projectID)
        }
        #expect(backend.beginCount == 0)
    }

    @Test func processReuseAndChangedGeometryInvalidateReview() async throws {
        for changed in [demoCaptureTarget(processID: 124),
                        demoCaptureTarget(launch: Date(timeIntervalSince1970: 2)),
                        demoCaptureTarget(width: 800)] {
            let (service, backend, _, _, _) = fixture()
            let reviewed = try await service.prepare(request: request(), projectId: projectID)
            backend.candidates = [changed]
            await #expect(throws: ContextDemoCaptureError.staleReview) {
                try await service.start(reviewedPlan: reviewed, currentRequest: request())
            }
            #expect(backend.beginCount == 0)
        }
    }

    @Test func changedActionsRevisionAndExpiredReviewNeverRecord() async throws {
        for changed in [request(revision: 1), request(actions: [ContextDemoReviewedAction(id: "click", summary: "Click Save")])] {
            let (service, backend, _, _, _) = fixture()
            let reviewed = try await service.prepare(request: request(), projectId: projectID)
            await #expect(throws: ContextDemoCaptureError.staleReview) {
                try await service.start(reviewedPlan: reviewed, currentRequest: changed)
            }
            #expect(backend.beginCount == 0)
        }
        let (service, backend, timing, _, _) = fixture()
        let reviewed = try await service.prepare(request: request(), projectId: projectID)
        timing.now += 121
        await #expect(throws: ContextDemoCaptureError.staleReview) {
            try await service.start(reviewedPlan: reviewed, currentRequest: request())
        }
        #expect(backend.beginCount == 0)
    }

    @Test func successfulFinalizationPublishesPrivateCanonicalAssetAndReopensDigest() async throws {
        let (service, backend, _, inspector, root) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reviewed = try await service.prepare(request: request(), projectId: projectID)
        var callbackCount = 0
        let result = try await service.start(reviewedPlan: reviewed, currentRequest: request()) { callbackCount += 1 }
        #expect(callbackCount == 1 && backend.stopCount > 0 && inspector.inspectionCount == 1)
        #expect(result.asset.relativePath == (try ContextDemoAsset.relativePath(projectId: projectID, assetId: result.asset.id)))
        #expect(result.asset.requestId == "request-one" && result.asset.target == request().target)
        #expect(result.asset.durationSeconds == 1 && result.asset.sha256.count == 64)
        #expect(result.asset.byteSize == Int64(backend.initialBytes.count))
        #expect(try service.verifiedURL(for: result.asset) == result.url)
        var information = stat()
        #expect(lstat(result.url.path, &information) == 0 && information.st_mode & 0o777 == 0o600)
        #expect(!FileManager.default.fileExists(atPath: try #require(backend.outputURL).path))
        try service.discard(result.asset)
        #expect(!FileManager.default.fileExists(atPath: result.url.path))
        await #expect(throws: ContextDemoCaptureError.staleReview) {
            try await service.start(reviewedPlan: reviewed, currentRequest: request())
        }
    }

    @Test func failedStartRemovesPartialBeforeThrowing() async throws {
        let (service, backend, _, _, root) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        backend.failureAfterFileCreation = .failedToStart
        let reviewed = try await service.prepare(request: request(), projectId: projectID)
        await #expect(throws: ContextDemoCaptureError.failedToStart) {
            try await service.start(reviewedPlan: reviewed, currentRequest: request())
        }
        #expect(!FileManager.default.fileExists(atPath: try #require(backend.outputURL).deletingLastPathComponent().path))
        #expect(backend.stopCount > 0 && backend.releaseCount > 0)
    }

    @Test func cancelDuringStartAndLateInspectionDeletesEveryAsset() async throws {
        for cancelAtInspection in [false, true] {
            let (service, backend, _, inspector, root) = fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            if cancelAtInspection { inspector.onInspect = { service.cancel() } }
            else { backend.onBegin = { service.cancel() } }
            let reviewed = try await service.prepare(request: request(), projectId: projectID)
            await #expect(throws: CancellationError.self) {
                try await service.start(reviewedPlan: reviewed, currentRequest: request())
            }
            #expect(!FileManager.default.fileExists(atPath: try #require(backend.outputURL).deletingLastPathComponent().path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("context-demo/\(projectID)").path).isEmpty)
        }
    }

    @Test func taskCancellationAlsoCleansPartial() async throws {
        let (service, backend, _, _, root) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reviewed = try await service.prepare(request: request(), projectId: projectID)
        let operation = Task { @MainActor in
            try await service.start(reviewedPlan: reviewed, currentRequest: request()) {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(!FileManager.default.fileExists(atPath: try #require(backend.outputURL).deletingLastPathComponent().path))
    }

    @Test func writerTimeoutsAndByteBudgetFailClosed() async throws {
        for failure in [ContextDemoCaptureError.startTimedOut, .finalizationTimedOut, .fileBudgetExceeded] {
            let (service, backend, _, _, root) = fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            if failure == .startTimedOut { backend.beginsImmediately = false }
            if failure == .finalizationTimedOut { backend.finishesImmediately = false }
            if failure == .fileBudgetExceeded { backend.state.bytes = ContextDemoCaptureLimits.maximumBytes + 1 }
            let reviewed = try await service.prepare(request: request(), projectId: projectID)
            await #expect(throws: failure) {
                try await service.start(reviewedPlan: reviewed, currentRequest: request())
            }
            #expect(!FileManager.default.fileExists(atPath: try #require(backend.outputURL).deletingLastPathComponent().path))
        }
    }

    @Test func invalidReadbackCannotBecomeAcceptedAsset() async throws {
        for metadata in [ContextDemoRecordingMetadata(duration: .nan, width: 640, height: 480),
                         ContextDemoRecordingMetadata(duration: 2.1, width: 640, height: 480),
                         ContextDemoRecordingMetadata(duration: 1, width: 642, height: 480)] {
            let (service, backend, _, inspector, root) = fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            inspector.metadata = metadata
            let reviewed = try await service.prepare(request: request(), projectId: projectID)
            await #expect(throws: ContextDemoCaptureError.invalidRecording) {
                try await service.start(reviewedPlan: reviewed, currentRequest: request())
            }
            #expect(!FileManager.default.fileExists(atPath: try #require(backend.outputURL).deletingLastPathComponent().path))
        }
    }

    @Test func finishFromStartedCallbackFinalizesInsteadOfDiscarding() async throws {
        let (service, _, timing, _, root) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reviewed = try await service.prepare(request: request(), projectId: projectID)
        let before = timing.now
        let result = try await service.start(reviewedPlan: reviewed, currentRequest: request()) { service.finish() }
        #expect(timing.now == before && result.asset.durationSeconds == 1)
        try service.discard(result.asset)
    }

    @Test func geometryIsEvenBoundedAndNeverUpscaled() throws {
        let large = try ContextDemoCaptureLimits.geometry(demoCaptureTarget(width: 3841, height: 2161))
        #expect(large.width <= 1920 && large.height <= 1080)
        #expect(large.width.isMultiple(of: 2) && large.height.isMultiple(of: 2))
        let small = try ContextDemoCaptureLimits.geometry(demoCaptureTarget(width: 641, height: 481))
        #expect(small.width == 640 && small.height == 480)
        #expect(throws: ContextDemoCaptureError.invalidRequest) {
            try ContextDemoCaptureLimits.geometry(demoCaptureTarget(width: .infinity))
        }
    }

    @Test func nativeErrorsMapWithoutLeakingWindowOrOSDetails() {
        #expect(ContextDemoScreenCapture.map(NSError(domain: SCStreamErrorDomain, code: -3801)) == .permissionDenied)
        #expect(ContextDemoScreenCapture.map(NSError(domain: SCStreamErrorDomain, code: -3806)) == .targetUnavailable)
        #expect(ContextDemoScreenCapture.map(NSError(domain: SCStreamErrorDomain, code: -3802)) == .failedToStart)
        #expect(ContextDemoScreenCapture.map(NSError(domain: SCStreamErrorDomain, code: -3821)) == .interrupted)
    }
}
