using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

/// <summary>The clip style card (design §6.6); the decisions are VoxClip.Core's <see cref="ClipStyleCard"/>.</summary>
public sealed partial class EditorViewModel
{
    private bool clipStyleReopened;

    /// <summary>The status bar item reopened the card after a choice.</summary>
    public bool ClipStyleReopened
    {
        get => clipStyleReopened;
        set { if (SetProperty(ref clipStyleReopened, value)) OnPropertyChanged(nameof(ShowsClipStyleCard)); }
    }

    /// <summary>True while the card shows above the clip list.</summary>
    public bool ShowsClipStyleCard => ClipStyleCard.Shows(project, clipStyleReopened, !IsReadOnly && !isLeaving);

    /// <summary>Stores <paramref name="style"/> as one undo step and, when <paramref name="collapse"/>, folds the card.</summary>
    public void ChooseClipStyle(ClipStyle style, IReadOnlySet<string> libraryStyles, bool collapse)
    {
        if (isLeaving || IsReadOnly || Busy) return;
        RecordClipStyle(ClipStyleCard.Choose(project, style, libraryStyles));
        if (collapse) ClipStyleReopened = false;
        ApplyCaptionPick(libraryStyles);
    }

    /// <summary>With Auto, the active clip uses the AI's pick for it, as one undo step.</summary>
    public void ApplyCaptionPick(IReadOnlySet<string> libraryStyles)
    {
        if (isLeaving || IsReadOnly || Busy || ClipStyleCard.ApplyPick(project, libraryStyles) is not { } next) return;
        RecordClipStyle(next);
    }

    private void RecordClipStyle(Project next)
    {
        CaptionDrag.Cancel();
        if (next.ClipStyle?.SameAs(project.ClipStyle) == true && next.Captions.StyleId == project.Captions.StyleId
            || next.ClipStyle is null && project.ClipStyle is null && next.Captions.StyleId == project.Captions.StyleId) return;
        undo.Push(CaptureHistory()); redo.Clear();
        project = next with { ModifiedAt = DateTimeOffset.UtcNow };
        foreach (var name in new[] { nameof(IsDirty), nameof(CanUndo), nameof(CanRedo), nameof(UndoActionName), nameof(RedoActionName), nameof(ShowsClipStyleCard) }) OnPropertyChanged(name);
        Changed?.Invoke(this, EventArgs.Empty);
    }
}
