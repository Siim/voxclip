import Foundation
import VoxClipCore
import VoxClipMedia

/// "Did matching help" before the first take with a video's own voice (voice-lab §6.13, ADR-R45 step 4): the anchor's
/// takes already accepted into the owner's recent projects, scored on this Mac as each new take is, so Settings › Voices
/// can show "siim · 0.54 across 8 earlier takes" beside the video's voice. Read only; nothing is sent.
extension VoiceLabSession {
    /// Measures the anchor's baseline in the background unless the book already holds the anchor's with the current
    /// speaker model. One whose anchor or model differs is dropped first. Returns the running measurement, if any.
    @discardableResult
    func measureAnchorBaseline() -> Task<Void, Never>? {
        if let running = anchorBaselineTask { return running }
        guard enabled, let anchor = anchorVoice(language: nil) else { return nil }
        let projects = anchorBaselineProjects()
        let paidRoot = app.locations.root.appendingPathComponent("VoiceLab", isDirectory: true)
        let projectStore = app.projectStore, log = Log(logger: app.log)
        let task = Task { [weak self] in
            guard let self else { return }
            defer { anchorBaselineTask = nil; measuringAnchorBaseline = false }
            guard let check = try? await referenceSpeakerCheck(language: anchor.language), check.available,
                  let model = check.embedder?.modelID else { return }
            if perVideoBook.baseline(anchorId: anchor.id, model: model) != nil { return }
            if perVideoBook.anchorBaseline != nil {
                // Another model's or another voice's numbers don't compare with this model's: dropped, then measured again.
                perVideoBook.anchorBaseline = nil
                perVideoBook = (try? await perVideoStore.update { book in var next = book; next.anchorBaseline = nil; return next }) ?? perVideoBook
            }
            measuringAnchorBaseline = true
            let result = await VoiceAnchorBaseline.measure(projects: projects, anchorID: anchor.id, paidRoot: paidRoot, check: check) { url in
                await Self.openForBaseline(url, store: projectStore)
            }
            guard !Task.isCancelled else { return }
            let baseline = VoicePerVideoBook.AnchorBaseline(anchorId: anchor.id, model: model, score: result.mean,
                takes: result.scores.count, measuredAt: VoiceConsentRecord.timestamp(Date()))
            var local = perVideoBook
            local.anchorBaseline = baseline
            perVideoBook = (try? await perVideoStore.update { book in var next = book; next.anchorBaseline = baseline; return next }) ?? local
            let score = result.mean.map { String(format: "%.3f", $0) } ?? "none"
            await log.write(.info, category: "voice-lab",
                message: "per-video anchor baseline takes=\(result.scores.count) score=\(score) model=\(model) projects=\(projects.count)")
            if let latest = perVideoBook.measurements.first(where: { $0.videoVoice != nil }) { await logMatchComparison(latest, log: log) }
        }
        anchorBaselineTask = task
        return task
    }

    /// A project file and its source media on this Mac, read only; nil when either is missing or unreadable.
    nonisolated static func openForBaseline(_ url: URL, store: JSONProjectStore) async -> VoiceAnchorBaseline.Opened? {
        guard let data = try? Data(contentsOf: url), let project = try? JSONProjectStore.decode(data),
              let media = try? await store.resolveSource(for: project, projectURL: url) else { return nil }
        return VoiceAnchorBaseline.Opened(project: project, media: media)
    }

    /// The log line with both numbers: a video's own voice and the anchor's baseline.
    func logMatchComparison(_ measurement: VoicePerVideoBook.Measurement, log: Log) async {
        guard let own = measurement.videoVoice, let baseline = perVideoBook.anchorBaseline, let score = baseline.score else { return }
        await log.write(.info, category: "voice-lab",
            message: "per-video match compared video=\(measurement.contentKey.prefix(8)) own=\(String(format: "%.3f", own)) anchor_baseline=\(String(format: "%.3f", score)) earlier_takes=\(baseline.takes)")
    }

    /// The baseline line Settings › Voices shows in its comparison, for the anchor it names.
    var anchorBaselineLine: String? {
        let anchor = anchorVoice(language: nil)
        return Self.baselineLine(perVideoBook.anchorBaseline, measuring: measuringAnchorBaseline, anchorID: anchor?.id,
                                 anchor: anchor.map { Self.rebuildName($0.voiceName) } ?? "your voice")
    }

    /// Settings › Voices' baseline line: "siim · 0.54 across 8 earlier takes", the quiet line while it measures, or nil
    /// before it was measured for this anchor.
    static func baselineLine(_ baseline: VoicePerVideoBook.AnchorBaseline?, measuring: Bool, anchorID: String?, anchor: String) -> String? {
        if measuring { return "Measuring \(anchor)'s earlier takes…" }
        guard let baseline, baseline.anchorId == anchorID else { return nil }
        guard let score = baseline.score, baseline.takes > 0 else { return "No earlier takes of \(anchor) on this Mac to compare with." }
        let value = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), score)
        return "\(anchor) · \(value) across \(baseline.takes) earlier \(baseline.takes == 1 ? "take" : "takes")"
    }
}
