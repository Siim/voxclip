import CryptoKit
import Foundation
import Testing
@testable import VoxClipCore

/// The persisted timestamp rule (editing §10.1) against `shared/fixtures/projects/timestamps.json`. The Windows Core
/// replays the same cases, so both platforms read and write the same text for the same instant.
@Suite struct TimestampWireRule {
    struct Cases: Decodable {
        struct Text: Decodable { let input: String; let canonical: String }
        struct Rejected: Decodable { let input: String; let reason: String }
        struct Instant: Decodable { let ticks: String; let canonical: String? }
        struct Property: Decodable { let seed: UInt64; let count: Int; let sha256: String; let first: String; let last: String }
        let texts: [Text]
        let rejected: [Rejected]
        let instants: [Instant]
        let property: Property
    }

    /// The example projects keep the whole-second timestamps that writers produced before the three-digit rule, so their
    /// first save writes the same instants in canonical form. An example not listed here must already be canonical.
    static let nonCanonicalExamples: Set<String> = [
        "projects/clip-from-long-take", "projects/interview-take", "voice-lab/clipped-seam-render-v3", "voice-lab/disclosure-above-30-render-v3", "voice-lab/disclosure-at-30-render-v3",
        "voice-lab/full-take-project", "voice-lab/full-take-render-v3", "voice-lab/one-sample-gap-render-v3",
        "voice-lab/passage-project", "voice-lab/passage-render-v3", "voice-lab/touching-render-v3", "voice-lab/voice-changer-half-render-v3",
    ]

    func cases() throws -> Cases { try JSONDecoder().decode(Cases.self, from: FixtureLoader.data("fixtures/projects/timestamps.json")) }

    /// The closest Date to 100 ns ticks since 0001-01-01, as the fixture generator models it.
    static func date(ticks: Int64) -> Date {
        let since = ticks - 631_139_040_000_000_000
        var seconds = since / 10_000_000, remainder = since % 10_000_000
        if remainder < 0 { seconds -= 1; remainder += 10_000_000 }
        return Date(timeIntervalSinceReferenceDate: Double(seconds) + Double(remainder) / 10_000_000)
    }

    /// One timestamp through the project decoder and encoder.
    static func projectRoundTrip(_ text: String) throws -> String {
        let dates = try ProjectJSON.decoder().decode([Date].self, from: JSONEncoder().encode([text]))
        return try JSONDecoder().decode([String].self, from: ProjectJSON.encoder().encode(dates))[0]
    }

    /// A stored document with every timestamp under a key ending in `At` written as a save writes it, for comparing a save
    /// with an example project that predates the three-digit rule.
    static func canonicalTimestamps(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            return .object(object.reduce(into: [:]) { result, item in
                if item.key.hasSuffix("At"), case .string(let text) = item.value, let written = UTCTimestamp.date(from: text).flatMap({ UTCTimestamp.string(from: $0) }) {
                    result[item.key] = .string(written)
                } else { result[item.key] = canonicalTimestamps(item.value) }
            })
        case .array(let array): return .array(array.map(canonicalTimestamps))
        default: return value
        }
    }

    /// Every string under a key ending in `At`, by JSON path.
    static func timestamps(_ value: JSONValue, path: String = "") -> [String: String] {
        switch value {
        case .object(let object):
            return object.reduce(into: [:]) { found, item in
                if item.key.hasSuffix("At"), case .string(let text) = item.value { found[path + "/" + item.key] = text }
                else { found.merge(timestamps(item.value, path: path + "/" + item.key)) { $1 } }
            }
        case .array(let array):
            return array.enumerated().reduce(into: [:]) { found, item in found.merge(timestamps(item.element, path: path + "/\(item.offset)")) { $1 } }
        default: return [:]
        }
    }

    @Test func acceptedTextsLoadAndSaveInCanonicalForm() throws {
        let cases = try cases()
        #expect(cases.texts.count == 317)
        for item in cases.texts {
            let date = try #require(UTCTimestamp.date(from: item.input), "\(item.input)")
            #expect(UTCTimestamp.string(from: date) == item.canonical, "\(item.input)")
            #expect(try Self.projectRoundTrip(item.input) == item.canonical, "\(item.input)")
            #expect(try Self.projectRoundTrip(item.canonical) == item.canonical, "\(item.canonical)")
        }
    }

    @Test func refusedTextsFailEveryReader() throws {
        let cases = try cases()
        #expect(cases.rejected.count == 53)
        guard case .object(var root) = try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/projects/interview-take.voxclip")) else {
            Issue.record("Expected a project object"); return
        }
        for item in cases.rejected {
            #expect(UTCTimestamp.date(from: item.input) == nil, "\(item.reason): \(item.input)")
            #expect(throws: (any Error).self, "\(item.reason): \(item.input)") { try Self.projectRoundTrip(item.input) }
            root["createdAt"] = .string(item.input)
            #expect(throws: VoxClipError.self, "\(item.reason): \(item.input)") { try JSONProjectStore.decode(JSONEncoder().encode(JSONValue.object(root))) }
        }
    }

    @Test func instantsWriteTheSharedText() throws {
        let cases = try cases()
        #expect(cases.instants.count == 232)
        for item in cases.instants {
            let date = Self.date(ticks: try #require(Int64(item.ticks)))
            #expect(UTCTimestamp.string(from: date) == item.canonical, "\(item.ticks)")
            if let canonical = item.canonical {
                #expect(String(decoding: try ProjectJSON.encoder().encode([date]), as: UTF8.self) == "[\n  \"\(canonical)\"\n]", "\(item.ticks)")
            } else {
                #expect(throws: EncodingError.self, "\(item.ticks)") { try ProjectJSON.encoder().encode([date]) }
            }
        }
    }

    /// Seeded instants, never the clock: the same SHA-256 as the generator and the Windows suite, each text stable
    /// through load and save, and each loaded date its instant rounded to the millisecond.
    @Test func seededInstantsMatchTheSharedDigest() throws {
        let property = try cases().property
        var state = property.seed
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        var lines: [String] = []
        for _ in 0..<property.count {
            let milliseconds = Int64(next() % 315_537_897_599_999), offset = Int64(next() % 9_000)
            let ticks = milliseconds * 10_000 + (offset < 4_500 ? offset : offset + 1_000)
            let text = try #require(UTCTimestamp.string(from: Self.date(ticks: ticks)))
            let loaded = try #require(UTCTimestamp.date(from: text))
            #expect(UTCTimestamp.string(from: loaded) == text)
            #expect(UTCTimestamp.milliseconds(from: loaded) == (ticks + 5_000) / 10_000 - 62_135_596_800_000)
            #expect(text.utf8.count == 24 && text.hasSuffix("Z"))
            lines.append(text)
        }
        #expect(lines.first == property.first && lines.last == property.last)
        let digest = SHA256.hash(data: Data(lines.map { $0 + "\n" }.joined().utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == property.sha256)
    }

    @Test func exampleProjectsKeepTheirTimestamps() throws {
        let fixtures = try FixtureLoader.sharedRoot().appendingPathComponent("fixtures")
        var names: [String] = []
        for folder in ["projects", "voice-lab"] {
            names += try FileManager.default.contentsOfDirectory(atPath: fixtures.appendingPathComponent(folder).path)
                .filter { $0.hasSuffix(".voxclip") }.map { "\(folder)/\($0.dropLast(".voxclip".count))" }
        }
        #expect(names.contains("projects/interview-take") && names.contains("projects/clip-from-long-take"))
        for name in names.sorted() {
            let source = try FixtureLoader.data("fixtures/\(name).voxclip")
            let saved = try JSONProjectStore.encode(JSONProjectStore.decode(source))
            #expect(try JSONProjectStore.encode(JSONProjectStore.decode(saved)) == saved, "\(name)")
            let before = Self.timestamps(try JSONDecoder().decode(JSONValue.self, from: source))
            let after = Self.timestamps(try JSONDecoder().decode(JSONValue.self, from: saved))
            #expect(!before.isEmpty && Set(after.keys) == Set(before.keys), "\(name)")
            var canonical = true
            for (path, text) in before {
                let expected = try #require(UTCTimestamp.date(from: text).flatMap { UTCTimestamp.string(from: $0) }, "\(name) \(path)")
                #expect(after[path] == expected, "\(name) \(path)")
                canonical = canonical && expected == text
            }
            #expect(canonical == !Self.nonCanonicalExamples.contains(name), "\(name)")
        }
    }

    @Test func writerRoundsTheExactBinaryValue() {
        // Exact binary halves of a millisecond go to the later instant on both sides of the reference date.
        #expect(UTCTimestamp.string(from: Date(timeIntervalSinceReferenceDate: 0.0625)) == "2001-01-01T00:00:00.063Z")
        #expect(UTCTimestamp.string(from: Date(timeIntervalSinceReferenceDate: -0.0625)) == "2000-12-31T23:59:59.938Z")
        // The binary64 closest to 0.0005 lies just above it, and the one below it just under.
        #expect(UTCTimestamp.string(from: Date(timeIntervalSinceReferenceDate: 0.0005)) == "2001-01-01T00:00:00.001Z")
        #expect(UTCTimestamp.string(from: Date(timeIntervalSinceReferenceDate: 0.0005.nextDown)) == "2001-01-01T00:00:00.000Z")
        #expect(UTCTimestamp.string(from: Date(timeIntervalSinceReferenceDate: -1e-300)) == "2001-01-01T00:00:00.000Z")
        #expect(UTCTimestamp.string(from: Date(timeIntervalSinceReferenceDate: 0)) == "2001-01-01T00:00:00.000Z")
        #expect(UTCTimestamp.string(from: .distantFuture) == "4001-01-01T00:00:00.000Z")
        // Foundation calls distantPast 0001-01-01 in its Julian calendar; proleptic Gregorian, it is 0000-12-30.
        #expect(UTCTimestamp.string(from: .distantPast) == nil)
        #expect(UTCTimestamp.string(from: Date(timeIntervalSinceReferenceDate: .infinity)) == nil)
        #expect(UTCTimestamp.string(from: Date(timeIntervalSinceReferenceDate: .nan)) == nil)
    }

    /// Cache metadata alone still reads any RFC 3339 offset (architecture §8.2) and is rewritten in canonical form.
    @Test func cacheMetadataReadsOffsets() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../.build/timestamp-tests/\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: directory) }
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": directory.path])
        let key = String(repeating: "c", count: 64), entry = locations.cache.appendingPathComponent(key)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try Data(#"{"schema": "voxclip-cache/1", "contentKey": "\#(key)", "createdAt": "2026-10-26T21:13:05.1234567+00:00", "lastAccessAt": "2026-10-26T23:13:05.5+02:00", "bytes": 0}"#.utf8)
            .write(to: entry.appendingPathComponent("meta.json"))
        let read = try #require(try await CacheStore(locations: locations).entry(contentKey: key))
        #expect(UTCTimestamp.string(from: read.createdAt) == "2026-10-26T21:13:05.123Z")
        struct Meta: Decodable { let createdAt: String }
        #expect(try JSONDecoder().decode(Meta.self, from: Data(contentsOf: entry.appendingPathComponent("meta.json"))).createdAt == "2026-10-26T21:13:05.123Z")
        #expect(UTCTimestamp.date(from: "2026-10-26T23:13:05.5+02:00", allowingOffset: true).flatMap { UTCTimestamp.string(from: $0) } == "2026-10-26T21:13:05.500Z")
        #expect(UTCTimestamp.date(from: "0001-01-01T00:30:00+01:00", allowingOffset: true) == nil)
        #expect(UTCTimestamp.date(from: "2026-10-26T21:13:05.123+00:00") == nil)
    }
}
