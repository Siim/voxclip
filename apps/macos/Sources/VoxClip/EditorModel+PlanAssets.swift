import Foundation
import VoxClipCore
import VoxClipMedia

extension EditorModel {
    static let clipPlanAssets = ClipPlanAssets()

    var clipIllustrationQuote: ClipIllustrationQuote? {
        app.shared.flatMap { try? ClipIllustrationQuote.load(shared: $0) }
    }

    func savedPlanIllustration(_ asset: ClipPlanAsset, client: ClipPlanAssets) -> ClipEffect? {
        guard let quote = clipIllustrationQuote else { return nil }
        return client.savedIllustration(asset, projectID: project.id, root: app.locations.root, quote: quote)
    }

    func collectPlanAsset(_ asset: ClipPlanAsset, client: ClipPlanAssets, approve: (Decimal) -> Bool) async throws -> ClipEffect? {
        let projectID = project.id
        let root = app.locations.root
        try Task.checkCancellation()
        if asset.kind == .sound { return try await client.sound(asset, projectID: projectID, root: root) }
        guard let quote = clipIllustrationQuote else { return nil }
        if let saved = client.savedIllustration(asset, projectID: projectID, root: root, quote: quote) { return saved }
        guard let key = try await app.secrets.key(for: "fal"), !key.isEmpty else { return nil }
        try Task.checkCancellation()
        guard approve(quote.usdPerImage) else { return nil }
        return try await Task.detached {
            try await client.illustration(asset, projectID: projectID, root: root, quote: quote, key: key)
        }.value
    }

    func makeItAssetStep(_ asset: ClipPlanAsset, operation: ClipAutopilotOperation, run: MakeItRun, client: ClipPlanAssets) async -> MakeItRow {
        let illustration = asset.kind == .illustration
        let title = illustration ? "Illustration" : "Sound effect"
        let snapshot = project
        var charged: Decimal = 0
        if illustration, savedPlanIllustration(asset, client: client) == nil {
            guard let quote = clipIllustrationQuote else { return MakeItRow(id: operation.id, text: "Kept the picture: illustration pricing isn't available") }
            guard (run.remaining ?? 0) >= quote.usdPerImage else { return MakeItRow(id: operation.id, text: "Kept the picture: an illustration is over the spend cap") }
        }
        run.line(illustration ? "Making an illustration…" : "Finding a sound effect…")
        let result = try? await collectPlanAsset(asset, client: client) { quote in
            guard (run.remaining ?? 0) >= quote, !run.cancelled, !isLeaving, project == snapshot else { return false }
            run.charge(quote); charged = quote
            return true
        }
        guard let effect = result else {
            return MakeItRow(id: operation.id, text: illustration ? "No illustration was placed" : "No licensed sound fit this beat",
                detail: illustration && charged == 0 ? "Add a fal.ai key in Settings to generate an illustration." : "")
        }
        guard project == snapshot, !run.cancelled, !isLeaving, !Task.isCancelled, let next = try? ClipEffects.adding([effect], to: project) else {
            return MakeItRow(id: operation.id, text: "\(title) saved, not placed")
        }
        let previous = project.clipEffects.first { $0.id == effect.id }
        replace(next, name: "Make it postable")
        run.inverses[operation.id] = .effect(id: effect.id, previous: previous)
        let detail = charged > 0 ? "\(operation.reason) · Up to \(Self.makeItDollars(charged))" : operation.reason
        return MakeItRow(id: operation.id, text: effect.sound.map { "Sound: \($0.title)" } ?? title, detail: detail,
                         play: max(0, effect.start - 0.5), undoable: true)
    }

    func askAssetStatus(_ asset: ClipPlanAsset) -> AskClaudeRow.Status {
        if asset.kind == .sound { return .asset(title: "Find sound · free", disabled: nil) }
        if savedPlanIllustration(asset, client: Self.clipPlanAssets) != nil {
            return .asset(title: "Place saved illustration", disabled: nil)
        }
        guard let quote = clipIllustrationQuote else { return .asset(title: "Generate illustration", disabled: "Illustration pricing isn't available.") }
        return .asset(title: "Generate illustration · up to \(Self.makeItDollars(quote.usdPerImage))",
                      disabled: askClaude.illustrationKeyAvailable == true ? nil : askClaude.illustrationKeyAvailable == nil
                         ? "Checking for a fal.ai key…" : "Add a fal.ai key in Settings to generate an illustration.")
    }

    func runAskAsset(_ rowID: String) {
        guard !isLeaving, let run = askClaude.run, askClaude.assetWorking == nil,
              let row = run.rows.first(where: { $0.id == rowID }), case .asset = row.status, case .asset(let asset) = row.operation.action,
              case .asset(_, nil) = askAssetStatus(asset) else { return }
        let snapshot = project
        askClaude.assetWorking = rowID
        Task { [weak self] in
            guard let self else { return }
            defer { askClaude.assetWorking = nil }
            let result = try? await collectPlanAsset(asset, client: Self.clipPlanAssets) { _ in !isLeaving && project == snapshot && askClaude.run === run }
            guard askClaude.run === run, let index = run.rows.firstIndex(where: { $0.id == rowID }) else { return }
            guard let effect = result else {
                run.rows[index].detail = asset.kind == .sound ? "No licensed sound fit this beat." : "No illustration was returned."
                return
            }
            guard !isLeaving, project == snapshot, let next = try? ClipEffects.adding([effect], to: project) else {
                run.rows[index].detail = "Saved, but the clip changed. Ask again to place it."
                return
            }
            replace(next, name: "Ask Claude")
            run.rows[index].status = .applied
            announce("Placed the \(asset.kind == .sound ? "sound effect" : "illustration")")
        }
    }
}
