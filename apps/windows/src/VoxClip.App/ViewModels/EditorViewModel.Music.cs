using VoxClip.Core.Domain.Music;

namespace VoxClip.App.ViewModels;

/// <summary>Background music (doc/spec/music.md, design §6.7 step 4): the Music section's model and the one undoable change it makes.</summary>
public sealed partial class EditorViewModel
{
    private MusicPanelModel? music;

    /// <summary>The Music section under Captions.</summary>
    public MusicPanelModel Music => music ??= new(this);

    /// <summary>Sets (or with null removes) the track under <paramref name="clipId"/> as one undo step named <paramref name="name"/>;
    /// a first track promotes the project to v4. False when nothing changed or the project is read-only.</summary>
    public bool SetMusic(ProjectMusic? entry, string? clipId, string name)
    {
        if (isLeaving || IsReadOnly) return false;
        var unique = entry is null ? null : Unique(entry);
        var next = MusicProject.Setting(unique, clipId, project);
        if (next.Music.SequenceEqual(project.Music) && next.SchemaVersion == project.SchemaVersion) return false;
        return ReplaceProject(next, name);
    }

    /// <summary><paramref name="entry"/> with an id no other clip's track has (Mac MusicProject.unique): one file under several clips keeps
    /// its content-named id on the first and gains "-2", "-3"… on the others.</summary>
    private ProjectMusic Unique(ProjectMusic entry)
    {
        var taken = project.Music.Where(item => item.ClipId != entry.ClipId).Select(item => item.Id).ToHashSet(StringComparer.Ordinal);
        if (!taken.Contains(entry.Id)) return entry;
        var suffix = 2;
        while (taken.Contains(entry.Id + "-" + suffix.ToString(System.Globalization.CultureInfo.InvariantCulture))) suffix++;
        return entry with { Id = entry.Id + "-" + suffix.ToString(System.Globalization.CultureInfo.InvariantCulture) };
    }
}
