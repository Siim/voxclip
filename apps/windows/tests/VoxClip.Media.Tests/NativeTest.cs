using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Ffmpeg;
using FFmpeg.AutoGen;
using Xunit;

namespace VoxClip.Media.Tests;

internal enum NativeGate { Prerequisite, Evidence }

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

    internal static NativeGateOutcome Outcome(NativeGate gate, bool present) => Decide(gate, present,
        Environment.GetEnvironmentVariable("VOXCLIP_REQUIRE_NATIVE"),
        Environment.GetEnvironmentVariable("VOXCLIP_REQUIRE_VM_EVIDENCE"));

    // VOXCLIP_REQUIRE_NATIVE governs only prerequisites and VOXCLIP_REQUIRE_VM_EVIDENCE only evidence.
    internal static NativeGateOutcome Decide(NativeGate gate, bool present, string? requireNative, string? requireVmEvidence)
    {
        if (present) return NativeGateOutcome.Run;
        var required = gate == NativeGate.Evidence ? requireVmEvidence : requireNative;
        return required == "1" ? NativeGateOutcome.Fail : NativeGateOutcome.Skip;
    }

    private static void Apply(NativeGateOutcome outcome, string remedy)
    {
        if (outcome == NativeGateOutcome.Fail) Assert.Fail(remedy);
        if (outcome == NativeGateOutcome.Skip) Assert.Skip(remedy);
    }
}
