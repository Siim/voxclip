using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Music;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Music;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.App.Pages;

/// <summary>Background music's live sources (doc/spec/music.md §3): Openverse, Eleven Music through the shared price catalogue and
/// the spend ledger, and the user's Music folder; the audition player pauses the preview first.</summary>
public sealed partial class EditorPage
{
    private MusicSuggestionService? musicSuggestions;
    private OpenverseMusicClient? openverse;
    private ElevenMusicClient? elevenMusic;

    private void InitializeMusic()
    {
        if (demo || App.Services.SharedRoot is not { } root) return;
        VoiceLabPriceCatalog? prices = null;
        try { prices = VoiceLabPrices.Load(root); } catch (VoxClipException) { }
        openverse = new OpenverseMusicClient(new HttpClientMusicHttp(TimeSpan.FromSeconds(20)));
        if (prices is not null)
            elevenMusic = new ElevenMusicClient(App.Services.Keys, prices, new VoiceLabSpendLedger(App.Services.Data),
                ElevenLabsRegions.FromSettings(App.Services.Settings, App.Services.Log), new HttpClientMusicHttp(TimeSpan.FromMinutes(5)));
        musicSuggestions = new MusicSuggestionService(openverse, elevenMusic,
            async ct => await App.Services.Keys.GetKeyAsync(ElevenMusicClient.KeyAccount, ct) is { Length: > 0 }, () => MusicLibraryFolder.DefaultFolder());
        ViewModel.Music.Services = new MusicPanelServices(
            (brief, seconds, ct) => musicSuggestions.CandidatesAsync(brief, seconds, ct),
            FetchMusicAsync,
            () => MusicLibraryFolder.DefaultFolder(),
            VoxClip.Media.Audio.MusicFiles.DurationSecondsAsync,
            App.Services.Data.Root);
        ViewModel.Music.Audition = new MusicAudition(this);
    }

    private Task<byte[]> FetchMusicAsync(MusicCandidate candidate, CancellationToken ct) => candidate.Source switch
    {
        MusicSource.Library when openverse is not null => openverse.DownloadAsync(candidate, ct),
        MusicSource.Generated when elevenMusic is not null => musicSuggestions?.Quote(candidate) is { } quote ? elevenMusic.ComposeAsync(quote, ct)
            : throw new VoxClipException(VoxClipErrorCode.ProviderError, "This price is out of date. Search again to see the current price."),
        _ => throw new VoxClipException(VoxClipErrorCode.MediaMissing, "This track isn't available. Search again.")
    };

    /// <summary>▶ in the Music section: a Windows media player; the editor's preview pauses first.</summary>
    private sealed class MusicAudition(EditorPage page) : IMusicAudition
    {
        private Windows.Media.Playback.MediaPlayer? player;

        public void Play(string source)
        {
            Stop();
            if (page.preview is { } preview) _ = page.RunAsync(() => page.SourceTransportAsync(token => preview.PauseAsync(token)), "Preview");
            var uri = source.StartsWith("https://", StringComparison.Ordinal) ? new Uri(source) : new Uri(Path.GetFullPath(source));
            player = new() { Source = Windows.Media.Core.MediaSource.CreateFromUri(uri) };
            player.Play();
        }

        public void Stop()
        {
            player?.Pause();
            player?.Dispose();
            player = null;
        }
    }
}
