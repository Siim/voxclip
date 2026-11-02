using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using VoxClip.App.ViewModels;

namespace VoxClip.App.Controls;

public sealed partial class EditorTabStrip : Grid
{
    private readonly TabView tabs = new();
    private bool syncing;
    public EditorTabs Model { get; } = new();
    internal object? SelectedItem => tabs.SelectedItem;
    public event EventHandler<string?>? ScopeRequested;

    public EditorTabStrip()
    {
        // Keep the styled control native: a managed TabView subclass constructed in
        // code can project as Control and reject the TabView style during loading.
        tabs.IsAddTabButtonVisible = false;
        tabs.CanDragTabs = false;
        tabs.CanReorderTabs = false;
        tabs.TabWidthMode = TabViewWidthMode.SizeToContent;
        MinWidth = 0;
        AutomationProperties.SetName(tabs, "Editor tabs");
        Children.Add(tabs);
        tabs.SelectionChanged += (_, _) =>
        {
            if (!syncing && SelectedItem is TabViewItem { Tag: EditorTab tab }) ScopeRequested?.Invoke(this, tab.ClipId);
        };
        tabs.TabCloseRequested += (_, args) =>
        {
            if (args.Tab.Tag is EditorTab tab) Close(tab.ClipId);
        };
    }

    public void Sync(IReadOnlyList<ClipRow> clips, string? activeClipId)
    {
        Model.Reconcile(clips);
        var active = clips.FirstOrDefault(clip => clip.Id == activeClipId);
        Model.Open(active?.Id, active?.Title ?? "Full take", active is not null && ShellViewModel.IsSuggestion(active));
        Render();
    }

    public bool CloseActive() => Close(Model.ActiveClipId);
    public void PinActive() { Model.Pin(Model.ActiveClipId); Render(); }
    private bool Close(string? clipId)
    {
        var restoreFocus = InputState.DescendsFrom(FocusManager.GetFocusedElement(XamlRoot) as DependencyObject, this);
        if (!Model.Close(clipId)) return false;
        Render();
        ScopeRequested?.Invoke(this, Model.ActiveClipId);
        if (restoreFocus && SelectedItem is Control target) target.Focus(FocusState.Keyboard);
        return true;
    }

    private void Render()
    {
        syncing = true;
        try
        {
            var wanted = Model.Items.Select(tab => tab.ClipId).ToHashSet();
            foreach (var item in tabs.TabItems.OfType<TabViewItem>().ToArray())
                if (item.Tag is EditorTab tab && !wanted.Contains(tab.ClipId)) tabs.TabItems.Remove(item);
            for (var index = 0; index < Model.Items.Count; index++)
            {
                var tab = Model.Items[index];
                var item = tabs.TabItems.OfType<TabViewItem>().FirstOrDefault(item => item.Tag is EditorTab current && current.ClipId == tab.ClipId);
                if (item is null)
                {
                    item = new TabViewItem();
                    item.DoubleTapped += (_, _) => { if (item.Tag is EditorTab current) { Model.Pin(current.ClipId); Render(); } };
                    tabs.TabItems.Add(item);
                }
                var currentIndex = tabs.TabItems.IndexOf(item);
                if (currentIndex != index) { tabs.TabItems.RemoveAt(currentIndex); tabs.TabItems.Insert(index, item); }
                item.Tag = tab;
                item.Header = tab.Title;
                item.IsClosable = tab.ClipId is not null;
                item.FontStyle = tab.Pinned ? Windows.UI.Text.FontStyle.Normal : Windows.UI.Text.FontStyle.Italic;
                AutomationProperties.SetName(item, tab.Title + (tab.Suggested ? ", suggested clip" : "") + (tab.Pinned ? ", pinned" : ", preview tab"));
                if (tab.ClipId == Model.ActiveClipId) tabs.SelectedItem = item;
            }
        }
        finally { syncing = false; }
    }
}
