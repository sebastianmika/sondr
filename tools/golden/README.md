# Golden fixtures

Reference data that Sondr's Swift code is tested against. Ground truth is
HF `laion/clap-htsat-fused` (PyTorch, CPU, fp32) and the legacy `sample_vault`
code at git tag `legacy-python-v0.2`.

## Regenerate

```sh
cd tools/golden
uv sync
uv run python generate.py          # writes ../../Tests/Fixtures (deleted first)
```

Needs `ffmpeg` (mp3, m4a) and `afconvert` (caf), the legacy repo at
`~/repos/sample_vault` (override: `SAMPLE_VAULT_LEGACY` or `--repo`), and the CLAP
weights (downloaded from Hugging Face on first run). Output is byte-identical
across runs; `Tests/Fixtures/CHECKSUMS.txt` lists the SHA-256 of every file.

Generated with: Python 3.12.14, numpy 2.5.4, librosa 0.11.0, torch 2.14.1,
transformers 4.57.6, model snapshot `8fa0f1c6`, legacy commit `b954ce7`.
`golden/manifest.json` records the same.

## Contents (`Tests/Fixtures`)

| Path | What |
|---|---|
| `audio/` | 51 synthetic files (no copyrighted audio): drums, tones, pads, noise, loops, edge cases (silence, DC, clipping, < 1 s, > 10 s), sample rates 22.05k-96k, mono/stereo, wav/aif/flac/mp3/caf/m4a. |
| `audio/corrupt/` | 3 files that must fail to decode. |
| `golden/manifest.json` | Per file: format, source rate, raw dims on the 7 s and the 10 s audio. |
| `golden/emb_7s.npy`, `emb_10s.npy` | Legacy-pipeline (7 s) and native-window (10 s) embeddings, 51x512 float32, L2-normalised, row order = manifest order. |
| `golden/mel/<name>.audio.npy`, `<name>.features.npy` | For 5 files: the 10 s-window audio fed in (float32) and the HF log-mel (1x1x1001x64). |
| `golden/decoded/<name>.npy` | For 13 files (other sample rates, stereo, 24-bit, float, aif/caf/mp3/m4a, > 10 s): librosa's decoded, resampled, peak-normalised audio as fed to CLAP (<= 480000 samples). Reference for `AudioLoader`. |
| `golden/mel_filters_slaney.npy` | The 513x64 float64 filter bank the extractor uses (Slaney scale and norm; the config's HTK bank is only for fusion). |
| `golden/text.json`, `text_embeddings.npy` | 20 queries with token ids, attention masks, embeddings. |
| `golden/tagger.json` | 200 paths with the legacy tagger's tag sets. |
| `golden/preprocessor_config.json` | Copy of the HF feature extractor config. |
| `golden/legacy_{aliases,stopwords}.json` | Verbatim legacy data. Copy to `Resources/` in Story 2.3. |

## Things to know when writing tests

- **Window is 10 s, not 7 s.** The legacy code truncated to 7 s, the model's
  extractor uses 10 s (480000 samples, hop 480, 64 mels, 50-14000 Hz, n_fft 1024).
  Both embedding sets are provided; `loop_*.flac` and `pad_9p5s.flac` differ
  between them (cosine 0.93-0.95), everything <= 7 s is identical.
- **Padding is `repeatpad`**, not zero padding: the extractor repeats short audio
  to fill 10 s. `edge_short_0p2s.wav` and `kick_long_tail.wav` exercise this.
- **`truncation="rand_trunc"` is random for audio > 10 s.** The generator crops to
  10 s itself (`librosa.load(duration=10)`) and asserts that nothing longer reaches
  the extractor. Swift must crop the same way.
- **Decoder differences.** References come from librosa (soxr_hq resampling,
  audioread for m4a/caf). AVFoundation will differ slightly for non-48 kHz and lossy
  files (`lossy: true`, `source_sr` in the manifest); use looser tolerances there.
  For exact mel parity use the stored `__audio` arrays, not a decode.
- **Text** uses `truncation=True` (tokenizer `model_max_length` = 512). The legacy
  code did not truncate and would have failed on the 400-word query.
- **Tagger fixtures encode legacy behaviour including its quirks**
  (`clp-wide` kept as one tag, `file.v` from `file.v1.2`, "Basses" -> "bass").
  Review disagreements per Story 2.3, do not blindly match.
- The three lossy fixtures (`lead.mp3`, `pad.mp3`, `pluck.m4a`) carry a -60 dB noise floor on purpose; without
  one, decoder differences below one 16-bit step change their embeddings by a few percent (docs/DECISIONS.md).
- `edge_silence.wav` has a valid, finite embedding (CLAP of digital silence).
