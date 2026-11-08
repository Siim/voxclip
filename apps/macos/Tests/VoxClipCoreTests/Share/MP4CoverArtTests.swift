import CryptoKit
import Foundation
import Testing
@testable import VoxClipCore

/// The MP4 cover-art writer (ADR-R48, doc/publishing.md §7) replaying shared/fixtures/cover-art, which
/// tools/fixtures/cover-art/generate_cover_art.py lays out from scratch and C# `Mp4CoverArtReplayTests` replays too.
@Suite("MP4 cover art")
struct MP4CoverArtTests {
    struct Case: Decodable {
        struct Table: Decodable, Equatable {
            let box: String
            let entries: [UInt64]
        }
        let id: String
        let input: String
        let inputSize: Int
        let inputSha256: String
        let image: String
        let refusal: String?
        let decodes: Bool?
        let growth: Int64?
        let outputSize: Int?
        let outputSha256: String?
        let inputChunkOffsets: [Table]?
        let chunkOffsets: [Table]?
        let boxes: [String]?
    }

    struct Document: Decodable {
        let schema: String
        let coverTypes: [String: UInt32]
        let caseCount: Int
        let cases: [Case]
    }

    static func document() throws -> Document {
        try JSONDecoder().decode(Document.self, from: FixtureLoader.data("fixtures/cover-art/cover-art-cases.json"))
    }

    static func file(_ name: String) throws -> Data { try FixtureLoader.data("fixtures/cover-art/" + name) }

    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func output(_ item: Case) throws -> Data { try MP4CoverArt.embed(file(item.image), in: file(item.input)) }

    static func tables(_ file: Data) throws -> [MP4CoverArt.ChunkOffsets] {
        let boxes = try MP4CoverArt.layout(length: UInt64(file.count)) { offset, count in
            file.subdata(in: Int(offset)..<min(file.count, Int(offset) + count))
        }
        let movie = try MP4CoverArt.movie(in: boxes)
        return try MP4CoverArt.chunkOffsets(moov: file.subdata(in: Int(movie.offset)..<Int(movie.end)))
    }

    static func named(_ id: String) throws -> Case { try #require(try document().cases.first { $0.id == id }) }

    static func count(_ needle: String, in data: Data) -> Int {
        var found = 0
        var from = data.startIndex
        while let range = data.range(of: Data(needle.utf8), in: from..<data.endIndex) {
            found += 1
            from = range.upperBound
        }
        return found
    }

    @Test func theFileHasItsSchemaTypesAndCases() throws {
        let raw = try #require(try JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/cover-art/cover-art-cases.json")) as? [String: Any])
        #expect(Set(raw.keys) == ["schema", "description", "coverTypes", "caseCount", "cases"])
        let document = try Self.document()
        #expect(document.schema == "voxclip-cover-art-cases/1")
        #expect(document.coverTypes == ["jpeg": MP4CoverArt.ImageType.jpeg.rawValue, "png": MP4CoverArt.ImageType.png.rawValue])
        #expect(document.caseCount == 17 && document.cases.count == 17)
        #expect(document.cases.filter { $0.refusal != nil }.count == 7)
    }

    /// Every case: the writer's output has the generator's size and SHA-256, or the case's refusal.
    @Test func everyVectorReplaysByteForByte() throws {
        for item in try Self.document().cases {
            let input = try Self.file(item.input)
            #expect(input.count == item.inputSize && Self.sha(input) == item.inputSha256, "\(item.id): input")
            if let refusal = item.refusal {
                #expect(throws: (any Error).self, "\(item.id)") { try Self.output(item) }
                do { _ = try Self.output(item) } catch let error as MP4CoverArt.Refusal {
                    #expect(error.wire == refusal, "\(item.id): \(error.wire)")
                }
                continue
            }
            let output = try Self.output(item)
            #expect(output.count == item.outputSize, "\(item.id): size \(output.count)")
            #expect(Self.sha(output) == item.outputSha256, "\(item.id): bytes")
            #expect(try Self.tables(output).map { Case.Table(box: $0.box, entries: $0.entries) } == item.chunkOffsets, "\(item.id): offsets")
            #expect(Int64(output.count) - Int64(input.count) == item.growth, "\(item.id): growth")
        }
    }

    /// moov before mdat: every stco and co64 entry moves by exactly the growth.
    @Test(arguments: ["moov-first", "moov-first-png", "existing-covr", "co64", "mdat-largesize", "mdat-to-end"])
    func moovFirstMovesEveryEntryByTheGrowth(_ id: String) throws {
        let item = try Self.named(id)
        let input = try Self.file(item.input)
        let output = try Self.output(item)
        let growth = Int64(output.count) - Int64(input.count)
        #expect(growth != 0)
        let before = try Self.tables(input), after = try Self.tables(output)
        #expect(before.map(\.box) == after.map(\.box))
        #expect(zip(before, after).allSatisfy { old, new in zip(old.entries, new.entries).allSatisfy { Int64($1) == Int64($0) + growth } })
        #expect(before.map(\.entries.count) == after.map(\.entries.count))
    }

    /// moov after mdat: no offset changes, and everything before moov is the input's bytes.
    @Test(arguments: ["moov-last", "udta-without-meta", "moov-to-end"])
    func moovLastKeepsEveryOffset(_ id: String) throws {
        let item = try Self.named(id)
        let input = try Self.file(item.input)
        let output = try Self.output(item)
        #expect(try Self.tables(output) == Self.tables(input))
        let boxes = try MP4CoverArt.layout(length: UInt64(input.count)) { offset, count in
            input.subdata(in: Int(offset)..<min(input.count, Int(offset) + count))
        }
        let movie = try MP4CoverArt.movie(in: boxes)
        #expect(output.prefix(Int(movie.offset)) == input.prefix(Int(movie.offset)))
    }

    /// An existing covr is replaced in place; the title, the encoder tag and the location in udta stay byte for byte.
    @Test func anExistingCoverIsReplacedAndTheOtherItemsKept() throws {
        let item = try Self.named("existing-covr")
        let input = try Self.file(item.input), jpeg = try Self.file("cover.jpg"), png = try Self.file("cover.png")
        let output = try Self.output(item)
        #expect(Self.count("covr", in: input) == 1 && Self.count("covr", in: output) == 1)
        #expect(output.range(of: png) == nil && output.range(of: jpeg) != nil)
        for kept in ["nam", "too", "xyz"] {
            let tag = Data([0xA9]) + Data(kept.utf8)
            let old = try #require(input.range(of: tag)), new = try #require(output.range(of: tag))
            let size = input[old.lowerBound - 4..<old.lowerBound].reduce(0) { $0 << 8 | Int($1) }
            #expect(input[old.lowerBound - 4..<old.lowerBound - 4 + size] == output[new.lowerBound - 4..<new.lowerBound - 4 + size], "\(kept)")
        }
        // The order in ilst: title, cover, encoder.
        let title = try #require(output.range(of: Data([0xA9]) + Data("nam".utf8))).lowerBound
        let cover = try #require(output.range(of: Data("covr".utf8))).lowerBound
        let tool = try #require(output.range(of: Data([0xA9]) + Data("too".utf8))).lowerBound
        #expect(title < cover && cover < tool)
        #expect(try Self.tables(output).allSatisfy { $0.box == "stco" })
    }

    /// An stco entry the growth would push past 2^32 - 1 turns its table into a co64; the other track's stays an stco.
    @Test func anOverflowingStcoBecomesACo64() throws {
        let item = try Self.named("stco-overflow")
        let input = try Self.file(item.input)
        let output = try Self.output(item)
        let before = try Self.tables(input), after = try Self.tables(output)
        #expect(before.map(\.box) == ["stco", "stco"] && after.map(\.box) == ["co64", "stco"])
        let growth = Int64(output.count) - Int64(input.count)
        #expect(after[0].entries.allSatisfy { $0 > UInt64(UInt32.max) })
        #expect(zip(before, after).allSatisfy { old, new in zip(old.entries, new.entries).allSatisfy { Int64($1) == Int64($0) + growth } })
        // The co64 adds four bytes per entry beyond the cover itself.
        let plain = try MP4CoverArt.embed(Self.file("cover.jpg"), in: Self.file("moov-first.mp4"))
        #expect(growth == Int64(plain.count) - Int64(try Self.file("moov-first.mp4").count) + 4 * Int64(after[0].entries.count))
    }

    /// Embedding again replaces the first cover: the file is as if only the second image had been embedded.
    @Test func embeddingAgainReplacesTheCover() throws {
        let input = try Self.file("moov-first.mp4"), jpeg = try Self.file("cover.jpg"), png = try Self.file("cover.png")
        let twice = try MP4CoverArt.embed(png, in: MP4CoverArt.embed(jpeg, in: input))
        #expect(twice == (try MP4CoverArt.embed(png, in: input)))
    }

    @Test func refusalsLeaveTheirReasons() throws {
        let input = try Self.file("moov-first.mp4")
        #expect(throws: MP4CoverArt.Refusal.unsupportedImage) { try MP4CoverArt.embed(Data("GIF89a".utf8), in: input) }
        #expect(throws: MP4CoverArt.Refusal.fragmented) { try MP4CoverArt.embed(Self.file("cover.jpg"), in: Self.file("fragmented-mvex.mp4")) }
        #expect(throws: MP4CoverArt.Refusal.fragmented) { try MP4CoverArt.embed(Self.file("cover.jpg"), in: Self.file("fragmented-moof.mp4")) }
        #expect(throws: MP4CoverArt.Refusal.truncated) { try MP4CoverArt.embed(Self.file("cover.jpg"), in: Self.file("truncated.mp4")) }
        #expect(throws: MP4CoverArt.Refusal.truncated) { try MP4CoverArt.embed(Self.file("cover.jpg"), in: Self.file("truncated-child.mp4")) }
        #expect(throws: MP4CoverArt.Refusal.unfollowableSize) { try MP4CoverArt.embed(Self.file("cover.jpg"), in: Self.file("bad-largesize.mp4")) }
        #expect(throws: MP4CoverArt.Refusal.noMovie) { try MP4CoverArt.embed(Self.file("cover.jpg"), in: Self.file("no-moov.mp4")) }
        // A second moov is not ours to guess between.
        let movie = try #require(input.range(of: Data("moov".utf8)))
        let moovSize = input[movie.lowerBound - 4..<movie.lowerBound].reduce(0) { $0 << 8 | Int($1) }
        let doubled = input + input[(movie.lowerBound - 4)..<(movie.lowerBound - 4 + moovSize)]
        #expect(throws: MP4CoverArt.Refusal.malformed) { try MP4CoverArt.embed(Self.file("cover.jpg"), in: doubled) }
    }
}
