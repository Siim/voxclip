using VoxClip.Core.Domain.Share;

namespace VoxClip.Media.Pipeline;

/// <summary>Puts the cover into an MP4 on disk (ADR-R48, doc/publishing.md §7) with Core's <see cref="Mp4CoverArt"/>, twin of the Mac
/// <c>MP4CoverEmbed</c>. It streams: only the top-level headers and <c>moov</c> are read into memory, the new <c>moov</c> is written, and the
/// rest of the file is copied in chunks into a staged file beside it, which then replaces the file in one move. A refusal or a failure
/// leaves the file as it was and removes the staged copy.</summary>
internal static class Mp4CoverEmbed
{
    /// <summary>The largest <c>moov</c> read into memory: a 60 s 1080p export's is about 38 KB, so even hours stay small.</summary>
    internal const ulong MovieLimit = 256UL << 20;
    /// <summary>Bytes copied at a time.</summary>
    internal const int Chunk = 4 << 20;

    /// <summary>Writes <c>&lt;file&gt;.cover</c> beside <paramref name="file"/> with <paramref name="image"/> as its cover art, then moves it
    /// over <paramref name="file"/>.</summary>
    internal static void Embed(byte[] image, string file, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(image);
        var staged = file + ".cover";
        var published = false;
        try
        {
            using (var input = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read, 1, FileOptions.SequentialScan))
            {
                var length = (ulong)input.Length;
                var layout = Mp4CoverArt.Layout(length, (offset, count) =>
                {
                    input.Position = checked((long)offset);
                    var buffer = new byte[count];
                    var read = input.ReadAtLeast(buffer, count, throwOnEndOfStream: false);
                    return read == count ? buffer : buffer[..read];
                });
                var movie = Mp4CoverArt.Movie(layout);
                if (movie.Size > MovieLimit) throw new InvalidDataException($"The MP4's movie box is {movie.Size} bytes.");
                input.Position = checked((long)movie.Offset);
                var moov = new byte[checked((int)movie.Size)];
                input.ReadExactly(moov);
                var edit = Mp4CoverArt.Edit(layout, moov, image);
                using var output = new FileStream(staged, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1, FileOptions.WriteThrough);
                Copy(input, 0, movie.Offset, output, ct);
                output.Write(edit.Moov);
                Copy(input, movie.Offset + movie.Size, length, output, ct);
                output.Flush(true);
            }
            ct.ThrowIfCancellationRequested();
            File.Move(staged, file, overwrite: true);
            published = true;
        }
        finally
        {
            if (!published)
            {
                try { File.Delete(staged); }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
            }
        }
    }

    private static void Copy(FileStream input, ulong start, ulong end, FileStream output, CancellationToken ct)
    {
        if (start >= end) return;
        input.Position = checked((long)start);
        var buffer = new byte[(int)Math.Min((ulong)Chunk, end - start)];
        var left = end - start;
        while (left > 0)
        {
            ct.ThrowIfCancellationRequested();
            var want = (int)Math.Min((ulong)buffer.Length, left);
            var read = input.Read(buffer, 0, want);
            if (read <= 0) throw new EndOfStreamException("The MP4 ended before its boxes did.");
            output.Write(buffer, 0, read);
            left -= (ulong)read;
        }
    }
}
