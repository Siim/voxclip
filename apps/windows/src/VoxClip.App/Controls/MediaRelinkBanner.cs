using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.ViewModels;

namespace VoxClip.App.Controls;

internal sealed class MediaRelinkBanner : ContentControl
{
    private InlineApproval? approval;
    private bool retired;
    internal MediaRelinkBanner()
    {
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        Visibility = Visibility.Collapsed;
        Loaded += (_, _) => retired = false;
        Unloaded += (_, _) => { retired = true; approval?.Cancel(); };
    }
    internal async Task<bool> ConfirmAsync(object snapshot, Func<bool> current, string comparison, CancellationToken token)
    {
        if (retired || approval is not null) return false;
        using var pending = new InlineApproval(new(Guid.NewGuid(), snapshot, "This file looks different. Use it anyway?",
            comparison, "Your source and edits stay untouched unless you choose Use This File.", "Use This File", false),
            current, token, Environment.TickCount);
        approval = pending; Visibility = Visibility.Visible;
        var row = new InlineConfirmation(pending); Content = row;
        row.FocusTarget.Focus(FocusState.Programmatic);
        try { return await pending.Completion && !retired && current(); }
        finally { approval = null; Content = null; Visibility = Visibility.Collapsed; }
    }
}
