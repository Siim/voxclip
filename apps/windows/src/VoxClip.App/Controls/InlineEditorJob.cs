using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.ViewModels;
using Windows.System;

namespace VoxClip.App.Controls;

internal sealed class InlineJobAction : EventArgs
{
    internal bool Cancel { get; set; }
}

internal abstract class InlineEditorJob : UserControl
{
    private readonly ContentControl body = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private readonly TextBlock title = Ui.Text("", "BodyStrongTextBlockStyle");
    private readonly Button primary = new();
    private readonly TextBlock primaryLabel = Ui.Text("");
    private readonly Button close = new();
    private int shownAt = Environment.TickCount;
    private bool opened;
    private bool closed;
    private ShellTextFocus? textFocus;
    internal bool OwnsComposition => textFocus?.OwnsComposition == true;
    protected EditorViewModel Editor { get; }
    internal string JobLabel { get; set; } = "Job";
    protected new object? Content { get => body.Content; set => body.Content = value; }
    protected string Title { get => title.Text; set => title.Text = value; }
    protected string PrimaryButtonText
    {
        get => primaryLabel.Text;
        set
        {
            if (value != PrimaryButtonText) shownAt = Environment.TickCount;
            primaryLabel.Text = value;
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(primary, value);
        }
    }
    protected string CloseButtonText { get => close.Content as string ?? ""; set => close.Content = value; }
    protected bool IsPrimaryButtonEnabled { get => primary.IsEnabled; set => primary.IsEnabled = value; }
    protected bool PrimaryButtonVisible
    {
        get => primary.Visibility == Visibility.Visible;
        set
        {
            if (value != PrimaryButtonVisible) ResetApprovalFreshness();
            primary.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
        }
    }
    protected bool RequiresExplicitApproval { get; set; }
    protected void ResetApprovalFreshness() => shownAt = Environment.TickCount;
    protected event EventHandler? Abandoned;
    internal Control FocusTarget => close;
    protected event EventHandler? Opened;
    protected event EventHandler? Closed;
    protected event EventHandler<InlineJobAction>? Closing;
    protected event EventHandler<InlineJobAction>? PrimaryButtonClick;
    protected event EventHandler<InlineJobAction>? CloseButtonClick;
    internal event EventHandler? Dismissed;

    protected InlineEditorJob(EditorViewModel editor)
    {
        Editor = editor;
        var layout = new Grid { Padding = new(16, 12, 16, 12), RowSpacing = 12 };
        layout.RowDefinitions.Add(new() { Height = GridLength.Auto });
        layout.RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
        layout.RowDefinitions.Add(new() { Height = GridLength.Auto });
        layout.Children.Add(title); Grid.SetRow(body, 1); layout.Children.Add(body);
        var actions = new Grid { ColumnSpacing = 8 };
        actions.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        actions.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        primary.Content = primaryLabel;
        actions.Children.Add(primary); Grid.SetColumn(close, 1); actions.Children.Add(close); Grid.SetRow(actions, 2); layout.Children.Add(actions);
        base.Content = layout;
        primary.Click += (_, _) => Activate();
        close.Click += (_, _) => RequestClose();
        primary.PreviewKeyDown += (_, args) =>
        {
            if (OwnsComposition) return;
            if (!RequiresExplicitApproval) return;
            if (args.Key == VirtualKey.Space)
            {
                args.Handled = true;
                if (!args.KeyStatus.WasKeyDown) RightColumn.RequestSourcePlayback(Editor);
                return;
            }
            if (args.Key != VirtualKey.Enter) return;
            args.Handled = true;
            if (InlineApproval.Allows(InputState.Down(VirtualKey.Control) ? InlineActivation.ControlReturn : InlineActivation.Return,
                    args.KeyStatus.WasKeyDown, InlineConfirmation.MessageTime(), shownAt)) Activate();
        };
        PreviewKeyDown += (_, args) =>
        {
            if (OwnsComposition) return;
            if (args.Key == VirtualKey.Space && !InputState.IsTextFocus(Microsoft.UI.Xaml.Input.FocusManager.GetFocusedElement(XamlRoot)))
            { args.Handled = true; if (!args.KeyStatus.WasKeyDown) RightColumn.RequestSourcePlayback(Editor); }
            else if (args.Key == VirtualKey.Escape) { args.Handled = true; RequestClose(); }
            else if (RequiresExplicitApproval && args.Key == VirtualKey.Enter && InputState.Down(VirtualKey.Control) && !args.KeyStatus.WasKeyDown)
            { args.Handled = true; Activate(); }
        };
        Loaded += (_, _) =>
        {
            textFocus ??= new(this);
            if (opened) return;
            opened = true; shownAt = Environment.TickCount;
            Opened?.Invoke(this, EventArgs.Empty);
            close.Focus(FocusState.Programmatic);
        };
        Unloaded += (_, _) =>
        {
            textFocus?.Dispose(); textFocus = null;
            if (opened && !closed) Abandoned?.Invoke(this, EventArgs.Empty);
        };
    }

    internal Task ShowAsync()
    {
        if (opened || closed) return Task.CompletedTask;
        if (!RightColumn.TryShow(Editor, this))
        {
            Hide();
            throw new InvalidOperationException("Finish or cancel the current inline job first.");
        }
        return Task.CompletedTask;
    }

    private void Activate()
    {
        if (closed || !primary.IsEnabled) return;
        var action = new InlineJobAction(); PrimaryButtonClick?.Invoke(this, action);
        if (!action.Cancel) Hide();
    }

    internal bool RequestClose()
    {
        if (closed) return true;
        var action = new InlineJobAction(); CloseButtonClick?.Invoke(this, action);
        if (action.Cancel) return false;
        Closing?.Invoke(this, action);
        if (action.Cancel) return false;
        Hide(); return true;
    }

    protected void Hide()
    {
        if (closed) return;
        closed = true; Closed?.Invoke(this, EventArgs.Empty); Dismissed?.Invoke(this, EventArgs.Empty);
    }
}
