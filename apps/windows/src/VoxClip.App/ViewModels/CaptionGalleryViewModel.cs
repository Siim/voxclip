using VoxClip.Core.Domain.Captions;

namespace VoxClip.App.ViewModels;

public sealed class CaptionGalleryViewModel : IDisposable
{
    private readonly EditorViewModel editor;
    private readonly CaptionResources resources;
    private readonly Func<bool> wordsVisible;
    private readonly Dictionary<string, CaptionGalleryPages> pages = new(StringComparer.Ordinal);
    public event EventHandler? Changed;

    public CaptionGalleryViewModel(EditorViewModel editor, CaptionResources resources, Func<bool> wordsVisible)
    {
        this.editor = editor;
        this.resources = resources;
        this.wordsVisible = wordsVisible;
        editor.Changed += EditorChanged;
    }

    public CaptionGallerySample Sample(CaptionStyle style, double playhead)
    {
        if (!pages.TryGetValue(style.Id, out var prepared))
        {
            var scope = editor.Project.Edits.ActiveClipId is { } clip ? CaptionCardScope.Clip(clip) : CaptionCardScope.FullTake;
            pages[style.Id] = prepared = new(editor.Project, scope, style, wordsVisible(), resources);
        }
        return prepared.Sample(playhead);
    }

    public void Refresh()
    {
        pages.Clear();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void EditorChanged(object? sender, EventArgs args) => Refresh();
    public void Dispose() => editor.Changed -= EditorChanged;
}
