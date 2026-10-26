namespace VoxClip.App.Services;

/// <summary>Selects one file from Windows-parsed redirected launch tokens.</summary>
internal static class RedirectedLaunchSelection
{
    internal static string? FilePath(IReadOnlyList<string> tokens, string? executablePath)
    {
        if (tokens.Count == 0) return null;
        var firstIsExecutable = string.Equals(tokens[0], executablePath, StringComparison.OrdinalIgnoreCase);
        var candidate = firstIsExecutable
            ? tokens.Count == 2 ? tokens[1] : null
            : tokens.Count == 1 ? tokens[0] : null;
        if (string.IsNullOrWhiteSpace(candidate) || candidate.StartsWith('-') || candidate.StartsWith('/')) return null;
        // A redirected launch with no file must never import an executable.
        return Path.GetExtension(candidate).Equals(".exe", StringComparison.OrdinalIgnoreCase) ? null : candidate;
    }
}
