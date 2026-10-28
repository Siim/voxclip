using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;
using Windows.System;

namespace VoxClip.App.Controls;

internal sealed class RewritePanel : Grid
{
    private readonly RewriteSession session;
    private readonly TextBox instruction = new() { Header = "What should change?", AcceptsReturn = false, MaxLength = 1000 };
    private readonly TextBox words = new() { AcceptsReturn = false, TextWrapping = TextWrapping.Wrap };
    private readonly Button propose = new() { Content = "Rewrite", HorizontalAlignment = HorizontalAlignment.Right };
    private readonly TextBlock estimate = Ui.Text("");
    private readonly TextBlock problem = Ui.Text("");
    private readonly StackPanel review = Ui.Stack(6);
    private readonly TextBlock changeSummary = Ui.Text("");
    private readonly Button apply = new() { HorizontalAlignment = HorizontalAlignment.Right };
    private bool updating;
    internal Control FocusTarget => instruction;
    internal bool ReturnFocusOnClose { get; private set; }
    internal event EventHandler? Closed;

    internal RewritePanel(RewriteSession session)
    {
        this.session = session;
        AutomationProperties.SetName(this, "Rewrite");
        RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
        RowDefinitions.Add(new() { Height = GridLength.Auto });
        BorderBrush = Ui.ThemeBrush(this, "VcLineDefaultBrush");
        BorderThickness = new(0, 1, 0, 0);
        var body = Ui.Stack(12);
        body.Margin = new(16, 12, 16, 12);
        var header = new Grid { ColumnSpacing = 6 };
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var heading = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        var waveform = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        foreach (var height in new[] { 4.0, 10.0, 14.0, 8.0, 4.0 })
            waveform.Children.Add(new Border { Width = 1.5, Height = height, VerticalAlignment = VerticalAlignment.Center,
                Background = Ui.ThemeBrush(this, "VcTextPrimaryBrush") });
        heading.Children.Add(waveform);
        var title = Ui.Text("Rewrite", "BodyStrongTextBlockStyle");
        title.FontSize = 13;
        heading.Children.Add(title);
        header.Children.Add(heading);
        var beta = new Border { BorderThickness = new(1), BorderBrush = Ui.ThemeBrush(this, "VcLineStrongBrush"),
            CornerRadius = new(4), Padding = new(4, 0, 4, 0), Child = Small("Beta") };
        Grid.SetColumn(beta, 1); header.Children.Add(beta);
        var selection = Small(session.Header); Grid.SetColumn(selection, 2); header.Children.Add(selection);
        var close = new Button { Content = new FontIcon { Glyph = "\uE711", FontSize = 12 }, Width = 32, Height = 32, Padding = new(0) };
        SetName(close, "Close Rewrite");
        ToolTipService.SetToolTip(close, "Close Rewrite (Esc)");
        AutomationProperties.SetAcceleratorKey(close, "Esc");
        close.Click += (_, _) => Close();
        Grid.SetColumn(close, 3); header.Children.Add(close);
        body.Children.Add(header);
        SetName(instruction, "What should change?"); SetName(words, "New words"); SetName(propose, "Rewrite");
        instruction.TextChanged += async (_, _) => { if (!updating) await session.SetInstructionAsync(instruction.Text); };
        words.TextChanged += (_, _) => { if (!updating) session.Edit(words.Text); };
        propose.Click += async (_, _) =>
        {
            if (session.Prepared is not { } action || !session.CanPropose) return;
            var approved = true;
            if (session.Estimate is { Kind: VoiceLabCostPresentationKind.Confirm } confirmation)
                approved = await new ContentDialog { XamlRoot = XamlRoot, Title = "Rewrite", Content = Ui.Text(confirmation.Text),
                    PrimaryButtonText = "Continue", CloseButtonText = "Cancel" }.ShowAsync() == ContentDialogResult.Primary;
            await session.ProposeAsync(action, approved);
        };
        body.Children.Add(instruction); body.Children.Add(propose);
        body.Children.Add(Small(session.SendLine)); body.Children.Add(estimate);
        if (session.Connector is null) body.Children.Add(Ui.Button("Open Settings", () => App.OpenSettings("Providers & Keys")));
        var newHeader = new Grid();
        newHeader.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        newHeader.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        newHeader.Children.Add(Ui.Text("New words", "BodyStrongTextBlockStyle"));
        changeSummary.HorizontalAlignment = HorizontalAlignment.Right;
        changeSummary.FontSize = 11;
        changeSummary.TextTrimming = TextTrimming.CharacterEllipsis;
        changeSummary.TextWrapping = TextWrapping.NoWrap;
        Grid.SetColumn(changeSummary, 1);
        newHeader.Children.Add(changeSummary);
        body.Children.Add(newHeader);
        body.Children.Add(words); body.Children.Add(review); body.Children.Add(problem);
        Children.Add(new ScrollViewer { Content = body, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled });
        var footerContent = Ui.Stack(12);
        var disclosure = new Grid { ColumnSpacing = 6 };
        disclosure.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        disclosure.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        disclosure.Children.Add(new FontIcon { Glyph = "\uE946", FontSize = 12, VerticalAlignment = VerticalAlignment.Top,
            Foreground = Ui.ThemeBrush(this, "VcTextSecondaryBrush") });
        var disclosureText = Small("Exports show AI MODIFIED on the video and in the post.");
        Grid.SetColumn(disclosureText, 1); disclosure.Children.Add(disclosureText);
        footerContent.Children.Add(disclosure);
        footerContent.Children.Add(apply);
        apply.Click += (_, _) =>
        {
            ReturnFocusOnClose = true;
            if (!session.ApplyLocalChanges()) ReturnFocusOnClose = false;
        };
        var footer = new Border { Padding = new(16, 12, 16, 12), BorderThickness = new(0, 1, 0, 0),
            BorderBrush = Ui.ThemeBrush(this, "VcLineDefaultBrush"), Child = footerContent };
        Grid.SetRow(footer, 1); Children.Add(footer);
        session.Changed += Changed;
        Loaded += (_, _) => instruction.Focus(FocusState.Programmatic);
        Unloaded += (_, _) => session.Changed -= Changed;
        KeyDown += Escape;
        Render();
    }

    private static void SetName(DependencyObject target, string name) => AutomationProperties.SetName(target, name);
    private TextBlock Small(string text)
    {
        var label = Ui.Text(text); label.FontSize = 11; label.Foreground = Ui.ThemeBrush(this, "VcTextSecondaryBrush"); return label;
    }
    private void Changed(object? sender, EventArgs args)
    {
        if (!session.IsOpen) { Closed?.Invoke(this, EventArgs.Empty); return; }
        Render();
    }
    private void Render()
    {
        updating = true;
        if (words.Text != session.NewWords) words.Text = session.NewWords;
        updating = false;
        propose.Content = session.ProposalButton;
        SetName(propose, session.ProposalButton);
        propose.IsEnabled = session.CanPropose;
        apply.Content = session.LocalAction ?? "";
        apply.Visibility = session.LocalAction is null ? Visibility.Collapsed : Visibility.Visible;
        SetName(apply, session.LocalAction ?? "Apply changes");
        estimate.Text = session.EstimateCopy;
        estimate.FontSize = 11;
        problem.Text = session.Problem;
        problem.Visibility = session.Problem.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        review.Children.Clear();
        changeSummary.Text = session.Review?.ChangeSummary ?? "";
        if (session.Review is { } current)
        {
            review.Children.Add(new RewriteDiffLine(current));
            foreach (var hunk in current.VoiceHunks) review.Children.Add(Small(hunk.Meter?.Copy ?? hunk.Refusal ?? ""));
            if (current.Summary is { } summary) review.Children.Add(Small(summary.Copy));
            if (current.Budget.Copy is { } budget) review.Children.Add(Small(budget));
        }
        if (session.Prepared is { } action) DispatcherQueue.TryEnqueue(() => session.MarkEstimateShown(action));
    }
    private void Escape(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key != VirtualKey.Escape) return;
        Close(); args.Handled = true;
    }
    private void Close() { ReturnFocusOnClose = true; session.Dispose(); }
}
