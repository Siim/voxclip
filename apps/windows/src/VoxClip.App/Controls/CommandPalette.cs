using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using VoxClip.App.ViewModels;
using Windows.System;

namespace VoxClip.App.Controls;

public sealed partial class CommandPalette : Grid
{
    private readonly TextBox query = new() { Header = "Commands", PlaceholderText = "Type a command…", Margin = new Thickness(12) };
    private readonly ListView results = new() { SelectionMode = ListViewSelectionMode.Single, IsItemClickEnabled = true, MaxHeight = 380 };
    private readonly TextBlock empty = new() { Text = "No matching commands.", Margin = new Thickness(12), Visibility = Visibility.Collapsed };
    private readonly TextBlock helpText = new() { Margin = new Thickness(12), TextWrapping = TextWrapping.Wrap };
    private readonly ScrollViewer help = new() { MaxHeight = 380, Visibility = Visibility.Collapsed };
    private readonly ShellInputSession input = new();
    private IReadOnlyList<ShellCommand> commands = [];
    private bool compositionJustEnded;
    public event EventHandler? Dismissed;
    public event EventHandler? CommandInvoking;
    public bool MayDismiss => input.MayDismiss(compositionJustEnded);

    public CommandPalette()
    {
        MaxWidth = 640;
        VerticalAlignment = VerticalAlignment.Top;
        HorizontalAlignment = HorizontalAlignment.Stretch;
        RowDefinitions.Add(new() { Height = GridLength.Auto });
        RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
        ActualThemeChanged += (_, _) => ApplyTheme();
        Loaded += (_, _) => { Ui.EffectsChanged += EffectsChanged; ApplyTheme(); };
        Unloaded += (_, _) => Ui.EffectsChanged -= EffectsChanged;
        AutomationProperties.SetName(this, "Command palette");
        AutomationProperties.SetName(query, "Search commands");
        AutomationProperties.SetName(results, "Matching commands");
        Children.Add(query);
        Children.Add(results);
        Children.Add(empty);
        help.Content = helpText;
        Children.Add(help);
        SetRow(results, 1);
        SetRow(empty, 1);
        SetRow(help, 1);
        query.TextChanged += (_, _) => Refresh();
        query.TextCompositionStarted += (_, _) => input.CompositionStarted();
        query.TextCompositionEnded += (_, _) => { input.CompositionEnded(); compositionJustEnded = true; };
        AddHandler(UIElement.KeyUpEvent, new KeyEventHandler((_, _) => compositionJustEnded = false), true);
        KeyDown += HandleKey;
        results.ItemClick += (_, args) =>
        {
            if (args.ClickedItem is ListViewItem { Tag: ShellCommand command }) Invoke(command);
        };
    }

    public void Open(IReadOnlyList<ShellCommand> available)
    {
        commands = available;
        compositionJustEnded = false;
        input.CompositionEnded();
        query.Text = "";
        Refresh();
        Visibility = Visibility.Visible;
        query.Focus(FocusState.Keyboard);
    }

    public void UpdateCommands(IReadOnlyList<ShellCommand> available)
    {
        commands = available;
        if (Visibility == Visibility.Visible && !input.IsComposing) Refresh();
    }

    public void ShowKeyboardHelp(string text)
    {
        helpText.Text = text;
        help.Visibility = Visibility.Visible;
        results.Visibility = empty.Visibility = Visibility.Collapsed;
    }

    private void Refresh()
    {
        var focused = XamlRoot is null ? null : FocusManager.GetFocusedElement(XamlRoot) as DependencyObject;
        var restoreResults = InputState.DescendsFrom(focused, results);
        help.Visibility = Visibility.Collapsed;
        results.Visibility = Visibility.Visible;
        var selected = (results.SelectedItem as ListViewItem)?.Tag as ShellCommand;
        results.Items.Clear();
        foreach (var command in ShellCommands.Filter(commands, query.Text))
        {
            var text = new StackPanel { Spacing = 2 };
            text.Children.Add(new TextBlock { Text = command.Title, FontSize = 14 });
            var detail = new TextBlock { Text = command.Detail, FontSize = 12, TextWrapping = TextWrapping.Wrap };
            detail.Foreground = Ui.ThemeBrush(this, "VcTextSecondaryBrush");
            text.Children.Add(detail);
            var item = new ListViewItem { Content = text, Tag = command, HorizontalContentAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetName(item, command.Title + ", " + command.Detail);
            AutomationProperties.SetItemStatus(item, command.IsEnabled ? "Available" : "Unavailable");
            results.Items.Add(item);
            if (selected?.Id == command.Id) results.SelectedItem = item;
        }
        if (results.SelectedIndex < 0 && results.Items.Count > 0) results.SelectedIndex = 0;
        empty.Visibility = results.Items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (restoreResults)
        {
            if (results.SelectedItem is ListViewItem item) item.Focus(FocusState.Keyboard);
            else query.Focus(FocusState.Keyboard);
        }
    }

    private void HandleKey(object sender, KeyRoutedEventArgs args)
    {
        if (args.Handled || input.IsComposing || compositionJustEnded) return;
        switch (args.Key)
        {
            case VirtualKey.Escape:
                if (!input.MayDismiss(compositionJustEnded)) return;
                args.Handled = true;
                Dismissed?.Invoke(this, EventArgs.Empty);
                break;
            case VirtualKey.Enter:
                args.Handled = true;
                if (input.MaySubmit(compositionJustEnded) && results.SelectedItem is ListViewItem { Tag: ShellCommand command }) Invoke(command);
                break;
            case VirtualKey.Down when ReferenceEquals(FocusManager.GetFocusedElement(XamlRoot), query):
            case VirtualKey.Up when ReferenceEquals(FocusManager.GetFocusedElement(XamlRoot), query):
                args.Handled = true;
                if (results.Items.Count > 0) results.SelectedIndex = Math.Clamp(results.SelectedIndex + (args.Key == VirtualKey.Down ? 1 : -1), 0, results.Items.Count - 1);
                if (results.SelectedItem is { } selected) results.ScrollIntoView(selected);
                break;
            case VirtualKey.Tab:
                args.Handled = true;
                if (InputState.DescendsFrom(FocusManager.GetFocusedElement(XamlRoot) as DependencyObject, results) || results.Items.Count == 0) query.Focus(FocusState.Keyboard);
                else if (results.Visibility == Visibility.Visible && results.SelectedItem is ListViewItem item) item.Focus(FocusState.Keyboard);
                break;
        }
    }

    private void Invoke(ShellCommand command)
    {
        if (!command.IsEnabled) { Refresh(); return; }
        CommandInvoking?.Invoke(this, EventArgs.Empty);
        command.TryExecute();
    }

    private void EffectsChanged(object? sender, EventArgs args) => ApplyTheme();
    private void ApplyTheme()
    {
        Background = Ui.ThemeBrush(this, "VcBgSurfaceBrush");
        if (!input.IsComposing) Refresh();
    }
}
