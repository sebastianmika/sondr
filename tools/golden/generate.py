"""Generate Sondr's golden fixtures.

Writes synthetic audio plus reference values computed by HF CLAP and the legacy
sample_vault code (read from a git tag) into ``Tests/Fixtures``.

Usage:
    uv run python generate.py [--out ../../Tests/Fixtures] [--repo PATH] [--tag TAG]
"""

import argparse
import hashlib
import json
import platform
import shutil
import subprocess
import tempfile
from pathlib import Path

import librosa
import numpy as np
import soundfile as sf
import torch
import transformers
from scipy.io import wavfile
from huggingface_hub import snapshot_download

import legacy
import synth
from tagger_paths import build_paths

MODEL_ID = "laion/clap-htsat-fused"
SR = 48000
WINDOW_S = 10.0
LEGACY_WINDOW_S = 7.0
MEL_SUBSET = [
    "edge_short_0p2s.wav",
    "kick_long_tail.wav",
    "sine_440.wav",
    "loop_drums_120.wav",
    "snare_basic.wav",
]
DECODE_SUBSET = [
    "sr44100_sine.wav",
    "sr22050_pad.wav",
    "sr96000_hat.wav",
    "stereo_44100_loop.flac",
    "loop_drums_90_stereo.wav",
    "bits24_kick.wav",
    "float32_snare.wav",
    "pluck.aif",
    "bass.caf",
    "lead.mp3",
    "pad.mp3",
    "pluck.m4a",
    "loop_12s.flac",
]
TEXT_QUERIES = [
    "kick",
    "punchy 808 kick drum",
    "snare with long reverb tail",
    "Hi-Hat closed",
    "warm analog pad",
    "",
    "   ",
    "UPPERCASE QUERY",
    "dark ambient texture, evolving; slow!",
    "808 bass — sub",
    "café ambience",
    "crowd cheering \U0001f389",
    "a",
    "vinyl crackle noise",
    "riser / sweep (white noise)",
    "distorted lead synth 140bpm",
    "female vocal chop 'ah'",
    "a very long and rambling description of a sound that goes on " * 3,
    "kick " * 400,
    "snare " * 700,
    "<s> literal </s> markers",
    "I'm sure they'll say it's 100% fine, won't they?",
    "  leading and   internal   spaces  ",
    "tab\tand\nnewline",
    "fill <mask> here and  <mask>there",
    "<pad><unk> odd",
    "snare, clap, hat; kick: bass? pad! lead... fx - vox (chop) [loop] {riser}",
]
FFMPEG_ARGS = ["-codec:a", "libmp3lame", "-b:a", "128k", "-bitexact", "-map_metadata", "-1"]


def write_audio(spec: synth.Spec, out_dir: Path) -> Path:
    """Synthesise ``spec`` and store it in its target format."""
    data = np.clip(spec.build(synth.rng_for(spec.name), spec.sr), -1.0, 1.0)
    path = out_dir / spec.name
    if spec.subtype == "FLOAT":
        # libsndfile stamps a PEAK chunk with the current time; wavfile does not.
        wavfile.write(path, spec.sr, data.astype(np.float32))
        return path
    if spec.fmt in ("wav", "flac", "aiff"):
        sf.write(path, data, spec.sr, format=spec.fmt.upper(), subtype=spec.subtype)
        return path
    with tempfile.TemporaryDirectory() as tmp:
        wav = Path(tmp) / "src.wav"
        sf.write(wav, data, spec.sr, subtype="PCM_16")
        if spec.fmt == "mp3":
            cmd = ["ffmpeg", "-y", "-loglevel", "error", "-i", str(wav), *FFMPEG_ARGS, str(path)]
        elif spec.fmt == "caf":
            cmd = ["afconvert", "-f", "caff", "-d", "LEI16", str(wav), str(path)]
        elif spec.fmt == "m4a":
            cmd = [
                "ffmpeg", "-y", "-loglevel", "error", "-i", str(wav), "-codec:a", "aac",
                "-b:a", "128k", "-fflags", "+bitexact", "-flags:a", "+bitexact",
                "-map_metadata", "-1", str(path),
            ]
        else:
            raise ValueError(f"unknown format {spec.fmt}")
        subprocess.run(cmd, check=True)
    return path


def write_corrupt(out_dir: Path) -> list[str]:
    """Write files that must fail to decode. Returns their names."""
    out_dir.mkdir(parents=True, exist_ok=True)
    good = out_dir.parent / "kick_short.wav"
    (out_dir / "truncated_header.wav").write_bytes(good.read_bytes()[:20])
    (out_dir / "not_audio.wav").write_bytes(b"this is not audio\n" * 20)
    (out_dir / "empty.wav").write_bytes(b"")
    return ["truncated_header.wav", "not_audio.wav", "empty.wav"]


def load_legacy_audio(path: Path, normalize_audio) -> np.ndarray:
    """Audio exactly as the legacy app fed it to CLAP (7 s cap)."""
    return normalize_audio(str(path))


def load_native_audio(path: Path) -> np.ndarray:
    """Audio as Sondr feeds CLAP: mono, 48 kHz, <=10 s, >=1 s, peak-normalised."""
    audio, _ = librosa.load(path, sr=SR, mono=True, duration=WINDOW_S)
    if len(audio) < SR:
        audio = np.pad(audio, (0, SR - len(audio)))
    peak = np.max(np.abs(audio))
    return audio / peak if peak > 0 else audio


def unit(vec: np.ndarray) -> np.ndarray:
    """L2-normalise as the legacy embedder does."""
    norm = np.linalg.norm(vec)
    return (vec / norm if norm > 0 else vec).astype(np.float32)


def pooled(output) -> np.ndarray:
    """Pooled embedding from a tensor or ModelOutput."""
    tensor = output.pooler_output if hasattr(output, "pooler_output") else output
    return tensor.cpu().numpy()


def sha256(path: Path) -> str:
    """Hex SHA-256 of a file."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    """Run all generation steps."""
    here = Path(__file__).resolve().parent
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=here.parent.parent / "Tests" / "Fixtures")
    ap.add_argument("--repo", type=Path, default=legacy.DEFAULT_REPO)
    ap.add_argument("--tag", default=legacy.DEFAULT_TAG)
    args = ap.parse_args()

    torch.manual_seed(0)
    torch.set_num_threads(1)
    out: Path = args.out
    if out.exists():
        shutil.rmtree(out)
    audio_dir = out / "audio"
    golden_dir = out / "golden"
    audio_dir.mkdir(parents=True)
    golden_dir.mkdir()

    pkg = legacy.export_tag(args.repo, args.tag)
    audio_utils = legacy.load_module(pkg, "audio_utils")
    features = legacy.load_module(pkg, "features")
    tagger = legacy.load_module(pkg, "tagger")
    shutil.copy(pkg / "data" / "aliases.json", golden_dir / "legacy_aliases.json")
    shutil.copy(pkg / "data" / "stopwords.json", golden_dir / "legacy_stopwords.json")

    snap = Path(snapshot_download(MODEL_ID))
    shutil.copy(snap / "preprocessor_config.json", golden_dir / "preprocessor_config.json")
    processor = transformers.ClapProcessor.from_pretrained(MODEL_ID)
    model = transformers.ClapModel.from_pretrained(MODEL_ID).eval().to("cpu")

    def embed_audio(audio: np.ndarray) -> np.ndarray:
        assert len(audio) <= SR * WINDOW_S, "rand_trunc would be random"
        inputs = processor(audio=[audio], sampling_rate=SR, return_tensors="pt")
        # HF flips is_longer to True for a lone short clip (fusion training quirk); the model's
        # real behaviour for <= 10 s is no fusion, and the Core ML tower is 1-channel.
        inputs["is_longer"] = torch.zeros_like(inputs["is_longer"])
        inputs["input_features"] = inputs["input_features"][:, :1]
        with torch.no_grad():
            return unit(pooled(model.get_audio_features(**inputs))[0])

    entries: list[dict] = []
    emb7: list[np.ndarray] = []
    emb10: list[np.ndarray] = []
    mel: dict[str, np.ndarray] = {}
    decoded: dict[str, np.ndarray] = {}
    for spec in synth.specs():
        path = write_audio(spec, audio_dir)
        info = sf.info(path) if spec.fmt != "m4a" else None
        a7 = load_legacy_audio(path, audio_utils.normalize_audio)
        a10 = load_native_audio(path)
        emb7.append(embed_audio(a7))
        emb10.append(embed_audio(a10))
        if spec.name in DECODE_SUBSET:
            decoded[spec.name] = a10.astype(np.float32)
        if spec.name in MEL_SUBSET:
            feats = processor(audio=[a10], sampling_rate=SR, return_tensors="pt")
            mel[f"{spec.name}__audio"] = a10.astype(np.float32)
            mel[f"{spec.name}__features"] = feats["input_features"][:, :1].numpy()
        src_sr = info.samplerate if info else spec.sr
        entries.append(
            {
                "name": spec.name,
                "format": spec.fmt,
                "source_sr": src_sr,
                "channels": info.channels if info else 1,
                "frames": info.frames if info else None,
                "note": spec.note,
                "lossy": spec.fmt in ("mp3", "m4a"),
                "dims_7s": features.compute_raw_dims(a7, SR, len(a7) / SR),
                "dims_10s": features.compute_raw_dims(a10, SR, len(a10) / SR),
                "samples_7s": len(a7),
                "samples_10s": len(a10),
            }
        )

    corrupt = write_corrupt(audio_dir / "corrupt")

    # Plain .npy (no zip) so Swift tests can read them with a tiny parser.
    np.save(golden_dir / "emb_7s.npy", np.stack(emb7))
    np.save(golden_dir / "emb_10s.npy", np.stack(emb10))
    (golden_dir / "mel").mkdir()
    for key, array in mel.items():
        name, kind = key.split("__")
        np.save(golden_dir / "mel" / f"{name}.{kind}.npy", array)
    (golden_dir / "decoded").mkdir()
    for name, array in decoded.items():
        np.save(golden_dir / "decoded" / f"{name}.npy", array)
    fe = processor.feature_extractor
    np.save(golden_dir / "mel_filters_slaney.npy", np.asarray(fe.mel_filters_slaney, np.float64))

    tok = processor.tokenizer
    text_emb, text_rows = [], []
    for q in TEXT_QUERIES:
        enc = tok(q, truncation=True)
        inputs = processor(text=[q], return_tensors="pt", truncation=True)
        with torch.no_grad():
            text_emb.append(unit(pooled(model.get_text_features(**inputs))[0]))
        text_rows.append({"query": q, "input_ids": enc["input_ids"], "attention_mask": enc["attention_mask"]})
    np.save(golden_dir / "text_embeddings.npy", np.stack(text_emb))
    (golden_dir / "text.json").write_text(
        json.dumps({"model_max_length": tok.model_max_length, "queries": text_rows}, indent=1, ensure_ascii=False)
    )

    paths = build_paths()
    tag_rows = [{"path": p, "tags": sorted(tagger.extract_tags(p))} for p in paths]
    (golden_dir / "tagger.json").write_text(json.dumps(tag_rows, indent=1, ensure_ascii=False))

    legacy_commit = subprocess.run(
        ["git", "-C", str(args.repo), "rev-parse", args.tag], capture_output=True, text=True, check=True
    ).stdout.strip()
    manifest = {
        "generator": {
            "python": platform.python_version(),
            "numpy": np.__version__,
            "librosa": librosa.__version__,
            "torch": torch.__version__,
            "transformers": transformers.__version__,
            "model": MODEL_ID,
            "model_snapshot": snap.name,
            "legacy_tag": args.tag,
            "legacy_commit": legacy_commit,
            "native_window_s": WINDOW_S,
            "legacy_window_s": LEGACY_WINDOW_S,
            "sample_rate": SR,
        },
        "audio": entries,
        "corrupt": corrupt,
        "mel_subset": MEL_SUBSET,
        "decoded_subset": DECODE_SUBSET,
    }
    (golden_dir / "manifest.json").write_text(json.dumps(manifest, indent=1))

    sums = sorted(
        f"{sha256(p)}  {p.relative_to(out)}" for p in out.rglob("*") if p.is_file() and p.suffix != ".txt"
    )
    (out / "CHECKSUMS.txt").write_text("\n".join(sums) + "\n")
    total = sum(p.stat().st_size for p in out.rglob("*") if p.is_file())
    print(f"wrote {len(entries)} audio files, {len(text_rows)} queries, {len(tag_rows)} paths")
    print(f"fixtures: {total / 1e6:.1f} MB in {out}")


if __name__ == "__main__":
    main()
