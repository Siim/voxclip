import Foundation

public struct ProjectClock: Sendable, Equatable {
    public struct Region: Sendable, Equatable {
        public let key: String
        public let label: String
        public let colourIndex: Int
        public let offsetSamples: Int
        public let durationSamples: Int
        public let gainDb: Double
        public let prefix: String

        public var endSample: Int { offsetSamples + durationSamples }
    }

    public let sampleRate: Int
    public let regions: [Region]
    public let transcript: Transcript?
    private let regionByWord: [String: Int]

    public var words: [TimedWord] { transcript?.words ?? [] }
    public var totalSamples: Int { regions.last?.endSample ?? 0 }
    var sampleRegions: [MediaInterval] {
        regions.map { MediaInterval(startSample: Int64($0.offsetSamples), endSample: Int64($0.endSample)) }
    }
    public var guardGaps: [Range<Int>] {
        zip(regions, regions.dropFirst()).map { $0.endSample..<$1.offsetSamples }
    }

    public static func build(_ project: Project) -> Self {
        let primary = project.media.source
        let rate = max(1, primary.audio?.sampleRate ?? 48_000)
        let first = Region(key: primary.contentKey, label: label(primary), colourIndex: 0, offsetSamples: 0,
                           durationSamples: samples(primary.durationSeconds, rate: rate), gainDb: 0, prefix: "")
        guard var transcript = project.transcript, let sources = project.media.spokenSources, !sources.isEmpty else {
            return Self(sampleRate: rate, regions: [first], transcript: project.transcript, regionByWord: [:])
        }
        var regions = [first]
        var regionByWord = Dictionary(transcript.words.map { ($0.id, 0) }, uniquingKeysWith: { first, _ in first })
        for source in sources {
            guard let reference = project.media.additionalSources.first(where: { $0.contentKey == source.sourceKey }) else { continue }
            let offset = samples(Double(source.offsetSeconds), rate: rate)
            let duration = samples(reference.durationSeconds, rate: rate)
            guard offset >= regions.last!.endSample, offset <= Int.max - duration else { continue }
            let index = regions.count
            let colour = ((prefixNumber(source.wordIdPrefix) ?? 2) - 1) % 6
            regions.append(Region(key: source.sourceKey, label: source.label ?? label(reference), colourIndex: colour,
                                  offsetSamples: offset, durationSamples: duration, gainDb: source.gainDb ?? 0, prefix: source.wordIdPrefix))
            func shifted(_ seconds: Double) -> Double {
                (Double(offset) + EditingPrimitives.jsRound(seconds * Double(rate))) / Double(rate)
            }
            for var word in source.transcript.words {
                word.id = source.wordIdPrefix + word.id
                word.start = shifted(word.start)
                word.end = shifted(word.end)
                word.rawStart = word.rawStart.map(shifted)
                word.rawEnd = word.rawEnd.map(shifted)
                regionByWord[word.id] = index
                transcript.words.append(word)
            }
        }
        transcript.durationSeconds = Double(regions.last!.endSample) / Double(rate)
        return Self(sampleRate: rate, regions: regions, transcript: transcript, regionByWord: regionByWord)
    }

    public func region(at sample: Int) -> Region? {
        regions.first { $0.offsetSamples <= sample && sample < $0.endSample }
    }

    public func region(of wordId: String) -> Region? {
        if regions.count == 1 { return words.contains { $0.id == wordId } ? regions[0] : nil }
        return regionByWord[wordId].map { regions[$0] }
    }

    public func containsRange(startWordId: String, endWordId: String) -> Bool {
        guard let start = region(of: startWordId) else { return false }
        return start == region(of: endWordId)
    }

    public func resolve(_ sample: Int) -> (key: String, localSample: Int)? {
        region(at: sample).map { ($0.key, sample - $0.offsetSamples) }
    }

    public func mapTime(key: String, localSample: Int) -> Int? {
        guard let region = regions.first(where: { $0.key == key }), 0 <= localSample, localSample < region.durationSamples else { return nil }
        return region.offsetSamples + localSample
    }

    public func sourceTime(_ clockSample: Int) -> (key: String, localSample: Int)? { resolve(clockSample) }

    public func clockTime(key: String, localSeconds: Double) -> Double? {
        guard let sample = Self.validSamples(localSeconds, rate: sampleRate) else { return nil }
        return mapTime(key: key, localSample: sample).map { Double($0) / Double(sampleRate) }
    }

    public func localTime(_ clockSeconds: Double) -> (key: String, localSeconds: Double)? {
        guard let sample = Self.validSamples(clockSeconds, rate: sampleRate), let result = resolve(sample) else { return nil }
        return (result.key, Double(result.localSample) / Double(sampleRate))
    }

    public func pauses(thresholdSeconds: Double) throws -> [Pause] {
        let detected = try detectPauses(words, thresholdSeconds: thresholdSeconds)
        guard regions.count > 1 else { return detected }
        return detected.filter { regionByWord[words[$0.afterIndex].id] == regionByWord[words[$0.afterIndex + 1].id] }
    }

    static func prefixNumber(_ prefix: String) -> Int? {
        guard prefix.first == "r", prefix.last == ".", let number = Int(prefix.dropFirst().dropLast()),
              (2...Int(Int32.max)).contains(number), prefix == "r\(number)." else { return nil }
        return number
    }

    static func validate(_ project: Project) throws {
        let sources = project.media.spokenSources
        try ProjectValidation.require((project.schemaVersion == ProjectMigrations.currentVersion) == (sources != nil), "Spoken recordings require project version 7")
        guard let sources else { return }
        try ProjectValidation.require((1...5).contains(sources.count) && project.transcript != nil, "Spoken recordings need a primary transcript and one to five companions")
        let media = project.media
        let rate = media.source.audio?.sampleRate ?? 48_000
        var end = media.source.durationSeconds
        var previousPrefix = 1
        var keys: Set<String> = [media.source.contentKey]
        var ids = Set(project.transcript?.words.map(\.id) ?? [])
        for source in sources {
            guard keys.insert(source.sourceKey).inserted,
                  ProjectValidation.matches(source.sourceKey, "[a-f0-9]{64}"),
                  media.additionalSources.filter({ $0.contentKey == source.sourceKey }).count == 1,
                  let reference = media.additionalSources.first(where: { $0.contentKey == source.sourceKey }),
                  let prefix = prefixNumber(source.wordIdPrefix), prefix > previousPrefix else {
                throw VoxClipError.projectUnreadable("Invalid spoken recording key or prefix")
            }
            let offset = Double(source.offsetSeconds)
            end = ceil(end) + 1
            try ProjectValidation.require(source.offsetSeconds <= Int(Int32.max) && offset >= end && reference.durationSeconds > 0 &&
                validSamples(offset + reference.durationSeconds, rate: rate) != nil, "Invalid spoken recording offset or duration")
            try ProjectValidation.text(source.label, max: 24)
            try ProjectValidation.require(source.gainDb.map { (-12...12).contains($0) } ?? true, "Invalid spoken recording gain")
            var previousStart = -Double.infinity
            for word in source.transcript.words {
                try ProjectValidation.require(word.start.isFinite && word.end.isFinite && word.start >= 0 && word.start >= previousStart &&
                    word.end > word.start && word.end <= reference.durationSeconds &&
                    ProjectValidation.matches(word.id, EditingLimits.clipIDPattern) &&
                    ProjectValidation.matches(source.wordIdPrefix + word.id, EditingLimits.clipIDPattern) &&
                    ids.insert(source.wordIdPrefix + word.id).inserted, "Invalid spoken recording word or timing")
                previousStart = word.start
            }
            end = offset + reference.durationSeconds
            previousPrefix = prefix
        }
    }

    private static func samples(_ seconds: Double, rate: Int) -> Int { validSamples(seconds, rate: rate) ?? 0 }
    private static func validSamples(_ seconds: Double, rate: Int) -> Int? {
        guard seconds >= 0, rate > 0 else { return nil }
        return Int(exactly: EditingPrimitives.jsRound(seconds * Double(rate)))
    }

    public static func label(_ reference: MediaReference) -> String {
        let path = reference.absolutePath.replacingOccurrences(of: "\\", with: "/")
        let url = URL(fileURLWithPath: path)
        let filename = url.deletingPathExtension().lastPathComponent
        let suffix = reference.recordingHash.map { "--\($0)" } ?? ""
        let stem = !suffix.isEmpty && filename.hasSuffix(suffix) ? String(filename.dropLast(suffix.count)) : filename
        let number = stem.range(of: "(?<![0-9])[0-9]{4}(?![0-9])", options: [.regularExpression, .backwards])
        let originalName = stem == filename ? url.lastPathComponent : "\(stem).\(url.pathExtension)"
        return number.map { String(stem[$0]) } ?? String(String.UnicodeScalarView(originalName.unicodeScalars.prefix(12)))
    }
}
