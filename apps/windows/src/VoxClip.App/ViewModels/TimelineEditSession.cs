using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

internal sealed class TimelineEditSession(EditorViewModel model, string? scope)
{
    internal Project Baseline { get; } = model.Project;
    internal EditPlan Plan { get; } = RenderCallerInputs.PlacementPlan(model.Project, scope);
    private readonly string? activeScope = model.Project.Edits.ActiveClipId;
    private IReadOnlyList<TimelineEdit> pending = [];
    private string? undoName;

    internal Project PreviewProject { get; private set; } = model.Project;
    internal string? Reason { get; private set; }
    internal bool IsCurrent => !model.IsReadOnly && !model.Busy && ReferenceEquals(Baseline, model.Project) &&
        model.Project.Edits.ActiveClipId == activeScope;

    internal bool Preview(IReadOnlyList<TimelineEdit> edits, string? batchName = null)
    {
        Cancel();
        if (!IsCurrent) return false;
        Reason = Probe(edits, out var next, out _);
        if (Reason is not null) return false;
        PreviewProject = next;
        pending = edits.ToArray();
        undoName = batchName;
        return !ReferenceEquals(next, Baseline);
    }

    internal string? Probe(IReadOnlyList<TimelineEdit> edits, out Project next, out string? name)
    {
        next = Baseline;
        name = null;
        foreach (var edit in edits)
        {
            var plan = ReferenceEquals(next, Baseline) ? Plan : RenderCallerInputs.PlacementPlan(next, scope);
            var result = TimelineEdits.Apply(edit, next, plan, scope);
            if (result is TimelineEditResult.Applied applied)
            {
                next = applied.Project;
                name = applied.UndoName;
            }
            else if (result is TimelineEditResult.Refused refused)
                return refused.Refusal.Copy;
        }
        return null;
    }

    internal bool Commit(IReadOnlyList<TimelineEdit> edits) => Preview(edits) && Commit();

    internal bool Commit()
    {
        if (!IsCurrent || pending.Count == 0) return false;
        Reason = Probe(pending, out var next, out var name);
        pending = [];
        return Reason is null && name is not null && model.ReplaceProject(next, undoName ?? name);
    }

    internal void Cancel()
    {
        pending = [];
        undoName = null;
        Reason = null;
        PreviewProject = Baseline;
    }
}
