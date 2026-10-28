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

## Default tag rules (2026-10-25)
- Numbers (`01`, `12.`), number pairs (`01-02`) and note names (`f#`, `c-3`) are not tags. They are the **initial value of the global "Ignored tags (all locations)" rules** (`DefaultTagRules.rules`): `TaggingStore.load` returns them when `meta.tag_rules` has never been saved, and from then on they are ordinary user rules (owner's request: not an extra hidden layer). Deleting them all saves `[]`, which stays empty.
- `Tagger` output and its golden test are untouched. No migration: existing libraries keep their saved rules (none saved = defaults on next load; their old tags stay until a retag).
- Side effect: a split `90bpm` yields `90`, which the number rule drops; the hyphenated `90bpm-chop-bright` stays whole.

## Multisamples as first-class objects (2026-10-25)
- Owner suggestion adopted: a group has a name, members and a representative; tags and categories are the union over members, so `sample_groups.cluster_id` and `refreshClusters` are gone. Manual groups survive rebuilds (`manual` flag); editing an automatic group makes it manual.
- Reported bug (area select → grouping off → on shows one row): reproduction tests at model and query level pass (20 groups → 80 flat rows → 20 groups). Working theory is SwiftUI `Table` row identity flipping between `TableRow` and `DisclosureTableRow`; mitigation `.id(browse.showsGroups)` on the Table. **Unverified until the owner clicks through it.**
- Default group name is the representative's file stem (e.g. `Piano C3`); the pitch-less grouper key (`piano`) would read better, one-line switch.

## Clusters as data (2026-10-25)
- The 14 clusters are only a seed; names, colours and descriptions are edited in Settings → Clusters. Edits that change centres re-sort all samples from stored vectors via `ClusterReassignJob` (chunked, resumable). The threshold is global: 0.22, tuned on the real library (90.6% of 31,403 samples reach it). The seed is now 14 clusters with CLAP prompts as keywords; 1 of 8 labelled fixtures still misses (`ClusterModelTests` known issue).

## Drag-out (2026-10-25)
- `NSItemProvider(contentsOf:)` made SwiftUI hand out a cached copy (Finder name "Waveform audio", DAW path under `~/Library/Caches/com.apple.SwiftUI.Drag-…`). Now `NSItemProvider(object: url as NSURL)` with `suggestedName`. Unverified in Finder/DAW until the owner re-tests.

## Signal Grid theme, appearance and accent (2026-10-25)
- Design in `docs/DESIGN.md`. Theme the native views (Table, NavigationSplitView, Form), do not rebuild them.
- **Accent is fixed orange.** `.tint` alone does not reach the Table selection (spike: stayed system blue); an `AccentColor` asset with dark `#FF5A1F` and light `#E9440E` does, and the spectrogram reads the token instead of `controlAccentColor`. Caveat: macOS honours the asset only while the system accent is Multicolor.
- **Light signal is `#E9440E`, not `#FF5A1F`**: 2.7:1 against the light ground, below the 3:1 target. `signalText` on light is `#B93705` (4.5:1 on every ground). Enforced by `ThemeTokensTests`.
- **Appearance** is a preference (`appearance`: system, light, dark) applied through `NSApp.appearance`, so every window and the AppKit table follow. Tokens are dynamic colours; views do not branch on the scheme except where pixels are baked (map raster, spectrogram), which key their render on `colorScheme`.
- **Cluster colours** stay as stored. The display colour is derived per scheme (`legible(on:)`: same hue, lightness moved until 3:1 against the window ground). New libraries are seeded with the LED set (no migration; existing libraries keep their colours).
- **Table cells use `.secondary`, not a fixed grey**, so text stays readable on the orange selection.
- **Icon** is drawn by `tools/make_icon.swift` (`make icon`), 3×5 pixel S at 32 px and below.
- Dev aids: `SONDR_APPEARANCE=light|dark|system`; `SONDR_SNAPSHOT` now activates the window and focuses the table so the selection is drawn active. Launch arguments `-showSoundMap YES -explorerTab map|axes` open the explorer without touching saved preferences.

