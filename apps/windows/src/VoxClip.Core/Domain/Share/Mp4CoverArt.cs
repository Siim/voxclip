using System.Buffers.Binary;
using System.Text;

namespace VoxClip.Core.Domain.Share;

/// <summary>Why <see cref="Mp4CoverArt"/> refuses a file; the file is left as it was.</summary>
public enum Mp4CoverArtRefusal
{
    /// <summary><c>moof</c>, <c>mfra</c> or <c>moov/mvex</c>: a fragmented movie keeps offsets the writer doesn't follow.</summary>
    Fragmented,
    /// <summary>A box runs past its parent or the file, or a header is cut short.</summary>
    Truncated,
    /// <summary>A size smaller than its own header, or a 64-bit size past what a file offset can hold.</summary>
    UnfollowableSize,
    /// <summary>No <c>moov</c>.</summary>
    NoMovie,
    /// <summary>Two <c>moov</c> boxes, a chunk-offset table whose count disagrees with its size, or a <c>udta/meta</c>
    /// that isn't iTunes metadata (<c>hdlr</c> <c>mdir</c>).</summary>
    Malformed,
    /// <summary>The image is neither a JPEG nor a PNG.</summary>
    UnsupportedImage,
}

/// <summary>A refusal of <see cref="Mp4CoverArt"/>.</summary>
public sealed class Mp4CoverArtException(Mp4CoverArtRefusal refusal) : Exception($"The MP4 cover can't be written: {refusal}.")
{
    /// <summary>Why the file was refused.</summary>
    public Mp4CoverArtRefusal Refusal { get; } = refusal;

    /// <summary>The shared vectors' name for the refusal.</summary>
    public string Wire => Refusal switch
    {
        Mp4CoverArtRefusal.Fragmented => "fragmented",
        Mp4CoverArtRefusal.Truncated => "truncated",
        Mp4CoverArtRefusal.UnfollowableSize => "unfollowableSize",
        Mp4CoverArtRefusal.NoMovie => "noMovie",
        Mp4CoverArtRefusal.Malformed => "malformed",
        _ => "unsupportedImage",
    };
}

/// <summary>The <c>data</c> atom's well-known type for the cover image.</summary>
public enum Mp4CoverImageType : uint
{
    /// <summary>A JPEG.</summary>
    Jpeg = 13,
    /// <summary>A PNG.</summary>
    Png = 14,
}

/// <summary>A box: its four-character type, where it starts, its header's length (8, or 16 with a 64-bit size) and its
/// size. A size-0 box (to the end) has the size it reaches.</summary>
/// <param name="Type">The four-character type.</param>
/// <param name="Offset">Where the box starts.</param>
/// <param name="HeaderSize">8, or 16 with a 64-bit size.</param>
/// <param name="Size">The whole box's size.</param>
public readonly record struct Mp4Box(string Type, ulong Offset, ulong HeaderSize, ulong Size)
{
    /// <summary>Where the box ends.</summary>
    public ulong End => Offset + Size;
}

/// <summary>The new <c>moov</c> (header included) that replaces <paramref name="Movie"/>.</summary>
/// <param name="Movie">The file's movie box.</param>
/// <param name="Moov">The new movie box's bytes.</param>
public sealed record Mp4CoverEdit(Mp4Box Movie, byte[] Moov)
{
    /// <summary>The new movie box's size minus the old one's.</summary>
    public long Growth => Moov.LongLength - (long)Movie.Size;
}

/// <summary>A track's chunk-offset table, in <c>moov</c> order.</summary>
/// <param name="Box"><c>stco</c> or <c>co64</c>.</param>
/// <param name="Entries">The chunk offsets.</param>
public sealed record Mp4ChunkOffsets(string Box, IReadOnlyList<ulong> Entries);

/// <summary>The MP4's cover art (ADR-R48, doc/publishing.md section 7), the twin of the Mac Core's <c>MP4CoverArt</c>:
/// the image in <c>moov/udta/meta/ilst/covr/data</c> (an ISO full-box <c>meta</c> with the iTunes <c>hdlr</c>
/// <c>mdir</c>/<c>appl</c>; type 13 for a JPEG, 14 for a PNG), as AtomicParsley writes it. Pure and byte-level: only the
/// boxes on the way to the cover and the chunk-offset tables change. An existing <c>covr</c> is replaced in place (a later
/// duplicate is dropped) and every other <c>ilst</c> item and <c>udta</c> child stays. When the media data comes after
/// <c>moov</c>, every <c>stco</c>/<c>co64</c> entry past the old <c>moov</c> moves by the growth, and an <c>stco</c> that
/// would pass 2^32 - 1 becomes a <c>co64</c>; when <c>moov</c> is last, no offset changes. Fragmented movies, sizes it can't
/// follow and truncated boxes are refused. Shared vectors: shared/fixtures/cover-art. The Windows exporter doesn't call it
/// yet: the cover export comes with the picture rows (apps/windows/CONTRACTS.md).</summary>
public static class Mp4CoverArt
{
    /// <summary>The image's type from its leading bytes, or null when it is neither a JPEG nor a PNG.</summary>
    public static Mp4CoverImageType? ImageType(ReadOnlySpan<byte> image)
    {
        if (image.StartsWith((ReadOnlySpan<byte>)[0xFF, 0xD8, 0xFF])) return Mp4CoverImageType.Jpeg;
        if (image.StartsWith((ReadOnlySpan<byte>)[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return Mp4CoverImageType.Png;
        return null;
    }

    /// <summary>The file's top-level boxes. <paramref name="read"/> returns up to the asked count of bytes at an offset,
    /// so a caller can stream a file of any length.</summary>
    public static IReadOnlyList<Mp4Box> Layout(ulong length, Func<ulong, int, byte[]> read)
    {
        ArgumentNullException.ThrowIfNull(read);
        var boxes = new List<Mp4Box>();
        ulong cursor = 0;
        while (cursor < length)
        {
            if (length - cursor < 8) throw new Mp4CoverArtException(Mp4CoverArtRefusal.Truncated);
            var header = read(cursor, 16);
            if (header.Length < 8) throw new Mp4CoverArtException(Mp4CoverArtRefusal.Truncated);
            var box = ParsedHeader(header, cursor, length - cursor);
            boxes.Add(box);
            cursor = box.End;
        }
        return boxes;
    }

    /// <summary>The one <c>moov</c>, refusing a fragmented movie.</summary>
    public static Mp4Box Movie(IReadOnlyList<Mp4Box> layout)
    {
        ArgumentNullException.ThrowIfNull(layout);
        if (layout.Any(box => box.Type is "moof" or "mfra")) throw new Mp4CoverArtException(Mp4CoverArtRefusal.Fragmented);
        var movies = layout.Where(box => box.Type == "moov").ToList();
        if (movies.Count == 0) throw new Mp4CoverArtException(Mp4CoverArtRefusal.NoMovie);
        if (movies.Count > 1) throw new Mp4CoverArtException(Mp4CoverArtRefusal.Malformed);
        return movies[0];
    }

    /// <summary>The new <c>moov</c> with <paramref name="image"/> as the cover; <paramref name="moov"/> is the movie box's
    /// bytes as the file has them.</summary>
    public static Mp4CoverEdit Edit(IReadOnlyList<Mp4Box> layout, byte[] moov, byte[] image)
    {
        ArgumentNullException.ThrowIfNull(moov);
        ArgumentNullException.ThrowIfNull(image);
        var type = ImageType(image) ?? throw new Mp4CoverArtException(Mp4CoverArtRefusal.UnsupportedImage);
        var movie = Movie(layout);
        if ((ulong)moov.LongLength != movie.Size) throw new Mp4CoverArtException(Mp4CoverArtRefusal.Truncated);
        var writer = new MovieWriter(moov, movie, CoverItem(type, image));
        return new Mp4CoverEdit(movie, writer.Written());
    }

    /// <summary>The whole file with <paramref name="image"/> as its cover, for small files and the shared vectors; an
    /// exporter streams instead.</summary>
    public static byte[] Embed(byte[] image, byte[] file)
    {
        ArgumentNullException.ThrowIfNull(file);
        var boxes = Layout((ulong)file.LongLength, (offset, count) => file.AsSpan((int)offset, (int)Math.Min(count, file.LongLength - (long)offset)).ToArray());
        var movie = Movie(boxes);
        int start = (int)movie.Offset, end = (int)movie.End;
        var edit = Edit(boxes, file[start..end], image);
        return [.. file.AsSpan(0, start), .. edit.Moov, .. file.AsSpan(end)];
    }

    /// <summary>Every track's <c>stco</c> or <c>co64</c> entries in a <c>moov</c> box's bytes.</summary>
    public static IReadOnlyList<Mp4ChunkOffsets> ChunkOffsets(byte[] moov)
    {
        ArgumentNullException.ThrowIfNull(moov);
        var header = ParsedHeader(moov, 0, (ulong)moov.LongLength);
        var root = new Node(header.Type, 0, (int)header.HeaderSize, (int)header.Size);
        return [.. MovieWriter.Tables(moov, root).Select(table => new Mp4ChunkOffsets(table.Node.Type, table.Entries))];
    }

    internal readonly record struct Node(string Type, int Start, int HeaderSize, int Size)
    {
        public int Body => Start + HeaderSize;
        public int End => Start + Size;
    }

    internal static Mp4Box ParsedHeader(ReadOnlySpan<byte> header, ulong offset, ulong available)
    {
        if (header.Length < 8 || available < 8) throw new Mp4CoverArtException(Mp4CoverArtRefusal.Truncated);
        var size32 = BinaryPrimitives.ReadUInt32BigEndian(header);
        var type = Encoding.UTF8.GetString(header[4..8]);
        ulong headerSize = 8, size;
        switch (size32)
        {
            case 0: size = available; break;
            case 1:
                if (header.Length < 16 || available < 16) throw new Mp4CoverArtException(Mp4CoverArtRefusal.Truncated);
                var large = BinaryPrimitives.ReadUInt64BigEndian(header[8..16]);
                if (large < 16 || large > long.MaxValue) throw new Mp4CoverArtException(Mp4CoverArtRefusal.UnfollowableSize);
                size = large;
                headerSize = 16;
                break;
            default:
                if (size32 < 8) throw new Mp4CoverArtException(Mp4CoverArtRefusal.UnfollowableSize);
                size = size32;
                break;
        }
        if (size > available) throw new Mp4CoverArtException(Mp4CoverArtRefusal.Truncated);
        return new Mp4Box(type, offset, headerSize, size);
    }

    internal static List<Node> Children(byte[] bytes, Node parent, int skip = 0)
    {
        var nodes = new List<Node>();
        var cursor = parent.Body + skip;
        if (cursor > parent.End) throw new Mp4CoverArtException(Mp4CoverArtRefusal.Truncated);
        while (cursor < parent.End)
        {
            var header = bytes.AsSpan(cursor, Math.Min(16, parent.End - cursor));
            var box = ParsedHeader(header, (ulong)cursor, (ulong)(parent.End - cursor));
            nodes.Add(new Node(box.Type, cursor, (int)box.HeaderSize, (int)box.Size));
            cursor += (int)box.Size;
        }
        return nodes;
    }

    internal static byte[] Be32(uint value)
    {
        var bytes = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(bytes, value);
        return bytes;
    }

    internal static byte[] Be64(ulong value)
    {
        var bytes = new byte[8];
        BinaryPrimitives.WriteUInt64BigEndian(bytes, value);
        return bytes;
    }

    /// <summary>A box around the payload: a 32-bit size, or a 64-bit one when <paramref name="large"/> or when needed.</summary>
    internal static byte[] Box(string type, byte[] payload, bool large = false)
    {
        var small = 8L + payload.LongLength;
        if (!large && small <= uint.MaxValue) return [.. Be32((uint)small), .. Encoding.ASCII.GetBytes(type), .. payload];
        return [.. Be32(1), .. Encoding.ASCII.GetBytes(type), .. Be64((ulong)(16L + payload.LongLength)), .. payload];
    }

    /// <summary><c>covr</c> holding one <c>data</c> atom: the well-known type, locale 0, then the image.</summary>
    internal static byte[] CoverItem(Mp4CoverImageType type, byte[] image) =>
        Box("covr", Box("data", [.. Be32((uint)type), .. Be32(0), .. image]));

    /// <summary>The iTunes metadata handler: <c>mdir</c>, manufacturer <c>appl</c>, an empty name.</summary>
    internal static readonly byte[] MetadataHandler = Box("hdlr", [.. Be32(0), .. Be32(0), .. "mdirappl"u8, .. Be32(0), .. Be32(0), 0]);

    /// <summary>Rewrites one <c>moov</c>: the cover on the way down <c>udta/meta/ilst</c>, and the chunk offsets for the
    /// growth.</summary>
    private sealed class MovieWriter
    {
        internal sealed record Table(Node Node, ulong[] Entries);

        private readonly byte[] _bytes;
        private readonly Node _root;
        private readonly Mp4Box _movie;
        private readonly byte[] _cover;
        private readonly List<Node> _children;
        private readonly List<Table> _tables;

        public MovieWriter(byte[] bytes, Mp4Box movie, byte[] cover)
        {
            var header = ParsedHeader(bytes, 0, (ulong)bytes.LongLength);
            if (header.Type != "moov") throw new Mp4CoverArtException(Mp4CoverArtRefusal.Malformed);
            _bytes = bytes;
            _movie = movie;
            _cover = cover;
            _root = new Node("moov", 0, (int)header.HeaderSize, (int)header.Size);
            _children = Children(bytes, _root);
            if (_children.Any(child => child.Type == "mvex")) throw new Mp4CoverArtException(Mp4CoverArtRefusal.Fragmented);
            _tables = Tables(bytes, _root);
        }

        /// <summary>The new <c>moov</c>. Its size depends only on which tables become <c>co64</c>, so the growth is measured
        /// with offsets unchanged, every <c>stco</c> it would push past 2^32 - 1 is promoted, and that repeats until none
        /// is left to promote.</summary>
        public byte[] Written()
        {
            var promoted = new HashSet<int>();
            while (true)
            {
                var growth = Moov(0, promoted).LongLength - (long)_movie.Size;
                var overflowing = _tables.Where(table => table.Node.Type == "stco" && !promoted.Contains(table.Node.Start)
                    && table.Entries.Any(entry => Moves(entry) && (long)entry + growth > uint.MaxValue)).ToList();
                if (overflowing.Count == 0) return Moov(growth, promoted);
                promoted.UnionWith(overflowing.Select(table => table.Node.Start));
            }
        }

        /// <summary>An entry at or past the old <c>moov</c>'s end points into data after it, which moves by the growth.</summary>
        private bool Moves(ulong entry) => entry >= _movie.End;

        private byte[] Raw(Node node) => _bytes[node.Start..node.End];

        private static byte[] Container(Node node, IEnumerable<byte[]> parts, byte[]? prefix = null) =>
            Box(node.Type, [.. prefix ?? [], .. parts.SelectMany(part => part)], node.HeaderSize == 16);

        private byte[] Moov(long growth, HashSet<int> promoted)
        {
            var parts = _children.Select(child => child.Type == "trak" ? Offsets(child, growth, promoted, ["mdia", "minf", "stbl"]) : Raw(child)).ToList();
            var index = _children.FindIndex(child => child.Type == "udta");
            if (index >= 0) parts[index] = UserData(_children[index]);
            else parts.Add(Box("udta", NewMetadata()));
            return Container(_root, parts);
        }

        private byte[] Offsets(Node node, long growth, HashSet<int> promoted, string[] path)
        {
            var parts = Children(_bytes, node).Select(child =>
            {
                if (path.Length > 0 && child.Type == path[0]) return Offsets(child, growth, promoted, path[1..]);
                if (path.Length > 0 || child.Type is not ("stco" or "co64")) return Raw(child);
                var table = _tables.FirstOrDefault(item => item.Node.Start == child.Start);
                return table is null ? Raw(child) : Rewritten(table, growth, promoted.Contains(child.Start));
            });
            return Container(node, parts.ToList());
        }

        private byte[] Rewritten(Table table, long growth, bool promote)
        {
            var entries = table.Entries.Select(entry => Moves(entry) ? (ulong)((long)entry + growth) : entry).ToArray();
            var flags = _bytes[table.Node.Body..(table.Node.Body + 4)];
            var count = Be32((uint)entries.Length);
            if (table.Node.Type == "co64" || promote)
                return Box("co64", [.. flags, .. count, .. entries.SelectMany(Be64)], table.Node.HeaderSize == 16);
            return Container(table.Node, [count, .. entries.Select(entry => Be32((uint)entry))], flags);
        }

        private byte[] NewMetadata() => Box("meta", [.. Be32(0), .. MetadataHandler, .. Box("ilst", _cover)]);

        private byte[] UserData(Node node)
        {
            var nodes = Children(_bytes, node);
            var parts = nodes.Select(Raw).ToList();
            var index = nodes.FindIndex(child => child.Type == "meta");
            if (index >= 0) parts[index] = Metadata(nodes[index]);
            else parts.Add(NewMetadata());
            return Container(node, parts);
        }

        /// <summary>An ISO full-box <c>meta</c>, or the QuickTime form whose children start at once (its first child is
        /// the <c>hdlr</c>).</summary>
        private byte[] Metadata(Node node)
        {
            var quickTime = node.Size >= node.HeaderSize + 8 && _bytes.AsSpan(node.Body + 4, 4).SequenceEqual("hdlr"u8);
            var skip = quickTime ? 0 : 4;
            var nodes = Children(_bytes, node, skip);
            var handler = nodes.FindIndex(child => child.Type == "hdlr");
            if (handler < 0 || nodes[handler].Size < nodes[handler].HeaderSize + 12
                || !_bytes.AsSpan(nodes[handler].Body + 8, 4).SequenceEqual("mdir"u8))
                throw new Mp4CoverArtException(Mp4CoverArtRefusal.Malformed);
            var parts = nodes.Select(Raw).ToList();
            var index = nodes.FindIndex(child => child.Type == "ilst");
            if (index >= 0) parts[index] = Items(nodes[index]);
            else parts.Add(Box("ilst", _cover));
            return Container(node, parts, _bytes[node.Body..(node.Body + skip)]);
        }

        /// <summary>The <c>ilst</c> with the first <c>covr</c> replaced in place and any later one dropped, or the cover
        /// appended.</summary>
        private byte[] Items(Node node)
        {
            var nodes = Children(_bytes, node);
            var first = nodes.FindIndex(child => child.Type == "covr");
            if (first < 0) return Container(node, [.. nodes.Select(Raw), _cover]);
            var parts = nodes.Select((child, index) => index == first ? _cover : child.Type == "covr" ? null : Raw(child))
                .OfType<byte[]>().ToList();
            return Container(node, parts);
        }

        /// <summary>Every <c>trak/mdia/minf/stbl</c> <c>stco</c> and <c>co64</c>, read and checked.</summary>
        internal static List<Table> Tables(byte[] bytes, Node root)
        {
            var found = new List<Table>();
            void Walk(Node node, string[] path)
            {
                foreach (var child in Children(bytes, node))
                {
                    if (path.Length > 0) { if (child.Type == path[0]) Walk(child, path[1..]); }
                    else if (child.Type is "stco" or "co64") found.Add(Read(bytes, child));
                }
            }
            Walk(root, ["trak", "mdia", "minf", "stbl"]);
            return found;
        }

        /// <summary>One table; an entry past what a signed file offset holds is refused, so moving it can't wrap.</summary>
        private static Table Read(byte[] bytes, Node node)
        {
            var width = node.Type == "co64" ? 8 : 4;
            if (node.Size < node.HeaderSize + 8) throw new Mp4CoverArtException(Mp4CoverArtRefusal.Malformed);
            var count = BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(node.Body + 4));
            if ((long)(node.Size - node.HeaderSize - 8) != (long)count * width) throw new Mp4CoverArtException(Mp4CoverArtRefusal.Malformed);
            var first = node.Body + 8;
            var entries = new ulong[count];
            for (var index = 0; index < entries.Length; index++)
                entries[index] = width == 8 ? BinaryPrimitives.ReadUInt64BigEndian(bytes.AsSpan(first + 8 * index))
                    : BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(first + 4 * index));
            if (entries.Any(entry => entry > (ulong)long.MaxValue >> 1)) throw new Mp4CoverArtException(Mp4CoverArtRefusal.UnfollowableSize);
            return new Table(node, entries);
        }
    }
}
