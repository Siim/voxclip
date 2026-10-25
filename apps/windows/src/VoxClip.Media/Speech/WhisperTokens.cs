using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Logging;
using Whisper.net;

namespace VoxClip.Media.Speech;

internal static class WhisperTokens
{
    internal static IReadOnlyList<RawToken> Map(SegmentData segment, double unitStart, double unitEnd, int group,
        bool dtw, bool multilingual, ILog log, Action? usedDtw = null)
    {
        var tokens = new List<RawToken>();
        foreach (var token in segment.Tokens)
        {
            var text = token.Text ?? "";
            if (token.Id >= (multilingual ? 50257 : 50256) || text.StartsWith("[_", StringComparison.Ordinal) && text.EndsWith(']') ||
                text.StartsWith("<|", StringComparison.Ordinal) && text.EndsWith("|>", StringComparison.Ordinal)) continue;
            var startsWord = tokens.Count == 0 || text.StartsWith(' ');
            if (dtw && token.DtwTimestamp >= 0) usedDtw?.Invoke();
            var start = (dtw && token.DtwTimestamp >= 0 ? token.DtwTimestamp : token.Start) / 100.0 + unitStart;
            tokens.Add(new(text.TrimStart(' '), !startsWord, Math.Clamp(start, unitStart, unitEnd),
                Math.Clamp(token.End / 100.0 + unitStart, unitStart, unitEnd), token.Probability, null, null, group));
        }
        if (!tokens.Any(token => token.Text.Contains('\ufffd'))) return tokens;
        var words = new List<List<int>>();
        for (var index = 0; index < tokens.Count; index++)
        {
            if (words.Count == 0 || !tokens[index].JoinsPrevious) words.Add([]);
            words[^1].Add(index);
        }
        var textWords = segment.Text.Trim().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (words.Count == textWords.Length)
        {
            for (var index = 0; index < words.Count; index++)
                foreach (var tokenIndex in words[index])
                    tokens[tokenIndex] = tokens[tokenIndex] with { Text = tokenIndex == words[index][0] ? textWords[index] : "" };
        }
        else
        {
            for (var index = 0; index < tokens.Count; index++)
                tokens[index] = tokens[index] with { Text = tokens[index].Text.Replace("\ufffd", "", StringComparison.Ordinal) };
            log.Write(LogLevel.Warn, "transcribe", "Whisper token UTF-8 repair had mismatched word counts; replacement characters were removed.");
        }
        return tokens;
    }
}
