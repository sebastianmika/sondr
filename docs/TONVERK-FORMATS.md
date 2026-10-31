# Tonverk sample formats

A developer reference for writing Elektron Tonverk multisample (`.elmulti`), drum/Subtracks (`.eldrum`) and preset (`.tvpst`) files, plus the SFZ route.

**Status.** Elektron has published no spec for these formats. This document rests on three kinds of evidence:

- **[L]** a survey of the Tonverk **factory library** on a device card: 110 `.elmulti`, 81 `.eldrum`, 175 `.tvpst` and 5,102 distinct WAVs, parsed with scripts, with counts given where they matter. This is the strongest evidence, but it shows what the device *ships*, not what it *accepts*.
- **[S]** asatamax's reverse-engineered spec ([ELMULTI_FORMAT_SPEC.md v1.4][spec]). It quotes the manual's Appendix E, "SFZ Support".
- **[C]** the ConvertWithMoss Tonverk reader and writer ([TonverkMultiFile.java][cwm-file], [TonverkMultiCreator.java][cwm-creator], [CHANGELOG][cwm-log]). Its fixes record what the device rejected on a real unit.

Also **[F]** forum report and **[I]** inference. Nothing was tested by loading files onto a device.

## 1. File types and library layout

| File | What it is |
|---|---|
| `.elmulti` | Pitched multisample for the Multi machine. TOML-like text mapping plus WAVs |
| `.eldrum` | Drum set (Subtracks/Drum machine). Same schema, different header comment |
| `.tvpst` | Full sound preset: engine parameters plus an embedded copy of the mapping (§7) |
| `.sfz` | Alternative import route. The only documented way to get random selection (§3) |
| `.wav` | Audio (§4) |

There is no separate "subtrack" file. A Subtracks/Drum sound is an `.eldrum` or a `.tvpst` using the drum engine [L][I].

Factory tree [L]:

```
Tonverk Factory Library/
  1-Multi-sampled Instruments/{1-Polyphonic Synths,2-Bass,3-Acoustic Hybrid,4-Waveforms}/<Name>/<Name>.elmulti + WAVs
  2-Drum Sets/{1-Synthetic Drums,2-Acoustic Hybrid,3-Utility Drums}/<Name>/<Name>.eldrum + WAVs
  3-Single Samples/  4-Presets/*.tvpst  5-Projects/  6-Wavetables/
```

All 191 instrument folders sit three levels deep, are flat, and hold only WAVs plus one mapping file. The mapping basename equals the folder name in 154 of 191 cases, not always, e.g. `Latin Perc/LatinPerc.eldrum`. Sample references are bare filenames in that folder. Users' own content goes under `User/` [F].

## 2. Mapping schema (`.elmulti` / `.eldrum`)

UTF-8 text, LF line endings, no BOM [L]. A small subset of TOML: one `key = value` per line, with arrays of tables for the hierarchy. The first line is `# ELEKTRON MULTI-SAMPLE MAPPING FORMAT` or `# ELEKTRON DRUM SET MAPPING FORMAT`.

- **Strings** use single quotes. Factory `.elmulti` always use single quotes; `.eldrum` `name` uses double quotes in 59 of 81 files, so both parse [L]. Use double quotes with `\"` escaped only if the value contains `'` [C].
- **Floats**: integral values are written `60.0`; others as the shortest float32 form, e.g. `0.49411765` [L].
- **Extension** must be `.elmulti` (not `.emulti`) [C].
- Do not emit other keys. The factory uses exactly the keys below, and ConvertWithMoss flags unknown ones.

| Level / key | Type | Meaning | Factory evidence [L] |
|---|---|---|---|
| root `version` | int | `0` | 191/191 |
| root `name` | string | Display name | max 21 chars; 2 names contain non-ASCII |
| `[[key-zones]]` `pitch` | int 0-127 | Root note, one zone per root, written in ascending order | never duplicated or unsorted |
| `key-center` | float | Tuning anchor. Normally `pitch` as float. The device transposes by `pitch - key-center` semitones [C] | equal to `pitch` in 4,270 of 4,271 zones; `4 Toys` has `pitch = 36`, `key-center = 38.0` |
| `[[…velocity-layers]]` `velocity` | float 0-1 | Lower threshold, about `midi_vel / 127` | see below |
| `strategy` | string | `'Forward'` | 4,731/4,731, the only value ever seen |
| `[[…sample-slots]]` `sample` | string | Bare filename | all 5,103 slots resolve in the same folder |
| `loop-mode` | string | `'Forward'` or `'Off'`, or omitted | omitted on 1,068 slots, `'Off'` on 778 plus 184 in `.eldrum`, `'Forward'` on 2,341 |
| `loop-start`, `loop-end` | int, frames | Always written together, only with `'Forward'` | 1,460 slots |
| `loop-crossfade` | int, frames | Optional | 1,031 of those 1,460 |
| `keep-looping-on-release` | bool | See below | 881 slots, always `true` |
| `trim-start`, `trim-end` | int, frames | Single-file chain mode | **never used anywhere in the factory library** |

There is no key-range, volume, pan or fine-tune key.

**Loop semantics seen in the factory.**

- `'Forward'` with `loop-start`/`loop-end` is a sustain loop, with the optional crossfade. It never carries `keep-looping-on-release`.
- `'Forward'` + `keep-looping-on-release = true` and **no loop points** loops the whole file. All 881 such slots are the Waveforms and Spectral instruments (§4).
- `'Off'` and an omitted `loop-mode` both play as one-shots. Both are used, and an omitted key is not an error.
- Whether `keep-looping-on-release` combined with explicit loop points works is untested; it never occurs.

**Key zones.** The device plays the nearest root note and transposes [S]. Zones cannot overlap, and the boundary between two roots is undocumented.

- `.elmulti` has 3-97 zones, mostly spaced every 1-12 semitones.
- `.eldrum` always has exactly **8 zones**, at `pitch` 60, 62, 64, 65, 67, 69, 71, 72 (81 of 81 files), one per Subtrack pad [L].

**Velocity layers.** `velocity` is a lower threshold. A layer covers [its threshold, the next layer's), and hard switching applies with no crossfade [S].

- Factory thresholds: 22 distinct values in `.elmulti`, 9 in `.eldrum`, range 0.0667-0.9176.
- Defaults: `0.49411765` (63) for multis, 2,578 uses; `0.24705882`/`0.24313726` (31) for drums.
- Layers per zone: 1-6 in `.elmulti`, 1-5 in `.eldrum`.
- **Layer order is not required to be ascending**: 117 factory zones (e.g. `Lofi Kalimba`) list layers out of order, so the device sorts them. Writing ascending is still safest.
- `velocity = 0.0` makes the device reject the file [C]. In `.tvpst`, `1.0` is valid (§7).
- Velocity also drives level by default [F].

**Round robin.** Several `sample-slots` in one layer cycle in file order [S][C]. Factory use: 3 slots per layer in 70 `.elmulti` layers (e.g. `Rubber Bass`), and 5, 6 or 8 slots in `.eldrum` layers (e.g. `Nitrum`, 8 per pad) [L]. Each slot may carry its own loop points. The counter scope (per zone, layer or global) and its reset are unknown.

## 3. Random selection: SFZ only

No random key exists in the native format (the spec lists it as "?"; the factory never shows one). The manual's SFZ route supports it, per the spec [S]:

- **Random:** `lorand`/`hirand` within a velocity layer. **Round robin:** `seq_length`/`seq_position`. They are mutually exclusive.
- **Required:** `sample`, plus `key` or `pitch_keycenter`. `pitch_keycenter=sample` is not supported. `lokey`/`hikey` are parsed but the nearest root wins.
- **Velocity:** `lovel`/`hivel`, up to 128 layers, hard switching. `xf*` crossfades are ignored.
- **Trim and loop:** `offset`/`end` map to the trim keys. `loop_start`/`loop_end` are in frames, `loop_crossfade` in **seconds**. `loop_mode`: `no_loop`/`one_shot` become `'Off'`, `loop_sustain` becomes `'Forward'`, `loop_continuous` becomes `'Forward'` with keep-looping. WAV `smpl` loops imply `loop_sustain` when `loop_mode` is absent.
- **Headers:** `<control>`, `<global>`, `<master>`, `<group>`, `<region>` are allowed. `<curve>` is ignored. `<effect>`, `<midi>` and `<sample>` make the load **fail**. `<control>` accepts `default_path`, `note_offset` and `octave_offset`.
- **Paths:** relative and UNIX style. `=`, balanced `<>`, `//` and `/*` are not allowed in file names.
- **Ignored:** `volume`, `pan`, `tune`, `ampeg_*`, filters and effects.

```sfz
<group> key=38 lovel=1 hivel=127
<region> sample=Snare-a.wav lorand=0.0 hirand=0.5
<region> sample=Snare-b.wav lorand=0.5 hirand=1.0
```

Practical rule: use `.elmulti` unless you need random selection.

## 4. Audio encoding and storage

**Safe target:** PCM WAV, 24-bit, 48 kHz, mono or stereo [L][S][C]. The factory contains much more:

| Encoding | Where [L] |
|---|---|
| 24-bit PCM, 48 kHz, mono or stereo | the large majority; stereo is common in both mapping types |
| 16-bit PCM, 48 kHz | 36 stereo files |
| **16-bit PCM, mono, with a non-48 kHz rate** | 485 files of `Pure Saw/Square/Triangle` |
| **64-bit IEEE float** (format tag 3, `fact` chunk), 48 kHz | 396 `Spectral *` files (e.g. 65,536 frames) |
| WAVE_FORMAT_EXTENSIBLE, 24-bit PCM, mono | 72 files (`Sine Valve`, `Ferrum`, `DynamicDrum`) |

- **Rate as pitch** (Waveforms): one 2,936-frame single cycle per semitone, MIDI 12-108 (97 zones). The WAV sample rate is set so the cycle plays at the note's frequency: `rate = round(cycle_frames × 440 × 2^((midi-69)/12))`. For example MIDI 12 gives 48,009 Hz and MIDI 108 gives 12,290,123 Hz. These files use `'Forward'` + `keep-looping-on-release = true` with no loop points. So the device honours arbitrary header rates, and a full-file loop is the way to ship single-cycle waveforms [L].
- **Chunks**: factory WAVs carry many layouts, so extra chunks are not fatal on their own: `fmt`+`data` only (802 slots); plus `smpl` (+ Sample Robot `srob`); `LIST`+`id3 `; `LGBM`; `fact`; `bext`+`junk`; leading `JUNK`. ConvertWithMoss still writes only `fmt `, `data` and, when looped, `smpl`, and says the parser is strict [C]. The safe minimal output is `fmt `/`data`/`smpl`, but the claim that nothing else loads is **not** supported by the factory content.
- **Device output**: the Tonverk writes little-endian AIFC (`sowt`) [C]. Its own recordings are reportedly 32-bit float [F].
- **Rate and length**: the engine runs at 48 kHz with 32-bit internal precision, and other rates play with lower quality [F]. The maximum length is reportedly about 45 minutes [F].
- **Two storage layouts:**
  1. **One WAV per slot** (all factory content). Do not write `trim-start`/`trim-end`; ConvertWithMoss found the device rejects them on per-sample files. Cut the audio instead.
  2. **Single-file chain**, as the on-device autosampler writes it: every slot points at one WAV with its own `trim-start`/`trim-end`, the end being exclusive (the next start equals it) [S]. No factory file exercises this, so it rests on [S] and [C] alone.

## 5. Loops

Loops live in the descriptor. Mirror them in the WAV `smpl` chunk, but note what the factory shows:

- Of the 1,460 looped slots, 1,280 have a `smpl` chunk and **180 have none**, so `smpl` is not required. Where present it matches the descriptor in 1,279 of 1,280 cases [L].
- The reverse also occurs: 86 `.elmulti` WAVs (`Submarine`, `Molecules`) contain a `smpl` loop that the descriptor does not use (no `loop-mode`). So the descriptor wins when they disagree, assuming the device plays them as one-shots. This is [I]; it was not heard on a device.
- Factory `smpl` chunks hold one forward loop (type 0, cue id 1, fraction 0, play count 0). `MIDIUnityNote` equals `pitch`, except in `Tulipa`, `Sharp Cutlery` and `Degraded Mullet` (57 slots).
- Only forward loops exist, and crossfade exists only in the descriptor. Render ping-pong or backward loops into the audio.

**Constraints**, found by failed loads [C] and confirmed by the factory [L]:

- `0 <= loop-start < loop-end <= frames - 2` (inclusive end). All 1,460 factory loops satisfy it, so a loop must not end on the last frame. Fix by appending one frame, a copy of the frame at `loop-start`.
- The crossfade blends the loop end with the audio **before** `loop-start`, so it must fit there. In the factory, `loop-start - loop-crossfade >= 973`. ConvertWithMoss uses `crossfade + 256 <= loop-start`, which is conservative.
- Factory crossfades are at most 71.5% of the loop length. ConvertWithMoss limits to 50%, which is safe.
- If a crossfade does not fit, move `loop-start` forward rather than cutting the crossfade, which would click. Exception: single-cycle loops of 512 frames or fewer keep their length, since the length is the pitch.
- When resampling to 48 kHz, scale the loop points by `48000 / rate`. For single-cycle loops, scale the length once and round once.
- Firmware 1.3.x reportedly broke "loop end = sample end", and "cut at loop point" adds 32 samples [F].

`smpl` chunk layout (standard RIFF, little-endian):

```
"smpl" u32 size = 36 + 24*numLoops
u32 manufacturer=0, product=0, samplePeriod=round(1e9/rate) (20833 @48k),
u32 midiUnityNote=pitch, midiPitchFraction=0, smpteFormat=0, smpteOffset=0,
u32 numSampleLoops=1, samplerData=0
loop: u32 cueId=1, type=0 (forward), start, end (inclusive), fraction=0, playCount=0
```

23 factory chunks have `samplePeriod = 0`, so the device does not depend on it.

## 6. Naming

Factory sample names mostly follow `{Name}-{NNN}-{midi:03d}-{note}{octave}.wav`, but the device does not parse them. The mapping drives everything.

- `{NNN}` is a per-pitch sequence index: it equals the layer rank in 3,485 slots and differs in 562 (of the 3,987 that follow the pattern). Round-robin slots in the factory use the next index (`Rubber Bass-000/001/002-036-c1.wav`), not an `-rr` suffix. The `-rrN` suffix is ConvertWithMoss's own.
- Notes are lowercase with `#` for sharps. The octave is `midi // 12 - 2` (MIDI 60 is `c3`), but **Waveforms use `midi // 12`** (MIDI 108 is `c9`).
- **B is written `h`** (`-047-h1.wav`) in some instruments, 125 slots in all, so a parser must not rely on the note letter.
- Some instruments use free-form names (15 `.elmulti` slots, e.g. `Anemone-001.wav`), and drums use e.g. `1_Kick_Royalty.wav` or `Nitrum-BD-001.wav`.
- The `midi` number differs from `pitch` in 60 slots.
- Longest sample name is 37 characters. No unusual characters appear (only letters, digits, space, `_`, `-`, `.`, `#`).

## 7. Presets (`.tvpst`)

A preset is a full sound: engine parameters plus, for the Multi and Drum engines, an embedded mapping [L].

```
version = 2
category = 'KEYS'            # optional: absent in 26 of 175 files; 'KEYS' (114) or 'DRUMS' (35)
tags = ['PAD', 'NOISY']      # 0-8 tags, inline or one per line; 'tags = []' when none

[parameters]                 # flat, every value a single-quoted string
arp_enabled = '0'  ... lfo1_*, lfo2_*, pitchbend_*/aftertouch_*/modwheel_*/breath_control_*,
fx1_*, fx2_*, midi_machine = '0', gen_machine = '1', gen_multi_* ...

[parameters.gen_multi_mapping_slot]      # or gen_drum_mapping_slot; absent for one-shot
version = 0
name = 'Robochoir'
[[parameters.gen_multi_mapping_slot.key-zones]]
pitch = 24
key-center = 24.0
[[parameters.gen_multi_mapping_slot.key-zones.velocity-layers]]
velocity = 0.4941176772117615
strategy = 'Forward'
[[parameters.gen_multi_mapping_slot.key-zones.velocity-layers.sample-slots]]
sample = '/mnt/sdcard/Elektron/Tonverk Factory Library/1-Multi-sampled Instruments/1-Polyphonic Synths/Robochoir/Robochoir-000-024-c0.wav'
loop-mode = 'Forward'
loop-start = 238942
loop-end = 542750
loop-crossfade = 2150
```

- **Preset version and `gen_machine`.** The top-level `version` is `2` in 163 files and `0` in 12 older ones. **The meaning of `gen_machine` differs between them**, so determine the engine from the `gen_<engine>_*` parameter prefix and the mapping-slot name, not from `gen_machine`:

  | Preset `version` | `gen_machine` → engine |
  |---|---|
  | 2 | `0` one-shot (27 files), `1` multi (113), `2` drum (23) |
  | 0 | `1` drum (4), `2` multi (8) |

  ConvertWithMoss also lists `4` for the Grainer (`gen_granular`), which does not occur in this library [C].
- **Parameter counts**: 122-142 keys for Multi, 132-142 for One-Shot, and 498-516 for Drum (eight `gen_drum_voice0..7_*` blocks). The full key list is not documented; start from a device-saved preset.
- **Mapping slot** is the same schema as §2, with absolute sample paths. It mirrors the source `.elmulti`/`.eldrum` in 120 of 143 presets. The other 23 (21 from drum sets) differ: 13 only in velocity values, 10 in samples. In `001 SLEW KIT` the pads were swapped via the device: the new samples come from `3-Single Samples` and get velocity `1.0`.
- **Velocity precision**: the device writes the float32 value widened to double (`0.4941176772117615`), and `1.0` is valid here.
- **One-shot engine** has no mapping slot. The sample is in `gen_oneshot_sample_slot` (absolute path), with normalised 0-1 fractions in `gen_oneshot_sample_start`/`_end`, `gen_oneshot_loop_start`/`_end`, plus `_loop_xfade` and `_loop_behavior`.
- **Tags**: the library uses 28 upper-case tags: ACOUSTIC, ARPEGGIO, ATMOSPHERIC, BASS, BRASS, BRIGHT, CHORD, DARK, DEEP, EPIC, EVOLVING, EXPRESSIVE, GLITCH, HARD, HI-HAT, KICK, LEAD, LOOP, METALLIC, NOISY, PAD, PERCUSSION, SNARE, SOFT, SOUND FX, STRINGS, TEXTURE, VINTAGE. Presets with other tags do not show up in the LOAD PRESET menu [C].

## 8. Examples

Full-feature `.elmulti` (velocity layers, round robin, loops, tuning):

```toml
# ELEKTRON MULTI-SAMPLE MAPPING FORMAT
version = 0
name = 'Example Pad'

[[key-zones]]
pitch = 60
key-center = 59.85

[[key-zones.velocity-layers]]
velocity = 0.0078740157
strategy = 'Forward'

[[key-zones.velocity-layers.sample-slots]]
sample = 'Example Pad-000-060-c3.wav'
loop-mode = 'Forward'
loop-start = 48000
loop-end = 191999
loop-crossfade = 4800

[[key-zones.velocity-layers.sample-slots]]
sample = 'Example Pad-001-060-c3.wav'
loop-mode = 'Forward'
loop-start = 48100
loop-end = 192099
loop-crossfade = 4800

[[key-zones.velocity-layers]]
velocity = 0.62992126
strategy = 'Forward'

[[key-zones.velocity-layers.sample-slots]]
sample = 'Example Pad-002-060-c3.wav'
loop-mode = 'Off'
```

Velocities 1-79 play the first layer and 80-127 the second. MIDI 60 is tuned +15 cents (`key-center = pitch - tune`) [C]. The first layer alternates between its two slots.

Whole-file loop for a single cycle (Waveforms style):

```toml
[[key-zones.velocity-layers.sample-slots]]
sample = 'PureSaw-000-012-c1.wav'
loop-mode = 'Forward'
keep-looping-on-release = true
```

`.eldrum`: eight zones at the fixed pad pitches, one layer each, and round robin by adding slots:

```toml
# ELEKTRON DRUM SET MAPPING FORMAT
version = 0
name = "Example Kit"

[[key-zones]]
pitch = 60
key-center = 60.0

[[key-zones.velocity-layers]]
velocity = 0.49411765
strategy = 'Forward'

[[key-zones.velocity-layers.sample-slots]]
sample = '1_Kick_ExampleKit.wav'
[[key-zones.velocity-layers.sample-slots]]
sample = '1_Kick_ExampleKit-2.wav'
```

Repeat the zone for pitches 62, 64, 65, 67, 69, 71 and 72.

## 9. Generator checklist

1. Convert to 24-bit PCM WAV at 48 kHz, or use the rate-as-pitch trick for single cycles. Write `fmt `, `data`, and `smpl` only when looped.
2. For each WAV, cut it to its region and do not write `trim-*`. Keep `loop-end <= frames - 2` (append a frame if needed).
3. Fit each crossfade: `loop-start - loop-crossfade >= 256` and `loop-crossfade <= 0.5 * loop length`. Mirror the loop into `smpl` (unity note = `pitch`).
4. Write one `[[key-zones]]` per root note, ascending. For drums, write exactly 8 zones at 60, 62, 64, 65, 67, 69, 71, 72.
5. Write non-zero velocities in ascending order. Each round-robin variant is one more slot.
6. Write `loop-mode` explicitly on every slot, and `keep-looping-on-release = true` only for whole-file loops.
7. Name the folder and the mapping file identically, keep everything in one flat folder, and keep names ASCII.
8. For `.tvpst`, determine the engine by key prefix, copy a device-saved preset as a template, and use absolute `/mnt/sdcard/...` sample paths.
9. For random selection, emit `.sfz`.

## 10. Open questions

- Round-robin counter scope and reset.
- A native random value for `strategy`.
- Zone boundaries between two roots.
- Whether the device ever honours a `smpl` loop that the descriptor omits.
- `keep-looping-on-release` with loop points.
- The `trim-*` chain mode, which no factory file uses, and whether loop points are then file- or region-relative.
- FLAC and AIFF import, and limits on zones, layers, slots and RAM.
- The exact `User/` subfolder names.
- Whether the device accepts a `#` comment line below the header (Sondr writes one, see §11), and a kit with fewer than 8 zones (Sondr leaves empty pads out).
- Reports: round robin working only on the first 3 tracks of an edited `.eldrum`, and an alleged OS 1.2.0 loading regression [F].

## 11. Sondr's eldrum builder

The format has no field for where a sample came from, so Sondr keeps that outside the mapping. Code: `Sources/SondrCore/Tonverk/`.

- **Folder.** `<name>/` holds `<name>.eldrum`, one `<pad>_<source name>.wav` per filled pad and `<name>.sondr.json`. File names are ASCII (other characters become `_`). Export never overwrites a folder and refuses a destination inside a library location.
- **Audio.** A WAV that is already 24-bit integer PCM at 48 kHz is copied unchanged. Anything else is converted. Mono and stereo only. Loop points are not carried over.
- **Sidecar** (`<name>.sondr.json`, versioned, a newer version is rejected). Per pad: `pad` (index into the pitch list), `content_hash` (SHA-256 of the source file, the library's sample identity), `original_path` and `filename` (the WAV in the folder). Sondr links a pad back to the library by hash, so a moved source still resolves. An entry whose `filename` no longer matches the mapping is ignored.
- **Comment line.** The mapping gets `# sondr: sources in <name>.sondr.json` below the header, for a reader that has lost the sidecar. **Not tested on the device**; `EldrumExport.write(..., comment: false)` leaves it out.
- **Foreign kits.** Without a sidecar, Sondr hashes each WAV and looks it up in the library, which only matches unconverted copies. Other pads show the WAV name. Kits with several velocity layers or round-robin slots load with the first sample of each pad and a warning, since saving would drop the rest.
- **Not covered.** Velocity layers, round robin, loop points, `.elmulti`, `.tvpst`.

## References

- [spec]: asatamax, *Elektron Tonverk Multi-Sample Format Specification* v1.4. <https://github.com/asatamax/tonverk-elmulti-converter/blob/main/docs/ELMULTI_FORMAT_SPEC.md>
- [cwm-file]: ConvertWithMoss `TonverkMultiFile.java`; also `TonverkMultiCreator.java` (loop fitting, trimming, velocity rule), `TonverkPresetFile.java` and `TonverkTags.java` in the same directory.
- [cwm-log]: ConvertWithMoss changelog. <https://github.com/git-moss/ConvertWithMoss/blob/main/documentation/CHANGELOG.md>
- elmconv, an EXS24/SFZ to `.elmulti` converter: <https://github.com/asatamax/tonverk-elmulti-converter>
- Elektronauts threads:
  - [SD card folders and filetypes](https://www.elektronauts.com/t/tonverk-sd-card-about-its-folders-and-filetypes-only/238640)
  - [Technical Q&A](https://www.elektronauts.com/t/tonverk-technical-q-a/238273)
  - [Multisampling non-MIDI instruments](https://www.elektronauts.com/t/multisampling-non-midi-instruments-on-tonverk/238139)
  - [elmconv](https://www.elektronauts.com/t/tonverk-tool-elmconv-exs24-sfz-to-elmulti-multi-sample-converter/243807)
  - [Free tools](https://www.elektronauts.com/t/free-tools-for-tonverk-multisample-subtrack-building-new-links/239331)
  - [MESET](https://www.elektronauts.com/t/meset-multisample-engine-slice-editor-for-tonverk-webapp/239137)
  - [LoopSeek](https://www.elektronauts.com/t/loopseek-automatically-create-perfect-loop-points-multisamples/250000)
  - [Multi Player loop mode](https://www.elektronauts.com/t/multi-player-loop-mode/244948)
- Elektron Tonverk user manual, Appendix E "SFZ Support". Not read directly; quoted via [spec].
- Tonverk factory library on the device card (`Elektron/Tonverk Factory Library`), surveyed for this document.

[spec]: https://github.com/asatamax/tonverk-elmulti-converter/blob/main/docs/ELMULTI_FORMAT_SPEC.md
[cwm-file]: https://github.com/git-moss/ConvertWithMoss/blob/main/src/main/java/de/mossgrabers/convertwithmoss/format/elektron/TonverkMultiFile.java
[cwm-creator]: https://github.com/git-moss/ConvertWithMoss/blob/main/src/main/java/de/mossgrabers/convertwithmoss/format/elektron/TonverkMultiCreator.java
[cwm-log]: https://github.com/git-moss/ConvertWithMoss/blob/main/documentation/CHANGELOG.md
