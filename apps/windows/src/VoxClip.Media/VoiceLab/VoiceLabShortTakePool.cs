using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;
#pragma warning disable CS1591

namespace VoxClip.Media.VoiceLab;

/// <summary>ADR-R37 (Mac <c>VoiceLabVoiceCheckSession</c>): one Rewrite plan's generated voiced speech and measured mismatches,
/// across its separately approved runs. Never holds source speech.</summary>
public sealed class VoiceLabVoiceCheckSession
{
    internal sealed record Sample(Guid Id, Guid Run, int? Phrase, string Record, float[] Voiced);
    private readonly object sync = new();
    private readonly List<Sample> samples = [];
    private readonly Dictionary<string, Guid> mismatches = new(StringComparer.Ordinal);
    private readonly Dictionary<Guid, VoiceLabTakeRow> unmeasured = [];

    internal void Remember(Sample sample)
    {
        lock (sync)
            if (sample.Voiced.Length > 0 && !samples.Any(known => known.Id == sample.Id)) samples.Add(sample);
    }
    /// <summary>A mismatch blocks unmeasured takes for the record until a later run passes a measured check; a pass in the
    /// failing run does not clear it.</summary>
    internal void Measured(string record, Guid run, bool passed)
    {
        lock (sync)
        {
            if (!passed) mismatches[record] = run;
            else if (mismatches.TryGetValue(record, out var failing) && failing != run) mismatches.Remove(record);
        }
    }
    internal bool AllowsUnmeasured(string record) { lock (sync) return !mismatches.ContainsKey(record); }
    /// <summary>Earlier generated speech a short retry may borrow: that phrase's takes most recent first, then the plan's others.</summary>
    internal IReadOnlyList<Sample> Earlier(string record, int phrase, Guid excluding)
    {
        lock (sync)
        {
            var earlier = Enumerable.Reverse(samples).Where(sample => sample.Run != excluding && sample.Record == record).ToArray();
            return earlier.Where(sample => sample.Phrase == phrase).Concat(earlier.Where(sample => sample.Phrase != phrase)).ToArray();
        }
    }
    internal void RememberUnmeasured(VoiceLabTakeRow row) { lock (sync) unmeasured[row.Id] = row; }
    /// <summary>Every unmeasured take of the plan, with the record's mismatch block applied now.</summary>
    internal Dictionary<Guid, VoiceLabTakeRow> UnmeasuredUpdates()
    {
        lock (sync)
            return unmeasured.ToDictionary(pair => pair.Key, pair => pair.Value.VoiceCheck.Evidence is { } evidence
                ? pair.Value.CheckingVoice(pair.Value.VoiceCheck, speakerFailed: mismatches.ContainsKey(evidence.RecordId)) : pair.Value);
    }
    public void Reset() { lock (sync) { samples.Clear(); mismatches.Clear(); unmeasured.Clear(); } }
}

/// <summary>ADR-R37 (Mac <c>VoiceLabShortTakePool</c>): one approved run's short generated takes, checked together at its end.
/// Groups are consecutive takes of one consent record, each closing at the first take reaching three seconds of voiced speech;
/// a shorter tail joins the group before it. Never retains source speech, pads, repeats or buys audio.</summary>
public sealed class VoiceLabShortTakePool
{
    /// <summary>A waiting take: its voiced speech, its consent record, and the checks its run applies before using a verdict.</summary>
    internal sealed record Member(VoiceLabTakeRow Row, float[] Voiced, int? Phrase, VoiceConsentRecord Record,
        Func<CancellationToken, Task> Validate, Func<float[], CancellationToken, Task<float[]>> Embed);
    private readonly object sync = new();
    private readonly VoiceLabVoiceCheckSession session;
    private readonly Guid run = Guid.NewGuid();
    private readonly int? retryPhrase;
    private readonly List<Member> members = [];
    private Task<IReadOnlyDictionary<Guid, VoiceLabTakeRow>>? finishing;
    public VoiceLabShortTakePool(VoiceLabVoiceCheckSession session, int? retryPhrase = null) { this.session = session; this.retryPhrase = retryPhrase; }

    internal void Append(Member member)
    {
        lock (sync)
        {
            if (finishing is not null || member.Row.VoiceCheck is not VoiceLabTakeVoiceCheck.WaitingCheck || member.Voiced.Length >= SpeakerAudio.WindowSize ||
                member.Voiced.Any(sample => !float.IsFinite(sample)) || members.Any(known => known.Row.Id == member.Row.Id))
                throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
            members.Add(member);
        }
        // Generation order is kept beside long takes, whose measurements finish at once.
        session.Remember(new(member.Row.Id, run, member.Phrase, member.Record.RecordId, member.Voiced));
    }

    /// <summary>A long take measured on its own: its verdict counts for the record, and its speech can be borrowed later.</summary>
    internal void Measured(Guid id, float[] voiced, VoiceConsentRecord record, int? phrase, bool passed)
    {
        session.Measured(record.RecordId, run, passed);
        session.Remember(new(id, run, phrase, record.RecordId, voiced));
    }

    /// <summary>Checks the run's waiting takes once, at its end or on Stop over the completed ones; consent and current inputs are
    /// checked again. Returns every checked row by id, with the plan's other unmeasured takes under the current mismatch block.</summary>
    public Task<IReadOnlyDictionary<Guid, VoiceLabTakeRow>> FinishAsync()
    {
        lock (sync)
        {
            if (finishing is not null) return finishing;
            var snapshot = members.ToArray();
            members.Clear();
            return finishing = Task.Run(() => CheckAsync(snapshot));
        }
    }

    internal static IReadOnlyList<IReadOnlyList<Member>> Groups(IReadOnlyList<Member> members)
    {
        List<List<Member>> groups = [];
        List<Member> pending = [];
        var frames = 0;
        foreach (var member in members)
        {
            pending.Add(member); frames += member.Voiced.Length;
            if (frames < SpeakerAudio.WindowSize) continue;
            groups.Add(pending); pending = []; frames = 0;
        }
        if (pending.Count > 0)
        {
            if (groups.Count == 0) groups.Add(pending);
            else groups[^1].AddRange(pending);
        }
        return groups;
    }

    private async Task<IReadOnlyDictionary<Guid, VoiceLabTakeRow>> CheckAsync(IReadOnlyList<Member> all)
    {
        Dictionary<Guid, VoiceLabTakeRow> results = [];
        foreach (var record in all.Select(member => member.Record.RecordId).Distinct(StringComparer.Ordinal).ToArray())
        {
            foreach (var group in Groups(all.Where(member => member.Record.RecordId == record).ToArray()))
            {
                var first = group[0];
                try
                {
                    foreach (var member in group) await member.Validate(CancellationToken.None).ConfigureAwait(false);
                    var voiced = group.SelectMany(member => member.Voiced).ToList();
                    var takeCount = group.Count;
                    if (retryPhrase is { } phrase && voiced.Count < SpeakerAudio.WindowSize)
                        foreach (var sample in session.Earlier(record, phrase, run))
                        {
                            var needed = SpeakerAudio.WindowSize - voiced.Count;
                            if (needed <= 0) break;
                            voiced.AddRange(sample.Voiced.Take(needed));
                            takeCount++;
                        }
                    var mode = voiced.Count >= SpeakerAudio.WindowSize ? VoiceLabShortSpeechMode.Pooled : VoiceLabShortSpeechMode.Unmeasured;
                    var evidence = new VoiceLabShortSpeechEvidence(mode, record, first.Record.ConsentMethod, voiced.Count, takeCount);
                    double? score = null;
                    if (mode == VoiceLabShortSpeechMode.Pooled)
                    {
                        var owner = VoiceConsentRecord.DecodeEmbedding(first.Record.Speaker.Embedding) ?? throw new VoiceConsentException(VoiceConsentError.InvalidRecord);
                        score = SpeakerAudio.Cosine(owner, await first.Embed(voiced.ToArray(), CancellationToken.None).ConfigureAwait(false));
                    }
                    foreach (var member in group) await member.Validate(CancellationToken.None).ConfigureAwait(false);
                    bool mismatch;
                    if (score is { } measured)
                    {
                        mismatch = measured < first.Record.Speaker.Threshold;
                        session.Measured(record, run, !mismatch);
                    }
                    else mismatch = !session.AllowsUnmeasured(record);
                    var check = VoiceLabTakeVoiceCheck.ShortSpeech(evidence);
                    foreach (var member in group)
                    {
                        if (mode == VoiceLabShortSpeechMode.Unmeasured) session.RememberUnmeasured(member.Row.CheckingVoice(check));
                        results[member.Row.Id] = member.Row.CheckingVoice(check, score, mismatch);
                    }
                }
                catch (VoiceConsentException error) when (error.Kind == VoiceConsentError.SpeakerMismatch)
                {
                    session.Measured(record, run, false);
                    foreach (var member in group) results[member.Row.Id] = member.Row.CheckingVoice(VoiceLabTakeVoiceCheck.PerTake, speakerFailed: true);
                }
                catch (Exception error) when (error is not OutOfMemoryException)
                {
                    // Consent and provider errors keep their own cause; anything else reads as audio that could not be checked.
                    var failure = error is VoiceConsentException or VoiceLabException or VoiceLabRunInvalidatedException ? error : new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
                    foreach (var member in group) results[member.Row.Id] = member.Row.CheckingVoice(VoiceLabTakeVoiceCheck.PerTake, failure: failure);
                }
            }
        }
        foreach (var (id, row) in session.UnmeasuredUpdates()) results[id] = row;
        return results;
    }
}
