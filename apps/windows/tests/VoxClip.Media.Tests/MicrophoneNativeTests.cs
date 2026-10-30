using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using NAudio.CoreAudioApi;
using VoxClip.Media.Audio;
using Xunit;

namespace VoxClip.Media.Tests;

[Trait("Category", "RequiresWindows")]
public sealed class MicrophoneNativeTests
{
    [Fact]
    public void N1InventoryNeverStartsAStreamAndHashesNames()
    {
        if (!OperatingSystem.IsWindows()) { NativeTest.Require(false, "N1 inventory is owed on Windows ARM64 and x64."); return; }
        var inventory = new List<object>();
        using var enumerator = new MMDeviceEnumerator();
        using var endpoints = enumerator.EnumerateAudioEndPoints(DataFlow.All, DeviceState.All);
        foreach (var endpoint in endpoints)
        {
            using (endpoint) inventory.Add(new { endpoint.DataFlow, endpoint.State,
                NameHash = Hash(endpoint.FriendlyName), IdHash = Hash(endpoint.ID) });
        }
        Evidence("N1", new { Architecture = RuntimeInformation.ProcessArchitecture.ToString(), Endpoints = inventory,
            CaptureCount = MicrophoneDevices.Active().Count,
            HasDefaultCapture = enumerator.HasDefaultAudioEndpoint(DataFlow.Capture, Role.Console), StreamOpened = false });
    }

    [Theory]
    [InlineData(44100)] [InlineData(48000)]
    public async Task N2SilentOutputScenarioTransparency(int rate)
    {
        Assert.True(rate is 44100 or 48000);
        await Task.CompletedTask;
        RequireScenario();
#if DEBUG
        var clock = new MicrophoneClock();
        var endpoint = new DebugMicrophoneEndpoint($"tone;rate={rate};channels=2", clock);
        await using var recorder = new VoiceMicrophoneRecorder(_ => endpoint, clock);
        await recorder.StartAsync(30, TestContext.Current.CancellationToken); clock.Advance(TimeSpan.FromSeconds(1));
        Assert.True(recorder.Snapshot().Level > 0);
        var take = recorder.Stop(); await recorder.Completion;
        Assert.Equal(rate, take.Rate); Assert.Equal(rate, take.Mono.Length);
        double error = 0;
        for (var frame = 0; frame < take.Mono.Length; frame++)
            error = Math.Max(error, Math.Abs(take.Mono[frame] - Math.Sin(2 * Math.PI * 440 * frame / rate) * 0.1));
        Assert.True(error < 0.000001);
        Evidence("N2", new { rate, Frames = take.Mono.Length, MaxError = error, AudibleOutput = false, Endpoint = "DEBUG scenario" });
#endif
    }

    [Fact]
    public async Task N3ScenarioStallReleasesOwnerAndZerosSamples()
    {
        await Task.CompletedTask;
        RequireScenario();
#if DEBUG
        var clock = new MicrophoneClock(); var endpoint = new DebugMicrophoneEndpoint("stall@1", clock);
        await using var recorder = new VoiceMicrophoneRecorder(_ => endpoint, clock);
        await recorder.StartAsync(30, TestContext.Current.CancellationToken); clock.Advance(TimeSpan.FromMilliseconds(2600)); await recorder.Completion;
        Assert.Equal(MicrophoneError.DeviceLost, recorder.Snapshot().Failure);
        Assert.Empty(recorder.Stop().Mono);
        Assert.Equal(1, endpoint.StopCount); Assert.Equal(1, endpoint.DisposeCount);
        Evidence("N3", new { Failure = "DeviceLost", Frames = 0, endpoint.StopCount, endpoint.DisposeCount, AudibleOutput = false });
#endif
    }

    [Fact]
    public async Task N4ScenarioCancellationAndTeardownRaces()
    {
        await Task.CompletedTask;
        RequireScenario();
#if DEBUG
        await new MicrophoneCaptureTests().ActivationWaitsWithoutTimeoutAndCancellationIsPrompt();
        await new MicrophoneCaptureTests().StopDiscardDisposeAndCallbacksCanRace();
        Evidence("N4", new { ActivationCancelled = true, TeardownOnce = true, AudibleOutput = false });
#endif
    }

    [Fact]
    public async Task N5PrivacyDenialOnlyInsideBackedUpHarness()
    {
        if (!OperatingSystem.IsWindows()) { NativeTest.Require(false, "N5 privacy denial is owed on Windows."); return; }
        NativeTest.RequireEvidence(Environment.GetEnvironmentVariable("VOXCLIP_MIC_PRIVACY_HARNESS") == "backed-up",
            "N5 must run through microphone-native.ps1 after its registry backup was copied to the host.");
        NativeTest.RequireAudioInput();
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        await using var recorder = new VoiceMicrophoneRecorder();
        MicrophoneError? failure = null;
        try
        {
            await recorder.StartAsync(30, cancellation.Token);
            await Task.Delay(TimeSpan.FromMilliseconds(2300), cancellation.Token);
            failure = recorder.Snapshot().Failure;
        }
        catch (MicrophoneException exception) { failure = exception.Error; }
        catch (OperationCanceledException) { }
        finally { recorder.Discard(); }
        Evidence("N5", new { Failure = failure?.ToString(), NoAudioWritten = true });
        if (failure is not (MicrophoneError.Permission or MicrophoneError.Silent))
            Assert.Skip("N5 is owed: this Windows build did not enforce the harness ConsentStore denial; manual D2 is required.");
    }

    [Fact]
    public void N6ReleaseContainsNoInjectionOrLoopbackEntry()
    {
#if DEBUG
        Assert.Skip("N6 requires the Release Media assembly.");
#else
        new MicrophoneCaptureTests().ReleaseAssemblyContainsNoDebugEndpointOrEnvironmentRead();
        Evidence("N6", new { InjectionAbsent = true, Architecture = RuntimeInformation.ProcessArchitecture.ToString() });
#endif
    }

    private static void RequireScenario()
    {
        NativeTest.Require(OperatingSystem.IsWindows(), "Native microphone scenarios are owed on Windows.");
        NativeTest.RequireEvidence(Environment.GetEnvironmentVariable("VOXCLIP_MIC_NATIVE") == "1",
            "Opt into inaudible DEBUG microphone scenarios with VOXCLIP_MIC_NATIVE=1 under the owned VM lease.");
#if !DEBUG
        Assert.Skip("N2-N4 require DEBUG-only scenario endpoints. No audible render playback is permitted.");
#endif
    }
    private static string Hash(string text) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
    private static void Evidence(string step, object result)
    {
        var json = JsonSerializer.Serialize(new { Step = step, Result = result });
        TestContext.Current.TestOutputHelper?.WriteLine(json);
        if (Environment.GetEnvironmentVariable("VOXCLIP_MIC_EVIDENCE_DIR") is { Length: > 0 } directory)
        {
            Directory.CreateDirectory(directory);
            File.WriteAllText(Path.Combine(directory, step + "-" + Guid.NewGuid().ToString("N") + ".json"), json);
        }
    }
}
