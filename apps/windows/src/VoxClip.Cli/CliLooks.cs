using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;

namespace VoxClip.Cli;

/// <summary>The looks file the CLI reads (shared/looks/clip-looks.json, looks spec §4.1).</summary>
internal static class CliLooks
{
    /// <summary>The library, or null when the shared files are missing or the file is broken.</summary>
    internal static ClipLookLibrary? Library()
    {
        try { return ClipLookLibrary.Load(SharedResources.ResolveRoot()); }
        catch (VoxClipException) { return null; }
        catch (IOException) { return null; }
    }

    /// <summary>The light and Auto thresholds, or null without the library: the frame pass then measures no light.</summary>
    internal static ClipColorMeasure? Measure() => Library()?.Measure;
}
