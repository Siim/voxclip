@preconcurrency import AVFoundation
import Foundation
import VoxClipCore

public enum RecordingLoudness {
    static let rate = 48_000

    public static func add(project: Project, key: String, label: String?, transcript: Transcript,
                           primary: URL, projectURL: URL? = nil) async throws -> Project {
        var result = try RecordingEdits.apply(.addSpokenSource(key: key, label: label, transcript: transcript, gainDb: nil), project: project).get().project
        let recordingLabel = ProjectClock.build(result).regions.first(where: { $0.key == key })?.label ?? "Recording"
        guard let reference = result.media.additionalSources.first(where: { $0.contentKey == key }),
              let index = result.media.spokenSources?.firstIndex(where: { $0.sourceKey == key }),
              let recording = JSONProjectStore.recordingURL(reference, beside: primary, projectURL: projectURL) else {
            throw VoxClipError.recordingMissing(recordingLabel)
        }
        let cuts = Set(project.edits.cutWordIds)
        let words = (project.transcript?.words ?? []).filter { !cuts.contains($0.id) }
        let gain = try await match(primary: primary, primaryWords: words, recording: recording, words: transcript.words)
        result.media.spokenSources?[index].gainDb = gain
        return result
    }

    public static func match(primary: URL, primaryWords: [TimedWord], recording: URL, words: [TimedWord]) async throws -> Double? {
        func speech(_ words: [TimedWord]) -> [Range<Double>] {
            words.filter { $0.kind == .word && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }
                .map { $0.start..<$0.end }
        }
        guard let original = try await measure(primary, ranges: speech(primaryWords)),
              let added = try await measure(recording, ranges: speech(words)) else { return nil }
        return (min(12, max(-12, original - added)) * 10).rounded() / 10
    }

    static func measure(_ url: URL, ranges: [Range<Double>],
                        isolation: isolated (any Actor)? = #isolation) async throws -> Double? {
        let selected = ranges.filter { !$0.isEmpty }.sorted { $0.lowerBound < $1.lowerBound }.reduce(into: [Range<Double>]()) { result, next in
            if let last = result.last, next.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, next.upperBound)
            } else { result.append(next) }
        }
        guard let first = selected.first, let last = selected.last else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = try await MediaSupport.audioTrack(in: asset) else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let timescale = Int32(rate)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: first.lowerBound, preferredTimescale: timescale),
                                       end: CMTime(seconds: last.upperBound, preferredTimescale: timescale))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: MediaSupport.pcm(rate: Double(rate), channels: 2))
        output.alwaysCopiesSampleData = false
        let provider = reader.outputProvider(for: output)
        guard reader.startReading() else { throw VoxClipError.decodeFailed("Cannot measure recording loudness") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var meter = try SocialLoudnessMeter(sampleRate: rate, channels: 2)
        var index = 0
        while let buffer = try await MediaReadQueue.next(provider) {
            try Task.checkCancellation()
            let start = Int((buffer.presentationTimeStamp.seconds * Double(rate)).rounded())
            let values = try MusicBedRenderer.floats(buffer)
            let end = start + values.count / 2
            while index < selected.count {
                let range = selected[index]
                let lower = Int((range.lowerBound * Double(rate)).rounded())
                let upper = Int((range.upperBound * Double(rate)).rounded())
                if lower >= end { break }
                let from = max(start, lower), to = min(end, upper)
                if from < to {
                    try values.withUnsafeBufferPointer { samples in
                        try meter.append(UnsafeBufferPointer(rebasing: samples[(from - start) * 2..<(to - start) * 2]))
                    }
                }
                if upper > end { break }
                index += 1
            }
        }
        guard reader.status == .completed else { throw VoxClipError.decodeFailed("Recording loudness did not finish decoding") }
        return meter.finish().integratedLufs()
    }
}
