using System.Security.Cryptography;
using System.Text.Json;
using VoxClip.Core.Domain.Share;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.ShareCore;

/// <summary>The MP4 cover-art writer (ADR-R48) replaying shared/fixtures/cover-art, which
/// tools/fixtures/cover-art/generate_cover_art.py lays out from scratch and Mac Core <c>MP4CoverArtTests</c> replays too.</summary>
public sealed class Mp4CoverArtReplayTests
{
    private static JsonElement Document()
    {
        using var document = FixtureLoader.ReadJson(Path.Combine("fixtures", "cover-art", "cover-art-cases.json"));
        return document.RootElement.Clone();
    }

    private static byte[] File(string name) => System.IO.File.ReadAllBytes(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "cover-art", name));

    private static string Sha(byte[] data) => Convert.ToHexStringLower(SHA256.HashData(data));

    private static JsonElement Named(string id) => Document().GetProperty("cases").EnumerateArray().Single(item => item.GetProperty("id").GetString() == id);

    private static byte[] Output(JsonElement item) => Mp4CoverArt.Embed(File(item.GetProperty("image").GetString()!), File(item.GetProperty("input").GetString()!));

    private static IReadOnlyList<Mp4ChunkOffsets> Tables(byte[] file)
    {
        var layout = Mp4CoverArt.Layout((ulong)file.LongLength, (offset, count) => file.AsSpan((int)offset, (int)Math.Min(count, file.LongLength - (long)offset)).ToArray());
        var movie = Mp4CoverArt.Movie(layout);
        return Mp4CoverArt.ChunkOffsets(file[(int)movie.Offset..(int)movie.End]);
    }

    private static string Describe(IEnumerable<Mp4ChunkOffsets> tables) => string.Join("; ", tables.Select(table => table.Box + ":" + string.Join(",", table.Entries)));

    private static string Describe(JsonElement tables) =>
        string.Join("; ", tables.EnumerateArray().Select(table => table.GetProperty("box").GetString() + ":" + string.Join(",", table.GetProperty("entries").EnumerateArray().Select(entry => entry.GetUInt64()))));

    [Fact]
    public void TheFileHasItsSchemaTypesAndCases()
    {
        var document = Document();
        Assert.Equal(["schema", "description", "coverTypes", "caseCount", "cases"], document.EnumerateObject().Select(property => property.Name));
        Assert.Equal("voxclip-cover-art-cases/1", document.GetProperty("schema").GetString());
        Assert.Equal((uint)Mp4CoverImageType.Jpeg, document.GetProperty("coverTypes").GetProperty("jpeg").GetUInt32());
        Assert.Equal((uint)Mp4CoverImageType.Png, document.GetProperty("coverTypes").GetProperty("png").GetUInt32());
        Assert.Equal(17, document.GetProperty("caseCount").GetInt32());
        Assert.Equal(17, document.GetProperty("cases").GetArrayLength());
        Assert.Equal(7, document.GetProperty("cases").EnumerateArray().Count(item => item.TryGetProperty("refusal", out _)));
    }

    [Fact]
    public void EveryVectorReplaysByteForByte()
    {
        foreach (var item in Document().GetProperty("cases").EnumerateArray())
        {
            var id = item.GetProperty("id").GetString()!;
            var input = File(item.GetProperty("input").GetString()!);
            Assert.Equal(item.GetProperty("inputSha256").GetString(), Sha(input));
            if (item.TryGetProperty("refusal", out var refusal))
            {
                var error = Assert.Throws<Mp4CoverArtException>(() => Output(item));
                Assert.True(refusal.GetString() == error.Wire, $"{id}: {error.Wire}");
                continue;
            }
            var output = Output(item);
            Assert.True(item.GetProperty("outputSize").GetInt32() == output.Length, $"{id}: size {output.Length}");
            Assert.True(item.GetProperty("outputSha256").GetString() == Sha(output), $"{id}: bytes");
            Assert.Equal(Describe(item.GetProperty("chunkOffsets")), Describe(Tables(output)));
            Assert.Equal(item.GetProperty("growth").GetInt64(), output.LongLength - input.LongLength);
        }
    }

    [Theory]
    [InlineData("moov-first")]
    [InlineData("moov-first-png")]
    [InlineData("existing-covr")]
    [InlineData("co64")]
    [InlineData("mdat-largesize")]
    [InlineData("mdat-to-end")]
    public void MoovFirstMovesEveryEntryByTheGrowth(string id)
    {
        var item = Named(id);
        var input = File(item.GetProperty("input").GetString()!);
        var output = Output(item);
        var growth = output.LongLength - input.LongLength;
        Assert.NotEqual(0, growth);
        var before = Tables(input);
        var after = Tables(output);
        Assert.Equal(before.Select(table => table.Box), after.Select(table => table.Box));
        Assert.Equal(before.Select(table => table.Entries.Select(entry => (long)entry + growth).ToArray()), after.Select(table => table.Entries.Select(entry => (long)entry).ToArray()));
    }

    [Theory]
    [InlineData("moov-last")]
    [InlineData("udta-without-meta")]
    [InlineData("moov-to-end")]
    public void MoovLastKeepsEveryOffset(string id)
    {
        var item = Named(id);
        var input = File(item.GetProperty("input").GetString()!);
        var output = Output(item);
        Assert.Equal(Describe(Tables(input)), Describe(Tables(output)));
        var layout = Mp4CoverArt.Layout((ulong)input.LongLength, (offset, count) => input.AsSpan((int)offset, (int)Math.Min(count, input.LongLength - (long)offset)).ToArray());
        var movie = Mp4CoverArt.Movie(layout);
        Assert.Equal(input[..(int)movie.Offset], output[..(int)movie.Offset]);
    }

    [Fact]
    public void AnExistingCoverIsReplacedAndTheOtherItemsKept()
    {
        var input = File("existing-covr.mp4");
        var output = Output(Named("existing-covr"));
        Assert.Equal(1, Count(input, "covr"u8));
        Assert.Equal(1, Count(output, "covr"u8));
        Assert.Equal(-1, output.AsSpan().IndexOf(File("cover.png")));
        Assert.NotEqual(-1, output.AsSpan().IndexOf(File("cover.jpg")));
        foreach (var tag in new[] { "nam", "too", "xyz" })
        {
            byte[] name = [0xA9, .. System.Text.Encoding.ASCII.GetBytes(tag)];
            int old = input.AsSpan().IndexOf(name) - 4, now = output.AsSpan().IndexOf(name) - 4;
            var size = (int)System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(input.AsSpan(old));
            Assert.Equal(input[old..(old + size)], output[now..(now + size)]);
        }
        byte[] titleTag = [0xA9, .. "nam"u8], toolTag = [0xA9, .. "too"u8];
        int title = output.AsSpan().IndexOf(titleTag), cover = output.AsSpan().IndexOf("covr"u8), tool = output.AsSpan().IndexOf(toolTag);
        Assert.True(title < cover && cover < tool);
    }

    [Fact]
    public void AnOverflowingStcoBecomesACo64()
    {
        var input = File("stco-overflow.mp4");
        var output = Output(Named("stco-overflow"));
        var before = Tables(input);
        var after = Tables(output);
        Assert.Equal(["stco", "stco"], before.Select(table => table.Box));
        Assert.Equal(["co64", "stco"], after.Select(table => table.Box));
        Assert.All(after[0].Entries, entry => Assert.True(entry > uint.MaxValue));
        var growth = output.LongLength - input.LongLength;
        Assert.Equal(before.Select(table => table.Entries.Select(entry => (long)entry + growth).ToArray()), after.Select(table => table.Entries.Select(entry => (long)entry).ToArray()));
    }

    [Fact]
    public void EmbeddingAgainReplacesTheCover()
    {
        var input = File("moov-first.mp4");
        Assert.Equal(Mp4CoverArt.Embed(File("cover.png"), input), Mp4CoverArt.Embed(File("cover.png"), Mp4CoverArt.Embed(File("cover.jpg"), input)));
    }

    [Fact]
    public void RefusalsLeaveTheirReasons()
    {
        var input = File("moov-first.mp4");
        Assert.Equal(Mp4CoverArtRefusal.UnsupportedImage, Assert.Throws<Mp4CoverArtException>(() => Mp4CoverArt.Embed("GIF89a"u8.ToArray(), input)).Refusal);
        var movie = input.AsSpan().IndexOf("moov"u8) - 4;
        var size = (int)System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(input.AsSpan(movie));
        byte[] doubled = [.. input, .. input.AsSpan(movie, size)];
        Assert.Equal(Mp4CoverArtRefusal.Malformed, Assert.Throws<Mp4CoverArtException>(() => Mp4CoverArt.Embed(File("cover.jpg"), doubled)).Refusal);
    }

    private static int Count(byte[] data, ReadOnlySpan<byte> needle)
    {
        var found = 0;
        var span = data.AsSpan();
        for (var at = span.IndexOf(needle); at >= 0; at = span.IndexOf(needle))
        {
            found++;
            span = span[(at + needle.Length)..];
        }
        return found;
    }
}
