using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

/// <summary>How a phrase's quoted words and expression tags are laid out on its card.</summary>
internal static class RewriteQuote
{
    /// <summary>Mac <c>AudioTagPhrase.pieces</c>: the quote marks sit on the first and last words, or stand alone when a tag
    /// starts or ends the phrase.</summary>
    internal static IReadOnlyList<(int? Tag, int? Word, string Text)> Pieces(IReadOnlyList<string> words, IReadOnlyList<VoiceLabAudioTag> tags)
    {
        List<(int?, int?, string)> pieces = [];
        var startsWithTag = tags.Any(tag => tag.BeforeToken == 0) || words.Count == 0;
        var endsWithTag = tags.Any(tag => tag.BeforeToken >= words.Count) || words.Count == 0;
        if (startsWithTag) pieces.Add((null, null, "“"));
        for (var boundary = 0; boundary <= words.Count; boundary++)
        {
            foreach (var (_, index) in tags.Select((tag, index) => (tag, index)).Where(item => Math.Min(item.tag.BeforeToken, words.Count) == boundary))
                pieces.Add((index, null, tags[index].Tag));
            if (boundary >= words.Count) continue;
            var word = words[boundary];
            if (boundary == 0 && !startsWithTag) word = "“" + word;
            if (boundary == words.Count - 1 && !endsWithTag) word += "”";
            pieces.Add((null, boundary, word));
        }
        if (endsWithTag) pieces.Add((null, null, "”"));
        return pieces;
    }

}
