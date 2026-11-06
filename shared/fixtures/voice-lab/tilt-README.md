# Voice Lab tone-match vectors

`tilt-cases.json` (`voxclip-voice-lab-tilt/1`) pins the tone match of voice-lab.md §8.7 item 2b: a generated take is tilted towards the spectral slope of the original speech beside it. Regenerate it only with `python3 tools/fixtures/voice-lab/generate_tilt.py` (pure Python, no NumPy) and review the diff as a behaviour change. `check_drift.py` compares it within its float tolerance, because the coefficients and the FFT twiddles use libm. The Mac suite `apps/macos/Tests/VoxClipCoreTests/VoiceLab/VoiceLabTiltReplayTests.swift` and the Windows suite `apps/windows/tests/VoxClip.Core.Tests/Tracks/voice-lab/VoiceLabTiltReplayTests.cs` replay every case within the tolerances and fail on an unknown kind.

## Signals

Signals are parameters, never samples: `{seed, samples, shape, shift, quiet}`. The base is the 32-bit LCG `x(n+1) = (1664525 × x(n) + 1013904223) mod 2^32` from `x(0) = seed`. Sample `n` is `(x(n+1) >> 16) / 2^15 − 1`, times `2^−shift`. Three extra leading samples feed the shapes:

- `white` is the base itself;
- `bright` is `(x[n] − x[n−1]) / 2`;
- `warm` is `(x[n] + x[n−1] / 2) / 2`;
- `dark` is the mean of four consecutive samples.

`quiet` ranges `[start, end)` are scaled by `2^−12`, below the voiced floor. Every sample is exact in binary32, so every platform reads the same input.

## Rules the vectors pin

- **Frames.** The frame size is the smallest power of two at least 40 ms long (`frameSize`). Frames are periodic-Hann windowed, start every half frame from each side's first sample, and are whole frames only. A frame counts when its RMS, before the window, is above −45 dBFS.
- **Bands.** There are twenty one-third-octave bands, centred at `1000 × 2^(b/3)` Hz for `b = −10…9` (100 Hz to 7.94 kHz). Band `b` takes bins `k` in 1…N/2−1 with `fc × 2^(−1/6) ≤ k × rate / N < fc × 2^(1/6)`. A band whose upper edge passes Nyquist is absent (null). The FFT is iterative radix-2 with bit-reversed input. Its twiddle for stage `m`, offset `j` is `cos(−2πj/m) + i sin(−2πj/m)`.
- **Levels and slope.** A band's level is `10 × log10(power / (bins × frames))`. The slope is the least-squares fit of the levels against `b / 3`, over the bands present in both measurements. It needs at least four bands.
- **Match.** The tilt is the source slope minus the take slope, clamped to ±2 dB/octave, then rounded to 0.1 half away from zero. A result of 0 is no tilt (null).
- **Neighbourhood.** The source sides are those of the level match: up to `round_half_up(3 × rate)` samples before and after the window, each clamped to the take. Each side is framed on its own grid, and the window itself is excluded.
- **Cascade.** There is one bilinear first-order high shelf at each of 250 Hz, 1 kHz and 4 kHz below 0.45 × rate, prewarped at its frequency. Each has gain `A = 10^(2t/20)` and `K = tan(π f / rate)`:
  - `b0 = A(1 + K/√A)/(1 + K√A)`;
  - `b1 = A(K/√A − 1)/(1 + K√A)`;
  - `a1 = (K√A − 1)/(1 + K√A)`.

  The first section's `b0` and `b1` are divided by the cascade's magnitude at 1 kHz, so the pivot is 0 dB. A tilt beyond ±2 is clamped, and 0 or non-finite gives no sections.
- **Filter.** `y[n] = b0 x[n] + b1 x[n−1] − a1 y[n−1]` per section, in cascade, in binary64, from zero state at the first sample. The vectors hold the binary64 outputs; the renderer rounds each one to binary32 once.

## Case kinds

| `kind` | Input | `expected` |
|---|---|---|
| `frameSize` | `sampleRate` | `frameSize`, `bins` per band (`[first, end)` or null) |
| `sections` | `tiltDbPerOctave`, `sampleRate` | `sections` `[[b0, b1, a1]]`, `magnitudeDb` `[[hz, dB]]` below Nyquist |
| `filter` | `tiltDbPerOctave`, `sampleRate`, `input.impulse` or `input.signal` | `output` (binary64) |
| `bands` | `sampleRate`, `input.signal` | `frames`, `levelsDb` per band, `slopeDbPerOctave` over its own bands |
| `match` | `source`, `take` (names of `bands` cases) | `tiltDbPerOctave` (null for none), `sourceSlope`, `takeSlope` |
| `neighbourhood` | `sampleRate`, `input.signal`, `input.window` | `frames`, `levelsDb` |

`tolerances` gives the bounds: 1e-12 for coefficients and outputs, and 1e-9 for dB levels, magnitudes and slopes. Frame counts, bins and tilts must match exactly. No case lies within 0.01 of a rounding half-step.
