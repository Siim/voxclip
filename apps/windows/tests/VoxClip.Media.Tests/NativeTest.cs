using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Ffmpeg;
using FFmpeg.AutoGen;
using NAudio.CoreAudioApi;
using Xunit;

namespace VoxClip.Media.Tests;

internal enum NativeGate { Prerequisite, Evidence, AudioOutput, AudioInput }

internal enum NativeGateOutcome { Run, Skip, Fail }

internal static class NativeTest
{
    private static string? isolatedDataRoot;
    internal static async Task RequireAsync(bool windows = false)
    {
        if (Environment.GetEnvironmentVariable("VOXCLIP_DATA_DIR") is null)
        {
            isolatedDataRoot ??= Directory.CreateTempSubdirectory("voxclip-native-data-").FullName;
            Environment.SetEnvironmentVariable("VOXCLIP_DATA_DIR", isolatedDataRoot);
            AppDomain.CurrentDomain.ProcessExit += (_, _) =>
            {
                try { Directory.Delete(isolatedDataRoot, true); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            };
        }
        if (windows && !OperatingSystem.IsWindows())
            Require(false, "Windows WASAPI/H.264 tests require Windows; run: sh tests/VoxClip.Media.Tests/verify-vm.sh (set VOXCLIP_VM_HOST first)");
        FfmpegLoader.RootOverride = Environment.GetEnvironmentVariable("VOXCLIP_FFMPEG_DIR");
        try { await FfmpegLoader.InitializeAsync(TestContext.Current.CancellationToken); }
        catch (VoxClipException exception) when (exception.Code == VoxClipErrorCode.SharedResourcesMissing &&
            exception.InnerException is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException or NotSupportedException)
        {
            Require(false, "FFmpeg 9 LGPL shared libraries are missing or incompatible; run: VOXCLIP_FFMPEG_DIR=\"/path/to/ffmpeg9-lgpl/native\" dotnet test --project tests/VoxClip.Media.Tests -c Release");
        }
    }

    internal static string Fixture(string file)
    {
        var path = Path.Combine(NativePipelineTests.TestRoot, "Fixtures", "generated", file);
        Require(File.Exists(path), $"Generated fixture {file} is missing; run: sh tests/VoxClip.Media.Tests/generate-fixtures.sh");
        return path;
    }

    internal static unsafe void RequireInputFormat(string format)
    {
        Require(ffmpeg.av_find_input_format(format) != null,
            $"The pinned native FFmpeg test build omits the {format} demuxer; rerun with an LGPL FFmpeg 9 build that enables it.");
    }

    internal static unsafe void RequireFilter(string filter)
    {
        Require(ffmpeg.avfilter_get_by_name(filter) != null,
            $"The loaded native FFmpeg build omits the {filter} filter; rerun with an LGPL FFmpeg 9 build that enables it.");
    }

    /// <summary>Native prerequisites of required tests: Windows, FFmpeg libraries and components, fixtures.</summary>
    internal static void Require(bool condition, string remedy) => Apply(Outcome(NativeGate.Prerequisite, condition), remedy);

    /// <summary>Evidence only a VM or release run produces; hosted runs skip it even when native inputs are required.</summary>
    internal static void RequireEvidence(bool present, string remedy) => Apply(Outcome(NativeGate.Evidence, present), remedy);

    /// <summary>The default render endpoint that real WASAPI preview opens. Hosted runners have none and skip; the scripted VM runs
    /// set VOXCLIP_REQUIRE_AUDIO_OUTPUT=1, so a missing device fails them.</summary>
    internal static void RequireAudioOutput() => Apply(Outcome(NativeGate.AudioOutput, HasDefaultRenderEndpoint()),
        "This WASAPI preview test needs a default Windows audio output device, which hosted runners lack. verify-windows.ps1 (also run by verify-vm.sh) sets VOXCLIP_REQUIRE_AUDIO_OUTPUT=1 to require it.");

    internal static void RequireAudioInput() => Apply(Outcome(NativeGate.AudioInput, HasDefaultCaptureEndpoint()),
        "This microphone test requires a Console-role Windows capture endpoint. Set VOXCLIP_REQUIRE_AUDIO_INPUT=1 only for an explicitly provisioned native audio run.");

    private static bool HasDefaultCaptureEndpoint()
    {
        if (!OperatingSystem.IsWindows()) return false;
        try
        {
            using var devices = new MMDeviceEnumerator();
            return devices.HasDefaultAudioEndpoint(DataFlow.Capture, Role.Console);
        }
        catch (Exception) { return false; }
    }

    private static bool HasDefaultRenderEndpoint()
    {
        if (!OperatingSystem.IsWindows()) return false;
        try
        {
            using var devices = new MMDeviceEnumerator();
            return devices.HasDefaultAudioEndpoint(DataFlow.Render, Role.Console);
        }
        catch (Exception) { return false; }
    }

    internal static NativeGateOutcome Outcome(NativeGate gate, bool present) => Decide(gate, present,
        Environment.GetEnvironmentVariable("VOXCLIP_REQUIRE_NATIVE"),
        Environment.GetEnvironmentVariable("VOXCLIP_REQUIRE_VM_EVIDENCE"),
        Environment.GetEnvironmentVariable("VOXCLIP_REQUIRE_AUDIO_OUTPUT"),
        Environment.GetEnvironmentVariable("VOXCLIP_REQUIRE_AUDIO_INPUT"));

    // Each flag governs only its own gate: VOXCLIP_REQUIRE_NATIVE prerequisites, VOXCLIP_REQUIRE_VM_EVIDENCE evidence
    // and VOXCLIP_REQUIRE_AUDIO_OUTPUT the audio output device.
    internal static NativeGateOutcome Decide(NativeGate gate, bool present, string? requireNative, string? requireVmEvidence,
        string? requireAudioOutput, string? requireAudioInput = null)
    {
        if (present) return NativeGateOutcome.Run;
        var required = gate switch
        {
            NativeGate.Evidence => requireVmEvidence,
            NativeGate.AudioOutput => requireAudioOutput,
            NativeGate.AudioInput => requireAudioInput,
            _ => requireNative,
        };
        return required == "1" ? NativeGateOutcome.Fail : NativeGateOutcome.Skip;
    }

    private static void Apply(NativeGateOutcome outcome, string remedy)
    {
        if (outcome == NativeGateOutcome.Fail) Assert.Fail(remedy);
        if (outcome == NativeGateOutcome.Skip) Assert.Skip(remedy);
    }
}
