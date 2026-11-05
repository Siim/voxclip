import Foundation
import VoxClipCore
import VoxClipMedia

/// "Let a video teach your voice" in Settings › Voices (voice-lab §6.9, ADR-R41; design.md Settings › Voices): each
/// voice says how many of the owner's videos taught the guard, Learn from my videos scans recent projects and the
/// export folder on this Mac, and Forget learned references removes them, inline. Nothing is sent anywhere.
extension VoiceLabSession {
    /// The voice row's line: how many of the owner's videos the guard has learned from.
    static func learnedLine(_ record: VoiceConsentRecord) -> String {
        let count = VoiceSpeakerReferences.learnedCount(record.speaker)
        return switch count {
        case 0: "Not learned from your videos yet. VoxClip learns your voice from each video you transcribe."
        case 1: "Learned from 1 of your videos"
        default: "Learned from \(count) of your videos"
        }
    }

    /// The projects to learn from: the recent list, then `.voxclip` files at the top of the export folder, each once.
    func learningProjects() -> [URL] {
        var urls = app.recent
        let folder = ExportSelection.folder(app.string("export.folder", fallback: "~/Movies/VoxClip"))
        if let listed = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            urls += listed.filter { $0.pathExtension == "voxclip" }.sorted { $0.path < $1.path }
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Learns a reference for `recordID` from each of the owner's projects, one at a time, with the progress inline.
    func learnFromVideos(recordID: String, projects: [URL]? = nil) {
        guard learningTask == nil, let record = records.first(where: { $0.id == recordID }), record.status == .active else { return }
        let urls = projects ?? learningProjects()
        guard !urls.isEmpty else { learningLine[recordID] = "Open or export a video first. VoxClip learns from your projects on this Mac."; return }
        learningLine[recordID] = "Learning from video 1 of \(urls.count)… Nothing is sent."
        learningTask = Task { [weak self] in
            guard let self else { return }
            defer { learningTask = nil }
            guard let learner = await referenceLearner(language: record.language) else {
                learningLine[recordID] = "The speaker check isn't ready. Download it in Voice Lab, then try again."
                return
            }
            var learned = 0, other = 0
            for (index, url) in urls.enumerated() {
                if Task.isCancelled { break }
                learningLine[recordID] = "Learning from video \(index + 1) of \(urls.count)… Nothing is sent."
                switch await learn(url, recordID: recordID, learner: learner) {
                case .learned?, .kept?: learned += 1
                case .notTheOwner?: other += 1
                default: break
                }
            }
            await reloadRecordsQuietly()
            let total = records.first { $0.id == recordID }.map { VoiceSpeakerReferences.learnedCount($0.speaker) } ?? 0
            var summary = learned == 0 ? "No new speech of yours found in \(urls.count) \(urls.count == 1 ? "video" : "videos")."
                : "Checked \(urls.count) \(urls.count == 1 ? "video" : "videos"): your voice is learned from \(total)."
            if other > 0 { summary += " \(other) didn't sound like you; nothing was kept from \(other == 1 ? "it" : "them")." }
            learningLine[recordID] = summary
        }
    }

    /// Learns quietly from a project the user just transcribed, for every active voice in its language.
    func learnFromTranscribed(_ project: Project, media: URL) {
        guard enabled, learningTask == nil else { return }
        learningTask = Task { [weak self] in
            guard let self else { return }
            defer { learningTask = nil }
            let voices = (try? await store.activeVoices()) ?? []
            for record in voices where project.transcript?.language.map({ $0 == record.language }) ?? true {
                guard let learner = await referenceLearner(language: record.language) else { continue }
                _ = await learner.learn(project: project, media: media, recordID: record.id)
            }
            await reloadRecordsQuietly()
        }
    }

    /// Forgets every learned reference of a voice. The guard then judges phrases against the consent statement only.
    func forgetLearned(recordID: String) async {
        learningTask?.cancel(); learningTask = nil
        do {
            try await store.forgetReferences(recordID: recordID)
            await reloadRecordsQuietly()
            learningLine[recordID] = "Forgot what VoxClip learned from your videos. Your consent statement still checks every phrase."
        } catch { learningLine[recordID] = "Couldn't forget the learned references. Nothing else changed." }
    }

    private func learn(_ url: URL, recordID: String, learner: VoiceReferenceLearner) async -> VoiceReferenceLearner.Outcome? {
        guard let data = try? Data(contentsOf: url), let project = try? JSONProjectStore.decode(data),
              let media = try? await app.projectStore.resolveSource(for: project, projectURL: url) else { return nil }
        return await learner.learn(project: project, media: media, recordID: recordID)
    }

    private func referenceLearner(language: String) async -> VoiceReferenceLearner? {
        guard let check = try? await referenceSpeakerCheck(language: language), check.available else { return nil }
        return VoiceReferenceLearner(store: store, check: check)
    }

    private func reloadRecordsQuietly() async {
        if let loaded = try? await store.records() { records = loaded }
    }
}
