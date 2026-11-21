import Foundation
import VoxClipCore

private extension ClipAutopilotPlan.Music {
    var browserBrief: MusicBrief {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let search = mood.trimmingCharacters(in: .whitespacesAndNewlines)
        return MusicBrief(mood: title.isEmpty ? search : title, query: search.isEmpty ? title : search,
                          prompt: prompt, reason: reason)
    }
}

extension ClipAutopilotPlan {
    /// Keep the recommended direction first without dropping the alternatives the planner supplied.
    var musicBrowserBriefs: [MusicBrief] {
        guard let picked = pickedMusic ?? music.first else { return [] }
        return ([picked] + music.filter { $0 != picked }).map(\.browserBrief)
    }
}

extension ClipAutopilotMusicCue {
    var musicBrowserBriefs: [MusicBrief] { ([picked] + alternatives).map(\.browserBrief) }
}

extension EditorModel {
    var plannedMusicBrowserBriefs: [MusicBrief] {
        guard let clip = renderedActiveClipID, let plan = makeIt.run(for: clip)?.plan else { return [] }
        return plan.musicBrowserBriefs
    }
}
