using System.Text.Json;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Speech;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.Speech;

public sealed class SharedTranscriptionFixtureTests
{
    public static IEnumerable<object?[]> Responses()
    {
        var directory = Path.Combine(FixtureLoader.SharedRoot, "fixtures", "transcription", "elevenlabs");
        var paths = Directory.Exists(directory)
            ? Directory.GetFiles(directory, "*.expected.json").Order(StringComparer.Ordinal).ToArray() : [];
        if (paths.Length == 0) yield return [null];
        foreach (var path in paths) yield return [path];
    }

    [Theory]
    [MemberData(nameof(Responses))]
    public async Task PairedResponseMapsExactlyAndReusesOnePaidUpload(string? expectedPath)
    {
        Assert.SkipUnless(expectedPath is not null, "Shared transcription/elevenlabs fixture folder or expectation sidecars are missing.");
        var ct = TestContext.Current.CancellationToken;
        using var expectedDocument = JsonDocument.Parse(await File.ReadAllTextAsync(expectedPath!, ct));
        var expected = expectedDocument.RootElement;
        Assert.Equal("voxclip-transcription-expected/1", expected.GetProperty("schema").GetString());
        var responsePath = expectedPath![..^".expected.json".Length] + ".json";
        Assert.True(File.Exists(responsePath), "Every expectation must have a paired provider response.");
        var response = await File.ReadAllTextAsync(responsePath, ct);
        using var body = JsonDocument.Parse(response);
        using var files = new SpeechFiles();
        using var handler = new StubHttp((_, _) => Task.FromResult(StubHttp.Json(response)));
        using var engine = ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, region: ElevenLabsRegion.Default);
        var diarize = expected.GetProperty("diarize").GetBoolean();
        var raw = await engine.MapResponseAsync(body.RootElement, diarize, new LanguageChoice.Auto(), ct);
        var tokens = expected.GetProperty("rawTokens").EnumerateArray().Select(token => new RawToken(
            token.GetProperty("text").GetString()!, token.GetProperty("joinsPrevious").GetBoolean(),
            NullableNumber(token, "start"), NullableNumber(token, "end"), NullableNumber(token, "conf"),
            token.GetProperty("speaker").GetString(), token.GetProperty("kind").GetString() switch
            {
                null => null, "event" => (WordKind?)WordKind.Event,
                _ => throw new InvalidDataException("Unexpected shared raw-token kind.")
            }, token.GetProperty("group").GetInt32())).ToArray();
        Assert.Equal(tokens, raw.Tokens);
        Assert.Equal(expected.GetProperty("language").GetString(), raw.Language);
        var request = files.Request(new(Diarize: diarize));
        for (var import = 0; import < 2; import++)
        {
            var service = new TranscriptionService([engine], dataRoot: files.Root);
            if (expected.TryGetProperty("importError", out var importError) && importError.ValueKind == JsonValueKind.String)
            {
                var error = await Assert.ThrowsAsync<VoxClipException>(() => service.TranscribeAsync(request, null, null, ct));
                Assert.Equal(Enum.Parse<VoxClipErrorCode>(importError.GetString()!, ignoreCase: true), error.Code);
            }
            else
            {
                var transcript = await service.TranscribeAsync(request, null, null, ct);
                Assert.Equal(expected.GetProperty("language").GetString(), transcript.Language);
                Assert.Equal(import > 0, transcript.FromCache);
            }
        }
        Assert.Equal(expected.GetProperty("expectedUploads").GetInt32(), handler.Calls);
    }

    private static string WordAssemblyDirectory => Path.Combine(FixtureLoader.SharedRoot, "fixtures", "transcription", "word-assembly");

    public static IEnumerable<TheoryDataRow<string>> WordAssemblyCases() =>
        Directory.GetFiles(WordAssemblyDirectory, "*.json").Order(StringComparer.Ordinal).Select(path => new TheoryDataRow<string>(Path.GetFileName(path)));

    [Fact]
    public void SharedWordAssemblyCasesArePresent() => Assert.Equal(5, Directory.GetFiles(WordAssemblyDirectory, "*.json").Length);

    [Theory]
    [MemberData(nameof(WordAssemblyCases))]
    public void SharedWordAssemblyCaseMatches(string file)
    {
        using var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(WordAssemblyDirectory, file)));
        var fixture = document.RootElement;
        Assert.Equal("voxclip-word-assembly-fixture/1", fixture.GetProperty("schema").GetString());
        Assert.Equal(file, fixture.GetProperty("name").GetString() + ".json");
        Assert.False(string.IsNullOrEmpty(fixture.GetProperty("derivation").GetString()));
        var rule = fixture.GetProperty("rule");
        var grouping = new GroupingRule(rule.GetProperty("end").GetString() switch
            {
                "lastToken" => GroupingEnd.LastToken, "nextWordStart" => GroupingEnd.NextWordStart,
                _ => throw new InvalidDataException("Unexpected shared grouping end.")
            }, rule.GetProperty("conf").GetString() switch
            {
                "single" => GroupingConfidence.Single, "mean" => GroupingConfidence.Mean, "min" => GroupingConfidence.Min,
                _ => throw new InvalidDataException("Unexpected shared grouping confidence.")
            }, rule.GetProperty("bracketEvents").GetBoolean());
        var tokens = fixture.GetProperty("tokens").EnumerateArray().Select(token => new RawToken(
            token.GetProperty("text").GetString()!, token.GetProperty("joinsPrevious").GetBoolean(),
            NullableNumber(token, "start"), NullableNumber(token, "end"), NullableNumber(token, "conf"),
            token.GetProperty("speaker").GetString(), Kind(token), token.GetProperty("group").GetInt32())).ToArray();
        var actual = WordAssembler.Group(tokens, grouping, fixture.GetProperty("timelineStart").GetDouble());
        var expected = fixture.GetProperty("expect").EnumerateArray().ToArray();
        Assert.Equal(expected.Select(word => word.GetProperty("text").GetString()!).ToArray(), actual.Select(word => word.Text).ToArray());
        for (var index = 0; index < expected.Length; index++)
        {
            var word = actual[index];
            Assert.Equal(expected[index].GetProperty("speaker").GetString(), word.Speaker);
            Assert.Equal(Kind(expected[index]) ?? WordKind.Word, word.Kind);
            foreach (var (name, value) in new[] { ("start", word.Start), ("end", word.End), ("conf", word.Conf) })
            {
                var want = NullableNumber(expected[index], name);
                Assert.True(want is null ? value is null : value is { } got && Math.Abs(got - want.Value) <= 1e-9,
                    $"{file}: word {index} {name} is {value}, expected {want}");
            }
        }
    }

    private static double? NullableNumber(JsonElement token, string name) =>
        token.GetProperty(name).ValueKind == JsonValueKind.Null ? null : token.GetProperty(name).GetDouble();

    private static WordKind? Kind(JsonElement value) => value.GetProperty("kind").GetString() switch
    {
        null => null, "word" => WordKind.Word, "event" => WordKind.Event,
        _ => throw new InvalidDataException("Unexpected shared word kind.")
    };
}
