public enum AgentSuggestions {
    public struct Chip: Encodable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let prompt: String
        public let enabled: Bool
        public let reason: String?
    }

    public struct Transcription: Codable, Equatable, Sendable {
        public let label: String
        public let percent: Int

        public init(label: String, percent: Int) {
            self.label = label
            self.percent = percent
        }
    }

    public struct State: Sendable {
        public let project: Project
        public let lengthSeconds: Int
        public let platform: String?
        public let transcribing: Transcription?
        public let exportedSinceLastChange: Bool
        public let next: [String]

        public init(project: Project, lengthSeconds: Int, platform: String? = nil, transcribing: Transcription? = nil,
                    exportedSinceLastChange: Bool = false, next: [String] = []) {
            self.project = project
            self.lengthSeconds = lengthSeconds
            self.platform = platform
            self.transcribing = transcribing
            self.exportedSinceLastChange = exportedSinceLastChange
            self.next = next
        }

        public var composerReason: String? {
            transcribing.map { "The chat starts when \($0.label) is transcribed · \($0.percent)%." }
        }
    }

    public static func chips(state: State) -> [Chip] {
        guard state.transcribing == nil else { return [] }
        let turns = state.project.agentThread?.turns ?? []
        let pending = turns.contains(where: \.isPending)
        if pending && state.next.isEmpty { return [] }
        let candidates = availableChips(state)
        guard !turns.isEmpty else { return Array(candidates.prefix(4)) }

        var preferred: [Chip] = []
        for suggestion in state.next {
            let text = normalized(suggestion)
            guard let chip = candidates.first(where: {
                $0.enabled && (normalized($0.label) == text || normalized($0.prompt) == text)
            }), !preferred.contains(where: { $0.id == chip.id }) else { continue }
            preferred.append(chip)
            if preferred.count == 2 { return preferred }
        }
        if pending { return preferred }
        let used = Set(preferred.map(\.id))
        return Array((preferred + candidates.filter { !used.contains($0.id) }).prefix(2))
    }

    private static func availableChips(_ state: State) -> [Chip] {
        let project = state.project
        let clip = project.edits.clips.first { $0.id == project.edits.activeClipId } ?? project.edits.clips.first
        let clock = ProjectClock.build(project)
        let spoken: [ProjectClock.Region]
        if clock.regions.count == 1 {
            spoken = clock.words.contains { $0.kind != .event } ? clock.regions : []
        } else {
            let spokenKeys = Set(clock.words.lazy.filter { $0.kind != .event }.compactMap { clock.region(of: $0.id)?.key })
            spoken = clock.regions.filter { spokenKeys.contains($0.key) }
        }
        let target = state.platform.flatMap { $0.isEmpty ? nil : $0 }
        var chips: [Chip] = []
        if spoken.count >= 2 {
            let matched = TakeMatch.build(clock: clock)
            if clip == nil, hasOverlap(matched, primary: clock.regions[0].key) {
                let prompt = "Make one\(target.map { " \($0)" } ?? "") clip from the best parts"
                chips.append(chip("best-parts", "✦ \(prompt)", prompt: prompt))
            }
            if let best = bestFlow(matched, spoken: spoken) {
                chips.append(chip("best-flow", "Start from \(best.label), the best flow", prompt: "Start from \(best.label)"))
            }
        } else if spoken.count == 1 {
            chips.append(chip("best-parts", "Make one clip from the best parts",
                              reason: "Needs two spoken recordings. Add a recording to compare versions."))
        }

        let tighten = "Tighten it to \(state.lengthSeconds) s"
        guard let clip else {
            chips.append(chip("find-three", "Find three clips\(target.map { " for \($0)" } ?? "")"))
            chips.append(chip("tighten", tighten, reason: "Needs a clip. Make one first."))
            return chips
        }

        let hasMusic = MusicProject.entry(for: clip.id, in: project) != nil
        let hasCaptions = project.captionSettings(forClip: clip.id).styleId != "off"
        switch (hasMusic, hasCaptions) {
        case (false, false): chips.append(chip("add-music-captions", "Add music and captions, then export"))
        case (false, true): chips.append(chip("add-music", "Add music, then export"))
        case (true, false): chips.append(chip("add-captions", "Add captions, then export"))
        case (true, true): break
        }
        if let duration = clipDuration(clip.id, in: project), duration > Double(state.lengthSeconds) {
            chips.append(chip("tighten", tighten))
        }
        if var edit = try? EditState(project: project) {
            edit.activeClipId = clip.id
            if edit.summary.fillerCount > 3 { chips.append(chip("cut-fillers", "Cut the fillers")) }
        }
        if state.exportedSinceLastChange {
            chips.append(chip("find-two-more", "Find two more clips in these recordings"))
            chips.append(chip("make-teaser", "Make a 30 s teaser"))
        } else if hasMusic && hasCaptions {
            chips.append(chip("check-export", "Check it and export"))
        }
        return chips
    }

    private static func hasOverlap(_ matches: TakeMatch.Result, primary: String) -> Bool {
        let beats = matches.beats.filter { $0.takes.contains { $0.key == primary } }
        return !beats.isEmpty && beats.count(where: { $0.takes.count > 1 }) * 10 >= beats.count * 3
    }

    private static func bestFlow(_ matches: TakeMatch.Result, spoken: [ProjectClock.Region]) -> ProjectClock.Region? {
        var counts: [String: Int] = [:]
        for take in matches.beats.flatMap(\.takes) {
            counts[take.key, default: 0] += take.signals.restarts + take.signals.fillers
        }
        func density(_ region: ProjectClock.Region) -> Double {
            Double(counts[region.key, default: 0]) / Double(max(1, region.durationSamples))
        }
        return spoken.min { density($0) < density($1) }
    }

    private static func clipDuration(_ clipID: String, in project: Project) -> Double? {
        guard let timeline = try? RenderCallerInputs.timeline(project: project, clipID: clipID) else { return nil }
        let speed = ClipControlsProject.controls(for: clipID, in: project)?.speed ?? 1
        let timing = ClipSpeedTiming(speed: speed, timeline: timeline, effects: ClipEffects.rendered(in: project, clipID: clipID))
        return timing.rendered(timeline.duration)
    }

    private static func chip(_ id: String, _ label: String, prompt: String? = nil, reason: String? = nil) -> Chip {
        Chip(id: id, label: label, prompt: prompt ?? label, enabled: reason == nil, reason: reason)
    }

    private static func normalized(_ text: String) -> String {
        text.unicodeScalars.split { " \t\r\n".unicodeScalars.contains($0) }
            .map { String(String.UnicodeScalarView($0)) }.joined(separator: " ").lowercased()
    }
}
