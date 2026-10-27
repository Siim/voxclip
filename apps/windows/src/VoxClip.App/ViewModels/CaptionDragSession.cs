using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

internal sealed class CaptionDragSession
{
    private ExportAspect? startingAspect;
    internal bool IsActive => startingAspect is not null;
    internal event EventHandler? Cancelled;
    internal void Begin(ExportAspect aspect) => startingAspect = aspect;
    internal void Cancel()
    {
        if (!IsActive) return;
        startingAspect = null;
        Cancelled?.Invoke(this, EventArgs.Empty);
    }
    internal bool Complete(ExportAspect aspect)
    {
        var valid = startingAspect == aspect;
        startingAspect = null;
        return valid;
    }
}
