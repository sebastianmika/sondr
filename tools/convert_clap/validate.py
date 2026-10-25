"""Check converted Core ML towers against the golden fixtures (PyTorch fp32 reference).

Usage:
    uv run python validate.py [--models ../../Models] [--fixtures ../../Tests/Fixtures]
"""

import argparse
import json
import time
from pathlib import Path

import coremltools as ct
import librosa
import numpy as np
import transformers

SR = 48000
THRESHOLD = 0.998


def load_native_audio(path: Path) -> np.ndarray:
    """Same loading as tools/golden/generate.py: mono, 48 kHz, <=10 s, >=1 s, peak-normalised."""
    audio, _ = librosa.load(path, sr=SR, mono=True, duration=10.0)
    if len(audio) < SR:
        audio = np.pad(audio, (0, SR - len(audio)))
    peak = np.max(np.abs(audio))
    return audio / peak if peak > 0 else audio


def report(label: str, cos: np.ndarray, names: list[str]) -> bool:
    """Print cosine statistics and return True if every item meets the threshold."""
    worst = int(np.argmin(cos))
    ok = bool((cos >= THRESHOLD).all())
    print(
        f"{label}: n={len(cos)} min={cos.min():.5f} mean={cos.mean():.5f} "
        f"worst={names[worst]} below_{THRESHOLD}={int((cos < THRESHOLD).sum())} "
        f"-> {'OK' if ok else 'FAIL'}"
    )
    return ok


def main() -> None:
    """Run parity and speed checks; exit non-zero on failure."""
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--models", type=Path, default=here.parent.parent / "Models")
    parser.add_argument(
        "--fixtures", type=Path, default=here.parent.parent / "Tests" / "Fixtures"
    )
    parser.add_argument(
        "--units", default="ALL", choices=["ALL", "CPU_ONLY", "CPU_AND_GPU", "CPU_AND_NE"]
    )
    args = parser.parse_args()
    units = getattr(ct.ComputeUnit, args.units)

    golden = args.fixtures / "golden"
    manifest = json.loads((golden / "manifest.json").read_text())
    names = [a["name"] for a in manifest["audio"]]
    ref_audio = np.load(golden / "emb_10s.npy")
    processor = transformers.ClapProcessor.from_pretrained("laion/clap-htsat-fused")
    audio_model = ct.models.MLModel(str(args.models / "ClapAudio.mlpackage"), compute_units=units)
    text_model = ct.models.MLModel(str(args.models / "ClapText.mlpackage"), compute_units=units)
    print("version:", audio_model.user_defined_metadata.get("model_version"), "units:", args.units)

    feats = np.concatenate(
        [
            processor(
                audio=[load_native_audio(args.fixtures / "audio" / n)],
                sampling_rate=SR,
                return_tensors="np",
            )["input_features"][:, :1]
            for n in names
        ]
    )
    shape = audio_model.get_spec().description.input[0].type.multiArrayType.shape
    fixed = int(shape[0]) if shape[0] > 0 and len(shape) == 4 else 0
    print(f"audio input shape {list(shape)} -> {'fixed batch ' + str(fixed) if fixed else 'flexible batch'}")

    def run(chunk: np.ndarray) -> np.ndarray:
        """Predict one chunk, padding with zeros up to the fixed batch."""
        n = len(chunk)
        if fixed:
            chunk = np.concatenate([chunk, np.zeros((fixed - n, *chunk.shape[1:]), np.float32)])
        return audio_model.predict({"input_features": chunk})["embedding"][:n]

    step = fixed or 17
    batched = np.concatenate([run(feats[i : i + step]) for i in range(0, len(feats), step)])
    ok = report(f"audio batch={step}", (batched * ref_audio).sum(1), names)
    one = np.concatenate([run(f[None]) for f in feats])
    ok &= report("audio 1+padding", (one * ref_audio).sum(1), names)
    print(f"  padded vs full-batch consistency: min cos {(batched * one).sum(1).min():.5f}")

    sixteen = feats[:16]
    run(sixteen)
    t0 = time.perf_counter()
    for _ in range(5):
        run(sixteen)
    rate = 5 * 16 / (time.perf_counter() - t0)
    print(f"  audio throughput: {rate:.1f} embeddings/s (batch 16)")

    text = json.loads((golden / "text.json").read_text())["queries"]
    ref_text = np.load(golden / "text_embeddings.npy")
    out, latencies = [], []
    for q in text:
        feed = {
            "input_ids": np.array([q["input_ids"]], dtype=np.int32),
            "attention_mask": np.array([q["attention_mask"]], dtype=np.int32),
        }
        t0 = time.perf_counter()
        out.append(text_model.predict(feed)["embedding"][0])
        latencies.append(time.perf_counter() - t0)
    labels = [q["query"][:30] for q in text]
    ok &= report("text          ", (np.stack(out) * ref_text).sum(1), labels)
    short = sorted(latencies[:17])
    print(
        f"  text latency (short queries): median {1000 * short[len(short) // 2]:.0f} ms, "
        f"max {1000 * short[-1]:.0f} ms"
    )
    raise SystemExit(0 if ok else 1)


if __name__ == "__main__":
    main()
