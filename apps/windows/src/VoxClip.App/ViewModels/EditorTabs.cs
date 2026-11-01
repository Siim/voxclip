namespace VoxClip.App.ViewModels;

public sealed record EditorTab(string? ClipId, string Title, bool Pinned, bool Suggested);

public sealed class EditorTabs
{
    private readonly List<EditorTab> tabs = [new(null, "Full take", true, false)];
    public IReadOnlyList<EditorTab> Items => tabs;
    public string? ActiveClipId { get; private set; }

    public void Open(string? clipId, string title, bool suggested, bool pin = false)
    {
        var existing = tabs.FindIndex(tab => tab.ClipId == clipId);
        if (existing >= 0)
            tabs[existing] = tabs[existing] with { Title = title, Suggested = suggested, Pinned = tabs[existing].Pinned || pin };
        else
        {
            var preview = tabs.FindIndex(tab => !tab.Pinned);
            var tab = new EditorTab(clipId, title, pin, suggested);
            if (preview >= 0 && !pin) tabs[preview] = tab;
            else tabs.Add(tab);
        }
        ActiveClipId = clipId;
    }

    public void Pin(string? clipId)
    {
        var index = tabs.FindIndex(tab => tab.ClipId == clipId);
        if (index >= 0) tabs[index] = tabs[index] with { Pinned = true };
    }

    public bool Close(string? clipId)
    {
        if (clipId is null) return false;
        var index = tabs.FindIndex(tab => tab.ClipId == clipId);
        if (index < 0) return false;
        tabs.RemoveAt(index);
        if (ActiveClipId == clipId) ActiveClipId = tabs[Math.Max(0, index - 1)].ClipId;
        return true;
    }

    public void Reconcile(IReadOnlyList<ClipRow> clips)
    {
        foreach (var tab in tabs.Where(tab => tab.ClipId is not null).ToArray())
        {
            var clip = clips.FirstOrDefault(clip => clip.Id == tab.ClipId);
            if (clip is null) Close(tab.ClipId);
            else
            {
                var index = tabs.IndexOf(tab);
                tabs[index] = tab with { Title = clip.Title, Suggested = ShellViewModel.IsSuggestion(clip) };
            }
        }
    }

    public string? Adjacent(int direction)
    {
        var current = Math.Max(0, tabs.FindIndex(tab => tab.ClipId == ActiveClipId));
        return tabs[(current + direction % tabs.Count + tabs.Count) % tabs.Count].ClipId;
    }
}
