using System.Collections.Concurrent;
using System.Security.Cryptography;
using VoxClip.Core.Domain.Captions;

namespace VoxClip.Media.Captions;

internal static class CaptionFontFiles
{
    private static readonly ConcurrentDictionary<(string Root, string File), Lazy<string>> Verified = new();

    internal static string Path(CaptionResources data, string file)
    {
        var font = data.Font(file);
        return Verified.GetOrAdd((data.Root, file), _ => new(() =>
        {
            var root = System.IO.Path.GetFullPath(System.IO.Path.Combine(data.Root, "fonts")) + System.IO.Path.DirectorySeparatorChar;
            var path = System.IO.Path.GetFullPath(System.IO.Path.Combine(root, font.Path));
            if (!path.StartsWith(root, StringComparison.Ordinal)) throw new InvalidDataException("Invalid bundled font path.");
            using var stream = File.OpenRead(path);
            if (!StringComparer.Ordinal.Equals(Convert.ToHexStringLower(SHA256.HashData(stream)), font.Sha256))
                throw new InvalidDataException("Bundled caption font checksum mismatch.");
            return path;
        }, LazyThreadSafetyMode.PublicationOnly)).Value;
    }
}
