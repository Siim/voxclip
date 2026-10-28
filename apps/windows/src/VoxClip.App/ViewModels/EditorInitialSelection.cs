using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

internal static class EditorInitialSelection
{
    internal static async Task ApplyAsync(ExportAspect aspect, Task loaded, Action<int> select, CancellationToken cancellationToken)
    {
        await loaded.WaitAsync(cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        for (var index = 0; index < EditorLayout.Frames.Count; index++)
            if (EditorLayout.Frames[index] == aspect)
            {
                select(index);
                return;
            }
        throw new ArgumentOutOfRangeException(nameof(aspect));
    }
}
