import Foundation
import VoxClipCore

/// The inline offer as last counted (`EditorModel.cutEdgeOffer`), with what it was counted over.
struct CutEdgeOfferMemo {
    let edits: ProjectEdits
    let waveforms: [UUID?]
    /// Whether the open Rewrite held paid work, which freezes its scope's edges.
    let paidRewrite: Bool
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
    /// - the word ranges of paid work (`paidCutEdgeScopes`) in the first recording, the one Rewrite voices, a full take
    ///   as every word of it;
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
        for scope in scopes {
            guard let range = scope ?? (primary.words.isEmpty ? nil : 0...(primary.words.count - 1)),
                  range.upperBound < primary.words.count else { continue }
            result[primary.key, default: CutEdges.Freeze()].paidScopes.append(
                ClipWordRange(startWordId: primary.words[range.lowerBound].id, endWordId: primary.words[range.upperBound].id))
        }
        if !scopes.isEmpty {
            for recording in recordings.dropFirst() {
                result[recording.key, default: CutEdges.Freeze()].voiceRanges.append(
                    TimeRange(start: -Double.greatestFiniteMagnitude, end: Double.greatestFiniteMagnitude))
            }
        }
        return result
    }

    /// The word ranges (positions in `project.transcript`, as `rewriteInputs` reads them) whose inputs paid work is made
    /// from; nil is the full take. They are a clip with a whole-clip revoice or a lip sync, the open Rewrite while it
    /// holds paid takes (spec §3.2b; `hasPaidWork`, a paid whole-clip voice too), and a Rewrite's paid takes saved beside
    /// the project.
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
        if openRewritePaysCutEdgeScope, let session = openRewrite {
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

    /// Whether the open Rewrite holds paid work, so its scope's edges are frozen: the memos are read again when it gets
    /// or loses paid takes.
    var openRewritePaysCutEdgeScope: Bool { openRewrite.map { $0.isOpen && $0.hasPaidWork } ?? false }

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

    // MARK: Old cuts: the offer and Fix cut edges

    /// What "Fix cut edges" would do now (editing §5.10 "Existing projects"): N edges that would move, K kept beside voice
    /// patches, and the recordings whose levels aren't loaded. Counted once per change of the edits, the waveforms or
    /// the open Rewrite.
    var cutEdgeOffer: CutEdges.Offer {
        _ = transcriptRevision
        _ = openRewrite
        let waveforms = [waveform?.identity] + recordingWaveforms.keys.sorted().map { recordingWaveforms[$0]?.identity }
        let paidRewrite = openRewritePaysCutEdgeScope
        if let memo = cutEdgeOfferMemo, memo.edits == project.edits, memo.waveforms == waveforms, memo.paidRewrite == paidRewrite { return memo.offer }
        // With no kept/cut boundary left without a key there is nothing to count, and no levels to analyse.
        let cut = Set(project.edits.cutWordIds), edges = project.edits.cutEdges
        let open = !cut.isEmpty && CutEdges.recordings(project).contains { recording in
            recording.words.indices.dropFirst().contains { index in
                edges[recording.words[index].id] == nil && CutEdges.qualifies(recording.words[index - 1], recording.words[index], cutWordIds: cut)
            }
        }
        let offer = open ? CutEdges.offer(project, envelopes: cutEdgeEnvelopes, freeze: cutEdgeFreeze(project))
            : CutEdges.offer(project, envelopes: [:])
        cutEdgeOfferMemo = CutEdgeOfferMemo(edits: project.edits, waveforms: waveforms, paidRewrite: paidRewrite, offer: offer)
        return offer
    }

    var canFixCutEdges: Bool { capabilities.edit && cutEdgeOffer.count > 0 }

    /// Why Edit ▸ Fix Cut Edges is disabled (design.md, the menu bar), or nil when it can run.
    var fixCutEdgesReason: String? {
        let offer = cutEdgeOffer
        guard offer.count == 0 else { return nil }
        guard let key = offer.unloaded.first else { return "All cut edges are in the quiet" }
        return unloadedLevelsReason(key)
    }

    /// Why a recording's levels aren't there to seat on: its video is missing or unreadable (its load read no levels), or
    /// they are still loading.
    func unloadedLevelsReason(_ key: String) -> String {
        recordingIsMissing(key) || unreadableWaveformKeys.contains(key) || (key == project.media.source.contentKey && mediaUnreadable)
            ? "Reconnect \(recordingLabel(key)) to fix its cut edges" : "Waveform still loading"
    }

    /// A recording's name as the timeline's recording lanes show it.
    func recordingLabel(_ key: String) -> String {
        recordingRegions.first { $0.key == key }?.label ?? ProjectClock.label(project.media.source)
    }

    /// Fix cut edges: every old cut's edges that can move into the quiet, as one undo step, then the result line.
    func fixCutEdges() {
        guard capabilities.edit,
              let (fixed, offer) = try? CutEdges.fix(project, envelopes: cutEdgeEnvelopes, freeze: cutEdgeFreeze(project)),
              offer.count > 0 else { return }
        replace(fixed, name: "Fix cut edges")
        let moved = "Moved \(offer.count) cut \(offer.count == 1 ? "edge" : "edges") into the quiet"
        let text = offer.frozen > 0 ? moved + " · \(offer.frozen) kept beside voice patches" : moved
        cutEdgeResult = (project.edits, text)
        announce(text)
    }

    // MARK: A selected cut

    /// The selected cut words' edges at a kept neighbour (design.md, the timeline edit bar): on a quiet point the seat
    /// found, with Use word edge to pin each one at the word edge, or on the word edge, with Use quiet point to seat them
    /// again. Nil when no selected cut word has such an edge. Read once per change of the selection, the edits, the
    /// waveforms or the open Rewrite.
    var selectedCutEdge: CutEdgeChoice? {
        let selected = selectedWordIDs
        guard !selected.isDisjoint(with: cutWordIDs) else { return nil }
        _ = transcriptRevision
        _ = openRewrite
        let waveforms = [waveform?.identity] + recordingWaveforms.keys.sorted().map { recordingWaveforms[$0]?.identity }
        let paidRewrite = openRewritePaysCutEdgeScope
        let unreadable = unreadableWaveformKeys
        if let memo = cutEdgeChoiceMemo, memo.selected == selected, memo.edits == project.edits, memo.waveforms == waveforms,
           memo.unreadable == unreadable, memo.paidRewrite == paidRewrite {
            return memo.choice
        }
        let choice = cutEdgeChoice(selected: selected)
        cutEdgeChoiceMemo = CutEdgeChoiceMemo(selected: selected, edits: project.edits, waveforms: waveforms, unreadable: unreadable,
                                              paidRewrite: paidRewrite, choice: choice)
        return choice
    }

    private func cutEdgeChoice(selected: Set<String>) -> CutEdgeChoice? {
        let project = project
        let cut = Set(project.edits.cutWordIds), edges = project.edits.cutEdges
        let rate = Double(max(1, project.media.source.audio?.sampleRate ?? 48_000))
        var boundaries: [(recording: CutEdges.Recording, index: Int)] = []
        for recording in CutEdges.recordings(project) {
            let words = recording.words
            for index in words.indices.dropFirst() where CutEdges.qualifies(words[index - 1], words[index], cutWordIds: cut) {
                let removed = cut.contains(words[index].id) ? words[index] : words[index - 1]
                if selected.contains(removed.id) { boundaries.append((recording, index)) }
            }
        }
        guard !boundaries.isEmpty else { return nil }
        /// The word edge, sample-rounded as stored: where today's padding ends a cut between touching words.
        func wordEdge(_ a: TimedWord, _ b: TimedWord) -> Double { EditingPrimitives.jsRound((a.end + b.start) / 2 * rate) / rate }
        let freeze = cutEdgeFreeze(project)
        let open = boundaries.filter { item in
            !CutEdges.isFrozen(words: item.recording.words, at: item.index, cutWordIds: cut, freeze: freeze[item.recording.key] ?? CutEdges.Freeze())
        }
        let quiet = boundaries.contains { item in
            let a = item.recording.words[item.index - 1], b = item.recording.words[item.index]
            return edges[b.id].map { $0 != wordEdge(a, b) } ?? false
        }
        let kept = "Kept beside a voice patch"
        var writes: [String: Double] = [:]
        if quiet {
            for item in open {
                let a = item.recording.words[item.index - 1], b = item.recording.words[item.index]
                let pin = wordEdge(a, b)
                if pin > a.start, pin < b.end, edges[b.id] != pin { writes[b.id] = pin }
            }
            return CutEdgeChoice(quiet: true, writes: writes, reason: writes.isEmpty ? kept : nil)
        }
        guard !open.isEmpty else { return CutEdgeChoice(quiet: false, writes: [:], reason: kept) }
        let envelopes = cutEdgeEnvelopes
        var unloaded: [String] = []
        for recording in CutEdges.recordings(project) {
            let ids = Set(open.filter { $0.recording.key == recording.key }.map { $0.recording.words[$0.index].id })
            guard !ids.isEmpty else { continue }
            guard let envelope = envelopes[recording.key] else { unloaded.append(recording.key); continue }
            let seated = CutEdges.seat(words: recording.words, cutWordIds: cut, envelope: envelope, sampleRate: rate,
                                       freeze: freeze[recording.key] ?? CutEdges.Freeze(),
                                       existing: edges.filter { !ids.contains($0.key) }, only: ids)
            writes.merge(seated.edges) { _, new in new }
        }
        guard writes.isEmpty else { return CutEdgeChoice(quiet: false, writes: writes, reason: nil) }
        return CutEdgeChoice(quiet: false, writes: [:], reason: unloaded.first.map(unloadedLevelsReason) ?? "No quiet point near this edge")
    }

    /// The selected cut's action, as one undo step named for it ("Use word edge", "Use quiet point").
    func useSelectedCutEdge() {
        guard capabilities.edit, let choice = selectedCutEdge, choice.reason == nil, !choice.writes.isEmpty else { return }
        var next = project
        next.edits.cutEdges.merge(choice.writes) { _, new in new }
        replace(next, name: choice.action)
    }

    /// The edit bar row's action: the selected cut's, else Fix cut edges.
    func runCutEdgeBarAction() {
        if selectedCutEdge != nil { useSelectedCutEdge() } else { fixCutEdges() }
    }

    /// The one cut edge row the timeline edit bar shows: a selected cut's edges, the result of Fix cut edges while
    /// its edits stand, or the offer while old cuts could move.
    var cutEdgeBarRow: CutEdgeBarRow? {
        if let choice = selectedCutEdge { return CutEdgeBarRow(text: choice.status, action: choice.action, reason: choice.reason) }
        if let result = cutEdgeResult, result.edits == project.edits { return CutEdgeBarRow(text: result.text) }
        let count = cutEdgeOffer.count
        guard count > 0 else { return nil }
        return CutEdgeBarRow(text: "\(count) \(count == 1 ? "cut" : "cuts") can land in the quiet", action: "Fix cut edges")
    }
}

/// The selected cut's edges as last read (`EditorModel.selectedCutEdge`), with what they were read over.
struct CutEdgeChoiceMemo {
    let selected: Set<String>
    let edits: ProjectEdits
    let waveforms: [UUID?]
    /// The recordings that couldn't be read, whose reason is Reconnect.
    let unreadable: Set<String>
    let paidRewrite: Bool
    let choice: CutEdgeChoice?
}

/// Where a selected cut's edges sit and what its one action writes, by the later word's clock id: each edge's word edge
/// (Use word edge) or the quiet point found (Use quiet point).
struct CutEdgeChoice: Equatable {
    /// At least one edge sits on a quiet point the seat found.
    let quiet: Bool
    let writes: [String: Double]
    /// Why the action can't run, or nil.
    let reason: String?
    var status: String { quiet ? "Cut edge: quiet point" : "Cut edge: word edge" }
    var action: String { quiet ? "Use word edge" : "Use quiet point" }
}

/// A row of the timeline edit bar about cut edges: its line and, when it has one, its inline action and why that is
/// disabled.
struct CutEdgeBarRow: Equatable {
    var text: String
    var action: String? = nil
    var reason: String? = nil
}
