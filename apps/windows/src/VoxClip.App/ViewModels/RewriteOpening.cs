using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

internal sealed class RewriteOpening
{
    private readonly EditorViewModel editor;
    private readonly Project project;
    private readonly long revision;
    internal int First { get; }
    internal int Last { get; }
    internal int? InsertionAfter { get; }
    internal bool IsCurrent => ReferenceEquals(project, editor.Project) && revision == editor.RewriteSelectionRevision && !editor.IsLeaving;

    internal RewriteOpening(EditorViewModel editor, int? insertionAfter)
    {
        this.editor = editor;
        project = editor.Project;
        revision = editor.RewriteSelectionRevision;
        First = editor.SelectionStart;
        Last = editor.SelectionEnd;
        InsertionAfter = insertionAfter;
    }
}
