"""Convert HF CLAP (laion/clap-htsat-fused) to Core ML.

Writes ``ClapAudio.mlpackage`` and ``ClapText.mlpackage`` plus ``model_version.txt``.

Audio tower: log-mel features (16, 1, 1001, 64) (fixed batch; pad the tail) -> L2-normalised 512-d embedding.
Text tower:  input_ids, attention_mask (1, L) -> L2-normalised 512-d embedding.
Projection heads and L2 normalisation are inside the models. Log-mel extraction and
tokenisation stay on the Swift side.

Usage:
    uv run python convert.py [--out ../../Models] [--audio-precision fp16|fp32]
        [--text-precision fp16|fp32] [--audio-batch N]
"""

import argparse
import types
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
import torch.nn.functional as F
import transformers
from huggingface_hub import snapshot_download
from transformers.models.clap import modeling_clap

MODEL_ID = "laion/clap-htsat-fused"
FRAMES = 1001
MELS = 64
MAX_BATCH = 32
FIXED_BATCH = 16
MAX_TEXT_TOKENS = 512


def time_resize_matrix(frames: int = FRAMES, target: int = 1024) -> torch.Tensor:
    """Matrix equal to HF's bicubic time-axis resize (frames -> target).

    ``upsample_bicubic2d`` has no Core ML converter, but the resize is linear, so
    resizing an identity matrix yields the exact operator.
    """
    eye = torch.eye(frames).reshape(1, 1, frames, frames)
    resized = F.interpolate(eye, (target, frames), mode="bicubic", align_corners=True)
    return resized[0, 0]


def patch_resize(model: transformers.ClapModel) -> None:
    """Swap ops the converter cannot handle for exact equivalents."""
    encoder = model.audio_model.audio_encoder
    weights = time_resize_matrix()
    freq_ratio = encoder.freq_ratio

    def reshape_mel2img(self, x: torch.Tensor) -> torch.Tensor:
        x = torch.einsum("ot,bctf->bcof", weights, x)
        batch, channels, time, freq = x.shape
        x = x.reshape(batch, channels * freq_ratio, time // freq_ratio, freq)
        x = x.permute(0, 1, 3, 2).contiguous()
        return x.reshape(batch, channels, freq * freq_ratio, time // freq_ratio)

    encoder.reshape_mel2img = types.MethodType(reshape_mel2img, encoder)
    encoder.avgpool = GlobalMean()
    text = model.text_model
    text.get_extended_attention_mask = types.MethodType(additive_mask, text)
    modeling_clap.window_partition = window_partition
    modeling_clap.window_reverse = window_reverse


def window_partition(x: torch.Tensor, window_size: int) -> torch.Tensor:
    """HF's Swin window partition using rank-5 reshapes (Core ML allows rank <= 5)."""
    batch, height, width, channels = x.shape
    x = x.reshape(batch * (height // window_size), window_size, width // window_size, window_size, channels)
    x = x.permute(0, 2, 1, 3, 4)
    return x.reshape(-1, window_size, window_size, channels)


def window_reverse(windows: torch.Tensor, window_size: int, height: int, width: int) -> torch.Tensor:
    """Inverse of :func:`window_partition`, also with rank <= 5 reshapes."""
    channels = windows.shape[-1]
    x = windows.reshape(-1, width // window_size, window_size, window_size, channels)
    x = x.permute(0, 2, 1, 3, 4)
    return x.reshape(-1, height, width, channels)


def additive_mask(self, attention_mask: torch.Tensor, input_shape, device=None, dtype=None):
    """Attention mask with -1e4 instead of finfo.min, which overflows to -inf in fp16."""
    mask = attention_mask[:, None, None, :].to(torch.float32)
    return (1.0 - mask) * -1e4


class GlobalMean(torch.nn.Module):
    """``AdaptiveAvgPool1d(1)`` as a plain mean; the converter fails on it with a flexible batch."""

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return x.mean(dim=-1, keepdim=True)


class AudioTower(torch.nn.Module):
    """Log-mel features to normalised audio embedding."""

    def __init__(self, model: transformers.ClapModel) -> None:
        super().__init__()
        self.model = model

    def forward(self, input_features: torch.Tensor) -> torch.Tensor:
        # Clips are cropped to the 10 s window, so the fusion branch (is_longer) is never taken.
        is_longer = torch.zeros(input_features.shape[0], 1, dtype=torch.bool)
        features = self.model.get_audio_features(input_features=input_features, is_longer=is_longer)
        return F.normalize(features, dim=-1)


class TextTower(torch.nn.Module):
    """Token ids to normalised text embedding."""

    def __init__(self, model: transformers.ClapModel) -> None:
        super().__init__()
        self.model = model

    def forward(self, input_ids: torch.Tensor, attention_mask: torch.Tensor) -> torch.Tensor:
        text = self.model.get_text_features(input_ids=input_ids, attention_mask=attention_mask)
        return F.normalize(text, dim=-1)


def model_version(snapshot: str, audio_precision: str, text_precision: str) -> str:
    """Version string stored in ``meta.model_version``; bump the suffix on any change."""
    return f"{MODEL_ID}@{snapshot[:8]}-a{audio_precision}-t{text_precision}-v1"


def convert_audio(
    model: transformers.ClapModel, precision: ct.precision, batch_size: int = 0
) -> ct.models.MLModel:
    """Trace and convert the audio tower; ``batch_size`` 0 means a flexible batch."""
    example = torch.randn(2, 1, FRAMES, MELS)
    with torch.no_grad():
        traced = torch.jit.trace(AudioTower(model).eval(), example, strict=False)
    batch = ct.RangeDim(1, MAX_BATCH, default=1) if batch_size == 0 else batch_size
    return ct.convert(
        traced,
        inputs=[ct.TensorType("input_features", shape=ct.Shape((batch, 1, FRAMES, MELS)))],
        outputs=[ct.TensorType("embedding")],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=precision,
        convert_to="mlprogram",
    )


def convert_text(model: transformers.ClapModel, precision: ct.precision) -> ct.models.MLModel:
    """Trace and convert the text tower with a flexible sequence length."""
    ids = torch.randint(3, 1000, (1, 77))
    mask = torch.ones(1, 77, dtype=torch.long)
    with torch.no_grad():
        traced = torch.jit.trace(TextTower(model).eval(), (ids, mask), strict=False)
    length = ct.RangeDim(2, MAX_TEXT_TOKENS, default=77)
    shape = ct.Shape((1, length))
    return ct.convert(
        traced,
        inputs=[
            ct.TensorType("input_ids", shape=shape, dtype=np.int32),
            ct.TensorType("attention_mask", shape=shape, dtype=np.int32),
        ],
        outputs=[ct.TensorType("embedding")],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=precision,
        convert_to="mlprogram",
    )


def main() -> None:
    """Convert both towers and write them with their version string."""
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, default=here.parent.parent / "Models")
    parser.add_argument("--audio-precision", choices=["fp16", "fp32"], default="fp16")
    parser.add_argument("--text-precision", choices=["fp16", "fp32"], default="fp32")
    parser.add_argument(
        "--audio-batch", type=int, default=FIXED_BATCH, help="fixed batch; 0 = flexible (slow, GPU-incompatible)"
    )
    args = parser.parse_args()

    def precision(name: str) -> ct.precision:
        return ct.precision.FLOAT16 if name == "fp16" else ct.precision.FLOAT32

    snapshot = Path(snapshot_download(MODEL_ID)).name
    version = model_version(snapshot, args.audio_precision, args.text_precision)

    model = transformers.ClapModel.from_pretrained(MODEL_ID).eval()
    patch_resize(model)
    args.out.mkdir(parents=True, exist_ok=True)
    towers = {
        "ClapAudio": lambda: convert_audio(model, precision(args.audio_precision), args.audio_batch),
        "ClapText": lambda: convert_text(model, precision(args.text_precision)),
    }
    for name, build in towers.items():
        ml = build()
        ml.short_description = f"{name} tower of {MODEL_ID}, L2-normalised 512-d output"
        ml.user_defined_metadata["model_version"] = version
        ml.save(str(args.out / f"{name}.mlpackage"))
        print(f"saved {name}.mlpackage")
    (args.out / "model_version.txt").write_text(version + "\n")
    print(f"model_version = {version}")


if __name__ == "__main__":
    main()
