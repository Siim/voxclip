import VoxClipCore

struct RewriteReplacement: Equatable {
    static let undoCopy = "This part was already revoiced. Undo that revoice to rewrite it."

    let segmentIDs: Set<String>
    let recordIDs: Set<String>

    init(overlapping ids: Set<String>, in project: Project) {
        let records = (project.voiceLab.wholeClipRevoices ?? []).filter { !ids.isDisjoint(with: $0.segmentIds) }
        self.segmentIDs = ids.union(records.flatMap(\.segmentIds))
        self.recordIDs = Set(records.map(\.id))
    }

    func removing(from project: Project) -> Project {
        var next = project
        for index in next.voiceLab.segments.indices where segmentIDs.contains(next.voiceLab.segments[index].id) {
            next.voiceLab.segments[index].enabled = false
        }
        next.voiceLab.wholeClipRevoices?.removeAll { recordIDs.contains($0.id) }
        if next.voiceLab.wholeClipRevoices?.isEmpty == true { next.voiceLab.wholeClipRevoices = nil }
        return next
    }
}

extension RewriteSession {
    private var overlappingReplacementSegments: [VoiceLabSegment] {
        let bounds: TimeRange
        switch rewriteScope {
        case .clip(let id):
            guard let clip = project.edits.clips.first(where: { $0.id == id }),
                  let range = Self.clipRange(id, in: project),
                  let times = try? clipTimes(transcript, clip: clip, startIndex: range.lowerBound, endIndex: range.upperBound) else { return [] }
            bounds = times
        case .selection:
            guard let first = source.first, let last = source.last else { return [] }
            bounds = TimeRange(start: first.start, end: last.end)
        case .fullTake:
            return project.voiceLab.segments.filter(\.enabled)
        }
        return enabledReplacements(in: bounds)
    }

    private var replacementGrid: VoiceLabSampleGrid {
        VoiceLabSampleGrid(rate: Double(project.media.source.audio?.sampleRate ?? 48_000))
    }

    private func enabledReplacements(in bounds: TimeRange) -> [VoiceLabSegment] {
        let grid = replacementGrid
        return project.voiceLab.segments.filter {
            $0.enabled && grid.sample($0.replace.start) < grid.sample(bounds.end)
                && grid.sample($0.replace.end) > grid.sample(bounds.start)
        }
    }

    var usedRewriteReplacement: RewriteReplacement? {
        let ids = Set(overlappingReplacementSegments.map(\.id))
        return ids.isEmpty ? nil : RewriteReplacement(overlapping: ids, in: project)
    }

    var wholeClipReplacement: RewriteReplacement? {
        if case .fullTake = rewriteScope {
            let ids = Set(overlappingReplacementSegments.map(\.id))
            guard !ids.isEmpty, usedWholeClip.map({ Set($0.segmentIds) == ids }) == true else { return nil }
            return RewriteReplacement(overlapping: ids, in: project)
        }
        guard let clipID = wholeClipID, let range = Self.clipRange(clipID, in: project),
              let clip = project.edits.clips.first(where: { $0.id == clipID }),
              let bounds = try? clipTimes(transcript, clip: clip, startIndex: range.lowerBound, endIndex: range.upperBound),
              envelope != nil, editor.app.voiceLabRewriteEnabled else { return nil }
        if case .selection(let selection) = rewriteScope, selection != range { return nil }
        let grid = replacementGrid
        let segments = enabledReplacements(in: bounds)
        let ids = Set(segments.map(\.id))
        guard !ids.isEmpty, segments.allSatisfy({ grid.contains(bounds.start, bounds.end, start: $0.replace.start, end: $0.replace.end) }),
              (project.voiceLab.wholeClipRevoices ?? []).contains(where: { $0.clipId == clipID && Set($0.segmentIds) == ids }) else { return nil }
        return RewriteReplacement(overlapping: ids, in: project)
    }

    func stopForUsedRevoice() -> Bool {
        guard let replacement = usedRewriteReplacement, wholeClipReplacement == nil else { return false }
        let copy = RewriteReplacement.undoCopy
        task.show(.error(.message(copy)), headline: PanelHeadline(text: "Already revoiced"), cards: [.text(copy)],
                  footer: PanelFooter(primary: undoRevoiceAction(replacement)))
        editor.announce(copy)
        return true
    }

    func undoRevoiceAction(_ replacement: RewriteReplacement) -> PanelAction {
        PanelAction(id: "undoUsedRevoice", title: "Undo") { [weak self] in
            guard let self, isOpen, !hasUnusedPaidWork, !editor.capabilities.exporting else { return }
            guard voiceSpendCurrent, usedRewriteReplacement == replacement else { showChanged(); return }
            let next = replacement.removing(from: editor.project)
            guard next != editor.project, (try? VoiceLabProject.validate(next)) != nil else { return }
            clearProposal()
            task.show(.error(.message(RewriteReplacement.undoCopy)), headline: PanelHeadline(text: "Already revoiced"))
            editor.replace(next, name: "Undo Revoice")
            showChanged(reason: .revoiceUndone)
        }
    }
}
