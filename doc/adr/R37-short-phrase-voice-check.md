# ADR-R37: pooled voice checks for short generated phrases

Date: 2026-11-02. Status: accepted lead decision.

The casual-speech replay spent 39 synthesis requests on 13 phrases and rejected every take before checking words. Raw lengths were 1.36–3.12 seconds; trimming and VAD left less than the calibrated three seconds of voiced speech. A local transcript review found the intended words in 37 takes and “fight simulator” in two. Test audio is synthetic; no user recording is stored.

Every completed take receives the existing Scribe word comparison, clipping and seam-loudness checks within the approved quote. Five tokens or fewer still require exact words. Longer generated takes with at least 48,000 voiced samples at 16 kHz keep their own speaker check.

For shorter takes, collect only this approved run's generated VAD output, in take order, for the same consent record. Check the completed pool after the last take, and check the completed subset on Stop. Use the existing 48,000-sample windows, 24,000-sample hops, consent embedding and threshold. Never add source speech, padding, repetition or an extra paid request. A measured pool mismatch adds the speaker failure to every pooled take; it does not erase a separate words failure.

Until the pool finishes, rows say “waiting for the voice check” and cannot be selected. A checked short row says “Short phrase · words checked · voice checked across 3 takes” with the actual count. If the completed pool still has fewer than 48,000 voiced samples, say “voice couldn't be measured (under 3 s of speech)”. Such a row is selectable only for an active own clone with recordedStatement or projectAttestation consent, and only after its words and acoustic checks pass. Record the unmeasured evidence explicitly, with no invented speaker score or passed measurement.

The first run quotes one candidate per phrase. Try another separately quotes and approves one more synthesis plus its bounded Scribe check. Prices come from the held plan; the three visible take slots remain. Speech estimates use a provider rate floor, trim allowances and a voiced-fraction margin as an advisory for optional surrounding-sentence review; short phrases are never forced to expand.

Existing measured recipes retain their format. Optional short-speech evidence preserves pooled checks or the own-clone under-length exception through acceptance and rendering. Existing frozen shared replay fixtures are unchanged. Windows adoption of the new unmeasured rendering policy remains a separate platform gate.
