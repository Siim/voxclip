using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using VoxClip.App.Controls;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Clips;
using Windows.System;

namespace VoxClip.App.Pages;

/// <summary>The "Rewrite as" strip (design §6.3.1) in the editor: the scope bar's tone row (a menu, with "+ Save as my tone" naming the
/// field's text inline), the selection flyout's and clip rows' "Rewrite as", and Rewrite opened on the asked words at once.</summary>
public sealed partial class EditorPage
{
    private RewritePanel? rewritePanel;

    private void InitializeRewriteTones()
    {
        if (App.Services.SharedRoot is { } root)
        {
            try
            {
                var catalog = RewriteToneCatalog.Load(root);
                ViewModel.Tones = new RewriteToneServices(catalog, MainWindow.SavedRewriteTones,
                    tones => App.Services.SetAsync(RewriteToneCatalog.SettingsKey, MyRewriteTones.Encode(tones)));
            }
            catch (Exception exception) when (exception is IOException or VoxClip.Core.Domain.Shared.VoxClipException) { }
        }
        ViewModel.RewriteAsRequested += (_, request) => _ = RunAsync(() => RewriteAsAsync(request), "Rewrite");
    }

    /// <summary>Opens Rewrite on the request's words (the selection) or scope (a clip, or the full take) with the tone's instruction in
    /// the field, and sends it at once; a send that asks first asks inline in the panel.</summary>
    private async Task RewriteAsAsync(RewriteAsRequest request)
    {
        if (request.Words is { } words)
        {
            ViewModel.Select(words.First);
            ViewModel.Select(words.Last, extend: true);
        }
        ShellAsk.Text = request.Instruction;
        await OpenRewriteAsync(false, request.Instruction);
        if (rewritePanel is { } panel && rewrite is { IsOpen: true } session && ReferenceEquals(panel.Session, session)) await panel.SendNowAsync();
    }

    /// <summary>"Tone: ✦ Viral YouTuber" while the scope can be rewritten.</summary>
    private void UpdateToneButton()
    {
        var items = ViewModel.ShowsToneStrip ? ViewModel.RewriteStripItems : [];
        ToneButton.Visibility = items.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (items.Count == 0) { SaveToneHost.Visibility = Visibility.Collapsed; return; }
        ToneButton.Content = "Tone: " + items[0].Title;
        AutomationProperties.SetName(ToneButton, "Rewrite as a tone, default " + items[0].Title.Replace("✦ ", "", StringComparison.Ordinal));
    }

    /// <summary>The tone row's menu: each chip (the one the field shows is checked), then "+ Save as my tone".</summary>
    private void FillToneMenu()
    {
        ToneMenu.Items.Clear();
        var match = ViewModel.RewriteStripMatch(ShellAsk.Text);
        foreach (var item in ViewModel.RewriteStripItems)
        {
            var entry = new ToggleMenuFlyoutItem { Text = item.Label, IsChecked = match?.Id == item.Id };
            ToolTipService.SetToolTip(entry, item.Detail);
            entry.Click += (_, _) =>
            {
                ShellAsk.Text = item.Instruction;
                ViewModel.RewriteScopeAs(item);
            };
            ToneMenu.Items.Add(entry);
        }
        ToneMenu.Items.Add(new MenuFlyoutSeparator());
        var save = new MenuFlyoutItem { Text = "+ Save as my tone", IsEnabled = ViewModel.CanSaveAsTone(ShellAsk.Text) };
        if (!save.IsEnabled) ToolTipService.SetToolTip(save, "Type how you want words rewritten in the Ask field first.");
        save.Click += (_, _) =>
        {
            SaveToneHost.Visibility = Visibility.Visible;
            SaveToneName.Text = "";
            SaveToneName.Focus(FocusState.Programmatic);
        };
        ToneMenu.Items.Add(save);
    }

    /// <summary>"+ Save as my tone": the field's text under the typed name; the new tone shows as a chip and in the card's Tone menu.</summary>
    private async Task SaveFieldAsToneAsync()
    {
        if (await ViewModel.SaveToneAsync(SaveToneName.Text, ShellAsk.Text) is null) return;
        SaveToneHost.Visibility = Visibility.Collapsed;
        UpdateToneButton();
        ShellAsk.Focus(FocusState.Programmatic);
    }

    private void SaveToneKey(KeyRoutedEventArgs args)
    {
        if (args.Key == VirtualKey.Enter) { args.Handled = true; _ = SaveFieldAsToneAsync(); }
        else if (args.Key == VirtualKey.Escape) { args.Handled = true; SaveToneHost.Visibility = Visibility.Collapsed; ShellAsk.Focus(FocusState.Programmatic); }
    }
}
