namespace VoxClip.App.ViewModels;

internal enum EditorMediaState { Ready, Missing, Corrupt, Demo, AudioOnly }
internal static class EditorMediaPresentation
{
    internal static string FileName(string stored) => stored.Replace('\\', '/').Split('/').LastOrDefault(part => part.Length > 0) ?? stored;
    internal static double MessageFraction(bool portrait) => portrait ? 0.38 : 0.36;
    internal static string Title(EditorMediaState state) => state switch
    {
        EditorMediaState.Missing => "Video not found", EditorMediaState.Corrupt => "Can't read this video",
        EditorMediaState.Demo => "Demo · no video", EditorMediaState.AudioOnly => "Audio only", _ => ""
    };
    internal static string Notice(EditorMediaState state, string file) => state switch
    {
        EditorMediaState.Missing => $"Can't find {file}. Edits are saved.",
        EditorMediaState.Corrupt => $"Can't read {file}. Edits are saved.",
        EditorMediaState.Demo => "Demo project with no video. Changes aren't saved to the fixture.", _ => ""
    };
    internal static string Accessible(EditorMediaState state, int? clip, bool ai) =>
        (clip is null ? "Video preview, full take" : $"Video preview, clip {clip}") + (ai ? ", contains AI-modified speech" : "") + (state switch
        {
            EditorMediaState.Missing => ", video not found", EditorMediaState.Corrupt => ", video can't be read",
            EditorMediaState.Demo => ", demo project", EditorMediaState.AudioOnly => ", audio only", _ => ""
        });
}
