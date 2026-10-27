using System.Globalization;
using System.Text;
using VoxClip.Core.Domain.Editing;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>The length of new wording for the length budget and its checks (voice-lab §8.9.1). Spaces, punctuation, symbols,
/// combining marks and number forms other than decimal digits do not count. Vectors: <c>shared/fixtures/voice-lab/text-length-cases.json</c>.</summary>
public static class VoiceLabTextLength
{
    /// <summary>The number of Unicode scalars of general category L* or Nd in the NFC form of <paramref name="text"/>.</summary>
    public static int Length(string text)
    {
        var count = 0;
        foreach (var rune in EditingAlgorithms.Nfc(text).EnumerateRunes())
            if (Rune.GetUnicodeCategory(rune) is UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter or UnicodeCategory.TitlecaseLetter
                or UnicodeCategory.ModifierLetter or UnicodeCategory.OtherLetter or UnicodeCategory.DecimalDigitNumber) count++;
        return count;
    }
}
