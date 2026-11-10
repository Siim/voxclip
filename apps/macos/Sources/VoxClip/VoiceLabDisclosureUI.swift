import VoxClipCore

extension EditorModel {
    func containsAISpeech(clipID: String? = nil) -> Bool {
        let lower: Double, upper: Double
        if let clipID {
            guard let clip = project.edits.clips.first(where: { $0.id == clipID }),
                  let first = index(clip.startWordId), let last = index(clip.endWordId) else { return false }
            lower = words[first].start; upper = words[last].end
        } else { lower = 0; upper = project.media.source.durationSeconds }
        // A replace range meets the clip on the source sample grid, as the output planner's clip filter does (§10.1).
        let grid = sourceGrid
        return project.voiceLab.segments.contains { $0.enabled && $0.isAIModified && grid.overlaps(lower, upper, start: $0.replace.start, end: $0.replace.end) }
    }
    func exportAccessibleName(_ name: String, targets: [ExportTarget]) -> String {
        name + (targets.contains { target in
            switch target {
            case .fullEdit: containsAISpeech()
            case .clip(let id): containsAISpeech(clipID: id)
            }
        } ? ", contains AI-modified speech" : "")
    }
}
