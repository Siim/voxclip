using VoxClip.Core.Domain.Shared;
#pragma warning disable CS1591

namespace VoxClip.Core.Domain.VoiceLab;

public abstract record VoiceLabEditCommand
{
    private VoiceLabEditCommand() { }
    public sealed record Accept(VoiceLabSegment Segment, IReadOnlyList<VoiceLabAsset> Assets, VoiceLabVoiceReference Voice) : VoiceLabEditCommand;
    /// <summary><c>Voice</c> is null when every segment is the user's own recorded take, which uses no clone (<see cref="VoiceLabRecordedTake"/>).</summary>
    public sealed record AcceptAll(IReadOnlyList<VoiceLabSegment> Segments, IReadOnlyList<VoiceLabAsset> Assets, VoiceLabVoiceReference? Voice) : VoiceLabEditCommand;
    public sealed record SetEnabled(string SegmentId, bool Enabled) : VoiceLabEditCommand;
    public sealed record Delete(string SegmentId) : VoiceLabEditCommand;
    public sealed record ChooseCandidate(string SegmentId, int Index) : VoiceLabEditCommand;

    public string ActionName => this switch
    {
        AcceptAll => "Accept Voice Lab takes",
        Accept => "Accept Voice Lab take",
        SetEnabled { Enabled: true } => "Turn on Voice Lab",
        SetEnabled => "Turn off Voice Lab",
        Delete => "Delete Voice Lab segment",
        ChooseCandidate => "Choose Voice Lab take",
        _ => throw new InvalidOperationException()
    };
    public Project ApplyingTo(Project project, VoiceLabOutputScope? outputScope = null) => this switch
    {
        Accept accept => ApplyAccept(project, new([accept.Segment], accept.Assets, accept.Voice), outputScope ?? VoiceLabOutputScope.Full),
        AcceptAll accept => ApplyAccept(project, accept, outputScope ?? VoiceLabOutputScope.Full),
        SetEnabled enabled => VoiceLabProject.SetEnabled(project, enabled.SegmentId, enabled.Enabled),
        Delete delete => VoiceLabProject.Delete(project, delete.SegmentId),
        ChooseCandidate choose => VoiceLabProject.SelectCandidate(project, choose.SegmentId, choose.Index),
        _ => throw new InvalidOperationException()
    };
    private static Project ApplyAccept(Project project, AcceptAll command, VoiceLabOutputScope scope)
    {
        if (command.Segments.Count == 0) throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidSegment);
        var upgraded = VoiceLabProject.UpgradeToV3(project);
        if (command.Voice is { } reference)
        {
            var voice = upgraded.VoiceLab.Voices!.FirstOrDefault(item => item.Id == reference.Id);
            if (voice is not null && voice != reference) throw new VoiceLabProjectException(VoiceLabProjectErrorCode.ConsentUnverified);
            if (voice is null) upgraded = VoiceLabProject.AddVoiceReference(upgraded, reference);
        }
        var assets = upgraded.VoiceLab.Assets!.ToDictionary(asset => asset.Id, StringComparer.Ordinal);
        var added = new List<VoiceLabAsset>();
        var introduced = new HashSet<string>(StringComparer.Ordinal);
        foreach (var asset in command.Assets)
        {
            if (!introduced.Add(asset.Id)) throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidAsset);
            if (assets.TryGetValue(asset.Id, out var existing))
            {
                if (existing != asset) throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidAsset);
            }
            else { assets.Add(asset.Id, asset); added.Add(asset); }
        }
        var result = VoiceLabProject.AcceptAll(upgraded, added, command.Segments);
        VoiceLabProject.Validate(result, scope, command.Segments);
        return result;
    }
}

public sealed record VoiceLabEditStep(Project Before, Project After, string ActionName, bool BeforeDirty = false, bool AfterDirty = true);

public sealed record VoiceLabEditHistory(Project Present, IReadOnlyList<VoiceLabEditStep> UndoStack, IReadOnlyList<VoiceLabEditStep> RedoStack, bool IsDirty = false)
{
    public VoiceLabEditHistory(Project project, bool isDirty = false) : this(project, [], [], isDirty) { }
    public string? UndoActionName => UndoStack.LastOrDefault()?.ActionName;
    public string? RedoActionName => RedoStack.LastOrDefault()?.ActionName;
    public VoiceLabEditHistory Apply(VoiceLabEditCommand command, DateTimeOffset? modifiedAt = null, VoiceLabOutputScope? outputScope = null)
    {
        if (command is VoiceLabEditCommand.AcceptAll) throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidScope);
        return ApplyCore(command, outputScope ?? VoiceLabOutputScope.Full, command.ActionName, modifiedAt);
    }
    public VoiceLabEditHistory Apply(IReadOnlyList<VoiceLabSegment> segments, IReadOnlyList<VoiceLabAsset> assets, VoiceLabVoiceReference? voice,
        VoiceLabOutputScope scope, string actionName, DateTimeOffset? modifiedAt = null)
    {
        if (!(actionName == "Rewrite full take" || System.Text.RegularExpressions.Regex.IsMatch(actionName, @"\ARewrite (clip [1-9][0-9]*|[1-9][0-9]* words)\z")))
            throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidScope);
        return ApplyCore(new VoiceLabEditCommand.AcceptAll(segments, assets, voice), scope, actionName, modifiedAt);
    }
    private VoiceLabEditHistory ApplyCore(VoiceLabEditCommand command, VoiceLabOutputScope scope, string actionName, DateTimeOffset? modifiedAt)
    {
        var next = command.ApplyingTo(Present, scope);
        if (command is VoiceLabEditCommand.SetEnabled enabled && Present.VoiceLab.Segments.Any(segment => segment.Id == enabled.SegmentId && segment.Enabled == enabled.Enabled) ||
            command is VoiceLabEditCommand.ChooseCandidate chosen && Present.VoiceLab.Segments.Any(segment => segment.Id == chosen.SegmentId && segment.SelectedCandidateIndex == chosen.Index)) return this;
        var date = modifiedAt ?? TimeProvider.System.GetUtcNow();
        if (date <= Present.ModifiedAt)
        {
            if (modifiedAt.HasValue) throw new ArgumentOutOfRangeException(nameof(modifiedAt));
            date = Present.ModifiedAt.AddTicks(1);
        }
        next = next with { ModifiedAt = date };
        var step = new VoiceLabEditStep(Present, next, actionName, IsDirty, true);
        return new(next, Array.AsReadOnly(UndoStack.TakeLast(499).Append(step).ToArray()), [], true);
    }
    public VoiceLabEditHistory Undo() => UndoStack.Count == 0 ? this : new(UndoStack[^1].Before,
        Array.AsReadOnly(UndoStack.Take(UndoStack.Count - 1).ToArray()), Array.AsReadOnly(RedoStack.Append(UndoStack[^1]).ToArray()), UndoStack[^1].BeforeDirty);
    public VoiceLabEditHistory Redo() => RedoStack.Count == 0 ? this : new(RedoStack[^1].After,
        Array.AsReadOnly(UndoStack.TakeLast(499).Append(RedoStack[^1]).ToArray()), Array.AsReadOnly(RedoStack.Take(RedoStack.Count - 1).ToArray()), RedoStack[^1].AfterDirty);
}
