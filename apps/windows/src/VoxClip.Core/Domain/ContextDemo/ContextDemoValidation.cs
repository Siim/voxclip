#pragma warning disable CS1591
using System.Text.RegularExpressions;
using System.Diagnostics.CodeAnalysis;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.ContextDemo;

public static class ContextDemoValidation
{
    internal static void Require([DoesNotReturnIf(false)] bool condition, ContextDemoError code)
    {
        if (!condition) throw new ContextDemoException(code);
    }

    private static bool Matches(string? value, string pattern) => value is not null &&
        Regex.IsMatch(value, "\\A(?:" + pattern + ")\\z", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
    internal static bool Identifier(string? value) => Matches(value, "[A-Za-z0-9][A-Za-z0-9._:-]{0,63}");
    internal static bool ProjectID(string? value) => Matches(value, "[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}");
    internal static bool FileID(string? value) => Matches(value, "[a-z0-9][a-z0-9_-]{0,63}") &&
        !Matches(value, "con|prn|aux|nul|com[1-9]|lpt[1-9]");
    private static bool Text(string? value, int maximum) => !string.IsNullOrWhiteSpace(value) &&
        System.Text.Encoding.UTF8.GetByteCount(value) <= maximum && !value.Any(char.IsControl);

    public static void Target(ContextDemoTarget value)
    {
        Require(value is not null && Text(value.DisplayName, 256) && Text(value.Locator, 4096), ContextDemoError.InvalidTarget);
        switch (value.Kind)
        {
            case ContextDemoTargetKind.DesktopApp:
                Require(Matches(value.Locator, "[A-Za-z0-9][A-Za-z0-9._!-]{0,255}"), ContextDemoError.InvalidTarget);
                break;
            case ContextDemoTargetKind.CodeProject:
                Require(Uri.TryCreate(value.Locator, UriKind.Absolute, out var project) && project.Scheme == "file" &&
                    (project.Host.Length == 0 || project.Host == "localhost") && project.UserInfo.Length == 0 &&
                    project.Query.Length == 0 && project.Fragment.Length == 0 &&
                    !Uri.UnescapeDataString(value.Locator).Any(char.IsControl) &&
                    Uri.UnescapeDataString(value.Locator).Split('/').All(component => component != ".."), ContextDemoError.InvalidTarget);
                break;
            case ContextDemoTargetKind.WebPage:
                Require(Uri.TryCreate(value.Locator, UriKind.Absolute, out var page) && page.Scheme is "https" or "http" &&
                    page.Host.Length > 0 && page.UserInfo.Length == 0, ContextDemoError.InvalidTarget);
                break;
            default: throw new ContextDemoException(ContextDemoError.InvalidTarget);
        }
    }

    public static void CaptureRequest(ContextDemoCaptureRequest value)
    {
        Target(value.Target);
        Require(Identifier(value.Id) && Identifier(value.PlanId) && value.Revision >= 0 && double.IsFinite(value.DurationSeconds) &&
            value.DurationSeconds is > 0 and <= 30 && !value.Actions.IsDefault && value.Actions.Length <= 64, ContextDemoError.InvalidRequest);
        var identities = new HashSet<string>(StringComparer.Ordinal);
        foreach (var action in value.Actions)
        {
            Require(Identifier(action.Id) && Text(action.Summary, 1024), ContextDemoError.InvalidRequest);
            Require(identities.Add(action.Id), ContextDemoError.DuplicateIdentity);
        }
        if (value.Window is { } window)
            Require(window.WindowID > 0 && window.ProcessID > 0 && Matches(window.BundleID, "[A-Za-z0-9][A-Za-z0-9._-]{0,255}") &&
                (value.Target.Kind != ContextDemoTargetKind.DesktopApp || window.BundleID == value.Target.Locator), ContextDemoError.InvalidRequest);
    }

    public static void Asset(ContextDemoAsset value, string projectId)
    {
        Target(value.Target);
        Require(FileID(value.Id) && Identifier(value.RequestId) && value.RelativePath == ContextDemoAsset.MakeRelativePath(projectId, value.Id),
            ContextDemoError.UnsafePath);
        Require(Matches(value.Sha256, "[0-9a-f]{64}") && double.IsFinite(value.DurationSeconds) && value.DurationSeconds is > 0 and <= 30 &&
            value.PixelWidth is >= 2 and <= 1920 && value.PixelWidth % 2 == 0 && value.PixelHeight is >= 2 and <= 1080 &&
            value.PixelHeight % 2 == 0 && value.ByteSize is > 0 and <= 67108864 && UtcTimestamp.TryRound(value.CreatedAt, out _), ContextDemoError.InvalidAsset);
    }

    internal static bool Range(TimeRange range, bool allowPoint = false) => double.IsFinite(range.Start) && double.IsFinite(range.End) &&
        range.Start >= 0 && (allowPoint ? range.End >= range.Start : range.End > range.Start);
    internal static bool OnGrid(double seconds, double sampleRate)
    {
        var samples = seconds * sampleRate;
        return double.IsFinite(samples) && samples is >= 0 and <= 9007199254740991 && Math.Abs(samples - Math.Round(samples)) <= .000001;
    }

    internal static bool HasSamples(TimeRange range, double sampleRate) => Math.Round(range.End * sampleRate) > Math.Round(range.Start * sampleRate);

    public static void Narration(ContextDemoNarrationSnapshot value)
    {
        Require(double.IsFinite(value.SampleRate) && value.SampleRate is >= 1 and <= 384000 && Math.Round(value.SampleRate) == value.SampleRate &&
            value.OutputSamples is > 0 and <= 9007199254740991 && !value.Pieces.IsDefaultOrEmpty && value.Pieces.Length <= 100000, ContextDemoError.InvalidNarration);
        double outputEnd = 0, sourceEnd = 0;
        foreach (var piece in value.Pieces)
        {
            Require(Range(piece.Source, piece.Synthetic) && Range(piece.Output) && HasSamples(piece.Output, value.SampleRate) &&
                (piece.Synthetic || HasSamples(piece.Source, value.SampleRate)) && OnGrid(piece.Source.Start, value.SampleRate) &&
                OnGrid(piece.Source.End, value.SampleRate) && OnGrid(piece.Output.Start, value.SampleRate) && OnGrid(piece.Output.End, value.SampleRate) &&
                Math.Abs(piece.Output.Start - outputEnd) * value.SampleRate <= .000001 && piece.Source.Start >= sourceEnd, ContextDemoError.InvalidNarration);
            sourceEnd = piece.Source.End;
            outputEnd = piece.Output.End;
        }
        Require(Math.Abs(outputEnd * value.SampleRate - value.OutputSamples) <= .000001, ContextDemoError.InvalidNarration);
    }

    public static void Document(ContextDemoDocument value)
    {
        Require(value.Format == "voxclip-context-demo" && value.Version == 1, ContextDemoError.UnsupportedVersion);
        Require(ProjectID(value.ProjectId) && Identifier(value.PlanId) && Matches(value.SourceContentKey, "[0-9a-f]{64}") && value.Revision >= 0 &&
            !value.Assets.IsDefault && !value.Placements.IsDefault && value.Assets.Length <= 64 && value.Placements.Length <= 64, ContextDemoError.InvalidRequest);
        Narration(value.Narration);
        var assets = new Dictionary<string, ContextDemoAsset>(StringComparer.Ordinal);
        foreach (var asset in value.Assets)
        {
            Asset(asset, value.ProjectId);
            Require(assets.TryAdd(asset.Id, asset), ContextDemoError.DuplicateIdentity);
        }
        var identities = new HashSet<string>(StringComparer.Ordinal);
        double editedEnd = 0;
        foreach (var placement in value.Placements)
        {
            Require(Identifier(placement.Id) && identities.Add(placement.Id), ContextDemoError.DuplicateIdentity);
            if (!assets.TryGetValue(placement.AssetId, out var asset)) throw new ContextDemoException(ContextDemoError.MissingAsset);
            Require(Range(placement.Source) && HasSamples(placement.Source, value.Narration.SampleRate) && placement.Source.End <= asset.DurationSeconds && double.IsFinite(placement.EditedStartSeconds) &&
                placement.EditedStartSeconds >= 0 && double.IsFinite(placement.EditedEndSeconds) && placement.EditedEndSeconds <= value.Narration.DurationSeconds &&
                OnGrid(placement.Source.Start, value.Narration.SampleRate) && OnGrid(placement.Source.End, value.Narration.SampleRate) &&
                OnGrid(placement.EditedStartSeconds, value.Narration.SampleRate) && OnGrid(placement.EditedEndSeconds, value.Narration.SampleRate), ContextDemoError.InvalidPlacement);
            Require(placement.EditedStartSeconds >= editedEnd, ContextDemoError.OverlappingPlacements);
            editedEnd = placement.EditedEndSeconds;
        }
    }
}
