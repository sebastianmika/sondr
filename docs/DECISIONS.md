# Decisions

## Embedding model: `laion/clap-htsat-fused` (2026-10-25)
- `laion/gan-clap-320k-binaural` named in REQUIREMENTS.md does not exist on Hugging Face (API and file URLs return 401, search finds nothing). Owner chose `laion/clap-htsat-fused`.
- Preprocessing config equals the old `clap-htsat-unfused` one (48 kHz, 10 s, 64 mels, 1024 FFT, hop 480, fmin 50, fmax 14 kHz, 512-d output). Only `enable_fusion` and `truncation: fusion` differ, so mel, tokenizer and loader code carry over.
- **Fusion is not used.** For clips of at most 10 s the original LAION model runs without the fusion branch. HF's `ClapFeatureExtractor` marks a lone short clip `is_longer=True` anyway (fusion training quirk), which changes the embedding (cosine 0.71 against the plain path). The audio tower is therefore traced with `is_longer=False` and a **1-channel** input `(16, 1, 1001, 64)`. The golden references are generated the same way (`tools/golden/generate.py`), so "ground truth is HF" means HF with `is_longer` forced to False and channel 0 of the features.
- Conversion needed no new patches beyond the four old ones (bicubic time resize, mean pool, rank-5 Swin windows, -1e4 mask). Audio fp16 batch 16, text fp32.
- Parity (51 audio fixtures, 27 text queries, `validate.py --units CPU_AND_GPU`): audio min cosine 0.99981, mean 1.0001; text min 1.00000. Throughput 385 emb/s at batch 16 on `cpuAndGPU` (old model: 256).
- Model version string: `laion/clap-htsat-fused@365dea6e-afp16-tfp32-v1`.

## Mel filter bank: HTK, not Slaney (2026-10-25)
REQUIREMENTS §5.1 says Slaney scale and norm. That holds for `clap-htsat-unfused` (`truncation: rand_trunc`). With `clap-htsat-fused` (`truncation: fusion`) HF's `ClapFeatureExtractor` uses the `mel_filters` bank (HTK scale, no norm) for clips of at most 10 s. `MelSpectrogram.swift` uses that bank; Slaney gave a 50+ dB mismatch against the golden features. Mel parity is exactly 0.0 dB on the 5 fixtures.
Swift end-to-end embeddings (51 files): min cosine 0.99870 (the 22.05 kHz file, resampler difference), mean 0.99997. Text min 0.9999999.
