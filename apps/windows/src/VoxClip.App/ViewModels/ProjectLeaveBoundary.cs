namespace VoxClip.App.ViewModels;

/// <summary>A leave refused before it started, because the open Rewrite holds paid takes not used or discarded yet (Mac
/// <c>WorkspaceShell.leave</c>, design.md R2 "Closing Rewrite"): nothing froze, saved or closed, and the takes stay.</summary>
internal sealed class ProjectLeaveHeldException() : InvalidOperationException(Copy)
{
    internal const string Copy = "Rewrite has paid takes you haven't used. Use or discard them in Rewrite, then leave this project. They are kept.";
}

/// <summary>Holds the UI-thread project value still while a saved editor is being replaced.</summary>
internal sealed class ProjectLeaveBoundary(EditorViewModel model)
{
    public bool IsLeaving { get; private set; }

    /// <summary>Whether the open Rewrite holds paid takes not used or discarded yet. Leaving disposes that Rewrite and retires its
    /// paid windows (<c>RewriteSession.EditorPropertyChanged</c>), even when the save then fails, so a leave never starts over them:
    /// <see cref="BeginAsync"/> throws <see cref="ProjectLeaveHeldException"/> first. The editor page sets it.</summary>
    internal Func<bool>? HoldsPaidWork { get; set; }

    public async Task BeginAsync(Func<Task> save)
    {
        if (IsLeaving) throw new InvalidOperationException("Project transition is already active.");
        if (HoldsPaidWork?.Invoke() == true) throw new ProjectLeaveHeldException();
        IsLeaving = true;
        model.BeginLeaving();
        try { await save(); }
        catch
        {
            Resume();
            throw;
        }
    }

    public void Resume()
    {
        if (!IsLeaving) return;
        IsLeaving = false;
        model.ResumeEditing();
    }
}
