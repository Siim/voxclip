import Foundation

/// The MP4's cover art (ADR-R48, doc/publishing.md §7), written as AtomicParsley writes it: the image in
/// `moov/udta/meta/ilst/covr/data` (an ISO full-box `meta` with the iTunes `hdlr` `mdir`/`appl`, well-known type 13 for a
/// JPEG and 14 for a PNG). AVFoundation's writer embeds an iTunes `covr` on macOS 27 and never on macOS 26, so VoxClip
/// writes the box itself on every version.
///
/// Pure and byte-level: given the file's top-level boxes and its `moov`, `edit` returns the new `moov`. Everything else in
/// the file is kept byte for byte, and inside `moov` only the boxes on the way to the cover and the chunk-offset tables
/// change. An existing `covr` is replaced in place (a later duplicate is dropped), and every other `ilst` item and `udta`
/// child stays. When the media data comes after `moov` (network-optimised exports), every `stco` and `co64` entry past the
/// old `moov` moves by the growth; an `stco` that would pass 2^32 - 1 becomes a `co64`. When `moov` is last, no offset
/// changes. Fragmented movies, sizes it can't follow and truncated boxes are refused before anything is written. Shared
/// vectors: shared/fixtures/cover-art (C# `Mp4CoverArt` replays them).
public enum MP4CoverArt {
    /// Why a file is refused; the file is left as it was.
    public enum Refusal: Error, Equatable, Sendable {
        /// `moof`, `mfra` or `moov/mvex`: a fragmented movie keeps offsets this writer doesn't follow.
        case fragmented
        /// A box runs past its parent or the file, or a header is cut short.
        case truncated
        /// A size smaller than its own header, or a 64-bit size past what a file offset can hold.
        case unfollowableSize
        /// No `moov`.
        case noMovie
        /// Two `moov` boxes, a chunk-offset table whose count disagrees with its size, or a `udta/meta` that isn't iTunes
        /// metadata (`hdlr` `mdir`).
        case malformed
        /// The image is neither a JPEG nor a PNG.
        case unsupportedImage

        /// The shared vectors' name.
        public var wire: String {
            switch self {
            case .fragmented: "fragmented"
            case .truncated: "truncated"
            case .unfollowableSize: "unfollowableSize"
            case .noMovie: "noMovie"
            case .malformed: "malformed"
            case .unsupportedImage: "unsupportedImage"
            }
        }
    }

    /// The `data` atom's well-known type for the image.
    public enum ImageType: UInt32, Sendable {
        case jpeg = 13
        case png = 14

        /// From the image's leading bytes.
        public init?(image: Data) {
            if image.starts(with: [0xFF, 0xD8, 0xFF]) { self = .jpeg }
            else if image.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { self = .png }
            else { return nil }
        }
    }

    /// A box: its four-character type, where it starts, its header's length (8, or 16 with a 64-bit size) and its size.
    /// A size-0 box (to the end) has the size it reaches.
    public struct Box: Equatable, Sendable {
        public let type: String
        public let offset: UInt64
        public let headerSize: UInt64
        public let size: UInt64
        public var end: UInt64 { offset + size }
    }

    /// The new `moov` (header included) that replaces `movie`.
    public struct Edit: Equatable, Sendable {
        public let movie: Box
        public let moov: Data
        public var growth: Int64 { Int64(moov.count) - Int64(movie.size) }
    }

    /// A track's chunk-offset table, in `moov` order.
    public struct ChunkOffsets: Equatable, Sendable {
        public let box: String
        public let entries: [UInt64]
    }

    /// The file's top-level boxes. `read(offset, count)` returns up to `count` bytes at `offset`, so a caller can stream a
    /// file of any length without loading it.
    public static func layout(length: UInt64, read: (UInt64, Int) throws -> Data) throws -> [Box] {
        var boxes: [Box] = []
        var cursor: UInt64 = 0
        while cursor < length {
            guard length - cursor >= 8 else { throw Refusal.truncated }
            let header = [UInt8](try read(cursor, 16))
            guard header.count >= 8 else { throw Refusal.truncated }
            let box = try parsedHeader(header, at: cursor, available: length - cursor)
            boxes.append(box)
            cursor = box.end
        }
        return boxes
    }

    /// The one `moov`, refusing a fragmented movie.
    public static func movie(in layout: [Box]) throws -> Box {
        if layout.contains(where: { $0.type == "moof" || $0.type == "mfra" }) { throw Refusal.fragmented }
        let movies = layout.filter { $0.type == "moov" }
        guard let movie = movies.first else { throw Refusal.noMovie }
        guard movies.count == 1 else { throw Refusal.malformed }
        return movie
    }

    /// The new `moov` with `image` as the cover. `moov` is the movie box's bytes as the file has them.
    public static func edit(layout: [Box], moov: Data, image: Data) throws -> Edit {
        guard let type = ImageType(image: image) else { throw Refusal.unsupportedImage }
        let movie = try movie(in: layout)
        guard UInt64(moov.count) == movie.size else { throw Refusal.truncated }
        let writer = try MovieWriter(bytes: [UInt8](moov), movie: movie, cover: coverItem(type: type, image: [UInt8](image)))
        return Edit(movie: movie, moov: Data(try writer.written()))
    }

    /// The whole file with `image` as its cover, for small files and the shared vectors; the exporter streams instead.
    public static func embed(_ image: Data, in file: Data) throws -> Data {
        let base = file.startIndex
        let boxes = try layout(length: UInt64(file.count)) { offset, count in
            let start = base + Int(offset)
            return file.subdata(in: start..<min(file.endIndex, start + count))
        }
        let movie = try movie(in: boxes)
        let start = base + Int(movie.offset), end = base + Int(movie.end)
        let edit = try edit(layout: boxes, moov: file.subdata(in: start..<end), image: image)
        return file.subdata(in: base..<start) + edit.moov + file.subdata(in: end..<file.endIndex)
    }

    /// Every track's `stco` or `co64` entries in a `moov` box's bytes.
    public static func chunkOffsets(moov: Data) throws -> [ChunkOffsets] {
        let bytes = [UInt8](moov)
        let header = try parsedHeader(bytes, at: 0, available: UInt64(bytes.count))
        return try MovieWriter.tables(in: bytes, root: Node(type: header.type, start: 0, headerSize: Int(header.headerSize), size: Int(header.size)))
            .map { ChunkOffsets(box: $0.node.type, entries: $0.entries) }
    }

    // MARK: Boxes

    /// A box inside the in-memory `moov`, with byte indexes.
    struct Node {
        let type: String
        let start: Int
        let headerSize: Int
        let size: Int
        var body: Int { start + headerSize }
        var end: Int { start + size }
    }

    /// A box header at `offset` with `available` bytes to its parent's end.
    static func parsedHeader(_ header: [UInt8], at offset: UInt64, available: UInt64) throws -> Box {
        guard header.count >= 8, available >= 8 else { throw Refusal.truncated }
        let size32 = read32(header, 0)
        let type = String(decoding: header[4..<8], as: UTF8.self)
        var headerSize: UInt64 = 8
        let size: UInt64
        switch size32 {
        case 0: size = available
        case 1:
            guard header.count >= 16, available >= 16 else { throw Refusal.truncated }
            let large = read64(header, 8)
            guard large >= 16, large <= UInt64(Int64.max) else { throw Refusal.unfollowableSize }
            size = large
            headerSize = 16
        default:
            guard size32 >= 8 else { throw Refusal.unfollowableSize }
            size = UInt64(size32)
        }
        guard size <= available else { throw Refusal.truncated }
        return Box(type: type, offset: offset, headerSize: headerSize, size: size)
    }

    /// The children of `parent` in `bytes`, starting `skip` bytes into its body (4 for a full box's version and flags).
    static func children(_ bytes: [UInt8], of parent: Node, skip: Int = 0) throws -> [Node] {
        var nodes: [Node] = []
        var cursor = parent.body + skip
        guard cursor <= parent.end else { throw Refusal.truncated }
        while cursor < parent.end {
            let available = parent.end - cursor
            let header = Array(bytes[cursor..<min(parent.end, cursor + 16)])
            let box = try parsedHeader(header, at: UInt64(cursor), available: UInt64(available))
            nodes.append(Node(type: box.type, start: cursor, headerSize: Int(box.headerSize), size: Int(box.size)))
            cursor += Int(box.size)
        }
        return nodes
    }

    static func read32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        bytes[at..<at + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    static func read64(_ bytes: [UInt8], _ at: Int) -> UInt64 {
        bytes[at..<at + 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    static func be32(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }
    static func be64(_ value: UInt64) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }

    /// A box around `payload`: a 32-bit size, or a 64-bit one when `large` or when the payload needs it.
    static func box(_ type: String, _ payload: [UInt8], large: Bool = false) -> [UInt8] {
        let small = UInt64(8 + payload.count)
        if !large, small <= UInt64(UInt32.max) { return be32(UInt32(small)) + Array(type.utf8) + payload }
        return be32(1) + Array(type.utf8) + be64(UInt64(16 + payload.count)) + payload
    }

    /// `covr` holding one `data` atom: the well-known type, locale 0, then the image.
    static func coverItem(type: ImageType, image: [UInt8]) -> [UInt8] {
        box("covr", box("data", be32(type.rawValue) + be32(0) + image))
    }

    /// The iTunes metadata handler: `mdir`, manufacturer `appl`, an empty name.
    static let metadataHandler: [UInt8] = box("hdlr", be32(0) + be32(0) + Array("mdirappl".utf8) + be32(0) + be32(0) + [0])
}

/// Rewrites one `moov`: the cover on the way down `udta/meta/ilst`, and the chunk offsets for the growth.
private struct MovieWriter {
    typealias Node = MP4CoverArt.Node
    typealias Refusal = MP4CoverArt.Refusal

    struct Table {
        let node: Node
        let entries: [UInt64]
    }

    let bytes: [UInt8]
    let root: Node
    let movie: MP4CoverArt.Box
    let cover: [UInt8]
    let children: [Node]
    let tables: [Table]

    init(bytes: [UInt8], movie: MP4CoverArt.Box, cover: [UInt8]) throws {
        let header = try MP4CoverArt.parsedHeader(bytes, at: 0, available: UInt64(bytes.count))
        guard header.type == "moov" else { throw Refusal.malformed }
        self.bytes = bytes
        self.movie = movie
        self.cover = cover
        root = Node(type: "moov", start: 0, headerSize: Int(header.headerSize), size: Int(header.size))
        children = try MP4CoverArt.children(bytes, of: root)
        if children.contains(where: { $0.type == "mvex" }) { throw Refusal.fragmented }
        tables = try Self.tables(in: bytes, root: root)
    }

    /// The new `moov`. Its size depends only on which tables become `co64`, so the growth is measured with offsets
    /// unchanged, every `stco` it would push past 2^32 - 1 is promoted, and that repeats until none is left to promote.
    func written() throws -> [UInt8] {
        var promoted = Set<Int>()
        while true {
            let growth = Int64(try moov(growth: 0, promoted: promoted).count) - Int64(movie.size)
            let overflowing = tables.filter { table in
                table.node.type == "stco" && !promoted.contains(table.node.start)
                    && table.entries.contains { moves($0) && Int64($0) + growth > Int64(UInt32.max) }
            }
            if overflowing.isEmpty { return try moov(growth: growth, promoted: promoted) }
            promoted.formUnion(overflowing.map(\.node.start))
        }
    }

    /// An entry at or past the old `moov`'s end points into data after it, which moves by the growth.
    func moves(_ entry: UInt64) -> Bool { entry >= movie.end }

    func raw(_ node: Node) -> [UInt8] { Array(bytes[node.start..<node.end]) }

    /// `node` with new children, keeping its header form (a 64-bit size stays 64-bit) and any `prefix` (a full box's
    /// version and flags).
    func container(_ node: Node, _ parts: [[UInt8]], prefix: [UInt8] = []) -> [UInt8] {
        MP4CoverArt.box(node.type, prefix + parts.flatMap { $0 }, large: node.headerSize == 16)
    }

    func moov(growth: Int64, promoted: Set<Int>) throws -> [UInt8] {
        var parts = try children.map { child -> [UInt8] in
            switch child.type {
            case "trak": try offsets(child, growth: growth, promoted: promoted, path: ["mdia", "minf", "stbl"])
            default: raw(child)
            }
        }
        if let index = children.firstIndex(where: { $0.type == "udta" }) {
            parts[index] = try userData(children[index])
        } else {
            parts.append(MP4CoverArt.box("udta", newMetadata()))
        }
        return container(root, parts)
    }

    /// The track's boxes down `path` to its `stbl`, whose `stco`/`co64` move by `growth`.
    func offsets(_ node: Node, growth: Int64, promoted: Set<Int>, path: ArraySlice<String>) throws -> [UInt8] {
        let parts = try MP4CoverArt.children(bytes, of: node).map { child -> [UInt8] in
            if let next = path.first, child.type == next {
                return try offsets(child, growth: growth, promoted: promoted, path: path.dropFirst())
            }
            guard path.isEmpty, child.type == "stco" || child.type == "co64",
                  let table = tables.first(where: { $0.node.start == child.start }) else { return raw(child) }
            return rewritten(table, growth: growth, promote: promoted.contains(child.start))
        }
        return container(node, parts)
    }

    func rewritten(_ table: Table, growth: Int64, promote: Bool) -> [UInt8] {
        let entries = table.entries.map { moves($0) ? UInt64(Int64($0) + growth) : $0 }
        let flags = Array(bytes[table.node.body..<table.node.body + 4])
        let count = MP4CoverArt.be32(UInt32(entries.count))
        if table.node.type == "co64" || promote {
            return MP4CoverArt.box("co64", flags + count + entries.flatMap(MP4CoverArt.be64), large: table.node.headerSize == 16)
        }
        return container(table.node, [count] + entries.map { MP4CoverArt.be32(UInt32($0)) }, prefix: flags)
    }

    // MARK: The cover

    func newMetadata() -> [UInt8] {
        MP4CoverArt.box("meta", MP4CoverArt.be32(0) + MP4CoverArt.metadataHandler + MP4CoverArt.box("ilst", cover))
    }

    func userData(_ node: Node) throws -> [UInt8] {
        let nodes = try MP4CoverArt.children(bytes, of: node)
        var parts = nodes.map(raw)
        if let index = nodes.firstIndex(where: { $0.type == "meta" }) {
            parts[index] = try metadata(nodes[index])
        } else {
            parts.append(newMetadata())
        }
        return container(node, parts)
    }

    /// An ISO full-box `meta`, or the QuickTime form whose children start at once (its first child is the `hdlr`).
    func metadata(_ node: Node) throws -> [UInt8] {
        let quickTime = node.size >= node.headerSize + 8 && Array(bytes[node.body + 4..<node.body + 8]) == Array("hdlr".utf8)
        let skip = quickTime ? 0 : 4
        let nodes = try MP4CoverArt.children(bytes, of: node, skip: skip)
        guard let handler = nodes.first(where: { $0.type == "hdlr" }), handler.size >= handler.headerSize + 12,
              Array(bytes[handler.body + 8..<handler.body + 12]) == Array("mdir".utf8) else { throw Refusal.malformed }
        var parts = nodes.map(raw)
        if let index = nodes.firstIndex(where: { $0.type == "ilst" }) {
            parts[index] = try items(nodes[index])
        } else {
            parts.append(MP4CoverArt.box("ilst", cover))
        }
        return container(node, parts, prefix: Array(bytes[node.body..<node.body + skip]))
    }

    /// The `ilst` with the first `covr` replaced in place and any later one dropped, or the cover appended.
    func items(_ node: Node) throws -> [UInt8] {
        let nodes = try MP4CoverArt.children(bytes, of: node)
        guard let first = nodes.firstIndex(where: { $0.type == "covr" }) else { return container(node, nodes.map(raw) + [cover]) }
        let parts = nodes.indices.compactMap { index -> [UInt8]? in
            if index == first { return cover }
            return nodes[index].type == "covr" ? nil : raw(nodes[index])
        }
        return container(node, parts)
    }

    // MARK: Chunk offsets

    /// Every `trak/mdia/minf/stbl` `stco` and `co64`, read and checked.
    static func tables(in bytes: [UInt8], root: Node) throws -> [Table] {
        var found: [Table] = []
        func walk(_ node: Node, _ path: ArraySlice<String>) throws {
            for child in try MP4CoverArt.children(bytes, of: node) {
                if let next = path.first {
                    if child.type == next { try walk(child, path.dropFirst()) }
                } else if child.type == "stco" || child.type == "co64" {
                    found.append(try read(bytes, child))
                }
            }
        }
        try walk(root, ["trak", "mdia", "minf", "stbl"])
        return found
    }

    /// One table; an entry past what a signed file offset holds is refused, so moving it can't wrap.
    static func read(_ bytes: [UInt8], _ node: Node) throws -> Table {
        let width = node.type == "co64" ? 8 : 4
        guard node.size >= node.headerSize + 8 else { throw Refusal.malformed }
        let count = Int(MP4CoverArt.read32(bytes, node.body + 4))
        guard node.size - node.headerSize - 8 == count * width else { throw Refusal.malformed }
        let first = node.body + 8
        let entries = (0..<count).map { index in
            width == 8 ? MP4CoverArt.read64(bytes, first + 8 * index) : UInt64(MP4CoverArt.read32(bytes, first + 4 * index))
        }
        guard entries.allSatisfy({ $0 <= UInt64(Int64.max) >> 1 }) else { throw Refusal.unfollowableSize }
        return Table(node: node, entries: entries)
    }
}
