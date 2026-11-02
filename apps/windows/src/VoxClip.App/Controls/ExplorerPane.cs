using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Input;
using Windows.System;
using VoxClip.App.ViewModels;

namespace VoxClip.App.Controls;

public sealed partial class ExplorerPane : ListView
{
    public bool IsPaneOpen
    {
        get => Visibility == Visibility.Visible;
        set => Visibility = value ? Visibility.Visible : Visibility.Collapsed;
    }

    public ExplorerPane()
    {
        SelectionMode = ListViewSelectionMode.Single;
        IsItemClickEnabled = true;
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        ChoosingItemContainer += (_, args) =>
        {
            var container = args.ItemContainer ?? new ListViewItem();
            container.HorizontalContentAlignment = HorizontalAlignment.Stretch;
            container.Padding = new Thickness(8, 0, 8, 0);
            container.MinHeight = 28;
            container.ContextFlyout = null;
            if (args.Item is SidebarRow row)
            {
                container.IsTabStop = IsDestination(row);
                container.SetBinding(IsEnabledProperty, new Binding { Source = row, Path = new PropertyPath(nameof(SidebarRow.IsEnabled)), Mode = BindingMode.OneWay });
                container.SetBinding(AutomationProperties.NameProperty, new Binding { Source = row, Path = new PropertyPath(nameof(SidebarRow.AccessibleName)), Mode = BindingMode.OneWay });
                AutomationProperties.SetAccessibilityView(container, row.Kind == SidebarKind.Separator ? AccessibilityView.Raw : AccessibilityView.Content);
                AutomationProperties.SetHeadingLevel(container, IsHeading(row) ? AutomationHeadingLevel.Level2 : AutomationHeadingLevel.None);
            }
            args.ItemContainer = container;
        };
    }

    public DependencyObject? ContainerFromMenuItem(object item) => ContainerFromItem(item);
    public object? MenuItemFromContainer(DependencyObject container) => ItemFromContainer(container);
    protected override void OnKeyDown(KeyRoutedEventArgs args)
    {
        if (args.Key is VirtualKey.Up or VirtualKey.Down && !InputState.IsTextFocus(FocusManager.GetFocusedElement(XamlRoot))
            && !InputState.Down(VirtualKey.Control) && !InputState.Down(VirtualKey.Menu) && !InputState.Down(VirtualKey.Shift))
        {
            var current = SelectedIndex;
            var focused = FocusManager.GetFocusedElement(XamlRoot) as DependencyObject;
            for (var index = 0; index < Items.Count; index++)
                if (ContainerFromIndex(index) is DependencyObject container && InputState.DescendsFrom(focused, container)) { current = index; break; }
            var step = args.Key == VirtualKey.Down ? 1 : -1;
            for (var index = current + step; index >= 0 && index < Items.Count; index += step)
            {
                if (Items[index] is not SidebarRow { IsEnabled: true } row || !IsDestination(row)) continue;
                SelectedItem = row;
                ScrollIntoView(row);
                DispatcherQueue.TryEnqueue(() => (ContainerFromItem(row) as Control)?.Focus(FocusState.Keyboard));
                break;
            }
            args.Handled = true;
            return;
        }
        base.OnKeyDown(args);
    }
    private static bool IsDestination(SidebarRow row) => row.Kind is SidebarKind.Home or SidebarKind.FullTake or SidebarKind.Clip or SidebarKind.Suggestion or SidebarKind.Recent or SidebarKind.Action or SidebarKind.Outline;
    private static bool IsHeading(SidebarRow row) => row.Kind is SidebarKind.Project or SidebarKind.SuggestedHeader or SidebarKind.RecentHeader or SidebarKind.ClipsHeader or SidebarKind.OutlineHeader;
}
