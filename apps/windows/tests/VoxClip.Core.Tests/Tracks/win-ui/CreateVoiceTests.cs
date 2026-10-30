#if WIN_UI_TESTS
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
using System.Text;
using System.Text.Json;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Logging;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Media.Audio;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

public sealed class CreateVoiceTests
{
    private static CancellationToken Token => TestContext.Current.CancellationToken;
    private static Task Dispatch(Action action) { action(); return Task.CompletedTask; }
    private static string AppFile(string file) => File.ReadAllText(Path.Combine(Path.GetDirectoryName(SharedResources.ResolveRoot())!, "apps/windows/src/VoxClip.App", file));

    [Fact]
    public void CreationAuditDoesNotHardCodeAReleaseVersion()
    {
        var backend = AppFile("Services/VoiceStatementBackend.cs");
        Assert.DoesNotContain("\"0.1.0\"", backend);
        Assert.Contains("Assembly.GetName().Version?.ToString() ?? \"unknown\"", backend);
    }

    [Theory]
    [InlineData(false, false, false)]
    [InlineData(true, false, false)]
    [InlineData(false, true, false)]
    [InlineData(false, false, true)]
    [InlineData(true, true, false)]
    [InlineData(true, false, true)]
    [InlineData(false, true, true)]
    [InlineData(true, true, true)]
    public async Task AllThreeAttestationsAreRequired(bool own, bool adult, bool videos)
    {
        await using var setup = new ConsentSetup();
        setup.Session.SetInputs("Example", "en", own, adult, videos);
        Assert.Equal(own && adult && videos, setup.Session.CanRecord);
        if (!own || !adult || !videos) { await setup.Session.RecordAsync(); Assert.Equal(0, setup.Capture.Starts); }
    }

    [Fact]
    public async Task DecomposedNameUsesTheRuneLimitWithoutNormalization()
    {
        await using var setup = new ConsentSetup();
        setup.Session.SetInputs(string.Concat(Enumerable.Repeat("o\u0303", 31)), "en", true, true, true);
        Assert.False(setup.Session.CanRecord); Assert.Null(setup.Session.Statement);
        Assert.Equal("Enter a name with 1 to 60 Unicode scalars and no control characters.", setup.Session.Message);
        setup.Session.SetInputs(string.Concat(Enumerable.Repeat("o\u0303", 30)), "en", true, true, true);
        Assert.True(setup.Session.CanRecord);
    }

    [Theory]
    [InlineData("speaker")]
    [InlineData("language")]
    [InlineData("plan")]
    [InlineData("beta")]
    public async Task PreGateBlocksBeforeCaptureConsentAndScribe(string closed)
    {
        await using var setup = new ConsentSetup();
        setup.Speaker = closed != "speaker";
        setup.Enabled = closed != "beta";
        setup.Plan = closed == "plan" ? "Check your ElevenLabs account before creating a voice." : null;
        setup.Session.SetInputs("Example", closed == "language" ? "et" : "en", true, true, true);
        Assert.NotNull(setup.Session.BlockedReason);
        await setup.Session.RecordAsync();
        Assert.False(setup.Session.RequestVerification());
        await setup.Session.ApproveVerificationAsync(true);
        Assert.Equal(0, setup.Capture.Starts); Assert.Equal(0, setup.Consents); Assert.Equal(0, setup.ScribeCalls);
        setup.AssertNoStatement();
    }

    [Fact]
    public async Task AnnouncementPrecedesCaptureBy600msAndRestartIsBusy()
    {
        await using var setup = new ConsentSetup();
        var said = new List<string>();
        setup.Session.Announcement += text => { Assert.False(setup.Session.Recording); said.Add(text); };
        setup.Inputs();
        var delay = setup.Clock.NextDelay(TimeSpan.FromMilliseconds(600));
        var work = setup.Session.RecordAsync();
        await delay.WaitAsync(Token);
        Assert.Equal("Recording. Read the statement aloud.", Assert.Single(said));
        Assert.True(setup.Session.IsBusyForRestart); Assert.Equal(0, setup.Capture.Starts);
        setup.Clock.Advance(TimeSpan.FromMilliseconds(599));
        Assert.Equal(0, setup.Capture.Starts);
        var recording = setup.WhenRecording();
        setup.Clock.Advance(TimeSpan.FromMilliseconds(1));
        await recording.WaitAsync(Token);
        Assert.True(setup.Session.IsBusyForRestart); Assert.Single(said);
        setup.Session.StopRecording(); await work;
        Assert.Equal("Recording stopped, 5 seconds.", said[^1]);
        Assert.True(setup.Session.HasStatementRecording); Assert.True(setup.Session.IsBusyForRestart);
    }

    [Fact]
    public async Task VerifyWaitsForApprovalUsesForced16kAndCleansTemporaryAudio()
    {
        await using var setup = new ConsentSetup();
        await setup.TakeAsync();
        var wav = setup.StatementBytes();
        var format = VoiceConsentAudio.ValidateWav(wav);
        Assert.Equal(48000, format.Rate); Assert.Equal(5 * 48000, format.Frames);
        Assert.Contains("< $0.01", setup.Session.VerificationCost);
        await setup.Session.ApproveVerificationAsync(true);
        Assert.Equal(0, setup.ScribeCalls);
        Assert.True(setup.Session.RequestVerification());
        await setup.Session.ApproveVerificationAsync(false);
        Assert.Equal(0, setup.ScribeCalls); Assert.True(setup.Session.HasStatementRecording);
        Assert.True(setup.Session.RequestVerification());
        await setup.Session.ApproveVerificationAsync(true);
        Assert.True(setup.Session.Verified); Assert.Equal(1, setup.ScribeCalls); Assert.Equal(1, setup.Consents);
        Assert.Equal("Statement verified. Record your training read-aloud next.", setup.Session.Message);
        setup.AssertNoTemporaryAudio();
    }

    [Fact]
    public async Task FailedVerifyDiscardsStatementAndNextTakeGetsNewNonce()
    {
        await using var setup = new ConsentSetup { Mismatch = true };
        await setup.TakeAsync();
        var firstNonce = setup.Session.Statement!.Nonce.ToArray();
        Assert.True(setup.Session.RequestVerification()); await setup.Session.ApproveVerificationAsync(true);
        Assert.False(setup.Session.Verified); Assert.False(setup.Session.HasStatementRecording); Assert.Null(setup.Session.Statement);
        Assert.Equal("That didn't match the statement. Read it again, clearly, in one take.", setup.Session.Message);
        setup.AssertNoStatement(); setup.AssertNoTemporaryAudio();
        await setup.TakeAsync();
        Assert.NotEqual(firstNonce, setup.Session.Statement!.Nonce.ToArray());
    }

    [Theory]
    [InlineData(3)]
    [InlineData(35)]
    public async Task OutOfRangeStatementIsDiscarded(int seconds)
    {
        await using var setup = new ConsentSetup();
        setup.Capture.Seconds = seconds;
        await setup.TakeAsync();
        Assert.False(setup.Session.HasStatementRecording); Assert.Null(setup.Session.Statement);
        Assert.Contains("5–30 seconds", setup.Session.Message);
        Assert.Equal(30, setup.Capture.MaximumSeconds);
        setup.AssertNoStatement();
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    public async Task EveryLeaveTriggerDefaultsToKeepGoingAndStopDeletes(int value)
    {
        var trigger = (VoiceCreationLeaveTrigger)value;
        await using var setup = new ConsentSetup();
        await setup.TakeAsync();
        var called = new List<VoiceCreationLeaveTrigger>();
        Assert.False(await setup.Session.TryLeaveAsync(trigger, observed => { called.Add(observed); return Task.FromResult(false); }));
        Assert.True(setup.Session.HasStatementRecording);
        Assert.Equal(new[] { trigger }, called);
        Assert.False(VoiceCreationDialog.Leave.PrimaryDefault);
        Assert.Equal("Keep going", VoiceCreationDialog.Leave.Close);
        Assert.Equal("Stop", VoiceCreationDialog.Leave.Primary);
        Assert.Equal("Stop creating your voice? The recording is deleted from this PC.", VoiceCreationDialog.Leave.Message);
        Assert.True(await setup.Session.TryLeaveAsync(trigger, _ => Task.FromResult(true)));
        setup.AssertNoStatement(); Assert.False(setup.Session.IsBusyForRestart);
    }

    [Fact]
    public async Task GateClosingDuringCaptureOrVerificationAbandonsAllAudio()
    {
        await using var setup = new ConsentSetup();
        setup.Inputs();
        var delay = setup.Clock.NextDelay(TimeSpan.FromMilliseconds(600));
        var recording = setup.WhenRecording(); var work = setup.Session.RecordAsync();
        await delay.WaitAsync(Token); setup.Clock.Advance(TimeSpan.FromMilliseconds(600)); await recording.WaitAsync(Token);
        setup.Enabled = false; await setup.Session.GateChangedAsync(); await work;
        setup.AssertNoStatement(); Assert.False(setup.Session.Recording);
        setup.Enabled = true; await setup.TakeAsync();
        setup.HoldScribe = new(TaskCreationOptions.RunContinuationsAsynchronously);
        Assert.True(setup.Session.RequestVerification()); var verify = setup.Session.ApproveVerificationAsync(true);
        await setup.ScribeEntered.Task.WaitAsync(Token);
        setup.Enabled = false; await setup.Session.GateChangedAsync(); await verify;
        setup.AssertNoStatement(); setup.AssertNoTemporaryAudio(); Assert.False(setup.Session.Verified);
    }

    [Fact]
    public async Task ActivationWaitAnnouncesAfterOneSecondAndCanBeCancelled()
    {
        await using var setup = new ConsentSetup();
        setup.Inputs(); setup.Capture.HoldActivation = true;
        var delay = setup.Clock.NextDelay(TimeSpan.FromMilliseconds(600));
        var waiting = setup.Clock.NextDelay(TimeSpan.FromSeconds(1));
        var said = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        setup.Session.Announcement += text => { if (text == VoiceLabCopy.MicrophoneWaiting) said.TrySetResult(text); };
        var work = setup.Session.RecordAsync();
        await delay.WaitAsync(Token); setup.Clock.Advance(TimeSpan.FromMilliseconds(600)); await waiting.WaitAsync(Token);
        setup.Clock.Advance(TimeSpan.FromMilliseconds(999)); Assert.False(said.Task.IsCompleted);
        setup.Clock.Advance(TimeSpan.FromMilliseconds(1));
        Assert.Equal(VoiceLabCopy.MicrophoneWaiting, await said.Task.WaitAsync(Token));
        Assert.True(setup.Session.IsBusyForRestart);
        Assert.True(await setup.Session.TryLeaveAsync(VoiceCreationLeaveTrigger.Back, _ => Task.FromResult(true)));
        await work; setup.AssertNoStatement(); Assert.False(setup.Session.IsBusyForRestart);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    public async Task LeaveDuringRecordingVetoKeepsInputsAndStopDiscards(int value)
    {
        await using var setup = new ConsentSetup();
        setup.Inputs();
        var delay = setup.Clock.NextDelay(TimeSpan.FromMilliseconds(600)); var recording = setup.WhenRecording();
        var work = setup.Session.RecordAsync();
        var expected = setup.Session.Statement;
        setup.Session.SetInputs("Changed during preparation", "et", false, false, false);
        Assert.Equal(expected, setup.Session.Statement);
        await delay.WaitAsync(Token); setup.Clock.Advance(TimeSpan.FromMilliseconds(600)); await recording.WaitAsync(Token);
        Assert.False(await setup.Session.TryLeaveAsync((VoiceCreationLeaveTrigger)value, _ => Task.FromResult(false)));
        Assert.True(setup.Session.Recording);
        Assert.True(await setup.Session.TryLeaveAsync((VoiceCreationLeaveTrigger)value, _ => Task.FromResult(true)));
        await work; setup.AssertNoStatement(); Assert.False(setup.Session.Recording);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task FailedVerifyKeepsCleanupWarningAndVetoesLeaving(bool rateLimited)
    {
        await using var setup = new ConsentSetup { Mismatch = !rateLimited, ForceTooMany = rateLimited };
        await setup.TakeAsync();
        setup.FailDeletion = true;
        Assert.True(setup.Session.RequestVerification());
        await setup.Session.ApproveVerificationAsync(true);
        Assert.StartsWith("The statement recording could not be removed.", setup.Session.Message);
        Assert.Contains(rateLimited ? "Three attempts are allowed per 10 minutes." : "That didn't match the statement.", setup.Session.Message);
        Assert.False(await setup.Session.TryLeaveAsync(VoiceCreationLeaveTrigger.Back, _ => Task.FromResult(true)));
        Assert.True(setup.Session.IsBusyForRestart);
        setup.FailDeletion = false;
        Assert.True(setup.Session.CanRetryCleanup);
        Assert.False(setup.Session.CanRecord); Assert.False(setup.Session.CanVerify);
        Assert.Contains("Leaving and restarting are blocked", setup.Session.Message);
        Assert.Contains("Try removing the recording again", AppFile("Controls/CreateVoicePage.cs"));
        await setup.Session.RetryCleanupAsync();
        Assert.False(setup.Session.IsBusyForRestart); Assert.False(setup.Session.CanRetryCleanup);
        setup.AssertNoStatement();
        Assert.True(await setup.Session.TryLeaveAsync(VoiceCreationLeaveTrigger.Back, _ => Task.FromResult(true)));
    }

    [Fact]
    public async Task VerificationIsLimitedToThreeAttemptsPerTenMinutes()
    {
        await using var setup = new ConsentSetup { Mismatch = true };
        for (var attempt = 0; attempt < 4; attempt++)
        {
            await setup.TakeAsync(); Assert.True(setup.Session.RequestVerification());
            await setup.Session.ApproveVerificationAsync(true); setup.AssertNoStatement(); setup.AssertNoTemporaryAudio();
        }
        Assert.Equal(3, setup.ScribeCalls);
        Assert.Equal("Three attempts are allowed per 10 minutes. Please try again later.", setup.Session.Message);
        setup.Clock.Advance(TimeSpan.FromMinutes(10));
        await setup.TakeAsync(); Assert.True(setup.Session.RequestVerification()); await setup.Session.ApproveVerificationAsync(true);
        Assert.Equal(4, setup.ScribeCalls); setup.AssertNoStatement();
    }

    [Theory]
    [InlineData(MicrophoneError.Permission)]
    [InlineData(MicrophoneError.NoDevice)]
    [InlineData(MicrophoneError.Unavailable)]
    [InlineData(MicrophoneError.DeviceLost)]
    [InlineData(MicrophoneError.Silent)]
    public async Task MicrophoneFailuresAbandonEnrollmentWithApprovedCopy(MicrophoneError failure)
    {
        await using var setup = new ConsentSetup();
        setup.Capture.Failure = failure;
        await setup.TakeAsync();
        Assert.Equal(VoiceLabCopy.MicrophoneFailure(failure), setup.Session.Message);
        Assert.Equal(failure, setup.Session.MicrophoneFailure);
        Assert.Null(setup.Session.Statement); setup.AssertNoStatement();
    }

    [Fact]
    public void PageHasOrderedAccessibleCaptionAndNoCaptureAnnouncements()
    {
        var page = AppFile("Controls/CreateVoicePage.cs");
        Assert.Contains("If you use a screen reader, wear headphones so it isn't recorded.", page);
        Assert.True(page.IndexOf("body.Children.Add(teleprompter)", StringComparison.Ordinal) < page.IndexOf("body.Children.Add(headphones)", StringComparison.Ordinal));
        Assert.True(page.IndexOf("body.Children.Add(headphones)", StringComparison.Ordinal) < page.IndexOf("body.Children.Add(record)", StringComparison.Ordinal));
        Assert.Contains("headphones.IsTextSelectionEnabled = true", page); Assert.DoesNotContain("SetLiveSetting", page);
        Assert.Contains("if (!session.Recording) Ui.Announce", page);
        Assert.Contains("voice-consent-teleprompter", page); Assert.Contains("SetName(teleprompter, \"Read this aloud\")", page);
        Assert.Contains("AutomationHeadingLevel.Level1", page); Assert.Contains("Cascadia Mono", page);
        var window = AppFile("SettingsWindow.xaml.cs");
        foreach (var trigger in new[] { "Navigation", "Back", "Escape", "Closing" }) Assert.Contains("VoiceCreationLeaveTrigger." + trigger, page + window);
        Assert.Contains("createVoicePage?.IsBusyForRestart == true", window);
        var dialog = AppFile("Controls/VoiceLabDialogs.cs");
        Assert.Contains("spec.PrimaryDefault ? ContentDialogButton.Primary : ContentDialogButton.Close", dialog);
        Assert.True(VoiceCreationDialog.Verify("< $0.01").PrimaryDefault);
        Assert.Equal("Cancel", VoiceCreationDialog.Verify("< $0.01").Close);
        Assert.Contains("VoiceEnrollmentLanguage", page);
        Assert.DoesNotContain("transcription.language", page);
    }

    [Fact]
    public async Task RecordingAgainReplacesTheStatementAndNonce()
    {
        await using var setup = new ConsentSetup();
        await setup.TakeAsync();
        var firstNonce = setup.Session.Statement!.Nonce.ToArray();
        var delay = setup.Clock.NextDelay(TimeSpan.FromMilliseconds(600));
        var recording = setup.WhenRecording();
        var work = setup.Session.RecordAsync();
        await delay.WaitAsync(Token); setup.Clock.Advance(TimeSpan.FromMilliseconds(600));
        await recording.WaitAsync(Token); setup.Session.StopRecording(); await work;
        Assert.NotEqual(firstNonce, setup.Session.Statement!.Nonce.ToArray());
        Assert.True(setup.Session.HasStatementRecording);
        Assert.Equal(48000, VoiceConsentAudio.ValidateWav(setup.StatementBytes()).Rate);
    }

    [Fact]
    public void NativeConsentHarnessKeepsFixturesIsolatedAndChecksPrivacy()
    {
        var script = File.ReadAllText(Path.Combine(Path.GetDirectoryName(SharedResources.ResolveRoot())!,
            "apps/windows/tests/VoxClip.Core.Tests/Tracks/win-ui/native-voicelab-walk.ps1"));
        Assert.All(script, character => Assert.True(character <= 127));
        foreach (var required in new[] { "'consent-gate'", "'consent'", "'consent-cap'", "'consent-error'", "ConsentScenario", "StopSeconds", "Assert-NoStatement", "Verify left temporary audio behind", "consent-scribe-result.json", "microphone-settings-uri.txt", "httpCalls -ne 0", "U3 must use the production speaker gate" })
            Assert.Contains(required, script);
    }

#if DEBUG
    [Fact]
    public async Task DebugScribeUsesFixtureMetadataAndDynamicNonceWithoutHttp()
    {
        var shared = SharedResources.ResolveRoot();
        var text = JsonSerializer.Deserialize<VoiceConsentText>(File.ReadAllBytes(Path.Combine(shared, "voice-lab", "statements.json")), new JsonSerializerOptions(JsonSerializerDefaults.Web))!;
        var words = File.ReadAllText(Path.Combine(shared, "voice-lab", "nonce-words-en.txt")).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        var statement = text.Statement("Example", "en", new DateOnly(2026, 10, 30), words);
        var scribe = new DebugConsentScribe(Path.Combine(shared, "fixtures", "voice-lab"));
        var request = new TranscriptionRequest(new(TranscriptEngine.Elevenlabs, "scribe_v2", new LanguageChoice.Forced("en"), new(Diarize: false)),
            new("unused-by-fixture.wav", 16000, 1, 0, 0), "consent-fixture");
        var result = await scribe.TranscribeAsync(statement, request, Token);
        Assert.True(DebugAvailableSpeakerCheck.Available);
        Assert.Equal(1, scribe.Calls);
        VoiceStatementMatch.Verify(result, statement);
        Assert.DoesNotContain("HttpClient", AppFile("Services/DebugConsentScribe.cs"));
    }
#else
    [Fact]
    public void ReleaseAppInspectionHasAnUnconditionalBuildPrerequisite()
    {
        var root = Path.GetDirectoryName(SharedResources.ResolveRoot())!;
        var project = System.Xml.Linq.XDocument.Load(Path.Combine(root, "apps/windows/tests/VoxClip.Core.Tests/Tracks/win-ui/VoxClip.Ui.Tests.csproj"));
        var target = Assert.Single(project.Descendants("Target"), target => (string?)target.Attribute("Name") == "BuildReleaseAppForInspection");
        Assert.Equal("CoreCompile", (string?)target.Attribute("BeforeTargets"));
        var build = Assert.Single(target.Elements("MSBuild"));
        Assert.Equal("Restore;Build", (string?)build.Attribute("Targets"));
        Assert.EndsWith("VoxClip.App.TypeCheck.csproj", (string?)build.Attribute("Projects"));
        Assert.Contains("Configuration=Release", (string?)build.Attribute("Properties"));
    }

    [Fact]
    public void ReleaseOmitsConsentFakesAndDebugEnvironmentStrings()
    {
        var assembly = typeof(CreateVoiceSession).Assembly;
        Assert.DoesNotContain(assembly.GetTypes(), type => type.Namespace == "VoxClip.App.Services" && type.Name.StartsWith("Debug", StringComparison.Ordinal));
        var root = Path.GetDirectoryName(SharedResources.ResolveRoot())!;
        var typecheck = Path.Combine(root, "apps/windows/tests/VoxClip.App.TypeCheck/bin/Release/net10.0-windows10.0.26100.0/VoxClip.WinCheck.dll");
        Assert.True(File.Exists(typecheck), "Build the Release App typecheck before running the Release UI tests.");
        using var stream = File.OpenRead(typecheck); using var pe = new PEReader(stream);
        var metadata = pe.GetMetadataReader();
        Assert.DoesNotContain(metadata.TypeDefinitions.Select(handle => metadata.GetString(metadata.GetTypeDefinition(handle).Name)), name => name.StartsWith("DebugConsent", StringComparison.Ordinal) || name.StartsWith("DebugAvailableSpeaker", StringComparison.Ordinal) || name.StartsWith("DebugVoice", StringComparison.Ordinal));
        var prefix = string.Join("_", "VOXCLIP", "DEBUG", "");
        Assert.Equal(-1, File.ReadAllBytes(typecheck).AsSpan().IndexOf(Encoding.Unicode.GetBytes(prefix)));
        foreach (var file in new[] { "Services/DebugConsentScribe.cs", "Services/DebugVoiceLabBackend.cs", "Services/DebugVoiceCreationBackend.cs" })
        { var source = AppFile(file); Assert.StartsWith("#if DEBUG", source); Assert.EndsWith("#endif", source.TrimEnd()); }
        foreach (var file in new[] { "Services/AppServices.cs", "Controls/CreateVoicePage.cs" })
        {
            var depth = 0;
            foreach (var line in AppFile(file).Split('\n'))
            {
                if (line.Trim() == "#if DEBUG") depth++;
                if (line.Trim() == "#endif" && depth > 0) depth--;
                if (line.Contains("VOXCLIP_DEBUG_", StringComparison.Ordinal) || line.Contains("DebugConsent", StringComparison.Ordinal) || line.Contains("DebugAvailableSpeaker", StringComparison.Ordinal) || line.Contains("DebugVoiceCreation", StringComparison.Ordinal))
                    Assert.True(depth > 0, $"DEBUG wiring must be guarded in {file}: {line}");
            }
        }
    }
#endif

    private sealed class ConsentSetup : IAsyncDisposable
    {
        private readonly string root = Path.Combine(Path.GetTempPath(), "voxclip-consent-ui-" + Guid.NewGuid().ToString("N"));
        internal readonly ConsentClock Clock = new();
        internal readonly ConsentCapture Capture = new();
        internal readonly CreateVoiceSession Session;
        internal bool Enabled = true, Speaker = true, Mismatch, FailDeletion, ForceTooMany;
        internal string? Plan;
        internal int Consents, ScribeCalls;
        internal TaskCompletionSource? HoldScribe;
        internal readonly TaskCompletionSource ScribeEntered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal ConsentSetup()
        {
            var locations = new DataLocations(root, Path.Combine(root, "settings.json"), Path.Combine(root, "Models"), Path.Combine(root, "cache"), Path.Combine(root, "autosave"), Path.Combine(root, "secrets"), Path.Combine(root, "logs"));
            var backend = new VoiceStatementBackend(locations, new NoKeys(), new QuietLog(), ElevenLabsRegion.Default,
                () => Enabled, () => Plan, _ => { Consents++; return Task.CompletedTask; }, Clock, () => Speaker, ScribeAsync);
            Session = new(new DeletionFailureBackend(backend, () => FailDeletion, () => ForceTooMany), Capture, Dispatch, Clock);
        }
        internal void Inputs() => Session.SetInputs("Example", "en", true, true, true);
        internal Task WhenRecording()
        {
            var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            Session.Changed += (_, _) => { if (Session.Recording) ready.TrySetResult(); };
            return ready.Task;
        }
        internal async Task TakeAsync()
        {
            Inputs();
            var delay = Clock.NextDelay(TimeSpan.FromMilliseconds(600));
            var recording = WhenRecording(); var work = Session.RecordAsync();
            await delay.WaitAsync(Token); Clock.Advance(TimeSpan.FromMilliseconds(600));
            await recording.WaitAsync(Token); Session.StopRecording(); await work;
        }
        private async Task<RawTranscript> ScribeAsync(VoiceConsentStatement statement, TranscriptionRequest request, CancellationToken ct)
        {
            Assert.False(request.Plan.Options.Diarize); Assert.Equal(new LanguageChoice.Forced("en"), request.Plan.Language);
            var format = VoiceConsentAudio.ValidateWav(await File.ReadAllBytesAsync(request.Audio.Wav16kPath, ct));
            Assert.Equal(16000, format.Rate); Assert.Equal(5 * 16000, format.Frames); Assert.Equal(format.Frames, request.Audio.SampleCount);
            Assert.StartsWith(Path.Combine(root, "cache", "voice-consent"), request.Audio.Wav16kPath);
            ScribeCalls++; ScribeEntered.TrySetResult();
            if (HoldScribe is not null) await HoldScribe.Task.WaitAsync(ct);
            var tokens = (Mismatch ? "wrong words" : statement.Text).Split(' ', StringSplitOptions.RemoveEmptyEntries);
            return new(new(TranscriptEngine.Elevenlabs, "scribe_v2", null, "test", "en"), 1, new(GroupingEnd.LastToken, GroupingConfidence.Single, false),
                tokens.Select((word, index) => new RawToken(word, false, index * .1, index * .1 + .1, 1, null, null, index)).ToArray(), "en", 1, true, TimingSource.Native, "synthetic-consent");
        }
        internal byte[] StatementBytes() => File.ReadAllBytes(Assert.Single(Directory.GetFiles(root, "statement.wav", SearchOption.AllDirectories)));
        internal void AssertNoStatement() => Assert.Empty(Directory.Exists(root) ? Directory.GetFiles(root, "statement.wav", SearchOption.AllDirectories) : []);
        internal void AssertNoTemporaryAudio()
        {
            var directory = Path.Combine(root, "cache", "voice-consent");
            Assert.Empty(Directory.Exists(directory) ? Directory.GetFileSystemEntries(directory) : []);
        }
        public async ValueTask DisposeAsync()
        {
            FailDeletion = false;
            await Session.DisposeAsync();
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }
    private sealed class DeletionFailureBackend(IVoiceStatementBackend inner, Func<bool> fail, Func<bool> tooMany) : IVoiceStatementBackend
    {
        public bool Enabled => inner.Enabled;
        public bool SpeakerAvailable => inner.SpeakerAvailable;
        public string? PlanMessage => inner.PlanMessage;
        public string VerificationCost => inner.VerificationCost;
        public VoiceConsentStatement Statement(string name, string language, DateOnly date) => inner.Statement(name, language, date);
        public Task SaveStatementAsync(string recordId, MicrophoneTake take, CancellationToken ct) => inner.SaveStatementAsync(recordId, take, ct);
        public Task VerifyAsync(string recordId, VoiceConsentStatement statement, VoiceConsentAttestations attestations, CancellationToken ct) => tooMany() ? Task.FromException(new VoiceConsentException(VoiceConsentError.TooManyAttempts)) : inner.VerifyAsync(recordId, statement, attestations, ct);
        public Task AbandonAsync(string recordId) => fail() ? Task.FromException(new IOException("injected deletion failure")) : inner.AbandonAsync(recordId);
        public void Dispose() => inner.Dispose();
    }
    private sealed class ConsentCapture : IVoiceStatementCapture
    {
        public Task StartTrainingAsync(CancellationToken ct) => StartAsync(ct);
        private TaskCompletionSource done = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private bool recording;
        private MicrophoneTake? take;
        internal int Starts, MaximumSeconds;
        internal int Seconds = 5;
        internal bool HoldActivation;
        internal MicrophoneError? Failure;
        public MicrophoneSnapshot Snapshot => new(recording, false, recording ? Seconds : 0, .5, Failure, "Synthetic microphone");
        public Task StartAsync(CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested(); Starts++; MaximumSeconds = 30;
            done = new(TaskCreationOptions.RunContinuationsAsynchronously); recording = true; take = null;
            return HoldActivation ? new TaskCompletionSource().Task.WaitAsync(ct) : Task.CompletedTask;
        }
        public Task Completion => done.Task;
        public MicrophoneTake Stop()
        {
            recording = false;
            take ??= new(Enumerable.Range(0, Seconds * 44100).Select(index => (float)(.15 * Math.Sin(2 * Math.PI * 220 * index / 44100))).ToArray(), 44100);
            done.TrySetResult(); return take;
        }
        public void Discard() { recording = false; if (take is not null) Array.Clear(take.Mono); done.TrySetResult(); }
        public ValueTask DisposeAsync() { Discard(); return ValueTask.CompletedTask; }
    }
    private sealed class NoKeys : IKeyProvider { public Task<string?> GetKeyAsync(string account, CancellationToken ct) => throw new InvalidOperationException("No provider keys may be read by consent tests."); }
    private sealed class QuietLog : ILog
    {
        public void RegisterSecret(string secret) { }
        public void Write(LogLevel level, string category, string message) { }
        public Task<IReadOnlyList<string>> ReadRecentAsync(int count, CancellationToken ct) => Task.FromResult<IReadOnlyList<string>>([]);
        public Task FlushAsync(CancellationToken ct) => Task.CompletedTask;
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}

internal sealed class ConsentClock : TimeProvider
{
    private DateTimeOffset now = new(2026, 10, 30, 12, 0, 0, TimeSpan.Zero);
    private readonly List<ConsentTimer> timers = [];
    private readonly Dictionary<TimeSpan, TaskCompletionSource> next = [];
    public override DateTimeOffset GetUtcNow() => now;
    public override long GetTimestamp() => now.UtcTicks;
    public override long TimestampFrequency => TimeSpan.TicksPerSecond;
    internal Task NextDelay(TimeSpan delay)
    {
        lock (timers) { var pending = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); next[delay] = pending; return pending.Task; }
    }
    public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
    {
        lock (timers)
        {
            var timer = new ConsentTimer(callback, state, now + dueTime); timers.Add(timer);
            if (next.Remove(dueTime, out var pending)) pending.TrySetResult();
            return timer;
        }
    }
    internal void Advance(TimeSpan duration)
    {
        ConsentTimer[] due;
        lock (timers) { now += duration; due = timers.Where(timer => !timer.Disposed && timer.Due <= now).ToArray(); }
        foreach (var timer in due) { timer.Disposed = true; timer.Callback(timer.State); }
    }
    private sealed class ConsentTimer(TimerCallback callback, object? state, DateTimeOffset due) : ITimer
    {
        internal readonly TimerCallback Callback = callback;
        internal readonly object? State = state;
        internal readonly DateTimeOffset Due = due;
        internal bool Disposed;
        public bool Change(TimeSpan dueTime, TimeSpan period) => false;
        public void Dispose() => Disposed = true;
        public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
    }
}
#endif
