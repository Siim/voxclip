# ADR-R45: a matching voice for each video, made from its own verified speech; the previous video's is removed

Date: 2026-11-06. Status: accepted (package v2-per-video-voice; the user's request and the lead's decisions below).

## Context

The user (2026-11-06): "i think it makes sense to clone the voice each time again for each individual clip we make and rm prev one... otherwize i think it wont match well".

ADR-R41 and ADR-R44 measured why. The user's clone "siim (VoxClip)", made from 8 project samples, scores about 0.54 against the user's own speech beside its takes, while that speech scores 0.81–0.90 against the consent recording. The takes are also darker than the room. ADR-R44's rebuild trains only on speech at the §6.5.1 floor (20 dB SNR), and the user's car video DJI_20261014184458_0030_D_1080p (348 s) has none: its stretches are 4.5–15.4 dB, median 7.4. So the rebuild offers "27 s from 0 videos and your consent clip", which is not enough.

The lead decided:

- **Per source video, not per clip.** Clips of one video share its microphone, room and noise, and a 20–45 s clip is too little speech for a clone.
- **The consent voice stays** as the anchor and the fallback.
- **The previous video's voice is removed** when a new one is made.

## Measurement (read only, local, 2026-11-06)

`VoicePerVideoMeasureTests` read the DJI 0030 project and its media, the anchor's consent folder (copied into a temporary store) and the installed speaker model (wespeaker-resnet34, τ 0.45). Nothing was written to the user's data and nothing was sent. §6.5.1 gives 15 pieces of 5–30 s (all rejected as `lowSnr` at 20 dB, 4 more `short`). Each piece was scored one hop, by its lowest part, against the anchor's own embedding.

| SNR floor | Pieces | Speech | Pass one hop | Their speech | The video's voice |
|---|---:|---:|---:|---:|---|
| 20 dB | 0 | 0 s | 0 | 0 s | none |
| 12 dB | 2 | 42.6 s | 0 | 0 s | none |
| 8 dB | 6 | 110.4 s | 3 | 41.0 s | 41.0 s + the 27.7 s consent clip, 4 files |
| 6 dB | 13 | 246.7 s | 4 | 53.2 s | 53.2 s + the clip, 5 files |

The passing pieces are 72.4–82.0 s (8.83 dB, 0.47), 83.4–100.2 s (8.84 dB, 0.48), 101.4–116.0 s (11.31 dB, 0.49) and, at 6 dB, 172.3–184.5 s (6.70 dB, 0.45). A fifth owner piece (295.8–312.2 s, 0.47) is at 4.46 dB. The cleanest piece (117–137 s, 15.4 dB) is not the owner one hop from the statement (0.40), and it stays out at every floor. The production finder at 8 dB agrees: "1 min 8 s from 1 video and your consent clip", 4 WAVs.

## Decision

1. **The floor.** A per-video voice uses an SNR floor of **8 dB** (`VoicePerVideo.minimumSnrDb`) for cleanliness only. When any piece is under 20 dB, creation sets ElevenLabs' `remove_background_noise` to true (§6.5 step 5; the client already sent the field and the quote already bound it). The tone match and room tone at render put the room back. 8 dB is the lowest floor that gives this video enough of its own speech with margin (41 s for a 30 s minimum). Going to 6 dB adds one 12 s piece and doubles the noisy pool (13 pieces, 9 of them not the owner one hop), and leaves less headroom for the noise removal. Below 8 dB is a choice for a later measurement with more videos, not for this one.
2. **Identity is unchanged.** Every piece must pass **one hop** against the anchor's own embedding by its lowest part (§6.6, ADR-R41), whatever the floor. The lower floor never admits a voice that is not the owner's. Noise lowers the score, so it can only remove pieces.
3. **One video.** The picker is the rebuild's (`VoiceRebuild.pick`, the most different pieces after the cleanest), limited to this project's source, with up to 24 candidates from it. The pieces are §6.5.1's own, split within one speaker's run and ended by any transcript event such as music. Below 20 dB they are the pieces §6.5.1 rejected only as `lowSnr`.
4. **The anchor's consent.** The anchor's consent clip (`reference.wav`) is sent first, so the new record's embedding is the anchor's own and ADR-R41's one-hop bound does not move. The new record carries the anchor's attestations and creator binding, through the existing attested creation, journal and quote. The per-video book records the anchor's id and the clip's SHA-256 as the link. Learned references are carried over through `carryReferences`, each re-checked one hop.
5. **The minimum.** The video's own speech must reach **30 s** (`VoicePerVideo.minimumVideoMs`, the attested route's minimum) without the consent clip, so the voice is the video's and not the statement's. Below that, the video keeps the anchor and says so once ("This video has only {n} of your own clear speech, so takes use siim. A matching voice needs 30 s.").
6. **The one-time opt-in.** The setting `voiceLab.matchEachVideo` has no default. While it is unset, Rewrite (and so ✦ Make it postable and ✦ Claude does it all, whose takes go through Rewrite) shows one inline card. It reads: "Make a matching voice from this video? Your takes will sound like this recording. The previous video's voice is removed. Only your clearest speech from this video is sent to ElevenLabs; no video." It offers **Match this video · {price}** and **Use siim**. The price is the catalogue's `createClone` row: "free" today. A missing row says the price list has none, and VoxClip never invents a price. The click is the approval for this and later videos. Settings › Voices shows the answer and can change it. Claude mode never answers it and only reads it: with "match", every run makes the video's voice before any price, as a manual one does.
7. **Use.** The video's voice is stored per media `contentKey` in app data (`<data>/VoiceLab/per-video.json`, `voxclip-voice-per-video/1`), never in the project file. Rewrite starts with it for every take in that video, every clip included. Another video starts with the anchor, never with a previous video's voice. The guard and references work as before. The new voice's length calibration (ADR-R43) is seeded from the anchor's, and its own takes then take over.
8. **Removal.** After the new voice is created and saved, the previous video's voice is deleted through the existing deletion (creator binding, journal, tombstone, §6.10). The anchor is never deleted. A voice whose project still holds paid takes nobody used or discarded is kept until they are. Takes already rendered into projects never keep it: rendered assets stay playable. A failed deletion stays owed, with a one-line note in Settings › Voices, **Retry now**, and a background retry that backs off from 30 s to an hour.
9. **Measure.** After the first take with a video's voice, its speaker cosine against the original speech beside it (the guard's speech, on this Mac) is recorded for that video. The anchor's takes in the video are pooled the same way. Settings › Voices shows both, and the log carries the numbers.

## Consequences

- The user's ElevenLabs account holds at most the anchor and one video's voice, plus one owed while its takes wait.
- A creation per new video. It is free on the catalogue today. On a plan with a voice-slot limit the creation can fail, and then the takes use the anchor with the reason in one line.
- The real before/after comparison needs the user's opt-in click on their account. The diagnostic in Settings › Voices then answers "did matching help".
- Windows owes the twin (apps/macos/CONTRACTS.md).
