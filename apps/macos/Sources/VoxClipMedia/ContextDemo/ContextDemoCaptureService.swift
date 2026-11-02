import Foundation
import VoxClipCore

public struct ContextDemoReviewedCapture: Sendable, Equatable {
    public let request: ContextDemoCaptureRequest
    public let projectId: String
    public let target: ContextDemoCaptureTarget
    public let pixelWidth: Int
    public let pixelHeight: Int
    fileprivate let token: UUID
    fileprivate let preparedUptime: Double
}

public struct ContextDemoCaptureResult: Sendable {
    public let asset: ContextDemoAsset
    public let url: URL
}

@MainActor public final class ContextDemoCaptureService {
    private let backend: any ContextDemoCaptureBackend
    private let inspector: any ContextDemoRecordingInspecting
    private let timing: any ContextDemoCaptureTiming
    private let store: ContextDemoAssetStore
    private var reviewed: ContextDemoReviewedCapture?
    private var reviewTurn = UUID()
    private var running = false
    private var cancelled = false
    private var finishing = false

    public convenience init(assetRoot: URL? = nil) {
        self.init(backend: ContextDemoScreenCapture(), inspector: ContextDemoRecordingInspector(),
                  timing: ContextDemoSystemTiming(), store: ContextDemoAssetStore(rootURL: assetRoot))
    }

    init(backend: any ContextDemoCaptureBackend, inspector: any ContextDemoRecordingInspecting,
         timing: any ContextDemoCaptureTiming, store: ContextDemoAssetStore) {
        self.backend = backend; self.inspector = inspector; self.timing = timing; self.store = store
    }

    public func availability() -> ContextDemoCaptureAvailability { backend.availability() }

    public func targets() async throws -> [ContextDemoCaptureTarget] {
        guard availability() == .available else { throw ContextDemoCaptureError.permissionRequired }
        return try await backend.windows()
    }

    public func prepare(request: ContextDemoCaptureRequest, projectId: String) async throws -> ContextDemoReviewedCapture {
        guard !running else { throw ContextDemoCaptureError.alreadyRecording }
        try request.validate()
        guard request.durationSeconds.isFinite, (1...ContextDemoCaptureLimits.maximumSeconds).contains(request.durationSeconds) else {
            throw ContextDemoCaptureError.invalidRequest
        }
        _ = try ContextDemoAsset.relativePath(projectId: projectId, assetId: UUID().uuidString.lowercased())
        let turn = UUID(); reviewTurn = turn; reviewed = nil
        let candidates = try await targets()
        try Task.checkCancellation()
        guard reviewTurn == turn, !running else { throw ContextDemoCaptureError.staleReview }
        let matches: [ContextDemoCaptureTarget]
        if let binding = request.window {
            matches = candidates.filter { $0.binding == binding }
        } else {
            guard request.target.kind == .desktopApp else { throw ContextDemoCaptureError.targetUnavailable }
            matches = candidates.filter { $0.bundleIdentifier == request.target.locator }
        }
        guard matches.count <= 1 else { throw ContextDemoCaptureError.ambiguousTarget }
        guard let target = matches.first else { throw ContextDemoCaptureError.targetUnavailable }
        if request.target.kind == .desktopApp {
            guard request.target.locator == target.bundleIdentifier else { throw ContextDemoCaptureError.staleReview }
        }
        let geometry = try ContextDemoCaptureLimits.geometry(target)
        let plan = ContextDemoReviewedCapture(request: request, projectId: projectId, target: target,
            pixelWidth: geometry.width, pixelHeight: geometry.height, token: UUID(), preparedUptime: timing.now)
        reviewed = plan
        return plan
    }

    public func start(reviewedPlan: ContextDemoReviewedCapture, currentRequest: ContextDemoCaptureRequest,
                      onStarted: (@MainActor () -> Void)? = nil) async throws -> ContextDemoCaptureResult {
        guard !running else { throw ContextDemoCaptureError.alreadyRecording }
        guard reviewed == reviewedPlan, currentRequest == reviewedPlan.request,
              timing.now >= reviewedPlan.preparedUptime, timing.now - reviewedPlan.preparedUptime <= 120 else {
            throw ContextDemoCaptureError.staleReview
        }
        reviewed = nil; running = true; cancelled = false; finishing = false
        var file: ContextDemoCaptureFile?
        var published = false
        defer { running = false; backend.release() }
        do {
            try checkCancellation()
            guard availability() == .available else { throw ContextDemoCaptureError.permissionRequired }
            let targets = try await backend.windows()
            try checkCancellation()
            guard targets.contains(reviewedPlan.target) else { throw ContextDemoCaptureError.staleReview }
            let captureFile = try store.create(projectId: reviewedPlan.projectId)
            file = captureFile
            let startDeadline = timing.now + ContextDemoCaptureLimits.startTimeout
            try await backend.begin(window: reviewedPlan.target, output: captureFile.partialURL,
                                    width: reviewedPlan.pixelWidth, height: reviewedPlan.pixelHeight)
            try checkCancellation()
            while !backend.snapshot().started {
                try checkSnapshot(captureFile)
                guard timing.now < startDeadline else { throw ContextDemoCaptureError.startTimedOut }
                try await timing.pause()
            }
            try checkSnapshot(captureFile)
            let captureDeadline = timing.now + max(0, currentRequest.durationSeconds - 0.1)
            onStarted?()
            while timing.now < captureDeadline, !finishing {
                try checkSnapshot(captureFile)
                try await timing.pause()
            }
            try checkSnapshot(captureFile)
            backend.stop()
            let finishDeadline = timing.now + ContextDemoCaptureLimits.finishTimeout
            while !backend.snapshot().finished || !backend.snapshot().stopped {
                try checkSnapshot(captureFile, finalizing: true)
                guard timing.now < finishDeadline else { throw ContextDemoCaptureError.finalizationTimedOut }
                try await timing.pause()
            }
            try checkSnapshot(captureFile, finalizing: true)
            let metadata = try await inspector.inspect(captureFile.partialURL)
            try checkCancellation()
            guard metadata.duration.isFinite, metadata.duration > 0,
                  metadata.duration <= currentRequest.durationSeconds,
                  metadata.width == reviewedPlan.pixelWidth, metadata.height == reviewedPlan.pixelHeight else {
                throw ContextDemoCaptureError.invalidRecording
            }
            let digest = try store.publish(captureFile)
            published = true
            let asset = ContextDemoAsset(id: captureFile.assetID, requestId: currentRequest.id,
                target: currentRequest.target, relativePath: captureFile.relativePath, sha256: digest.sha256,
                durationSeconds: metadata.duration, pixelWidth: metadata.width, pixelHeight: metadata.height,
                byteSize: Int64(digest.byteCount), createdAt: Date())
            try checkCancellation()
            let result = ContextDemoCaptureResult(asset: asset, url: try verifiedURL(for: asset))
            try store.complete(captureFile)
            return result
        } catch {
            await stopForCleanup()
            if let file { try store.remove(file, published: published) }
            if cancelled || error is CancellationError { throw CancellationError() }
            throw error
        }
    }

    public func finish() { if running { finishing = true } }

    public func cancel() {
        reviewTurn = UUID(); reviewed = nil
        if running { cancelled = true; backend.stop() }
    }

    public func discard(_ asset: ContextDemoAsset) throws {
        _ = try verifiedURL(for: asset, checkingCancellation: false)
        try store.remove(relativePath: asset.relativePath)
    }

    public func verifiedURL(for asset: ContextDemoAsset) throws -> URL {
        try verifiedURL(for: asset, checkingCancellation: true)
    }

    private func verifiedURL(for asset: ContextDemoAsset, checkingCancellation: Bool) throws -> URL {
        guard asset.byteSize > 0, asset.byteSize <= Int64(ContextDemoCaptureLimits.maximumBytes),
              asset.durationSeconds.isFinite, asset.durationSeconds > 0,
              asset.durationSeconds <= ContextDemoCaptureLimits.maximumSeconds,
              (2...ContextDemoCaptureLimits.maximumWidth).contains(asset.pixelWidth),
              asset.pixelWidth.isMultiple(of: 2),
              (2...ContextDemoCaptureLimits.maximumHeight).contains(asset.pixelHeight),
              asset.pixelHeight.isMultiple(of: 2),
              URL(fileURLWithPath: asset.relativePath).lastPathComponent == "\(asset.id).mp4" else {
            throw ContextDemoCaptureError.invalidRecording
        }
        return try store.verify(relativePath: asset.relativePath,
            expected: ContextDemoFileDigest(byteCount: Int(asset.byteSize), sha256: asset.sha256),
            checkingCancellation: checkingCancellation)
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
    }

    private func checkSnapshot(_ file: ContextDemoCaptureFile, finalizing: Bool = false) throws {
        try checkCancellation()
        let state = backend.snapshot()
        if let error = state.error { throw error }
        if (state.finished || state.stopped) && !finalizing { throw ContextDemoCaptureError.interrupted }
        guard state.bytes <= ContextDemoCaptureLimits.maximumBytes,
              try store.bytes(file) <= ContextDemoCaptureLimits.maximumBytes else {
            throw ContextDemoCaptureError.fileBudgetExceeded
        }
    }

    private func stopForCleanup() async {
        let backend = backend
        let timing = timing
        await Task { @MainActor in
            backend.stop()
            let deadline = timing.now + ContextDemoCaptureLimits.finishTimeout
            while timing.now < deadline {
                backend.stop()
                let state = backend.snapshot()
                if state.stopped && (state.finished || state.error != nil) { break }
                try? await timing.pause()
            }
            backend.release()
        }.value
    }
}
