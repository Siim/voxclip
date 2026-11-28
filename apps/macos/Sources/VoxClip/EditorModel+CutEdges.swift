import Foundation
import VoxClipCore

/// The inline offer as last counted (`EditorModel.cutEdgeOffer`), with what it was counted over.
struct CutEdgeOfferMemo {
    let edits: ProjectEdits
    let waveforms: [UUID?]
    let offer: CutEdges.Offer
}

/// Cut edges seated in the quiet on Mac (editing §5.10, design.md §5.4 "Manual cuts and trims on Mac"): the levels and
/// freeze the seat reads, the commit hook `replace` calls, the timeline edit bar's offer and per-cut rows, and
/// Edit ▸ Fix Cut Edges.
extension EditorModel {
    // MARK: What the seat reads

    /// Each recording's 10 ms levels by its key, as `CutEdges.recordings` names them. The envelope's rate is 16 kHz, so
    /// the frame length is exactly 0.01 s (`WaveformData.frameSeconds`), never derived from the media's rate.
    var cutEdgeEnvelopes: [String: AudioEnvelope] {
        var waveforms = recordingWaveforms
        // A waveform set without a load (a demo project, the harness) is the only recording's.
        if waveforms.isEmpty, !hasSeveralRecordings, let waveform { waveforms[project.media.source.contentKey] = waveform }
        return waveforms.mapValues { AudioEnvelope(sampleRate: 16_000, levels: $0.fine) }
    }

    /// What keeps a boundary at today's padding (editing §5.10 "Frozen boundaries"), by recording key:
    /// - every Voice Lab segment's replace range, enabled or not, in its recording's local seconds;
    /// - the word ranges of paid work (`paidCutEdgeScopes`) in the first recording, the one Rewrite voices;
    /// - while any paid work is held, every later recording: its words have no position in Rewrite's scoped inputs, so its
    ///   cuts and edges count in every scope (`Project.rewriteInputs`).
    func cutEdgeFreeze(_ project: Project) -> [String: CutEdges.Freeze] {
        let recordings = CutEdges.recordings(project)
        guard let primary = recordings.first else { return [:] }
        let clock = ProjectClock.build(project)
        let rate = Double(clock.sampleRate)
        var result: [String: CutEdges.Freeze] = [:]
        for segment in project.voiceLab.segments {
            guard let region = clock.region(of: segment.replace.firstWordId) ?? clock.regions.first else { continue }
            let offset = Double(region.offsetSamples) / rate
            result[region.key, default: CutEdges.Freeze()].voiceRanges.append(
                TimeRange(start: segment.replace.start - offset, end: segment.replace.end - offset))
        }
        let scopes = paidCutEdgeScopes(project)
        for case let scope? in scopes {
            result[primary.key, default: CutEdges.Freeze()].paidScopes.append(
                ClipWordRange(startWordId: primary.words[scope.lowerBound].id, endWordId: primary.words[scope.upperBound].id))
        }
        if !scopes.isEmpty {
            for recording in recordings.dropFirst() {
                result[recording.key, default: CutEdges.Freeze()].voiceRanges.append(
                    TimeRange(start: -Double.greatestFiniteMagnitude, end: Double.greatestFiniteMagnitude))
            }
        }
        return result
    }

    /// The word ranges (positions in `project.transcript`, as `rewriteInputs` reads them) whose inputs paid or open work
    /// is made from; nil is the full take. They are a clip with a whole-clip revoice or a lip sync, the open Rewrite
    /// (paid or not: an edge moving at its scope's edge would set its proposal aside), and a Rewrite's paid takes saved
    /// beside the project.
    func paidCutEdgeScopes(_ project: Project) -> [ClosedRange<Int>?] {
        let words = project.transcript?.words ?? []
        guard !words.isEmpty else { return [] }
        let positions = Dictionary(words.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        func clipBounds(_ id: String?) -> ClosedRange<Int>? {
            guard let id, let clip = project.edits.clips.first(where: { $0.id == id }),
                  let lower = positions[clip.startWordId], let upper = positions[clip.endWordId], lower <= upper else { return nil }
            return lower...upper
        }
        /// `rewriteInputs`' word range: a selection takes in the clip it sits in. Nil when the clip is gone.
        func bounds(_ scope: RewriteScope, clip: String?) -> ClosedRange<Int>?? {
            switch scope {
            case .fullTake: return .some(nil)
            case .clip(let id): return clipBounds(id).map { .some($0) }
            case .selection(let selection):
                guard selection.lowerBound >= 0, selection.upperBound < words.count else { return nil }
                guard let enclosing = clipBounds(clip) else { return .some(selection) }
                return .some(min(selection.lowerBound, enclosing.lowerBound)...max(selection.upperBound, enclosing.upperBound))
            }
        }
        var scopes: [ClosedRange<Int>?] = []
        for record in project.voiceLab.wholeClipRevoices ?? [] {
            if record.clipId == WholeClipRevoice.fullTakeID { scopes.append(nil) } else if let range = clipBounds(record.clipId) { scopes.append(range) }
        }
        let clipRanges = project.edits.clips.compactMap { clipBounds($0.id) }
        for segment in project.voiceLab.segments where segment.candidates.contains(where: { $0.recipe?.video.mode == .lipsync }) {
            guard let position = positions[segment.replace.firstWordId] else { continue }
            let holding = clipRanges.filter { $0.contains(position) }
            scopes += holding.isEmpty ? [nil] : holding
        }
        if let session = openRewrite, session.isOpen {
            let clip: String? = if case .clip(let id) = session.scope { id } else { nil }
            if let scope = bounds(session.rewriteScope, clip: clip) { scopes.append(scope) }
        }
        for saved in savedPaidRewriteScopes(project) {
            let parts = saved.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            switch parts.first {
            case "full": scopes.append(nil)
            case "clip" where parts.count >= 2:
                if let range = clipBounds(parts.dropFirst().joined(separator: ":")) { scopes.append(range) }
            case "selection" where parts.count == 3:
                let ends = parts[1].split(separator: "-").compactMap { Int($0) }
                guard ends.count == 2, ends[0] <= ends[1] else { continue }
                if let scope = bounds(.selection(ends[0]...ends[1]), clip: parts[2].isEmpty ? nil : parts[2]) { scopes.append(scope) }
            default: continue
            }
        }
        return scopes
    }

    /// The scopes of the Rewrite proposals saved beside this project with paid work in them (`RewriteSavedProposal`):
    /// read without changing anything, once per project change.
    func savedPaidRewriteScopes(_ project: Project) -> [String] {
        if let memo = savedPaidRewriteScopesMemo { return memo }
        var scopes: [String] = []
        let paidRoot = app.locations.root.appendingPathComponent("VoiceLab", isDirectory: true)
        if let anyRecord = RewriteSavedProposalStore.url(paidRoot: paidRoot, projectId: project.id, scope: "full") {
            let folder = anyRecord.deletingLastPathComponent()
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
                guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                      let saved = try? decoder.decode(RewriteSavedProposal.self, from: data), saved.schema == RewriteSavedProposal.schema,
                      saved.projectId == project.id, Date().timeIntervalSince(saved.savedAt) < RewriteSavedProposal.lifetime,
                      saved.patchTakes > 0 || saved.wholeClip != nil else { continue }
                scopes.append(saved.scope)
            }
        }
        savedPaidRewriteScopesMemo = scopes
        return scopes
    }

    // MARK: The commit hook

    /// `replace`'s step for every edit: the boundaries whose kept/cut state changed are seated with the loaded levels and
    /// the freeze, and keys no longer at a kept/cut boundary go, so a cut and its restore leave the edits as they were. A
    /// recording without loaded levels keeps today's padding there; "Fix cut edges" picks it up later.
    func committingCutEdges(from before: Project, to after: Project) -> Project {
        let cutsChanged = before.edits.cutWordIds != after.edits.cutWordIds
        guard cutsChanged || !after.edits.cutEdges.isEmpty || before.edits.cutEdges != after.edits.cutEdges else { return after }
        let envelopes = cutsChanged ? cutEdgeEnvelopes : [:]
        let freeze = envelopes.isEmpty ? [:] : cutEdgeFreeze(after)
        return (try? CutEdges.finalize(before: before, after: after, envelopes: envelopes, freeze: freeze)) ?? after
    }
}
