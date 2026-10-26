namespace VoxClip.App.ViewModels;

/// <summary>Holds the UI-thread project value still while a saved editor is being replaced.</summary>
internal sealed class ProjectLeaveBoundary(EditorViewModel model)
{
    public bool IsLeaving { get; private set; }

    public async Task BeginAsync(Func<Task> save)
    {
        if (IsLeaving) throw new InvalidOperationException("Project transition is already active.");
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
