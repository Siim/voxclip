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
    private bool updating;
    internal Control FocusTarget => instruction;
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
        header.Children.Add(Ui.Text("〰  Rewrite", "BodyStrongTextBlockStyle"));
        var beta = new Border { BorderThickness = new(1), BorderBrush = Ui.ThemeBrush(this, "VcLineStrongBrush"),
            CornerRadius = new(4), Padding = new(4, 0, 4, 0), Child = Small("Beta") };
        Grid.SetColumn(beta, 1); header.Children.Add(beta);
        var selection = Small(session.Header); Grid.SetColumn(selection, 2); header.Children.Add(selection);
        var close = new Button { Content = new FontIcon { Glyph = "\uE711", FontSize = 12 }, Width = 32, Height = 32, Padding = new(0) };
        Name(close, "Close Rewrite");
        ToolTipService.SetToolTip(close, "Close Rewrite (Esc)");
        AutomationProperties.SetAcceleratorKey(close, "Esc");
        close.Click += (_, _) => session.Dispose();
        Grid.SetColumn(close, 3); header.Children.Add(close);
        body.Children.Add(header);
        Name(instruction, "What should change?"); Name(words, "New words"); Name(propose, "Rewrite");
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
        body.Children.Add(Ui.Text("New words", "BodyStrongTextBlockStyle"));
        body.Children.Add(words); body.Children.Add(review); body.Children.Add(problem);
        Children.Add(new ScrollViewer { Content = body, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled });
        var footer = new Border { Padding = new(16, 12, 16, 12), BorderThickness = new(0, 1, 0, 0),
            BorderBrush = Ui.ThemeBrush(this, "VcLineDefaultBrush"), Child = Small("Exports show AI MODIFIED on the video and in the post.") };
        Grid.SetRow(footer, 1); Children.Add(footer);
        session.Changed += Changed;
        Unloaded += (_, _) => session.Changed -= Changed;
        KeyDown += Escape;
        Render();
    }

    private static void Name(DependencyObject target, string name) => AutomationProperties.SetName(target, name);
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
        Name(propose, session.ProposalButton);
        propose.IsEnabled = session.CanPropose;
        estimate.Text = session.EstimateCopy;
        estimate.FontSize = 11;
        problem.Text = session.Problem;
        problem.Visibility = session.Problem.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (session.Prepared is { } action) DispatcherQueue.TryEnqueue(() => session.MarkEstimateShown(action));
    }
    private void Escape(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key != VirtualKey.Escape) return;
        session.Dispose(); args.Handled = true;
    }
}
