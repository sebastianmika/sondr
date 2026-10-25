"""Deterministic synthetic audio for the golden fixtures.

Every sound is built from a seeded RNG, so regenerating gives identical samples.
No copyrighted audio is used.
"""

import zlib
from collections.abc import Callable
from dataclasses import dataclass

import numpy as np
from scipy import signal

SR = 48000

Builder = Callable[[np.random.Generator, int], np.ndarray]


@dataclass(frozen=True)
class Spec:
    """One fixture file: how to synthesise it and how to store it."""

    name: str
    build: Builder
    sr: int = SR
    fmt: str = "wav"
    subtype: str = "PCM_16"
    note: str = ""


def rng_for(name: str) -> np.random.Generator:
    """Return an RNG seeded from the file name."""
    return np.random.default_rng(zlib.crc32(name.encode()))


def _t(seconds: float, sr: int) -> np.ndarray:
    return np.arange(int(round(seconds * sr))) / sr


def _decay(t: np.ndarray, tau: float) -> np.ndarray:
    return np.exp(-t / tau)


def _norm(x: np.ndarray, peak: float = 0.9) -> np.ndarray:
    m = float(np.max(np.abs(x)))
    return x if m == 0 else x * (peak / m)


def _highpass(x: np.ndarray, sr: int, hz: float) -> np.ndarray:
    sos = signal.butter(4, hz, btype="high", fs=sr, output="sos")
    return signal.sosfilt(sos, x)


def _lowpass(x: np.ndarray, sr: int, hz: float) -> np.ndarray:
    sos = signal.butter(4, hz, btype="low", fs=sr, output="sos")
    return signal.sosfilt(sos, x)


def kick(dur: float, tau: float = 0.12):
    """Sine sweep from 150 Hz down to 45 Hz with exponential decay."""

    def build(rng: np.random.Generator, sr: int) -> np.ndarray:
        t = _t(dur, sr)
        freq = 45 + 105 * np.exp(-t / 0.03)
        phase = 2 * np.pi * np.cumsum(freq) / sr
        return _norm(np.sin(phase) * _decay(t, tau))

    return build


def snare(dur: float):
    """Noise burst plus a 190 Hz tone."""

    def build(rng: np.random.Generator, sr: int) -> np.ndarray:
        t = _t(dur, sr)
        noise = _highpass(rng.standard_normal(t.size), sr, 1500) * _decay(t, 0.08)
        tone = np.sin(2 * np.pi * 190 * t) * _decay(t, 0.05)
        return _norm(0.7 * noise + 0.5 * tone)

    return build


def hat(dur: float, tau: float):
    """High-passed noise with a short decay."""

    def build(rng: np.random.Generator, sr: int) -> np.ndarray:
        t = _t(dur, sr)
        return _norm(_highpass(rng.standard_normal(t.size), sr, 6000) * _decay(t, tau))

    return build


def sine(freq: float, dur: float, amp: float = 0.8):
    """Plain sine tone with a 5 ms fade in and out."""

    def build(rng: np.random.Generator, sr: int) -> np.ndarray:
        t = _t(dur, sr)
        fade = np.minimum(1, np.minimum(t, dur - t) / 0.005)
        return amp * np.sin(2 * np.pi * freq * t) * fade

    return build


def chord(freqs: tuple[float, ...], dur: float, attack: float):
    """Sum of sines with a slow attack and release."""

    def build(rng: np.random.Generator, sr: int) -> np.ndarray:
        t = _t(dur, sr)
        env = np.minimum(1, t / attack) * np.minimum(1, (dur - t) / 0.3)
        x = sum(np.sin(2 * np.pi * f * t + rng.uniform(0, 6.28)) for f in freqs)
        return _norm(x * env)

    return build


def saw(freq: float, dur: float):
    """Band-limited sawtooth built from 20 harmonics."""

    def build(rng: np.random.Generator, sr: int) -> np.ndarray:
        t = _t(dur, sr)
        x = sum(np.sin(2 * np.pi * freq * k * t) / k for k in range(1, 21))
        return _norm(x * _decay(t, 0.8) * np.minimum(1, t / 0.01))

    return build


def noise(dur: float, pink: bool = False, amp: float = 0.7):
    """White noise, optionally tilted towards pink with a low-pass."""

    def build(rng: np.random.Generator, sr: int) -> np.ndarray:
        x = rng.standard_normal(int(dur * sr))
        if pink:
            x = _lowpass(x, sr, 3000)
        return _norm(x, amp)

    return build


def riser(dur: float, rising: bool = True):
    """Band-pass swept noise whose level rises (or falls) over time."""

    def build(rng: np.random.Generator, sr: int) -> np.ndarray:
        t = _t(dur, sr)
        x = _highpass(rng.standard_normal(t.size), sr, 400)
        env = (t / dur) ** 2 if rising else (1 - t / dur) ** 2
        chirp = signal.chirp(t, 200, dur, 4000 if rising else 100)
        return _norm((0.6 * x + 0.4 * chirp) * env)

    return build


def click_train(dur: float, rate_hz: float):
    """Single-sample clicks at a fixed rate."""

    def build(rng: np.random.Generator, sr: int) -> np.ndarray:
        x = np.zeros(int(dur * sr))
        x[:: int(sr / rate_hz)] = 0.9
        return x

    return build


def crackle(dur: float):
    """Sparse random impulses, like vinyl crackle."""

    def build(rng: np.random.Generator, sr: int) -> np.ndarray:
        n = int(dur * sr)
        x = np.zeros(n)
        idx = rng.integers(0, n, size=int(dur * 40))
        x[idx] = rng.uniform(-1, 1, size=idx.size)
        return _norm(x)

    return build


def formant_voice(dur: float, f0: float):
    """Harmonic source shaped by two vowel-like resonances."""

    def build(rng: np.random.Generator, sr: int) -> np.ndarray:
        t = _t(dur, sr)
        src = sum(np.sin(2 * np.pi * f0 * k * t) / k for k in range(1, 40))
        out = np.zeros_like(src)
        for centre in (700, 1200):
            sos = signal.butter(2, [centre - 150, centre + 150], "band", fs=sr, output="sos")
            out += signal.sosfilt(sos, src)
        return _norm(out * np.minimum(1, t / 0.05) * np.minimum(1, (dur - t) / 0.1))

    return build


def arpeggio(dur: float, notes: tuple[float, ...]):
    """Plucked notes played one after another."""

    def build(rng: np.random.Generator, sr: int) -> np.ndarray:
        out = np.zeros(int(dur * sr))
        step = int(dur * sr / (len(notes) * 2))
        for i in range(len(notes) * 2):
            f = notes[i % len(notes)]
            seg = _t(0.4, sr)
            note = np.sin(2 * np.pi * f * seg) * _decay(seg, 0.1)
            end = min(out.size, i * step + note.size)
            out[i * step : end] += note[: end - i * step]
        return _norm(out)

    return build


def drum_loop(bpm: float, bars: int, stereo: bool = False):
    """Kick, snare and hat pattern, optionally panned into stereo."""

    def build(rng: np.random.Generator, sr: int) -> np.ndarray:
        beat = 60 / bpm
        n = int(bars * 4 * beat * sr)
        out = np.zeros(n)
        parts = {
            "k": kick(0.3)(rng, sr),
            "s": snare(0.25)(rng, sr),
            "h": hat(0.08, 0.02)(rng, sr),
        }
        for step in range(bars * 8):
            pos = int(step * beat / 2 * sr)
            hits = ["h"] + (["k"] if step % 4 == 0 else []) + (["s"] if step % 4 == 2 else [])
            for h in hits:
                end = min(n, pos + parts[h].size)
                out[pos:end] += parts[h][: end - pos]
        out = _norm(out)
        if stereo:
            return np.stack([out, np.roll(out, 24) * 0.8], axis=1)
        return out

    return build


def long_loop(dur: float):
    """Tonal bed plus a pulsing kick, used for files over the 10 s window."""

    def build(rng: np.random.Generator, sr: int) -> np.ndarray:
        t = _t(dur, sr)
        bed = chord((110, 165, 220, 277), dur, 1.0)(rng, sr)
        pulse = np.zeros_like(t)
        k = kick(0.25)(rng, sr)
        for i in range(int(dur * 2)):
            pos = int(i * 0.5 * sr)
            end = min(t.size, pos + k.size)
            pulse[pos:end] += k[: end - pos]
        return _norm(0.5 * bed + 0.6 * pulse)

    return build


def constant(value: float, dur: float):
    """A constant signal; value 0 gives digital silence."""

    def build(rng: np.random.Generator, sr: int) -> np.ndarray:
        return np.full(int(dur * sr), value)

    return build


def scaled(inner: Builder, factor: float) -> Builder:
    """Scale another builder's output, e.g. for near-silent files."""

    def build(rng: np.random.Generator, sr: int) -> np.ndarray:
        return inner(rng, sr) * factor

    return build


def with_dc(inner: Builder, offset: float) -> Builder:
    """Add a DC offset to another builder's output."""

    def build(rng: np.random.Generator, sr: int) -> np.ndarray:
        return inner(rng, sr) * 0.5 + offset

    return build


def noisy(inner: Builder, level: float = 1e-3) -> Builder:
    """Add a white noise floor (default -60 dB).

    Band-limited synthetic tones leave most mel bins empty, so decoders that differ below
    one 16-bit step (AVFoundation vs libsndfile vs int16 paths) would move the embedding by a
    few percent. Real recordings always have a noise floor above that.
    """

    def build(rng: np.random.Generator, sr: int) -> np.ndarray:
        x = inner(rng, sr)
        return x + level * rng.standard_normal(x.shape)

    return build


def squared(freq: float, dur: float):
    """Full-scale square wave."""

    def build(rng: np.random.Generator, sr: int) -> np.ndarray:
        return np.sign(np.sin(2 * np.pi * freq * _t(dur, sr)) + 1e-12)

    return build


def specs() -> list[Spec]:
    """Return the full fixture list. Order is stable and part of the contract."""
    s = Spec
    return [
        s("kick_short.wav", kick(0.35)),
        s("kick_long_tail.wav", kick(1.2, tau=0.4)),
        s("snare_basic.wav", snare(0.4)),
        s("hat_closed_tiny.wav", hat(0.12, 0.015)),
        s("hat_open.wav", hat(0.6, 0.15)),
        s("rim_click.wav", click_train(0.05, 400)),
        s("tom_mid.wav", kick(0.5, tau=0.2)),
        s("sine_100.wav", sine(100, 1.0)),
        s("sine_220.wav", sine(220, 2.0)),
        s("sine_440.wav", sine(440, 2.0)),
        s("sine_1000.wav", sine(1000, 2.0)),
        s("sine_4000.wav", sine(4000, 2.0)),
        s("sine_10000.wav", sine(10000, 2.0)),
        s("pad_slow_attack.wav", chord((130.8, 164.8, 196.0, 246.9), 6.0, 1.5)),
        s("pad_9p5s.flac", chord((98.0, 123.5, 146.8), 9.5, 2.0), fmt="flac"),
        s("lead_saw.wav", saw(330, 1.5)),
        s("bass_sub.wav", sine(55, 1.5, 0.9)),
        s("pluck.aif", arpeggio(1.0, (392.0,)), fmt="aiff"),
        s("arpeggio.wav", arpeggio(3.0, (261.6, 329.6, 392.0, 523.3))),
        s("noise_white_1s.wav", noise(1.0)),
        s("noise_pink_2s.wav", noise(2.0, pink=True)),
        s("fx_riser.wav", riser(4.0)),
        s("fx_downlifter.wav", riser(3.0, rising=False)),
        s("fx_impact.wav", kick(2.5, tau=0.9)),
        s("click_train.wav", click_train(2.0, 8)),
        s("vocal_formant.wav", formant_voice(1.2, 140)),
        s("crackle.wav", crackle(2.0)),
        s("loop_drums_120.wav", drum_loop(120, 2)),
        s("loop_drums_90_stereo.wav", drum_loop(90, 2, stereo=True)),
        s("loop_7s.flac", long_loop(7.0), fmt="flac"),
        s("loop_10s.flac", long_loop(10.0), fmt="flac"),
        s("loop_12s.flac", long_loop(12.0), fmt="flac", note="longer than window"),
        s("loop_15s.flac", long_loop(15.0), fmt="flac", note="longer than window"),
        s("edge_silence.wav", constant(0.0, 1.0), note="peak is zero"),
        s("edge_near_silence.wav", scaled(noise(1.0), 1e-4)),
        s("edge_dc_offset.wav", with_dc(noise(1.0), 0.3)),
        s("edge_square_clip.wav", squared(200, 1.0)),
        s("edge_very_short.wav", sine(1000, 0.01), note="below 1 s minimum"),
        s("edge_short_0p2s.wav", sine(800, 0.2)),
        s("sr44100_sine.wav", sine(440, 1.5), sr=44100),
        s("sr44100_kick.wav", kick(0.4), sr=44100),
        s("sr22050_pad.wav", chord((196.0, 246.9), 2.0, 0.5), sr=22050),
        s("sr96000_hat.wav", hat(0.3, 0.05), sr=96000),
        s("bits24_kick.wav", kick(0.4), subtype="PCM_24"),
        s("float32_snare.wav", snare(0.4), subtype="FLOAT"),
        s("stereo_44100_loop.flac", drum_loop(100, 1, stereo=True), sr=44100, fmt="flac"),
        s("snare.aiff", snare(0.4), fmt="aiff"),
        s("lead.mp3", noisy(saw(262, 1.5)), fmt="mp3", note="lossy"),
        s("pad.mp3", noisy(chord((130.8, 196.0), 2.5, 0.5)), sr=44100, fmt="mp3", note="lossy"),
        s("bass.caf", sine(65, 1.2, 0.9), fmt="caf"),
        s("pluck.m4a", noisy(arpeggio(1.5, (440.0, 660.0))), fmt="m4a", note="lossy"),
    ]
