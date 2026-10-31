# Offline speaker calibration (S6)

Use a throwaway Python venv outside the repo, following the caption tools' pattern, with `requirements.txt`. NumPy is only for the independent numerical feature vector; neither calibration nor parity uses Python ONNX inference or Python cosine scores. The app and diagnostic use the exact official ONNX Runtime SwiftPM 1.19.2 package with its default CPU provider; no Core ML, XNNPACK or Extensions provider is registered.

The tool never downloads. Supply the verified model and Silero VAD in the same directory, extracted LibriSpeech dev-clean and test-clean (80 disjoint speakers), the DEBUG `voxclip-cli` and a scratch folder. Add dev-other and test-other for the harder, speaker-disjoint validation. Source archive hashes are pinned in `speaker.py` and the fixture README. When an archive is present beside the extracted root, the tool verifies it. FFmpeg only decodes corpus FLAC to six-second mono PCM16 at 48 kHz and 44.1 kHz; it is not linked or bundled. These synthesized rates are not independent microphone recordings. Set `VOXCLIP_SHARED_DIR`, `VOXCLIP_LIVE_TESTS=0` and `VOXCLIP_TEST_DOWNLOAD=0`.

```sh
python3 -m venv /tmp/voxclip-speaker-venv
/tmp/voxclip-speaker-venv/bin/pip install -r tools/voice-lab/requirements.txt
nice -n 10 swift build --package-path apps/macos --jobs 4 --product voxclip-cli -Xswiftc -O
/tmp/voxclip-speaker-venv/bin/python tools/voice-lab/speaker.py calibrate \
  --model /tmp/model/voxceleb_resnet34_LM.onnx \
  --vad /tmp/model/ggml-silero-v6.2.0.bin \
  --cli apps/macos/.build/debug/voxclip-cli \
  --corpus /tmp/LibriSpeech --harder --work /tmp/voxclip-speaker-work \
  --update-catalog
/tmp/voxclip-speaker-venv/bin/python tools/voice-lab/speaker.py parity \
  --model /tmp/model/voxceleb_resnet34_LM.onnx \
  --vad /tmp/model/ggml-silero-v6.2.0.bin \
  --cli apps/macos/.build/debug/voxclip-cli --work /tmp/voxclip-speaker-work
```

Add `--check` to `parity` to check existing fixtures without overwriting them. `--date` is explicit (the recorded S6 default is 2026-10-29). `speaker-diagnostic` is DEBUG-only; Release has no diagnostic entry. It calls `VoiceConsentAudio.pcm16k`, the same `SpeakerAudio.embedding` helper used by the production consent/use checks, the official CPU ONNX runtime and `VoiceSpeakerCheck.cosine`. Its per-clip embeddings and pair scores are the calibration inputs; Python does not recompute either. This selects the brief's production-pipeline option, not a claim to have measured Python/Swift runtime drift. No recording, audio output or native window is opened. `-Xswiftc -O` keeps the DEBUG hook while optimizing DSP loops.

The converter is `sinc32-blackman94`: native 16 kHz is unchanged; other rates use a phase-normalized Blackman-windowed sinc with cutoff `0.94 * min(1, 16000 / inputRate)`, half-width `ceil(32 / cutoff)`, zero extension, no delay, binary64 accumulation and Float32 output. Output length is `floor(inputFrames * 16000 / inputRate)`. The complete formula and phase alignment are binding in `doc/spec/voice-lab.md` §6.6. The combined preprocessing ID is `sinc32-blackman94-silero-6.2.0-kaldi80-v2`.

The feature contract is 16 kHz mono, existing Silero v6.2.0 in whisper.cpp b5454 (CPU, 2 threads), threshold 0.5, minimum speech 250 ms, minimum silence 100 ms, no padding or overlap. Concatenate the selected half-open speech ranges in order, then use 48,000-sample windows with a 24,000-sample hop; discard short tails. Kaldi-compatible features: PCM × 32768, 400-sample frames / 160-sample hop, per-frame DC removal, pre-emphasis 0.97, Hamming window, 512 FFT power, 80 triangular mel bins from 20 Hz to 8 kHz, natural log with float32 epsilon floor, per-bin mean subtraction, no dither/energy/CVN. Each window's 256-vector is L2-normalized, averaged, then L2-normalized again. Score with cosine. The runtime uses no provider fallback.

Calibration selects three distinct six-second utterances for each speaker, each rendered at both rates. It scores every distinct-utterance pair within each corpus/rate condition; it never pairs two rate versions of the same utterance. The 80 clean speakers fit the threshold; the 66 other speakers are disjoint validation, not additional fitting data. Neither correlated pairs nor rate renders are independent statistical trials. All independent speaker/source-clip counts and render/pair counts are reported separately.

The lead-approved rule is `tau = ceil-to-0.01(P99.9(clean calibration impostors) + max(0.002, measured cross-runtime drift))`, replacing the earlier maximum-impostor rule. Pool dev-clean and test-clean at both rates; sort scores and linearly interpolate at `(n-1)*0.999`. Decimal ceiling keeps an exact hundredth unchanged. Cross-runtime drift is not applicable here because scores already come from production; the fixed 0.002 absolute safety margin still applies. The floor is ten times the existing 0.0002 parity tolerance, not a measured bound on another runtime or unseen inputs. Freeze this candidate before harder validation. Publish only if every evaluated corpus/rate condition has FAR ≤ 0.5% and same-speaker pass ≥ 95%, with at least 200/50 pairs. Never lower the frozen candidate to pass a harder condition. A failed run clears the catalogue threshold, retains the failed evidence/margin and curves, and exits 2. With `--update-catalog`, once model verification passes, the tool clears a previously published threshold before starting corpus processing so interruption cannot preserve it.

The report includes the full 0.001-grid calibration and overall curves plus the percentile, rounding rule, exact margin candidate, model/VAD/CLI hashes, decoder version, source archives and selected WAV hashes. The 2026-10-29 end-to-end production rerun gives P99.9 = 0.44653703263815736 and publishes **tau = 0.45**. Every corpus/rate passes: worst FAR 0.113960% (test-clean), worst same-speaker pass 98.989899% (test-other). Pooled results are 30/47,088 false accepts and 874/876 same-speaker passes, not independent trials. The fixture README and §6.6 contain the full condition table. The catalogue's `outcome: passed` permits English only with installed, hash-verified model/VAD assets; English evidence never authorizes Estonian enrollment. The user's own-voice microphone check remains owed before release; spoof resistance and field validation remain separate gates.

CI runs `python3 -m unittest discover -s tools/voice-lab -p 'test_*.py'` and `python3 tools/voice-lab/check.py` without NumPy, ONNX, a corpus or network. They check percentile interpolation, decimal ceiling, drift/floor policy, failed-condition refusal, asset hashes, complete pair coverage, distinct/disjoint speaker/source identities, rates, counts, curves and catalogue evidence. Swift's real-model parity test runs only with a local `VOXCLIP_SPEAKER_MODEL_DIR`; otherwise it explicitly skips. Local verification uses real Swift CPU ONNX at all three fixture rates and checks that only verified English obtains tau 0.45, never Estonian or a caller-forged calibration. Do not download models inside tests.

## Estonian et-v1 (Riigikogu)

Estonian uses the same τ rule, gates and production CLI hook, and the corpus adapter `riigikogu.py`. The predeclared policy is `shared/fixtures/voice-lab/speaker/policy-et-v1.md`, which covers name normalisation, the transcript-only 30-session pool, the hash-split groups `rk-cal-a`, `rk-val-a`, `rk-cal-b` and `rk-val-b`, the replacement rule and the 40-speaker target / 17-speaker minimum. Group roles are explicit (`riigikogu.ROLES`, and `ROLES` for English), so no substring test decides which data fits τ.

`speaker.py` still never downloads. Only `riigikogu.py transcripts` and `riigikogu.py excerpt` use the network: they read the pinned Hugging Face revision over HTTPS.
- `transcripts` verifies every `.trs` against its Git blob ID.
- `select` reads transcripts only and writes a local selection file that contains names. Keep that file out of the repository and delete it afterwards.
- `excerpt` streams each pool FLAC once. It checks the LFS SHA-256 and the STREAMINFO MD5, and keeps only the six-second 16 kHz excerpts. The manifest it writes uses `rkNNN` keys.

Fitting and validation are separate runs. Commit the frozen report between them.

```sh
python3 tools/voice-lab/riigikogu.py transcripts --output /tmp/voxclip-et-calibration/data/trs
python3 tools/voice-lab/riigikogu.py select --transcripts /tmp/voxclip-et-calibration/data/trs --output /tmp/voxclip-et-calibration/data/selection.json
nice -n 10 python3 tools/voice-lab/riigikogu.py excerpt --selection /tmp/voxclip-et-calibration/data/selection.json \
  --output /tmp/voxclip-et-calibration/data --ffmpeg /opt/homebrew/bin/ffmpeg
nice -n 10 python3 tools/voice-lab/speaker.py calibrate --language et --phase fit --date 2026-10-31 \
  --excerpts /tmp/voxclip-et-calibration/data/excerpts.json --model /tmp/model/voxceleb_resnet34_LM.onnx \
  --vad /tmp/model/ggml-silero-v6.2.0.bin --cli apps/macos/.build/debug/voxclip-cli \
  --work /tmp/voxclip-et-calibration/work --ffmpeg /opt/homebrew/bin/ffmpeg
# commit calibration-et.json (status frozen-before-validation) and calibration-pairs-et.json, then:
nice -n 10 python3 tools/voice-lab/speaker.py calibrate --language et --phase validate --date 2026-10-31 \
  --excerpts /tmp/voxclip-et-calibration/data/excerpts.json --model /tmp/model/voxceleb_resnet34_LM.onnx \
  --vad /tmp/model/ggml-silero-v6.2.0.bin --cli apps/macos/.build/debug/voxclip-cli \
  --work /tmp/voxclip-et-calibration/work --ffmpeg /opt/homebrew/bin/ffmpeg
```

`--phase fit` renders and scores only the calibration groups. Each group × rate cell is one CLI run, and its renders are deleted as soon as they are hashed and scored, so at most one cell of renders is on disk. It writes `status: frozen-before-validation` with `threshold: null`. `--phase validate` refuses to run unless the frozen report matches its own calibration pairs and the same model, VAD, CLI and decoder. It never refits or lowers the candidate, and it exits 2 when a gate fails. Estonian never updates the catalogue: adoption is a separate change. `check.py` verifies either state of `calibration-et.json` offline, and `test_riigikogu.py` covers name normalisation, merging, pool and speaker selection, replacement, minimums and excerpt slicing using synthetic names only.
