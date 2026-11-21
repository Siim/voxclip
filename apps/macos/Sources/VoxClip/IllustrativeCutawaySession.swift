import Foundation
import VoxClipCore
import VoxClipMedia

struct IllustrativeCutawayReviewRequest {
    let id = UUID()
    let snapshot: ContextDemoEditorSnapshot
    let clipID: String?
}

extension EditorModel {
    func openGeneratedIllustrationReview() {
        let request = IllustrativeCutawayReviewRequest(snapshot: contextDemoSnapshot(), clipID: activeClip?.id)
        openContextDemoJob()
        contextDemoSession?.illustrationReviewRequest = request
    }
}

@MainActor @Observable final class IllustrativeCutawaySession {
    struct SheetRequest: Identifiable, Equatable {
        let id: UUID
        let prompt: String
    }

    enum Readiness {
        case ready(IllustrativeCutawaySelection)
        case unavailable(String)
    }

    private struct Review {
        let id = UUID()
        let selection: IllustrativeCutawaySelection
        let snapshot: ContextDemoEditorSnapshot
        let clipID: String?
        let document: ContextDemoDocument
    }

    @ObservationIgnored private weak var model: EditorModel?
    @ObservationIgnored private let assets: IllustrativeCutawayAssets
    private var review: Review?
    private(set) var sheetRequest: SheetRequest?
    private(set) var preparation: Task<Void, Never>?
    private(set) var draft: IllustrativeCutawayDraft?
    private(set) var message: String?
    var prompt = ""

    var selection: IllustrativeCutawaySelection? { review?.selection }
    var busy: Bool { sheetRequest != nil || preparation != nil }
    var canOpenSheet: Bool { isCurrent && !busy && draft == nil && IllustrativeCutawaySelection.reviewedPrompt(prompt) != nil }
    var canApply: Bool { isCurrent && !busy && draft != nil }
    var readiness: Readiness {
        guard let model else { return .unavailable("Open a project to illustrate a phrase.") }
        if let reason = model.contextDemoUnavailableReason { return .unavailable(reason) }
        guard !model.selectedWordIDs.isEmpty else { return .unavailable("Select a phrase in the transcript first.") }
        do { return .ready(try makeReview(model).selection) }
        catch { return .unavailable(Self.message(error, fallback: .stale)) }
    }

    init(model: EditorModel, assets: IllustrativeCutawayAssets? = nil) {
        self.model = model
        self.assets = assets ?? IllustrativeCutawayAssets(root: model.app.locations.root)
    }

    func reviewSelection(expected: IllustrativeCutawayReviewRequest? = nil) {
        guard !busy || expected != nil, let model else { return }
        reset()
        if let reason = model.contextDemoUnavailableReason { message = reason; return }
        do {
            if let expected, expected.clipID != model.activeClip?.id || !model.contextDemoIsCurrent(expected.snapshot) {
                throw IllustrativeCutawayIssue.stale
            }
            let next = try makeReview(model)
            review = next
            prompt = next.selection.suggestedPrompt
        } catch { report(error, fallback: .stale) }
    }

    func openSheet(supported: Bool) {
        guard supported, canOpenSheet,
              let submittedPrompt = IllustrativeCutawaySelection.reviewedPrompt(prompt) else { return }
        sheetRequest = SheetRequest(id: UUID(), prompt: submittedPrompt)
        message = nil
    }

    func cancelledSheet(_ requestID: UUID) {
        guard sheetRequest?.id == requestID else { return }
        sheetRequest = nil
    }

    func receive(_ url: URL, requestID: UUID) {
        guard sheetRequest?.id == requestID, let review else { return }
        guard isCurrent else { followEditor(); return }
        sheetRequest = nil
        do {
            let bytes = try IllustrativeCutawayAssets.readImage(at: url)
            let assets = self.assets
            preparation = Task { [weak self] in
                do {
                    let draft = try await assets.prepare(bytes, projectID: review.document.projectId,
                        reviewID: requestID, duration: review.selection.duration)
                    guard let self, !Task.isCancelled, self.review?.id == review.id, self.isCurrent else {
                        try? assets.discard(draft.asset)
                        self?.followEditor()
                        return
                    }
                    self.draft = draft
                    self.preparation = nil
                } catch {
                    guard let self, !Task.isCancelled, self.review?.id == review.id else { return }
                    self.preparation = nil
                    if self.isCurrent { self.report(error, fallback: .asset) }
                    else { self.followEditor() }
                }
            }
        } catch { report(error, fallback: .asset) }
    }

    @discardableResult func apply() -> Bool {
        guard canApply, let model, let review, let draft else { return false }
        do {
            _ = try assets.verifiedURL(for: draft.asset)
            let placement = ContextDemoPlacement(id: draft.asset.id, assetId: draft.asset.id,
                source: TimeRange(start: 0, end: review.selection.duration), editedStartSeconds: review.selection.start)
            let next = try review.document.placing(asset: draft.asset, placement: placement, expectedRevision: review.document.revision)
            guard try model.commitContextDemoDocument(next, expected: review.snapshot, name: "Apply generated illustration") else { return false }
            self.draft = nil
            reset()
            message = "Illustration applied. Your narration is unchanged. Undo removes the placement."
            return true
        } catch { report(error, fallback: .asset); return false }
    }

    var placed: [ContextDemoPlacement] {
        guard let document = model?.contextDemoDocument else { return [] }
        let assetIDs = Set(document.assets.filter(IllustrativeCutawayAssets.isGenerated).map(\.id))
        return document.placements.filter { assetIDs.contains($0.assetId) }
    }

    @discardableResult func remove(_ placementID: String) -> Bool {
        guard !busy, let model, model.contextDemoUnavailableReason == nil,
              let document = model.contextDemoDocument, let placement = placed.first(where: { $0.id == placementID }) else { return false }
        do {
            let next = try document.removingPlacement(id: placementID, expectedRevision: document.revision)
            let unreferenced = !next.placements.contains { $0.assetId == placement.assetId }
            let inventory = unreferenced ? next.assets.filter { $0.id != placement.assetId } : next.assets
            var project = model.project
            project.contextDemo = inventory.isEmpty && next.placements.isEmpty ? nil : ContextDemoDocument(
                projectId: next.projectId, planId: next.planId, revision: next.revision, narration: next.narration,
                assets: inventory, placements: next.placements, sourceContentKey: next.sourceContentKey)
            try ContextDemoProject.validate(project)
            model.replace(project, name: "Remove generated illustration")
            guard model.contextDemoDocument == project.contextDemo else { return false }
            reset()
            message = "Illustration removed. Undo restores the placement."
            return true
        } catch { report(error, fallback: .stale); return false }
    }

    func followEditor() {
        guard review != nil, !isCurrent else { return }
        reset()
        message = IllustrativeCutawayIssue.stale.localizedDescription
    }

    func reset() {
        preparation?.cancel()
        preparation = nil
        if let draft { try? assets.discard(draft.asset) }
        draft = nil
        sheetRequest = nil
        review = nil
        prompt = ""
        message = nil
    }

    private var isCurrent: Bool { review.map(modelIsCurrent) ?? false }

    private func makeReview(_ model: EditorModel) throws -> Review {
        let snapshot = model.contextDemoSnapshot()
        guard (1...30).contains(snapshot.selectedWordIDs.count), snapshot.selectedPauseIDs.isEmpty else {
            throw IllustrativeCutawayIssue.selection
        }
        let timeline = try RenderCallerInputs.timeline(project: snapshot.project)
        let document: ContextDemoDocument
        if let existing = snapshot.project.contextDemo {
            guard existing.isCurrent(project: snapshot.project, timeline: timeline) else { throw IllustrativeCutawayIssue.stale }
            document = existing
        } else {
            document = try ContextDemoDocument(project: snapshot.project, planId: UUID().uuidString, timeline: timeline)
        }
        let clipID = model.activeClip?.id
        let selection = try IllustrativeCutawaySelection.matching(project: snapshot.project, clipID: clipID,
            selected: snapshot.selectedWordIDs, timeline: timeline, document: document)
        return Review(selection: selection, snapshot: snapshot, clipID: clipID, document: document)
    }

    private func modelIsCurrent(_ review: Review) -> Bool {
        guard let model else { return false }
        return model.activeClip?.id == review.clipID && model.contextDemoIsCurrent(review.snapshot)
    }

    private func report(_ error: any Error, fallback: IllustrativeCutawayIssue) {
        message = Self.message(error, fallback: fallback)
    }

    private static func message(_ error: any Error, fallback: IllustrativeCutawayIssue) -> String {
        ((error as? IllustrativeCutawayIssue) ?? fallback).localizedDescription
    }
}
