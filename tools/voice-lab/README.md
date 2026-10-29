# Offline speaker calibration (S6)

Create a throwaway Python 3.9–3.12 venv outside the repo, following the caption tools' pattern, and install `requirements.txt`. These are tool-only dependencies, not app dependencies. The app uses the exact official ONNX Runtime SwiftPM 1.19.2 package with its default CPU provider; no Core ML, XNNPACK or Extensions provider is registered.

The tool never downloads. Supply the verified model and Silero VAD from `shared/catalog/voice-lab-models.json`, an extracted LibriSpeech test-clean archive (source and SHA in the fixture README), the DEBUG `voxclip-cli` and a scratch folder. FFmpeg is used only by the offline tool to decode corpus FLAC; it is not linked or bundled. Set `VOXCLIP_LIVE_TESTS=0` and `VOXCLIP_TEST_DOWNLOAD=0`.

```sh
/usr/bin/python3 -m venv /tmp/voxclip-speaker-venv
/tmp/voxclip-speaker-venv/bin/pip install -r tools/voice-lab/requirements.txt
/tmp/voxclip-speaker-venv/bin/python tools/voice-lab/speaker.py calibrate \
  --model /tmp/model/voxceleb_resnet34_LM.onnx \
  --vad /tmp/model/ggml-silero-v6.2.0.bin \
  --cli apps/macos/.build/debug/voxclip-cli \
  --corpus /tmp/LibriSpeech/test-clean --work /tmp/voxclip-speaker-work \
  --update-catalog
/tmp/voxclip-speaker-venv/bin/python tools/voice-lab/speaker.py parity \
  --model /tmp/model/voxceleb_resnet34_LM.onnx \
  --vad /tmp/model/ggml-silero-v6.2.0.bin \
  --cli apps/macos/.build/debug/voxclip-cli --work /tmp/voxclip-speaker-work
```

Add `--check` to `parity` to check existing fixtures without overwriting them. `--date` is explicit (the recorded S6 default is 2026-10-29). `speaker-diagnostic` is a DEBUG-only offline CLI command; Release has no diagnostic entry. It calls the production Silero VAD and the same Core windowing/features as the app. Calibration also independently recomputes every feature matrix in NumPy and refuses drift over 0.0002. No recording, audio output or native window is opened.

The feature contract is 16 kHz mono, existing Silero v6.2.0 in whisper.cpp b5454 (CPU, 2 threads), threshold 0.5, minimum speech 250 ms, minimum silence 100 ms, no padding or overlap. Concatenate the selected half-open speech ranges in order, then use 48,000-sample windows with a 24,000-sample hop; discard short tails. Kaldi-compatible features: PCM × 32768, 400-sample frames / 160-sample hop, per-frame DC removal, pre-emphasis 0.97, Hamming window, 512 FFT power, 80 triangular mel bins from 20 Hz to 8 kHz, natural log with float32 epsilon floor, per-bin mean subtraction, no dither/energy/CVN. Each window's 256-vector is L2-normalized, averaged, then L2-normalized again. Score with cosine. The runtime uses no provider fallback.

The threshold is the smallest candidate meeting empirical FAR ≤ 1% and same-speaker pass ≥ 95%, with at least 200/50 pairs. Ties use `nextafter(score, +inf)` because acceptance is `score >= threshold`. A failed calibration writes the complete curve and exits nonzero without publishing a new threshold. Corpus/model bytes and preprocessing are bound into the catalogue evidence. English calibration does not authorize Estonian enrollment. Neither clean-read calibration nor these parity vectors replace the user's microphone check, spoof resistance, or later field validation.

CI runs `python3 -m unittest discover -s tools/voice-lab -p 'test_*.py'` and `python3 tools/voice-lab/check.py` without NumPy, ONNX, a corpus or network. They check calibration policy and committed asset/score/metadata drift. Swift's real-model parity test runs only when `VOXCLIP_SPEAKER_MODEL_DIR` points to a local directory containing both pinned model files; otherwise it explicitly skips. Local S6 runs both real Python parity and Swift ONNX inference. Do not download models inside tests.
