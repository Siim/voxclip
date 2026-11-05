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
    }

    /// <summary>The caption style the active clip renders in (its pick, else the project default); the full video's otherwise.</summary>
    public string CaptionStyleId => ClipCaptionStyles.StyleId(project, project.Edits.ActiveClipId);

    /// <summary>The Captions panel's line: "This clip: Bold Pop · Claude's pick" or "Project default".</summary>
    public string CaptionStyleSource(Func<string, string> name) => ClipCaptionStyles.Source(project, project.Edits.ActiveClipId, name);

    private void RecordClipStyle(Project next)
    {
        CaptionDrag.Cancel();
        if (next.ClipStyle?.SameAs(project.ClipStyle) == true && next.Captions.StyleId == project.Captions.StyleId
            || next.ClipStyle is null && project.ClipStyle is null && next.Captions.StyleId == project.Captions.StyleId) return;
        PushHistory();
        project = next with { ModifiedAt = DateTimeOffset.UtcNow };
        foreach (var name in new[] { nameof(IsDirty), nameof(CanUndo), nameof(CanRedo), nameof(UndoActionName), nameof(RedoActionName), nameof(ShowsClipStyleCard) }) OnPropertyChanged(name);
        Changed?.Invoke(this, EventArgs.Empty);
    }
}
