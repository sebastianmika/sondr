# CLAP to Core ML

Converts `laion/clap-htsat-fused` into two Core ML programs in `Models/` (gitignored).

```sh
cd tools/convert_clap
uv sync
uv run python convert.py            # writes ../../Models/{ClapAudio,ClapText}.mlpackage + model_version.txt
uv run python validate.py           # parity + speed against Tests/Fixtures (needs Tests/Fixtures from tools/golden)
uv run python validate.py --units CPU_AND_GPU    # also ALL, CPU_ONLY, CPU_AND_NE
```

Pinned to `torch==2.7.0`: the newest version `coremltools` 9.0 has been tested with.
Both towers are traced with `torch.jit.trace` and converted to `mlprogram`, macOS 14+.

| Model | Input | Output | Precision |
|---|---|---|---|
| `ClapAudio` | `input_features` float32 `[16, 1, 1001, 64]` (HF log-mel) | `embedding` `[16, 512]`, L2-normalised | fp16 |
| `ClapText` | `input_ids`, `attention_mask` int32 `[1, 2..512]` | `embedding` `[1, 512]`, L2-normalised | fp32 |

Projection heads and L2 normalisation are inside the models. Log-mel and tokenisation are
Swift-side (Stories 1.2, 1.4). Both models carry `model_version` in their metadata;
`model_version.txt` has the same string. Change the `-v1` suffix in `convert.py` on any change
that alters outputs.

## Patches needed for conversion

All are exact equivalents; parity is checked by `validate.py`.

1. `upsample_bicubic2d` (time axis 1001 -> 1024 in `reshape_mel2img`) has no converter. It is
   linear, so it is replaced by a fixed 1024x1001 matrix obtained by resizing an identity matrix.
2. `AdaptiveAvgPool1d(1)` -> `mean(-1)` (the converter failed on it with a symbolic batch).
3. Swin `window_partition` / `window_reverse` rewritten with rank <= 5 reshapes (Core ML limit).
4. Text attention mask uses `-1e4` instead of `finfo.min`, which overflows to -inf in fp16.

## Things to know

- **Audio batch is fixed at 16.** A flexible batch (`--audio-batch 0`) converts and is correct, but
  ran at 14 emb/s on `ALL` and aborts the process on `CPU_AND_GPU` (Metal "failed to resolve dynamic
  dimensions"). Pad the tail batch with zeros; rows are independent (padded vs full cosine >= 0.9995).
- **Text stays fp32.** fp16 text only worked on some compute units (cosine ~0.6 on `CPU_ONLY`). The
  cost is size (about 480 MB vs 240 MB). It is run once per query, so speed does not matter.
- fp16 audio output norms are 1.0 +- 1e-3. Re-normalise in Swift if exact unit length matters.
- The Neural Engine does not help the audio tower (15 emb/s on `CPU_AND_NE`).
