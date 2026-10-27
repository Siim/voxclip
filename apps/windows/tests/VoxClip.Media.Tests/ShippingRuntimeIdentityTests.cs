using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using FFmpeg.AutoGen;
using VoxClip.Media.Ffmpeg;
using Xunit;

namespace VoxClip.Media.Tests;

/// <summary>Checks the actual loaded modules against the audited shipping report on Windows.</summary>
[Trait("Category", "RequiresFFmpeg")]
[Trait("Category", "RequiresWindows")]
public sealed class ShippingRuntimeIdentityTests
{
    private const string EvidenceRemedy =
        "Set VOXCLIP_SHIPPING_REPORT and VOXCLIP_MODULE_EVIDENCE for shipping runtime acceptance.";

    private static readonly string[] Names =
    [
        "avcodec-63.dll", "avformat-63.dll", "avutil-61.dll", "avfilter-12.dll",
        "swresample-7.dll", "swscale-10.dll"
    ];

    private static bool EvidencePresent =>
        !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("VOXCLIP_SHIPPING_REPORT")) &&
        !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("VOXCLIP_MODULE_EVIDENCE"));

    [Fact]
    public async Task LoadedModulesMatchShippingReport()
    {
        NativeTest.RequireEvidence(EvidencePresent, EvidenceRemedy);
        await MatchLoadedModulesAsync();
    }

    /// <summary>Behaviour tests run on any loaded FFmpeg and add this identity check whenever evidence is supplied.</summary>
    internal static async Task MatchShippingReportWhenEvidencePresentAsync()
    {
        if (NativeTest.Outcome(NativeGate.Evidence, EvidencePresent) == NativeGateOutcome.Skip) return;
        NativeTest.RequireEvidence(EvidencePresent, EvidenceRemedy);
        await MatchLoadedModulesAsync();
    }

    private static async Task MatchLoadedModulesAsync()
    {
        await NativeTest.RequireAsync(windows: true);
        var reportPath = Environment.GetEnvironmentVariable("VOXCLIP_SHIPPING_REPORT")!;
        var evidencePath = Environment.GetEnvironmentVariable("VOXCLIP_MODULE_EVIDENCE")!;
        using var report = JsonDocument.Parse(File.ReadAllText(reportPath));
        var expected = report.RootElement.GetProperty("dlls");
        var rid = report.RootElement.GetProperty("rid").GetString();
        Assert.Equal(rid switch
        {
            "win-arm64" => Architecture.Arm64,
            "win-x64" => Architecture.X64,
            _ => throw new InvalidDataException("Unknown audited runtime architecture.")
        }, RuntimeInformation.ProcessArchitecture);
        var root = Path.GetFullPath(Environment.GetEnvironmentVariable("VOXCLIP_FFMPEG_DIR")!);
        using var process = Process.GetCurrentProcess();
        var loaded = process.Modules.Cast<ProcessModule>()
            .Where(module => Names.Contains(module.ModuleName, StringComparer.OrdinalIgnoreCase))
            .ToDictionary(module => module.ModuleName, StringComparer.OrdinalIgnoreCase);
        Assert.Equal(Names.Length, loaded.Count);

        var modules = new List<object>();
        foreach (var name in Names)
        {
            Assert.True(loaded.TryGetValue(name, out var module), $"FFmpeg module not loaded: {name}");
            var path = Path.GetFullPath(module!.FileName);
            Assert.Equal(Path.Combine(root, name), path, ignoreCase: true);
            var bytes = new FileInfo(path).Length;
            using var stream = File.OpenRead(path);
            var hash = Convert.ToHexStringLower(SHA256.HashData(stream));
            Assert.Equal(expected.GetProperty(name).GetProperty("size").GetInt64(), bytes);
            Assert.Equal(expected.GetProperty(name).GetProperty("sha256").GetString(), hash);
            modules.Add(new { name, path, bytes, sha256 = hash });
        }
        var configuration = ffmpeg.avcodec_configuration();
        FfmpegLoader.ValidateConfiguration(configuration);
        var license = ffmpeg.avcodec_license();
        Assert.StartsWith("LGPL version 2.1 or later", license);
        Directory.CreateDirectory(Path.GetDirectoryName(evidencePath)!);
        File.WriteAllText(evidencePath, JsonSerializer.Serialize(new
        {
            report = report.RootElement.GetProperty("sha256").GetString(),
            rid = report.RootElement.GetProperty("rid").GetString(),
            processArchitecture = RuntimeInformation.ProcessArchitecture.ToString(),
            license,
            configuration,
            modules
        }, new JsonSerializerOptions { WriteIndented = true }));
    }

    [Fact]
    public async Task PcmFloatWavDecodesAndSeeksWithShippingDlls()
    {
        NativeTest.RequireEvidence(EvidencePresent, EvidenceRemedy);
        await MatchLoadedModulesAsync();
        var directory = Directory.CreateTempSubdirectory("voxclip-shipping-wav-").FullName;
        try
        {
            var path = Path.Combine(directory, "float-stereo.wav");
            const int frames = 48_000;
            const int channels = 2;
            const int bytesPerFrame = channels * sizeof(float);
            using (var stream = File.Create(path))
            using (var writer = new BinaryWriter(stream))
            {
                writer.Write("RIFF"u8);
                writer.Write(36 + frames * bytesPerFrame);
                writer.Write("WAVEfmt "u8);
                writer.Write(16);
                writer.Write((ushort)3);
                writer.Write((ushort)channels);
                writer.Write(48_000);
                writer.Write(48_000 * bytesPerFrame);
                writer.Write((ushort)bytesPerFrame);
                writer.Write((ushort)32);
                writer.Write("data"u8);
                writer.Write(frames * bytesPerFrame);
                for (var frame = 0; frame < frames; frame++)
                {
                    writer.Write(Sample(frame));
                    writer.Write(-Sample(frame));
                }
            }
            using var decoder = new AudioDecoder(path);
            Assert.Equal(48_000, decoder.SampleRate);
            Assert.Equal(channels, decoder.Channels);
            var samples = new float[256 * channels];
            Assert.Equal(256, decoder.Read(samples, 256, TestContext.Current.CancellationToken));
            for (var frame = 0; frame < 256; frame++)
            {
                Assert.InRange(Math.Abs(samples[frame * channels] - Sample(frame)), 0, 1e-6);
                Assert.InRange(Math.Abs(samples[frame * channels + 1] + Sample(frame)), 0, 1e-6);
            }
            decoder.Seek(12_000);
            Assert.Equal(256, decoder.Read(samples, 256, TestContext.Current.CancellationToken));
            for (var frame = 0; frame < 256; frame++)
            {
                Assert.InRange(Math.Abs(samples[frame * channels] - Sample(12_000 + frame)), 0, 1e-6);
                Assert.InRange(Math.Abs(samples[frame * channels + 1] + Sample(12_000 + frame)), 0, 1e-6);
            }
        }
        finally { Directory.Delete(directory, true); }
    }

    private static float Sample(int frame) => frame / 48_000f - 0.5f;
}
