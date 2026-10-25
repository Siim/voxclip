using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

/// <summary>Freeze one export range before deriving the edit plan and captions.</summary>
public static class ExportSelection
{
    public static EditState? Scope(EditState? state, ExportTarget target)
    {
        if (state is null)
        {
            if (target is ExportTarget.Clip) throw new ArgumentException("A clip needs a transcript.", nameof(target));
            return null;
        }
        return target switch
        {
            ExportTarget.FullEdit => state with { ActiveClipId = null },
            ExportTarget.Clip clip when state.Clips.Any(item => item.Id == clip.Id) => state with { ActiveClipId = clip.Id },
            _ => throw new ArgumentException("Choose an existing clip.", nameof(target))
        };
    }
}
