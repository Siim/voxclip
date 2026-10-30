using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Models;

namespace VoxClip.App.ViewModels;

internal static class TranscriptionModelChoices
{
    internal static TranscriptionModel[] InstalledLocal(IEnumerable<TranscriptionModel> catalogue, IReadOnlyList<InstalledModel> installed) =>
        catalogue.Where(model => model.Listed && model.Kind == "asr" && model.Engine == TranscriptEngine.Whispercpp &&
            installed.Any(entry => entry.Id == model.Id && entry.Verified)).ToArray();
}
