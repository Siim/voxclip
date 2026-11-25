import Foundation

public struct ClipPlanMusicShape: Codable, Sendable, Equatable {
    public struct Segment: Codable, Sendable, Equatable {
        let startWord: Int
        let endWord: Int
        let songFrom: Double?
        let loop: Bool?
        let gainDb: Double?
        let fadeIn: Double?
        let fadeOut: Double?
    }

    let fadeIn: Double?
    let fadeOut: Double?
    let duckDb: Double?
    let segments: [Segment]?
    static let keys: Set<String> = ["fadeIn", "fadeOut", "duckDb", "segments"]

    static func read(_ value: JSONValue, provider: Bool = false) throws -> Self? {
        var fields = value.aiObject?.filter { keys.contains($0.key) } ?? [:]
        if provider {
            for key in ["fadeIn", "fadeOut"] where fields[key]?.aiDouble == -1 { fields[key] = nil }
            if fields["duckDb"]?.aiDouble == 1 { fields["duckDb"] = nil }
            if case .array(let entries) = fields["segments"] {
                fields["segments"] = entries.isEmpty ? nil : .array(entries.map { entry in
                    guard var segment = entry.aiObject else { return entry }
                    for key in ["fadeIn", "fadeOut", "songFrom"] where segment[key]?.aiDouble == -1 { segment[key] = nil }
                    return .object(segment)
                })
            }
        }
        guard !fields.isEmpty else { return nil }
        let invalid = HarnessError.invalid("Choose valid music fades, ducking and segment anchors.")
        func number(_ fields: [String: JSONValue], _ key: String, range: ClosedRange<Double>) -> Bool {
            fields[key].map { $0.aiDouble.map(range.contains) == true } ?? true
        }
        guard number(fields, "fadeIn", range: 0...10), number(fields, "fadeOut", range: 0...10),
              number(fields, "duckDb", range: -24...0) else { throw invalid }
        if let raw = fields["segments"] {
            guard case .array(let entries) = raw, entries.count <= ProjectMusic.maximumSegments else { throw invalid }
            for entry in entries {
                let segment = try HarnessTimeline.requireObject(entry, keys: ["startWord", "endWord", "songFrom", "loop", "gainDb", "fadeIn", "fadeOut"])
                guard let start = segment["startWord"]?.aiInt, let end = segment["endWord"]?.aiInt, start >= 0, end >= start,
                      segment["loop"].map({ $0.aiBool != nil }) != false,
                      number(segment, "songFrom", range: 0...ProjectMusic.maximumDuration), number(segment, "gainDb", range: -40...12),
                      number(segment, "fadeIn", range: 0...10), number(segment, "fadeOut", range: 0...10) else { throw invalid }
            }
        }
        return try JSONDecoder().decode(Self.self, from: JSONValue.object(fields).aiEncoded())
    }

    public func placing(_ track: ProjectMusic, in project: Project, clipID: String?) throws -> ProjectMusic {
        var result = track
        result.fadeInSeconds = fadeIn ?? result.fadeInSeconds
        result.fadeOutSeconds = fadeOut ?? result.fadeOutSeconds
        if let duckDb { result.duckDb = duckDb; result.ducking = duckDb != 0 }
        if let segments, !segments.isEmpty {
            let words = project.transcript?.words ?? []
            let plan = try RenderCallerInputs.editPlan(project: project, clipID: clipID)
            let spans = clipID.flatMap { id in project.edits.clips.first { $0.id == id }?.playPartIndices(in: words) }
            let invalid = HarnessError.invalid("Place each music segment on kept words in the clip and inside the track.")
            func round(_ time: Double) -> Double { EditingPrimitives.jsRound(time * plan.sampleRate) / plan.sampleRate }
            result.segments = try segments.enumerated().map { index, segment in
                guard words.indices.contains(segment.startWord), words.indices.contains(segment.endWord),
                      spans.map({ spans in spans.contains { $0.contains(segment.startWord) } && spans.contains { $0.contains(segment.endWord) } }) != false else { throw invalid }
                let start = round(words[segment.startWord].start)
                let end = round(words[segment.endWord].end)
                let length = round(plan.mapTime(end, end: true) - plan.mapTime(start))
                let from = round(segment.songFrom ?? track.startOffsetSeconds)
                let loop = segment.loop ?? true
                guard length > 0.1, from >= 0, from < track.asset.durationSeconds, loop || length <= track.asset.durationSeconds - from else { throw invalid }
                return MusicSegment(id: "seg-\(index + 1)", anchorSeconds: start, lengthSeconds: length, songFromSeconds: from, loop: loop,
                                    gainDb: segment.gainDb ?? 0, fadeInSeconds: segment.fadeIn ?? result.fadeInSeconds,
                                    fadeOutSeconds: segment.fadeOut ?? result.fadeOutSeconds)
            }
        }
        return result
    }
}
