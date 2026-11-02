#pragma warning disable CS1591
using System.Collections.Immutable;
using System.Text.Json.Serialization;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Core.Domain.ContextDemo;

[JsonConverter(typeof(ContextDemoTargetKindConverter))]
public enum ContextDemoTargetKind
{
    [JsonStringEnumMemberName("desktopApp")] DesktopApp,
    [JsonStringEnumMemberName("codeProject")] CodeProject,
    [JsonStringEnumMemberName("webPage")] WebPage
}

public sealed record ContextDemoTarget(ContextDemoTargetKind Kind, string DisplayName, string Locator);
public sealed record ContextDemoWindowBinding(uint WindowID, int ProcessID, string BundleID);
public sealed record ContextDemoReviewedAction(string Id, string Summary);
public sealed record ContextDemoCaptureRequest(string Id, string PlanId, int Revision, ContextDemoTarget Target,
    double DurationSeconds, ContextDemoWindowBinding? Window, ImmutableArray<ContextDemoReviewedAction> Actions)
{
    public void Validate() => ContextDemoValidation.CaptureRequest(this);
}

public sealed record ContextDemoAsset(string Id, string RequestId, ContextDemoTarget Target, string RelativePath,
    string Sha256, double DurationSeconds, int PixelWidth, int PixelHeight, long ByteSize, DateTimeOffset CreatedAt)
{
    public static string MakeRelativePath(string projectId, string assetId)
    {
        ContextDemoValidation.Require(ContextDemoValidation.ProjectID(projectId) && ContextDemoValidation.FileID(assetId), ContextDemoError.UnsafePath);
        return $"context-demo/{projectId}/{assetId}.mp4";
    }
}

public sealed record ContextDemoPlacement(string Id, string AssetId, TimeRange Source, double EditedStartSeconds)
{
    [JsonIgnore] public double EditedEndSeconds => EditedStartSeconds + Source.End - Source.Start;
}

public sealed record ContextDemoNarrationPiece(TimeRange Source, TimeRange Output, bool Synthetic);
public sealed record ContextDemoNarrationSnapshot(double SampleRate, long OutputSamples, ImmutableArray<ContextDemoNarrationPiece> Pieces)
{
    [JsonIgnore] public double DurationSeconds => OutputSamples / SampleRate;

    public static ContextDemoNarrationSnapshot FromTimeline(RenderTimeline timeline)
    {
        ContextDemoValidation.Require(double.IsFinite(timeline.SampleRate) && timeline.SampleRate is >= 1 and <= 384000 &&
            timeline.OutputSamples is > 0 and <= 9007199254740991, ContextDemoError.InvalidNarration);
        var snapshot = new ContextDemoNarrationSnapshot(timeline.SampleRate, timeline.OutputSamples,
            new TimelinePieces(timeline).Pieces.Select(piece => new ContextDemoNarrationPiece(piece.Source, piece.Edited,
                piece.Kind == TimelinePieceKind.Ai)).ToImmutableArray());
        ContextDemoValidation.Narration(snapshot);
        return snapshot;
    }

    public bool Matches(ContextDemoNarrationSnapshot other) => SampleRate == other.SampleRate &&
        OutputSamples == other.OutputSamples && Pieces.SequenceEqual(other.Pieces);
}

public sealed record ContextDemoDocument(string Format, int Version, string ProjectId, string PlanId, int Revision,
    string SourceContentKey, ContextDemoNarrationSnapshot Narration, ImmutableArray<ContextDemoAsset> Assets,
    ImmutableArray<ContextDemoPlacement> Placements)
{
    public static ContextDemoDocument Create(Project project, string planId, RenderTimeline timeline)
    {
        var document = new ContextDemoDocument("voxclip-context-demo", 1, project.Id, planId, 0, project.Media.Source.ContentKey,
            ContextDemoNarrationSnapshot.FromTimeline(timeline), [], []);
        document.Validate();
        return document;
    }

    public void Validate() => ContextDemoValidation.Document(this);

    public bool IsCurrent(Project project, RenderTimeline timeline)
    {
        try
        {
            Validate();
            return ProjectId == project.Id && SourceContentKey == project.Media.Source.ContentKey &&
                Narration.Matches(ContextDemoNarrationSnapshot.FromTimeline(timeline));
        }
        catch (ContextDemoException) { return false; }
    }

    private ContextDemoDocument Next(IEnumerable<ContextDemoAsset> assets, IEnumerable<ContextDemoPlacement> placements, int expectedRevision)
    {
        Validate();
        ContextDemoValidation.Require(Revision == expectedRevision && Revision < int.MaxValue, ContextDemoError.StaleRevision);
        var next = this with
        {
            Revision = Revision + 1,
            Assets = assets.OrderBy(asset => asset.Id, StringComparer.Ordinal).ToImmutableArray(),
            Placements = placements.OrderBy(placement => placement.EditedStartSeconds).ThenBy(placement => placement.Id, StringComparer.Ordinal).ToImmutableArray()
        };
        next.Validate();
        return next;
    }

    public ContextDemoDocument ReplacingPlacement(ContextDemoPlacement placement, int expectedRevision) =>
        Next(Assets, Placements.Where(item => item.Id != placement.Id).Append(placement), expectedRevision);

    public ContextDemoDocument RemovingPlacement(string id, int expectedRevision)
    {
        ContextDemoValidation.Require(Placements.Any(item => item.Id == id), ContextDemoError.InvalidPlacement);
        return Next(Assets, Placements.Where(item => item.Id != id), expectedRevision);
    }

    public ContextDemoDocument AddingAsset(ContextDemoAsset asset, int expectedRevision)
    {
        ContextDemoValidation.Require(Assets.All(item => item.Id != asset.Id), ContextDemoError.DuplicateIdentity);
        return Next(Assets.Append(asset), Placements, expectedRevision);
    }

    public ContextDemoDocument ReplacingAsset(string id, ContextDemoAsset asset, int expectedRevision)
    {
        ContextDemoValidation.Require(Assets.Any(item => item.Id == id), ContextDemoError.MissingAsset);
        ContextDemoValidation.Require(asset.Id == id, ContextDemoError.InvalidAsset);
        return Next(Assets.Select(item => item.Id == id ? asset : item), Placements, expectedRevision);
    }

    public ContextDemoDocument Placing(ContextDemoAsset asset, ContextDemoPlacement placement, int expectedRevision)
    {
        ContextDemoValidation.Require(placement.AssetId == asset.Id, ContextDemoError.MissingAsset);
        var existing = Assets.FirstOrDefault(item => item.Id == asset.Id);
        ContextDemoValidation.Require(existing is null || existing == asset, ContextDemoError.DuplicateIdentity);
        return Next(existing is null ? Assets.Append(asset) : Assets,
            Placements.Where(item => item.Id != placement.Id).Append(placement), expectedRevision);
    }
}

public enum ContextDemoError
{
    UnsupportedVersion, InvalidTarget, InvalidRequest, UnsafePath, InvalidAsset, InvalidNarration,
    InvalidPlacement, DuplicateIdentity, MissingAsset, OverlappingPlacements, StaleRevision, StaleNarration, Cancelled
}

public sealed class ContextDemoException(ContextDemoError code) : Exception(code.ToString())
{
    public ContextDemoError Code { get; } = code;
}

public sealed record ContextDemoNarrationMapping(TimeRange Source, TimeRange Output);
public sealed record ContextDemoPreparedPlacement(string Id, string AssetId, TimeRange Source, TimeRange Output,
    ImmutableArray<ContextDemoNarrationMapping> NarrationMappings);
public sealed record ContextDemoRenderInput
{
    public string ProjectId { get; }
    public string PlanId { get; }
    public int Revision { get; }
    public string SourceContentKey { get; }
    public ContextDemoNarrationSnapshot Narration { get; }
    public TimeRange Scope { get; }
    public ImmutableArray<ContextDemoPreparedPlacement> Placements { get; }
    public ImmutableArray<ContextDemoAsset> Assets { get; }
    public bool PreservesNarration => true;
    public double CaptureAudioGain => 0;

    internal ContextDemoRenderInput(ContextDemoDocument document, TimeRange scope,
        ImmutableArray<ContextDemoPreparedPlacement> placements, ImmutableArray<ContextDemoAsset> assets)
    {
        ProjectId = document.ProjectId;
        PlanId = document.PlanId;
        Revision = document.Revision;
        SourceContentKey = document.SourceContentKey;
        Narration = document.Narration;
        Scope = scope;
        Placements = placements;
        Assets = assets;
    }

    public void Verify(string projectId, string sourceContentKey, RenderTimeline timeline)
    {
        ContextDemoValidation.Require(ProjectId == projectId && SourceContentKey == sourceContentKey &&
            Narration.Matches(ContextDemoNarrationSnapshot.FromTimeline(timeline)), ContextDemoError.StaleNarration);
    }

    public void VerifyRenderedTimeline(RenderTimeline timeline) => ContextDemoPlanner.VerifyRenderedTimeline(this, timeline);
}
