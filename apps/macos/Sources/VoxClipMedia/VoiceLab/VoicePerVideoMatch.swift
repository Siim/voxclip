import AVFoundation
import Foundation
import VoxClipCore

/// "Did matching help" (voice-lab §6.13): how close a take's voice is to the creator's own speech right beside it, with
/// the production speaker model, on this Mac. The original speech is the use-time guard's (§6.9): the transcript words
/// nearest the patch, in the patch speaker's turns. Nothing is sent.
public enum VoicePerVideoMatch {
    /// The cosine between the take's trimmed speech and that original speech, or nil when either has too little speech
    /// to embed.
    public static func score(take: VoiceLabTakeAudio, input: VoiceLabTakeInput, check: VoiceSpeakerCheck) async -> Double? {
        guard let original = try? VoiceLabTakeRun.guardSpeech(input) else { return nil }
        return await score(speech: take.trimmed, sampleRate: take.sampleRate, original: original, check: check)
    }

    /// The cosine between a take's speech at `sampleRate` and the original speech beside it (16 kHz), or nil when either
    /// has too little speech to embed. A take being made and a take already accepted are scored the same way.
    public static func score(speech: [Float], sampleRate: Int, original: [Float], check: VoiceSpeakerCheck) async -> Double? {
        guard check.available, sampleRate > 0, !speech.isEmpty, !original.isEmpty else { return nil }
        let take = sampleRate == 16_000 ? speech : VoiceConsentAudio.resample(speech, rate: sampleRate)
        guard let generated = try? await check.embedding(take), let beside = try? await check.embedding(original) else { return nil }
        return try? VoiceSpeakerCheck.cosine(generated, beside)
    }
}

/// The anchor's baseline (voice-lab §6.13): its takes already accepted into the owner's projects on this Mac, each scored
/// as `VoicePerVideoMatch` scores a new take, so the first take with a video's own voice has something to compare with.
/// Read only: a project, its source media and its paid audio are read, never written; a paid file is read through a
/// private snapshot. At most `maximum` takes, newest first, and one project open at a time. Nothing is sent.
public enum VoiceAnchorBaseline {
    /// A project as read from its file, with its source media resolved on this Mac.
    public struct Opened: Sendable {
        public let project: Project
        public let media: URL
        public init(project: Project, media: URL) { self.project = project; self.media = media }
    }

    /// Each scored take's cosine, newest first within a project.
    public struct Result: Sendable, Equatable {
        public let scores: [Double]
        public init(scores: [Double]) { self.scores = scores }
        public var mean: Double? { scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count) }
    }

    private struct Pick {
        let project: Int
        let segment: String
        let createdAt: Date
    }

    /// Scores the newest `maximum` of the anchor's takes across `projects`. A take whose paid file or source media is
    /// missing or unreadable is skipped silently. `open` reads one project; it is called for one project at a time,
    /// first to list each project's takes, then again for the projects whose takes are kept.
    public static func measure(projects: [URL], anchorID: String, paidRoot: URL, check: VoiceSpeakerCheck,
                               maximum: Int = VoicePerVideo.maximumBaselineTakes,
                               open: @Sendable (URL) async -> Opened?) async -> Result {
        guard check.available, maximum > 0 else { return Result(scores: []) }
        var picks: [Pick] = []
        var seen = Set<String>()
        for (index, url) in projects.enumerated() {
            if Task.isCancelled { return Result(scores: []) }
            guard let opened = await open(url), FileManager.default.fileExists(atPath: opened.media.path),
                  !VoiceLabDisclosureWriter.isLabelled(opened.media) else { continue }
            for take in VoicePerVideo.anchorTakes(in: opened.project, anchorID: anchorID)
            where FileManager.default.fileExists(atPath: paidRoot.appendingPathComponent(take.asset.file).path)
                && seen.insert(opened.project.id + "/" + take.segment.id).inserted {
                picks.append(Pick(project: index, segment: take.segment.id, createdAt: take.segment.provenance.createdAt))
            }
            picks.sort { $0.createdAt == $1.createdAt ? ($0.project, $0.segment) < ($1.project, $1.segment) : $0.createdAt > $1.createdAt }
            picks = Array(picks.prefix(maximum))
        }
        var scores: [Double] = []
        for index in Set(picks.map(\.project)).sorted() {
            if Task.isCancelled { break }
            let kept = Set(picks.filter { $0.project == index }.map(\.segment))
            guard let opened = await open(projects[index]) else { continue }
            for take in VoicePerVideo.anchorTakes(in: opened.project, anchorID: anchorID) where kept.contains(take.segment.id) {
                if Task.isCancelled { break }
                if let score = await score(take.segment, asset: take.asset, opened: opened, paidRoot: paidRoot, check: check) { scores.append(score) }
            }
        }
        return Result(scores: scores)
    }

    /// One accepted take against the guard's speech beside its window in the source media.
    static func score(_ segment: VoiceLabSegment, asset: VoiceLabAsset, opened: Opened, paidRoot: URL, check: VoiceSpeakerCheck) async -> Double? {
        let project = opened.project
        guard let rate = project.media.source.audio?.sampleRate, rate > 0,
              let take = try? takeSpeech(segment, asset: asset, projectId: project.id, paidRoot: paidRoot) else { return nil }
        let sampleRate: Double = Double(rate)
        let frames = Int64(EditingPrimitives.jsRound(project.media.source.durationSeconds * sampleRate))
        let startSample = Int64(EditingPrimitives.jsRound(segment.replace.start * sampleRate))
        let endSample = Int64(EditingPrimitives.jsRound(segment.replace.end * sampleRate))
        let selection = VoiceLabGuardSpeech.forTake(items: project.transcript?.words ?? [], start: segment.replace.start, end: segment.replace.end,
            startSample: startSample, endSample: endSample, sampleRate: rate, totalFrames: Int(frames))
        guard let original = try? await VoiceLabSourceAudio.guardSpeech(source: opened.media, frames: frames, sampleRate: rate, selection: selection)
        else { return nil }
        return await VoicePerVideoMatch.score(speech: take.samples, sampleRate: take.sampleRate, original: original, check: check)
    }

    /// The take's speech as Rewrite measured it: the paid file (hash-checked, through a private snapshot) mixed to mono,
    /// through the segment's tone match from the first frame, cut to the segment's trim.
    static func takeSpeech(_ segment: VoiceLabSegment, asset: VoiceLabAsset, projectId: String, paidRoot: URL) throws -> (samples: [Float], sampleRate: Int) {
        let prepared = try VoiceLabAssets.preparePaid(asset: asset, projectId: projectId, paidRoot: paidRoot,
                                                      scratchRoot: FileManager.default.temporaryDirectory)
        defer { prepared.invalidate() }
        let reader = try AVAudioFile(forReading: prepared.url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard reader.length > 0, reader.length <= Int64(UInt32.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: AVAudioFrameCount(reader.length)) else { throw VoiceLabError.invalidAudio }
        try reader.read(into: buffer)
        guard let planes = buffer.floatChannelData else { throw VoiceLabError.invalidAudio }
        let channels = Int(buffer.format.channelCount), frames = Int(buffer.frameLength)
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channels {
            for index in 0..<frames { mono[index] += planes[channel][index] / Float(channels) }
        }
        let sections = VoiceLabTilt.sections(tiltDbPerOctave: segment.audio.tiltDbPerOctave ?? 0, sampleRate: prepared.sampleRate)
        if !sections.isEmpty { mono = VoiceLabTilt.apply(mono, sections: sections) }
        let rate: Double = Double(prepared.sampleRate)
        let lower = max(0, Int(EditingPrimitives.jsRound(segment.audio.trimStart * rate)))
        let upper = min(frames, Int(EditingPrimitives.jsRound(segment.audio.trimEnd * rate)))
        guard upper > lower else { throw VoiceLabError.invalidAudio }
        return (Array(mono[lower..<upper]), prepared.sampleRate)
    }
}
