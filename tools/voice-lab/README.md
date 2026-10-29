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

The predeclared conservative rule is `tau = maximum clean-calibration impostor score + max(0.002, measured cross-runtime drift)`. This targets zero clean-calibration false accepts rather than spending the 0.5% budget. Cross-runtime drift is not applicable here because scores already come from production; the fixed 0.002 absolute safety margin still applies. The floor is ten times the existing 0.0002 parity tolerance, not a measured bound on another runtime or unseen inputs. Freeze this candidate before harder validation. Publish only if every evaluated corpus/rate condition has FAR ≤ 0.5% and same-speaker pass ≥ 95%, with at least 200/50 pairs. Never lower the frozen candidate to pass a harder condition. A failed run clears the catalogue threshold, retains the failed evidence/margin and curves, and exits 2. It does not claim that no lower threshold could meet a weaker pooled-only target. With `--update-catalog`, once model verification passes, the tool clears a previously published threshold before starting corpus processing so interruption cannot preserve it.

The report includes the full 0.001-grid calibration and overall curves plus the exact margin candidate, model/VAD/CLI hashes, decoder version, source archives and selected WAV hashes. The current candidate 0.5500655012824021 has zero false accepts and 97.7169% pooled same-speaker acceptance, but test-other is only 93.9394% at both rates. Therefore **no tau is shipped**. The catalogue's `outcome: withheld` makes the app refuse creation even with installed weights. English evidence never authorizes Estonian enrollment; the user's own-voice microphone check, spoof resistance and field validation remain separate gates.

CI runs `python3 -m unittest discover -s tools/voice-lab -p 'test_*.py'` and `python3 tools/voice-lab/check.py` without NumPy, ONNX, a corpus or network. They check margin policy, failed-condition refusal, asset hashes, complete pair coverage, distinct/disjoint speaker/source identities, rates, counts, curves and catalogue evidence. Swift's real-model parity test runs only with a local `VOXCLIP_SPEAKER_MODEL_DIR`; otherwise it explicitly skips. Local verification uses real Swift CPU ONNX at all three fixture rates even when calibration is withheld, without granting any clone capability. Do not download models inside tests.
