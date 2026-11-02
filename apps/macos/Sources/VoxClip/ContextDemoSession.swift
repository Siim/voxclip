import Foundation
import Observation
import VoxClipCore
import VoxClipMedia

@MainActor protocol ContextDemoRecording: AnyObject {
    func checkAvailability()
    func unavailableReason(for kind: ContextDemoTargetKind) -> String?
    func targets() async throws -> [ContextDemoCaptureTarget]
    func prepare(target: ContextDemoTarget, window: ContextDemoCaptureTarget?, duration: Double,
                 document: ContextDemoDocument) async throws -> ContextDemoCaptureRequest
    func prepare(target: ContextDemoTarget, window: ContextDemoCaptureTarget?, duration: Double,
                 document: ContextDemoDocument, webActions: [ContextDemoWebAction],
                 allowsPageScripts: Bool) async throws -> ContextDemoCaptureRequest
    func prepare(desktopPlan: ContextDemoDesktopPlan, document: ContextDemoDocument) async throws -> ContextDemoCaptureRequest
    func recordDesktop(_ request: ContextDemoCaptureRequest,
                       current: @escaping @MainActor () -> ContextDemoDesktopCurrent?) async throws -> (asset: ContextDemoAsset, url: URL)
    func record(_ request: ContextDemoCaptureRequest, isCurrent: @escaping @MainActor () -> Bool) async throws -> (asset: ContextDemoAsset, url: URL)
    func finish()
    func cancel()
    func discard(_ asset: ContextDemoAsset)
    func verifiedURL(for asset: ContextDemoAsset) throws -> URL
}

extension ContextDemoRecording {
    func prepare(desktopPlan: ContextDemoDesktopPlan, document: ContextDemoDocument) async throws -> ContextDemoCaptureRequest {
        throw ContextDemoDesktopError.unsupportedAction
    }
    func recordDesktop(_ request: ContextDemoCaptureRequest,
                       current: @escaping @MainActor () -> ContextDemoDesktopCurrent?) async throws -> (asset: ContextDemoAsset, url: URL) {
        throw ContextDemoDesktopError.unsupportedAction
    }
    func prepare(target: ContextDemoTarget, window: ContextDemoCaptureTarget?, duration: Double,
                 document: ContextDemoDocument, webActions: [ContextDemoWebAction],
                 allowsPageScripts: Bool) async throws -> ContextDemoCaptureRequest {
        guard webActions.isEmpty, !allowsPageScripts else { throw ContextDemoPreparationError.invalidPlan }
        return try await prepare(target: target, window: window, duration: duration, document: document)
    }
}

enum ContextDemoUIError: Error {
    case unavailable(String)
    case staleReview
    case invalidResult
}

@MainActor @Observable final class ContextDemoSession {
    enum Phase: Equatable {
        case choosing, preparing, ready, recording, result, placed, stale, failed, closed
    }

    private(set) var phase = Phase.choosing
    private(set) var targetKind = ContextDemoTargetKind.webPage
    private(set) var urlText = ""
    private(set) var projectURL: URL?
    let projectLaunch: ContextDemoProjectLaunchSession
    let desktopReview: ContextDemoDesktopReviewSession
    private(set) var webActions: [ContextDemoWebAction] = []
    private(set) var allowsPageScripts = false
    private(set) var windows: [ContextDemoCaptureTarget] = []
    private(set) var selectedWindowID: UInt32?
    private(set) var captureSeconds: Double = 10
    private(set) var request: ContextDemoCaptureRequest?
    private(set) var document: ContextDemoDocument?
    private(set) var recordedAsset: ContextDemoAsset?
    private(set) var previewURL: URL?
    private(set) var selectedPlacementID: String?
    private(set) var trimStart: Double = 0
    private(set) var trimEnd: Double = 0
    private(set) var editedStart: Double = 0
    private(set) var message: String?
    private(set) var loadingWindows = false
    @ObservationIgnored private weak var model: EditorModel?
    @ObservationIgnored private let backend: any ContextDemoRecording
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var windowOperation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var windowGeneration = UUID()
    @ObservationIgnored private var snapshot: ContextDemoEditorSnapshot?
    @ObservationIgnored private var desktopInspectionSnapshot: ContextDemoEditorSnapshot?
    @ObservationIgnored private var replacingPlacementID: String?
    @ObservationIgnored private var securityScopedProjectURL: URL?
    @ObservationIgnored private var draftPlacementID = UUID().uuidString

    init(model: EditorModel, backend: (any ContextDemoRecording)? = nil,
         projectLaunch: ContextDemoProjectLaunchSession? = nil,
         desktopReview: ContextDemoDesktopReviewSession? = nil) {
        self.model = model
        self.projectLaunch = projectLaunch ?? ContextDemoProjectLaunchSession()
        let desktopReview = desktopReview ?? ContextDemoDesktopReviewSession()
        self.desktopReview = desktopReview
        self.backend = backend ?? ContextDemoLocalRecorder(capture: ContextDemoCaptureService(assetRoot: model.app.locations.root),
            desktopReview: desktopReview)
        self.document = model.contextDemoDocument
    }

    var busy: Bool { phase == .preparing || phase == .recording }
    var selectedWindow: ContextDemoCaptureTarget? { windows.first { $0.id == selectedWindowID } }
    var unavailableReason: String? {
        guard let model else { return "The source project is no longer open." }
        return model.contextDemoUnavailableReason ?? backend.unavailableReason(for: targetKind)
    }
    var canReview: Bool {
        (phase == .choosing || phase == .stale || phase == .failed) && !projectLaunch.busy && !desktopReview.isDraining && unavailableReason == nil && captureSeconds.isFinite
            && (1...30).contains(captureSeconds) && (try? target()) != nil
    }
    var inputReason: String? {
        do { _ = try target(); return nil }
        catch { return Self.message(for: error) }
    }
    var canStart: Bool {
        phase == .ready && !projectLaunch.busy && !desktopReview.isDraining && request != nil && unavailableReason == nil && isCurrent
            && (!desktopReview.usesActions || desktopCurrent(generation: generation) != nil)
    }
    var isCurrent: Bool {
        guard let model, let snapshot else { return false }
        return model.contextDemoIsCurrent(snapshot)
    }
    var selectedAsset: ContextDemoAsset? {
        if let recordedAsset { return recordedAsset }
        guard let placement = selectedPlacement else { return nil }
        return document?.assets.first { $0.id == placement.assetId }
    }
    var selectedPlacement: ContextDemoPlacement? {
        document?.placements.first { $0.id == selectedPlacementID }
    }
    var canApply: Bool {
        guard phase == .result || phase == .placed, isCurrent, let placement = draftPlacement,
              recordedAsset != nil || placement != selectedPlacement else { return false }
        return placementReason == nil
    }
    var placementReason: String? {
        guard phase == .result || phase == .placed, let asset = selectedAsset, let document,
              let placement = draftPlacement else { return nil }
        guard trimStart.isFinite, trimEnd.isFinite, editedStart.isFinite,
              trimStart >= 0, trimEnd > trimStart, trimEnd <= asset.durationSeconds, editedStart >= 0 else {
            return "Choose a capture in/out range within the recorded file and a nonnegative narration position."
        }
        do {
            _ = try document.placing(asset: asset, placement: placement, expectedRevision: document.revision)
            return nil
        } catch { return Self.message(for: error) }
    }
    private var draftPlacement: ContextDemoPlacement? {
        guard let asset = selectedAsset else { return nil }
        return ContextDemoPlacement(id: selectedPlacementID ?? draftPlacementID, assetId: asset.id,
            source: TimeRange(start: trimStart, end: trimEnd), editedStartSeconds: editedStart)
    }

    func chooseKind(_ kind: ContextDemoTargetKind) {
        guard kind != targetKind, !busy, phase != .closed else { return }
        projectLaunch.stop()
        invalidateReview()
        targetKind = kind
    }
    func setURL(_ text: String) {
        guard text != urlText, !busy, phase != .closed else { return }
        invalidateReview()
        urlText = text
    }
    func setAllowsPageScripts(_ allowed: Bool) {
        guard allowed != allowsPageScripts, !busy, phase != .closed else { return }
        invalidateReview()
        allowsPageScripts = allowed
    }
    func appendWebAction(_ action: ContextDemoWebAction) {
        guard !busy, phase != .closed, targetKind == .webPage else { return }
        do {
            switch action {
            case .navigate: throw ContextDemoPreparationError.invalidPlan
            case .scroll, .pause, .followLink: break
            }
            _ = try ContextDemoWebPlan.prepare(url: urlText, revision: "draft", actions: webActions + [action])
            invalidateReview()
            webActions.append(action)
        } catch { message = Self.message(for: error) }
    }
    func appendWebLink(elementID: String, destination: String) {
        guard !busy, phase != .closed, targetKind == .webPage else { return }
        do { appendWebAction(.followLink(elementID: elementID, destination: try ContextDemoURLPolicy.validate(destination))) }
        catch { message = Self.message(for: error) }
    }
    func removeWebAction(at index: Int) {
        guard !busy, phase != .closed, webActions.indices.contains(index) else { return }
        invalidateReview()
        webActions.remove(at: index)
    }
    func useProjectPreviewURL(_ text: String) {
        guard !busy, !projectLaunch.busy, phase != .closed else { return }
        do {
            _ = try ContextDemoURLPolicy.validate(text)
            setURL(text)
            chooseKind(.webPage)
        } catch { message = Self.message(for: error) }
    }
    func chooseProject(_ url: URL) {
        guard !busy, !desktopReview.isDraining, phase != .closed else { return }
        invalidateReview()
        securityScopedProjectURL?.stopAccessingSecurityScopedResource()
        securityScopedProjectURL = url.startAccessingSecurityScopedResource() ? url : nil
        projectURL = url
        projectLaunch.chooseDirectory(url)
    }
    func chooseWindow(_ id: UInt32?) {
        guard selectedWindowID != id, !busy, phase != .closed else { return }
        invalidateReview()
        selectedWindowID = id
    }
    func setCaptureSeconds(_ value: Double) {
        guard value.isFinite, (1...30).contains(value), value != captureSeconds, !busy, phase != .closed else { return }
        invalidateReview(preservingDesktopInspection: true)
        captureSeconds = value
    }
    func setTrim(start: Double, end: Double, editedStart: Double) {
        guard !busy, phase != .closed else { return }
        guard let rate = document?.narration.sampleRate, rate.isFinite, rate > 0 else { return }
        trimStart = start.isFinite ? (start * rate).rounded() / rate : start
        if let asset = selectedAsset, end.isFinite, end >= asset.durationSeconds {
            trimEnd = floor(end * rate) / rate
        } else { trimEnd = end.isFinite ? (end * rate).rounded() / rate : end }
        self.editedStart = editedStart.isFinite ? (editedStart * rate).rounded() / rate : editedStart
    }

    func checkCaptureAccess() {
        guard !busy, phase != .closed else { return }
        backend.checkAvailability()
        message = backend.unavailableReason(for: targetKind)
            ?? "Screen Recording access is available. Review the webpage capture, or refresh and choose an exact app window. Nothing has started."
    }

    func checkDesktopAccess() {
        guard !busy, !desktopReview.isDraining, phase != .closed, targetKind != .webPage else { return }
        invalidateReview()
        desktopReview.checkAccess()
    }

    func inspectDesktopWindow() {
        guard !busy, !desktopReview.isDraining, phase != .closed, targetKind != .webPage,
              let window = selectedWindow, desktopReview.canInspect else { return }
        invalidateReview()
        desktopReview.inspect(window: window)
        if desktopReview.snapshot != nil { desktopInspectionSnapshot = model?.contextDemoSnapshot() }
    }

    func appendDesktopAction(_ action: ContextDemoDesktopAction) {
        guard !busy, !desktopReview.isDraining, phase != .closed, targetKind != .webPage,
              desktopReview.matches(window: selectedWindow), let model, let desktopInspectionSnapshot,
              model.contextDemoIsCurrent(desktopInspectionSnapshot) else { return }
        invalidateReview(preservingDesktopInspection: true)
        desktopReview.append(action, duration: captureSeconds)
    }

    func removeDesktopAction(at index: Int) {
        guard !busy, !desktopReview.isDraining, phase != .closed else { return }
        invalidateReview(preservingDesktopInspection: true)
        desktopReview.removeAction(at: index)
    }

    private func desktopCurrent(generation token: UUID) -> ContextDemoDesktopCurrent? {
        guard generation == token, phase != .closed, isCurrent, let model, let request,
              let plan = desktopReview.plan, request == plan.request,
              desktopReview.matches(window: selectedWindow), let desktopInspectionSnapshot,
              model.contextDemoIsCurrent(desktopInspectionSnapshot) else { return nil }
        return ContextDemoDesktopCurrent(request: request, sourceContentKey: model.project.media.source.contentKey)
    }

    func refreshWindows() {
        guard !busy, !loadingWindows, phase != .closed else { return }
        guard let reason = backend.unavailableReason(for: .desktopApp) else {
            let token = UUID()
            windowGeneration = token
            loadingWindows = true
            windowOperation = Task { [weak self, backend] in
                do {
                    let targets = try await backend.targets()
                    guard let self, self.windowGeneration == token, !Task.isCancelled, self.phase != .closed else { return }
                    self.windows = targets
                    self.loadingWindows = false
                    if self.desktopReview.snapshot != nil, !self.desktopReview.matches(window: self.selectedWindow) {
                        self.invalidateReview()
                    }
                    if let selected = self.selectedWindowID, !targets.contains(where: { $0.id == selected }) {
                        self.chooseWindow(nil)
                    }
                    self.message = targets.isEmpty ? "No recordable app windows were found. Open the app, then refresh the list." : nil
                } catch {
                    guard let self, self.windowGeneration == token, !Task.isCancelled else { return }
                    self.loadingWindows = false
                    self.message = Self.message(for: error)
                }
            }
            return
        }
        message = reason
    }

    func review() {
        guard canReview, let model else { return }
        if desktopReview.usesActions {
            guard let desktopInspectionSnapshot, model.contextDemoIsCurrent(desktopInspectionSnapshot),
                  desktopReview.matches(window: selectedWindow) else {
                invalidateReview()
                message = ContextDemoDesktopError.stalePlan.errorDescription
                return
            }
        }
        invalidateReview(preservingDesktopInspection: true)
        do {
            let target = try target()
            let document = try model.contextDemoDraftDocument()
            let expected = model.contextDemoSnapshot()
            let token = generation
            snapshot = expected
            self.document = document
            let position = try replacingPlacementID.flatMap { id in document.placements.first { $0.id == id }?.editedStartSeconds }
                ?? model.contextDemoPlayheadPosition()
            editedStart = (position * document.narration.sampleRate).rounded() / document.narration.sampleRate
            phase = .preparing
            let window = selectedWindow
            let seconds = captureSeconds
            let actions = targetKind == .webPage ? webActions : []
            let pageScripts = targetKind == .webPage && allowsPageScripts
            let desktopPlan = targetKind == .webPage ? nil : try desktopReview.prepare(
                request: ContextDemoCaptureRequest(id: UUID().uuidString, planId: document.planId,
                    revision: document.revision, target: target, durationSeconds: seconds, window: window?.binding),
                sourceContentKey: model.project.media.source.contentKey)
            operation = Task { [weak self, backend] in
                do {
                    let request: ContextDemoCaptureRequest
                    if let desktopPlan {
                        request = try await backend.prepare(desktopPlan: desktopPlan, document: document)
                        guard request == desktopPlan.request else { throw ContextDemoDesktopError.stalePlan }
                    } else {
                        request = try await backend.prepare(target: target, window: window, duration: seconds,
                            document: document, webActions: actions, allowsPageScripts: pageScripts)
                    }
                    try request.validate()
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    guard self.isCurrent else { self.followEditor(); return }
                    guard request.target == target, request.planId == document.planId, request.revision == document.revision,
                          request.durationSeconds == seconds else { throw ContextDemoUIError.staleReview }
                    if target.kind == .webPage, !actions.isEmpty || pageScripts {
                        let expected = try ContextDemoAutomation.prepare(request: request, actions: actions)
                        guard expected.request == request else { throw ContextDemoUIError.staleReview }
                    }
                    self.request = request
                    self.phase = .ready
                    self.operation = nil
                } catch {
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.fail(error)
                }
            }
        } catch { fail(error) }
    }

    func start() {
        guard canStart, let request else { return }
        let token = generation
        let desktopActions = desktopReview.usesActions
        phase = .recording
        message = nil
        operation = Task { [weak self, backend] in
            do {
                let result: (asset: ContextDemoAsset, url: URL)
                if desktopActions {
                    result = try await backend.recordDesktop(request) { [weak self] in
                        self?.desktopCurrent(generation: token)
                    }
                } else {
                    result = try await backend.record(request) { [weak self] in
                        guard let self else { return false }
                        return self.generation == token && self.isCurrent
                    }
                }
                guard let self, self.generation == token, !Task.isCancelled else {
                    backend.discard(result.asset)
                    return
                }
                guard self.isCurrent else {
                    backend.discard(result.asset)
                    self.followEditor()
                    return
                }
                guard result.asset.requestId == request.id, result.asset.target == request.target,
                      result.asset.durationSeconds.isFinite, result.asset.durationSeconds > 0,
                      result.asset.durationSeconds <= request.durationSeconds + 0.5,
                      let document = self.document else {
                    backend.discard(result.asset)
                    throw ContextDemoUIError.invalidResult
                }
                do {
                    _ = try document.addingAsset(result.asset, expectedRevision: document.revision)
                    guard result.url.isFileURL, try backend.verifiedURL(for: result.asset) == result.url else {
                        throw ContextDemoUIError.invalidResult
                    }
                }
                catch { backend.discard(result.asset); throw error }
                self.recordedAsset = result.asset
                self.previewURL = result.url
                self.trimStart = 0
                let available = min(result.asset.durationSeconds, max(0, document.narration.durationSeconds - self.editedStart))
                self.trimEnd = floor(available * document.narration.sampleRate) / document.narration.sampleRate
                self.phase = .result
                self.operation = nil
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.fail(error)
            }
        }
    }

    func finishRecording() {
        guard phase == .recording else { return }
        backend.finish()
    }

    func cancel() {
        guard phase != .closed else { return }
        projectLaunch.stop()
        desktopReview.invalidateInspection()
        desktopInspectionSnapshot = nil
        guard phase == .preparing || phase == .ready || phase == .recording else {
            backend.cancel()
            return
        }
        generation = UUID()
        operation?.cancel()
        operation = nil
        backend.cancel()
        request = nil
        snapshot = nil
        phase = recordedAsset == nil ? .choosing : .result
        message = nil
    }

    func followEditor() {
        guard phase != .closed, let model else { return }
        if let desktopInspectionSnapshot, !model.contextDemoIsCurrent(desktopInspectionSnapshot) {
            desktopReview.invalidateInspection()
            self.desktopInspectionSnapshot = nil
            backend.cancel()
        }
        if let snapshot, !model.contextDemoIsCurrent(snapshot) {
            generation = UUID()
            operation?.cancel()
            operation = nil
            backend.cancel()
            request = nil
            self.snapshot = nil
            phase = .stale
            message = "The source narration, selection or project changed. Review a new capture before placing this result. Your media and edits are safe."
        }
        document = model.contextDemoDocument
    }

    func selectPlacement(_ id: String) {
        guard !busy, phase != .closed, let model else { return }
        replacingPlacementID = nil
        invalidateReview()
        document = model.contextDemoDocument
        guard let document, let placement = document.placements.first(where: { $0.id == id }),
              let asset = document.assets.first(where: { $0.id == placement.assetId }) else { return }
        do {
            previewURL = try backend.verifiedURL(for: asset)
            selectedPlacementID = id
            trimStart = placement.source.start
            trimEnd = placement.source.end
            editedStart = placement.editedStartSeconds
            snapshot = model.contextDemoSnapshot()
            phase = .placed
        } catch { fail(error) }
    }

    @discardableResult func apply() -> Bool {
        guard canApply, let model, var next = document, let placement = draftPlacement, let snapshot else { return false }
        do {
            if let recordedAsset { next = try next.placing(asset: recordedAsset, placement: placement, expectedRevision: next.revision) }
            else { next = try next.replacingPlacement(placement, expectedRevision: next.revision) }
            let name = selectedPlacementID == nil ? "Place context demonstration" : recordedAsset == nil
                ? "Trim context demonstration" : "Replace context demonstration"
            guard try model.commitContextDemoDocument(next, expected: snapshot, name: name) else { return false }
            document = model.contextDemoDocument
            recordedAsset = nil
            selectedPlacementID = placement.id
            replacingPlacementID = nil
            self.snapshot = model.contextDemoSnapshot()
            request = nil
            phase = .placed
            message = "Demonstration placed. Your source narration continues underneath; capture audio is muted."
            return true
        } catch {
            if !isCurrent { followEditor() }
            else { message = Self.message(for: error) }
            return false
        }
    }

    func replaceSelected() {
        guard !busy, let id = selectedPlacementID, phase != .closed else { return }
        replacingPlacementID = id
        invalidateReview()
        selectedPlacementID = id
        phase = .choosing
        message = "Choose and review a new recording. The existing demonstration stays in the project until you apply its replacement."
    }

    @discardableResult func removeSelected() -> Bool {
        guard !busy, phase != .closed, let model, let id = selectedPlacementID,
              let document = model.contextDemoDocument else { return false }
        do {
            let next = try document.removingPlacement(id: id, expectedRevision: document.revision)
            guard try model.commitContextDemoDocument(next, expected: model.contextDemoSnapshot(), name: "Remove context demonstration") else { return false }
            replacingPlacementID = nil
            invalidateReview()
            self.document = model.contextDemoDocument
            message = "Demonstration removed. Your source media and narration are unchanged. Undo restores the placement."
            return true
        } catch { fail(error); return false }
    }

    func close() {
        guard phase != .closed else { return }
        let desktopOperation = desktopReview.usesActions || desktopReview.isDraining
            || request?.actions.first?.id == "desktop-plan" ? operation : nil
        cancel()
        projectLaunch.close()
        windowGeneration = UUID()
        windowOperation?.cancel()
        windowOperation = nil
        loadingWindows = false
        discardDraft()
        let scopedProjectURL = securityScopedProjectURL
        securityScopedProjectURL = nil
        if desktopReview.isDraining || desktopOperation != nil {
            Task { @MainActor [desktopReview, desktopOperation] in
                if let desktopOperation { await desktopOperation.value }
                await desktopReview.drain()
                scopedProjectURL?.stopAccessingSecurityScopedResource()
            }
        } else { scopedProjectURL?.stopAccessingSecurityScopedResource() }
        phase = .closed
    }

    func newCapture() {
        guard !busy, phase != .closed else { return }
        replacingPlacementID = nil
        invalidateReview()
    }

    private func target() throws -> ContextDemoTarget {
        switch targetKind {
        case .webPage:
            let url = try ContextDemoURLPolicy.validate(urlText)
            return ContextDemoTarget(kind: .webPage, displayName: url.host ?? "Webpage", locator: url.absoluteString)
        case .codeProject:
            guard let projectURL, projectURL.isFileURL, selectedWindow != nil else {
                throw ContextDemoUIError.unavailable("Choose a project folder and the exact running app window to record. No project command runs automatically.")
            }
            return ContextDemoTarget(kind: .codeProject, displayName: projectURL.lastPathComponent, locator: projectURL.absoluteString)
        case .desktopApp:
            guard let window = selectedWindow else {
                throw ContextDemoUIError.unavailable("Choose the exact running app window to record.")
            }
            return ContextDemoTarget(kind: .desktopApp, displayName: window.applicationName, locator: window.binding.bundleID)
        }
    }

    private func invalidateReview(preservingDesktopInspection: Bool = false) {
        if !preservingDesktopInspection {
            desktopReview.invalidateInspection()
            desktopInspectionSnapshot = nil
        }
        generation = UUID()
        draftPlacementID = UUID().uuidString
        operation?.cancel()
        operation = nil
        backend.cancel()
        request = nil
        snapshot = nil
        discardDraft()
        selectedPlacementID = replacingPlacementID
        phase = .choosing
        message = nil
    }
    private func discardDraft() {
        previewURL = nil
        if let recordedAsset { backend.discard(recordedAsset) }
        recordedAsset = nil
    }
    private func fail(_ error: Error) {
        operation = nil
        if error is CancellationError || (error as? ContextDemoError) == .cancelled {
            phase = .choosing
            message = nil
            return
        }
        phase = .failed
        message = Self.message(for: error)
    }
    static func message(for error: Error) -> String {
        switch error {
        case let error as ContextDemoDesktopError: error.errorDescription ?? "The exact selected window could not be automated. Manual recording remains available."
        case let error as ContextDemoPreparationError: error.userMessage
        case let error as ContextDemoBrowserError: error.userMessage
        case let error as ContextDemoCaptureError:
            switch error {
            case .permissionRequired, .permissionDenied:
                "Screen Recording access is not granted to VoxClip. Enable it in System Settings → Privacy & Security → Screen & System Audio Recording, then refresh. No permission request was made."
            case .targetUnavailable, .ambiguousTarget:
                "The selected window is unavailable or ambiguous. Refresh the window list and review the exact app window again."
            case .staleReview:
                "The selected app window or capture review changed or expired. Review the capture again."
            case .alreadyRecording:
                "A demonstration recording is still stopping. Wait for it to finish before starting another."
            case .encoderUnavailable:
                "The local H.264 recording encoder is unavailable. No capture was placed."
            case .fileBudgetExceeded:
                "The recording exceeded the 64 MiB local file limit and was discarded. Review a shorter capture."
            case .unsafeStorage:
                "The local demonstration storage is unsafe or unavailable. No capture was placed."
            case .invalidRecording:
                "The recorded file could not be verified as a usable local video. No capture was placed."
            case .startTimedOut, .finalizationTimedOut, .failedToStart, .interrupted, .invalidRequest:
                "The local recording did not complete safely. Review a shorter capture and try again. Your source media and edits are safe."
            }
        case ContextDemoUIError.unavailable(let reason): reason
        case ContextDemoUIError.staleReview, ContextDemoError.staleRevision, ContextDemoError.staleNarration:
            "The reviewed capture or source narration changed. Review it again before continuing. Your media and edits are safe."
        case ContextDemoError.unsupportedProjectPersistence:
            "Demonstration persistence is not connected to this project format yet. Nothing was placed or saved. Your media and edits are safe."
        case ContextDemoError.invalidPlacement, ContextDemoError.overlappingPlacements:
            "The trim must fit the narration and must not overlap another demonstration. Nothing was changed."
        case is CancellationError, ContextDemoError.cancelled: ""
        default:
            "The demonstration could not be prepared or recorded. Nothing was placed. Your media and edits are safe."
        }
    }
}

@MainActor final class ContextDemoWebCaptureLifetime {
    private(set) var isCancelled = false
    private(set) var browserFinished = false
    private(set) var browserFailure: Error?
    private var action: Task<Void, Never>?
    private var closed = false
    private let cancelCapture: @MainActor () -> Void
    private let stopBrowser: @MainActor () -> Void
    private let closeBrowser: @MainActor () -> Void

    init(cancelCapture: @escaping @MainActor () -> Void, stopBrowser: @escaping @MainActor () -> Void,
         closeBrowser: @escaping @MainActor () -> Void) {
        self.cancelCapture = cancelCapture
        self.stopBrowser = stopBrowser
        self.closeBrowser = closeBrowser
    }

    func retainAction(_ task: Task<Void, Never>) {
        guard !isCancelled, !closed else { task.cancel(); return }
        action = task
    }

    func actionsFinished() {
        guard !isCancelled, !closed else { return }
        browserFinished = true
    }

    func actionsFailed(_ error: Error) {
        guard !isCancelled, !closed else { return }
        browserFailure = error
        cancel()
    }

    func invalidate() { actionsFailed(ContextDemoBrowserError.targetUnavailable) }

    func cancel() {
        guard !isCancelled, !closed else { return }
        isCancelled = true
        cancelCapture()
        action?.cancel()
        stopBrowser()
    }

    func drainActions() async {
        action?.cancel()
        stopBrowser()
        if let action { await action.value }
        action = nil
    }

    func closeAfterCaptureDrained() {
        guard !closed else { return }
        closed = true
        closeBrowser()
    }
}

@MainActor final class ContextDemoLocalRecorder: ContextDemoRecording {
    private let capture: ContextDemoCaptureService
    private let desktopReview: ContextDemoDesktopReviewSession
    private let inspector = ContextDemoProjectInspector()
    private var reviewed: ContextDemoReviewedCapture?
    private var projectFacts: ContextDemoProjectSnapshot?
    private var browserReview: ContextDemoBrowserReview?
    private var reviewedPageScripts = false
    private var browser: ContextDemoBrowserSession?
    private var webCapture: ContextDemoWebCaptureLifetime?
    private var checkedAvailability: ContextDemoCaptureAvailability?

    init(capture: ContextDemoCaptureService = ContextDemoCaptureService(),
         desktopReview: ContextDemoDesktopReviewSession? = nil) {
        self.capture = capture
        self.desktopReview = desktopReview ?? ContextDemoDesktopReviewSession()
    }

    func unavailableReason(for kind: ContextDemoTargetKind) -> String? {
        guard let checkedAvailability else {
            return "Screen Recording access has not been checked. Choose Check Screen Recording Access. This checks the current grant without showing a permission prompt or starting a recording."
        }
        if checkedAvailability != .available { return ContextDemoSession.message(for: ContextDemoCaptureError.permissionRequired) }
        return nil
    }

    func checkAvailability() { checkedAvailability = capture.availability() }

    func targets() async throws -> [ContextDemoCaptureTarget] { try await capture.targets() }

    func prepare(desktopPlan: ContextDemoDesktopPlan, document: ContextDemoDocument) async throws -> ContextDemoCaptureRequest {
        guard !desktopReview.isDraining else { throw ContextDemoDesktopError.alreadyRunning }
        guard webCapture == nil else { throw ContextDemoCaptureError.alreadyRecording }
        cancel()
        return try await desktopReview.prepareCapture(plan: desktopPlan, document: document, capture: capture)
    }

    func recordDesktop(_ request: ContextDemoCaptureRequest,
                       current: @escaping @MainActor () -> ContextDemoDesktopCurrent?) async throws -> (asset: ContextDemoAsset, url: URL) {
        guard webCapture == nil else { throw ContextDemoCaptureError.alreadyRecording }
        let result = try await desktopReview.record(request: request, capture: capture, current: current)
        return (result.asset, result.url)
    }

    func prepare(target: ContextDemoTarget, window: ContextDemoCaptureTarget?, duration: Double,
                 document: ContextDemoDocument) async throws -> ContextDemoCaptureRequest {
        try await prepare(target: target, window: window, duration: duration, document: document,
            webActions: [], allowsPageScripts: false)
    }

    func prepare(target: ContextDemoTarget, window: ContextDemoCaptureTarget?, duration: Double,
                 document: ContextDemoDocument, webActions: [ContextDemoWebAction],
                 allowsPageScripts: Bool) async throws -> ContextDemoCaptureRequest {
        guard !desktopReview.isDraining else { throw ContextDemoDesktopError.alreadyRunning }
        cancel()
        guard target.kind == .webPage || (webActions.isEmpty && !allowsPageScripts) else {
            throw ContextDemoPreparationError.invalidPlan
        }
        guard duration.isFinite, (1...30).contains(duration) else { throw ContextDemoCaptureError.invalidRequest }
        if target.kind == .webPage {
            let request = ContextDemoCaptureRequest(id: UUID().uuidString, planId: document.planId,
                revision: document.revision, target: target, durationSeconds: duration)
            let review = try ContextDemoAutomation.prepare(request: request, actions: webActions)
            browserReview = review
            reviewedPageScripts = allowsPageScripts
            webProjectID = document.projectId
            return review.request
        }
        guard let window else { throw ContextDemoCaptureError.targetUnavailable }
        var actions = [ContextDemoReviewedAction(id: "capture-window", summary:
            "Record only \(window.applicationName) — \(window.windowTitle), window \(window.id), for up to \(Int(duration)) seconds. No other windows, microphone or system audio are recorded."),
            ContextDemoReviewedAction(id: "manual-interactions", summary:
            "You demonstrate the actions in this window. VoxClip does not click, type, change files or run commands automatically.")]
        if target.kind == .codeProject {
            guard let directory = URL(string: target.locator) else { throw ContextDemoPreparationError.invalidDirectory }
            let approval = try ContextDemoProjectReadApproval.approve(selectedDirectory: directory)
            let facts = try await inspector.inspect(approval: approval)
            try Task.checkCancellation()
            projectFacts = facts
            actions.append(ContextDemoReviewedAction(id: "project-facts", summary:
                "Use the selected project folder \(directory.lastPathComponent). Read-only facts checked: \(facts.files.map(\.name).joined(separator: ", ")). No dependencies, scripts or server will be started."))
        }
        let request = ContextDemoCaptureRequest(id: UUID().uuidString, planId: document.planId,
            revision: document.revision, target: target, durationSeconds: duration, window: window.binding, actions: actions)
        reviewed = try await capture.prepare(request: request, projectId: document.projectId)
        return request
    }

    func record(_ request: ContextDemoCaptureRequest, isCurrent: @escaping @MainActor () -> Bool) async throws -> (asset: ContextDemoAsset, url: URL) {
        guard desktopReview.plan == nil, !desktopReview.isDraining else { throw ContextDemoDesktopError.stalePlan }
        guard isCurrent() else { throw ContextDemoUIError.staleReview }
        if request.target.kind == .webPage { return try await recordWebPage(request, isCurrent: isCurrent) }
        guard let reviewed, reviewed.request == request else { throw ContextDemoCaptureError.staleReview }
        if let projectFacts { try await inspector.validateCurrent(projectFacts) }
        try Task.checkCancellation()
        guard isCurrent() else { throw ContextDemoUIError.staleReview }
        let result = try await capture.start(reviewedPlan: reviewed, currentRequest: request)
        self.reviewed = nil
        return (result.asset, result.url)
    }

    private func recordWebPage(_ request: ContextDemoCaptureRequest, isCurrent: @escaping @MainActor () -> Bool) async throws -> (asset: ContextDemoAsset, url: URL) {
        guard webCapture == nil else { throw ContextDemoCaptureError.alreadyRecording }
        guard let review = browserReview, review.request == request, let projectID = webProjectID else {
            throw ContextDemoPreparationError.stalePlan
        }
        let approval = try review.approve(currentRequest: request)
        let allowsPageScripts = reviewedPageScripts
        let browser = ContextDemoBrowserSession()
        let lifetime = ContextDemoWebCaptureLifetime(cancelCapture: { [weak self, weak browser] in
            guard let self, let browser, self.browser === browser else { return }
            self.capture.cancel()
        }, stopBrowser: { browser.stop() }, closeBrowser: { browser.cancel() })
        self.browser = browser
        webCapture = lifetime
        browserReview = nil
        webProjectID = nil
        browser.onInvalidated = { [weak self, weak browser, weak lifetime] in
            guard let self, let browser, let lifetime,
                  self.browser === browser, self.webCapture === lifetime else { return }
            lifetime.invalidate()
        }
        defer {
            lifetime.closeAfterCaptureDrained()
            if self.browser === browser { self.browser = nil }
            if webCapture === lifetime { webCapture = nil }
        }
        do {
            let target = try browser.start(review: review, approval: approval, currentRequest: request,
                allowsPageScripts: allowsPageScripts)
            let captureRequest = try review.captureRequest(window: target.window)
            let captureReview = try await capture.prepare(request: captureRequest, projectId: projectID)
            try Task.checkCancellation()
            _ = try browser.validatedCaptureTarget()
            guard webCapture === lifetime, !lifetime.isCancelled, isCurrent() else { throw ContextDemoPreparationError.stalePlan }
            let result = try await capture.start(reviewedPlan: captureReview, currentRequest: captureRequest) { [weak self, weak browser, weak lifetime] in
                guard let self, let browser, let lifetime, self.webCapture === lifetime else { return }
                guard !lifetime.isCancelled, isCurrent() else { lifetime.cancel(); return }
                lifetime.retainAction(Task { [weak self, weak lifetime, browser] in
                    do {
                        try await browser.run { [weak self, weak lifetime] in
                            guard let self, let lifetime, self.webCapture === lifetime,
                                  !lifetime.isCancelled, isCurrent() else { return nil }
                            return request
                        }
                        guard let self, let lifetime, self.webCapture === lifetime, !Task.isCancelled else { return }
                        lifetime.actionsFinished()
                    } catch {
                        guard let self, let lifetime, self.webCapture === lifetime, !Task.isCancelled else { return }
                        lifetime.actionsFailed(error)
                    }
                })
            }
            let actionsFinished = lifetime.browserFinished && lifetime.browserFailure == nil && !lifetime.isCancelled
            await lifetime.drainActions()
            guard actionsFinished, !lifetime.isCancelled else {
                try capture.discard(result.asset)
                throw lifetime.browserFailure ?? ContextDemoBrowserError.navigationTimedOut
            }
            do {
                try Task.checkCancellation()
                _ = try browser.validatedCaptureTarget()
                guard isCurrent() else { throw ContextDemoPreparationError.stalePlan }
            } catch {
                try capture.discard(result.asset)
                throw error
            }
            return (result.asset, result.url)
        } catch {
            lifetime.cancel()
            await lifetime.drainActions()
            throw lifetime.browserFailure ?? error
        }
    }

    private var webProjectID: String?

    func finish() { capture.finish() }
    func cancel() {
        desktopReview.cancelCapture()
        if let webCapture { webCapture.cancel() } else { capture.cancel() }
        reviewed = nil
        projectFacts = nil
        webProjectID = nil
        browserReview = nil
        reviewedPageScripts = false
    }
    func discard(_ asset: ContextDemoAsset) { try? capture.discard(asset) }
    func verifiedURL(for asset: ContextDemoAsset) throws -> URL { try capture.verifiedURL(for: asset) }
}
