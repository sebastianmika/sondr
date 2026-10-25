# Sondr: Requirements for a rebuild

Status: derived from the existing implementation (HEAD `77567d4`), `PLAN.md`, `README.md`, `docs/*` and the code. Written for an engineer who has not seen the old repo.

**Source of truth.** Where this file and the old code disagree, the old code wins for behaviour and this file wins for intent. Items marked **(provisional)** were tuned on synthetic data only. Items marked **(unverified)** were built but never tried by a person in the running app.

**Assumptions (change before starting if wrong).**
1. Same stack as before: native macOS 15+, Apple Silicon only, Swift 6, SwiftUI, GRDB/SQLite, Core ML. The requirements below name platform features (Table, Accelerate, Metal) because the layout and the speed targets depend on them.
2. No backwards compatibility. Schema and stored data may change freely; the owner recreates the library after each change. No migrations, version shims or fallbacks for old data.
3. No governance artifacts apply. This is a personal desktop tool, not a production model.

---

## 1. Product

A desktop app to manage and search a library of **50k to 250k audio samples** (drums, loops, synths, FX). Single user, single Mac, no server.

It lets the user:
- search by describing a sound in words ("warm analog pad") or by example ("find similar");
- see every sample sorted into sound categories (8 by default, user-editable);
- narrow the list by six audio features (sound axes) or by an area on a 2D map of the library;
- filter and curate tags, derived from folder and file names;
- play samples, and drag them into Finder or a DAW;
- treat one instrument sampled at many pitches (a **multisample**) as a single row.

**Hard rules**
- **R1.** The app never modifies, moves or deletes audio files. All derived data lives in the app's own database. Tests that scan must assert that file bytes and mtimes are unchanged.
- **R2.** Everything persistent is in **one SQLite file**. No second store (no vector DB).
- **R3.** The app is usable without the ML models: browsing, scanning, tags, keyword filtering, playback, multisample grouping by metadata. Indexing and describe-search are disabled with a clear message.
- **R4.** A failed file is recorded with a reason and shown. It is never embedded as silence.
- **R5.** Never auto-delete user data because a file vanished. Flag it `missing`.

---

## 2. Platform and technology

| Area | Requirement |
|---|---|
| OS | macOS 15+, Apple Silicon (arm64) only. Not sandboxed. Ad-hoc signed; Developer ID and notarisation are out of scope. |
| Language/UI | Swift 6 language mode, SwiftUI with AppKit where SwiftUI cannot do it (see §6.4, §9.2). `@Observable` models, `@MainActor` only for UI state. |
| Structure | A SwiftPM library (`SondrCore`, all logic, no SwiftUI) plus a thin app target (`App/`, XcodeGen `project.yml`). Everything testable with `swift test`. |
| Dependencies | GRDB 7.11+ only, plus a **vendored** GPU t-SNE library (MetalTSNE, MIT, from github.com/vals/mac-tsne commit `45d5c91`; see §9.3 for the required addition). No tokenizer dependency. |
| DB | GRDB `DatabasePool`, WAL, foreign keys on. Default path `~/Library/Application Support/Sondr/library.sqlite`; env `SONDR_DB` overrides. |
| Embedding model | `laion/gan-clap-320k-binaural`, converted once offline to Core ML. The app is pure Swift at runtime. See §5.1. |
| Build | `make debug \| release \| run-* \| project \| clean \| reset`. `make reset` deletes the DB (+wal/shm, honouring `SONDR_DB`) and the app's user defaults, keeps the models. Release is ~7x faster at indexing than debug. |
| Python tooling | `uv`-managed. `tools/convert_clap` (model conversion + parity validation), `tools/golden` (fixture generation). Python is never needed at runtime. |
| Concurrency | Actors for scanner, embedder, vector index, map service. One running job per kind, enforced by a registry; a second start fails at once with a typed error. |

**Job exclusion matrix.** Scan and index may run together. Retag excludes scan (it holds both job kinds). The cluster re-sort (§5.5) holds scan, index, retag and recluster, so it excludes all of them and they exclude it. Scan, add/remove location and rescan are disabled in the UI while indexing or retagging. A scan refuses to run while indexing or retagging.

---

## 3. Window layout

Three-column `NavigationSplitView`. Default window 1280 x 780, minimum 960 x 560.

```
+-----------------+------------------------------------------+-----------------+
| SIDEBAR         | CONTENT                                  | DETAIL          |
| 200/240/320 pt  | min 400, ideal 520                       | 240/280/400 pt  |
|                 | [toolbar: search field | Keyword/Describe|                 |
| Library         |  | group | audition | explore toggle]    | name            |
|  All samples N  | [banners]                                | waveform +      |
|  Unsorted N     | [Explore panel: Axes | Map  (optional,   |  spectrogram    |
| Clusters        |   resizable 160..700 pt, default 380)]   | Play / Find     |
|  8 rows, colour | Table: Name | Cluster | Tags | Length |  |  Similar        |
|  dot + count    |        Match                             | facts, tags,    |
| Tags (cloud)    | [footer: "N of M" | spinner | error]     | sound bars,     |
|  Manage Tags…   |                                          | paths, metadata |
| ---- jobs bar --|                                          |                 |
+-----------------+------------------------------------------+-----------------+
```

Settings is a separate window (⌘,), 760 x 700, tabs **General · Locations · Map**. The last used tab is remembered.

### 3.1 Start-up states
- Loading: spinner "Opening library…".
- Failed: full-window message "The library could not be opened" with the reason.
- Ready: the layout above.

### 3.2 Sidebar
- **Library**: "All samples" (count = samples minus missing), "Unsorted" (count). Single selection; selecting one sets the cluster filter.
- **Clusters**: the user's categories (8 by default), each with a colour dot (palette in §6.6) and sample count. Selecting one sets the cluster filter.
- **Tags**: shown only when tags exist. A wrapping cloud of chips `name count`, most used first (limit 200). Click toggles the tag in the filter (active chip is accent-filled). Below it a **Manage Tags…** button.
- **Jobs bar** (pinned bottom, material background):
  - scan progress (`Scanning <folder>…`, bar, "x of y files", indeterminate until the file count is known);
  - retag progress ("Updating tags", x of y);
  - index progress ("Indexing", bar over done+failed of total, Cancel);
  - when idle: **Index N** (disabled when nothing pending, a scan runs, or models are missing; tooltip says why) and **Rescan** (all locations; disabled when no locations or a job runs); a link "N failed" when failures exist;
  - summary line: "N samples, M indexed[, K missing]".
- **Failures sheet** (640 x 380): table File (rel path, full path as tooltip) | Reason; buttons **Try Again** (re-queues failed samples; disabled without models) and **Close**. Lists up to 1000.

### 3.3 Content column
- **Toolbar**: search field (placement toolbar); segmented **Keyword / Describe**; toggle *group multisamples* (icon `square.stack.3d.up`); toggle *play on select* (`speaker.wave.2`); toggle *explore panel* (`chart.xyaxis.line`).
  - Search prompts: "Filter by name or folder" (keyword) / "Describe a sound, e.g. “warm analog pad”" (describe).
  - Keyword applies after 150 ms of no typing, Describe after 400 ms. Switching mode re-runs the search at once.
- **Banners** (top, stacked, only when applicable): models missing (orange); text-search results "Best matches for “x”" with Clear; similar-results "Sounds like <name>" with Clear; error (red); *Area on the map: N samples* with ✕; *Sound axes: <brushed axes>* with ✕; *Tags:* removable chips.
- **Explore panel**: see §9.
- **Table** columns, in order:
  | Column | Content | Sortable |
  |---|---|---|
  | Name | icon (speaker, accent colour while playing; else waveform), display name, multisample badge (§7.6) | yes (case-insensitive) |
  | Cluster | colour dot + category name, or "–" | no |
  | Tags | comma-joined, secondary colour, one line | no |
  | Length | `1.23 s` below 10 s, else `m:ss`; monospaced digits | yes |
  | Match | cosine as `NN%`, only for describe/similar results | no |
  Multi-select. Default sort: name ascending. Not-yet-indexed samples sort last in either direction; sample id is the final tie-break so paging is stable.
- **Footer**: `N of M` (browse) or `N results`; small spinner while loading; playback error text in red.
- **Empty states**: library empty ("Your library is empty", *Add Folder…* opens Settings on the Locations tab); no match (standard search-empty view).

### 3.4 Detail column
See §8.2.

---

## 4. Library: locations, scanning, tagging

### 4.1 Locations
- A location is a folder. Managed **only in Settings → Locations** (no location section in the sidebar; no sidebar location filter UI).
- Each location stores: path, optional extension filter, optional max duration (columns exist, **no UI**, default none), extra tags, tag rules, multisample rules, added-at.
- **Settings → Locations tab**:
  - List of locations: folder name, sample count, path (middle-truncated), "Adds: <extra tags>", "Ignores N patterns", buttons **Edit…**, **Rescan**, **Show in Finder**, **Remove…**.
  - **Add Location…** (folder picker → editor sheet), **Rescan All**, a progress text while scanning/retagging.
  - Section **Ignored tags (all locations)**: rule list (§4.4) with *Apply and retag N samples* (N computed before confirming) and *Revert*.
  - Remove asks for confirmation: "N samples that are only found here leave the library, with their tags. The audio files are not touched."
  - Add, remove, rescan and edit are disabled while a scan, index or retag runs.
- **Location editor sheet** (680 wide, min height 600, content scrolls, **buttons stay pinned**). Used for Add and Edit. Sections:
  1. **Extra tags**: comma-separated, added to every sample of the folder; not filtered by any rule.
  2. **Ignored tags in this folder**: rule list (§4.4).
  3. **Rare tags** (Add only): stepper N (0..1000, default 1) "Drop tags that N or fewer samples have"; 0 disables the count rule. After import, auto tags used by ≤ N samples **or** by < 1 % of the location's new samples are removed. Extra tags and manual tags stay. Removals are remembered so rescans do not bring them back.
  4. **Multisamples**: switch "Show one instrument sampled at several pitches as one row" (default on) plus folder exceptions (§7.4).
  5. **Preview** "Tags this folder would get": see §4.5.
  - Buttons: Cancel; primary = **Import** (Add) or **Apply and retag N samples** / **Save** (Edit). Primary is disabled when a rule is invalid, when nothing changed (Edit), or while a scan runs (Add).
  - Edit: Cancel changes nothing. The retag count is recomputed as the user edits.

### 4.2 Scanner
- Recursive walk. Hidden files and symlinks skipped. Packages not descended. Supported extensions: `wav, wave, aif, aiff, flac, mp3, m4a, aac, caf`. **`.ogg` is unsupported.**
- Root is resolved with `realpath` (keeps `/private/var`). A missing root throws; it must not flag everything missing (unmounted volume). A location whose root is empty must not flag the whole location missing.
- Per file, in order: open with `AVAudioFile` (rejects corrupt files, gives duration/rate/channels/format, applies max-length filter) → SHA-256 in 1 MiB chunks. Corrupt and over-long files are never fully read. Corrupt files are retried on every scan.
- A sample is identified by content hash. Every path with that content is kept (`sample_paths`); one is canonical.
- Rescan skips files whose **size and mtime** are unchanged, **per path** (duplicates have their own mtime).
- Every file lands in exactly one counter: `new`, `duplicate`, `moved`, `skipped`, `filtered`, `errors`. `moved` = known content at a new path while none of the sample's old paths exist (includes a deleted file that comes back). `missing` counts samples newly flagged. `hashed` counts files actually read (to prove unchanged files are not re-read).
- A path whose content changed becomes a new sample; the old sample is deleted if it has no other path (its tags and embedding go with it).
- A sample that loses its last path is flagged `missing`, not deleted; tags and embedding survive the file's return.
- Writes are batched, one transaction per ~500 files. Bounded parallel reading (about the core count). Progress callback after the walk and after each batch.
- After a scan: reload the vector index, regroup multisamples (§7), refresh counts, show a message "Scanned <folder>: N new, N duplicates, N unreadable."
- **Display name** (`samples.name`): file name without a leading track number (`01 Kick.wav` → `Kick.wav`). If another sample in the same folder already has that name, append the root note from the metadata (`Kick C3.wav`), unless the name already contains a pitch; if still taken or no root note, append the removed number (`Kick 01.wav`). `filename` stays the real file name. Name is used in list, detail, search and name sort.

### 4.3 Auto-tagging (the `Tagger`)
Input per path: `<location folder name>/<path below the location>` (never the absolute path).
Algorithm (faithful port of the legacy tagger; must reproduce the 200 golden paths exactly):
1. Parts = directory components + file stem.
2. Alias lookup on whole lower-cased parts.
3. Split on `_`, whitespace, camelCase and letter/digit boundaries. Dots are **not** separators. Hyphenated segments are kept **whole** as one tag (`hi-hat`, `clp-wide`, `90bpm-chop-bright`); this is a deliberate legacy quirk, listed in §14.
4. Lower-case → alias → singularise (rule-based singulariser with exceptions, no OS lemmatiser) → alias again.
5. Drop stopwords and tokens shorter than 2 chars.

The `Tagger` output itself stays as is. On top of it, built-in **default rules** (`DefaultTagRules`, whole-tag regex, case-insensitive) drop tags that are noise: numbers `\d{1,2}\.?` (`01`, `12.`), number pairs `\d+([-._]\d+)+` (`01-02`, `3.5`) and note names `[a-g]#-?\d?`, `[a-g][#b]?-?\d` (`f#`, `c-3`). They stay: `808`, `909`, `120`, `2020`, `am`/`cm`/`dm`, bare `db`/`ab`, `90bpm-chop-bright`, `punchy-02-120`. Applied in `TagComputer.tags`, so scan, retag and location removal all use them.

Bundled data, copied byte-for-byte from the legacy app: `aliases.json`, `stopwords.json` (the old repo's `Sources/SondrCore/Resources/Tagger/`).

Tag provenance: `sample_tags.source` ∈ `auto | manual`.
- **Removals are sticky.** Removing an auto tag from a sample writes `removed_auto_tags`; later scans and retags never re-add it. Adding the tag manually lifts the removal. Manual tags are never downgraded by auto tagging.
- Auto tags are applied for every path the scanner records (new, duplicate, moved), never for skipped files.

### 4.4 Tag rules (blacklists)
- A rule = `{kind, pattern}`, kind ∈ **Text** (equals), **Pattern** (`*` any run, `?` one char, else literal), **Regular expression** (must match the **whole** tag). Always case-insensitive. Matched against the final tag (after aliases and singularising).
- Invalid regex is rejected when typed (red message under the rule), never stored; the dialog's primary button is disabled.
- Scopes: **global** (all locations; kept in `meta.tag_rules`) and **per location**. Both apply on import and on retag. Bundled stopwords and the default rules of §4.3 always apply in addition (not editable).
- Rules filter path-derived tags only. They never remove a location's extra tags or manual tags.

### 4.5 Tag preview
- Walks the folder once (file names only: no hashing, no decoding) and runs the tagger on each relative path. Result: `rawTag → count, example path`. Applying or editing rules is a filter over that dictionary, so the list updates as the user types. Cancellable; spinner "Reading file names…" on big folders.
- Table columns: Tag (crossed out and grey if blocked) | Files | Example (middle-truncated) | action. Action is **Ignore** (adds a Text rule) or the label "Ignored here" / "Ignored for all" (tooltip names the rule), or "Ignored by default" for tags hidden by the default rules (crossed out, no button). Filter field above the table. Header shows "N audio files". Extra tags are not listed.
- Counts files, not samples (duplicates are only found by the real import).

### 4.6 Retag
- Triggered by: editing a location's extra tags/rules, editing global rules, removing a location (survivors via another location).
- Affected samples: those with a path in a changed location; all samples with a location when global rules change.
- **Difference algorithm.** Auto tags of a sample = union over its paths of (tagger output for `<folder>/<rel path>` minus stopwords, global rules, that location's rules) plus that location's extra tags. A retag changes only the *difference* between the old and the new settings: delete `auto` rows in old−new (without writing `removed_auto_tags`), then add new−old through the sticky-aware path. Manual tags and auto tags created by rename/merge are never touched. Idempotent.
- Runs as a background job in chunks of ~500 samples (one transaction each), with progress and cancel. Excludes scan.
- The pending change (old and new settings) is committed in the same transaction as the settings; an interrupted retag **finishes at next launch** and reports "Retagged N samples".
- Removing a location also prunes unused tags.
- Cost reference: 62 s for 250k samples on a global change. Acceptable only because it is a background job.

---

## 5. Indexing (embeddings, features, thumbnails, clusters)

Work list: `embed_state = 'pending' AND missing = 0`, in id order. States: `pending → done | failed`. Resumable, cancellable, progress as a stream.

### 5.1 Embedding engine
- **Models.** Audio tower: fp16, **fixed batch 16** (flexible batch is 20x slower on `ALL` and crashes on GPU); tail batch zero-padded. Text tower: **fp32**, input ids/mask int32 `[1, 2..512]` (fp16 text is wrong on CPU). Projection heads and L2-normalisation inside the models; Swift re-normalises. Output 512-d, one shared text/audio space.
- **Model files.** `ClapAudio.mlpackage`, `ClapText.mlpackage`, `model_version.txt` (string with a `-vN` suffix, bumped on any change that alters outputs). Total ~535 MB (audio 57 MB, text 478 MB). Bundled into the app by an XcodeGen post-build `rsync`; warn (not fail) when absent.
- **Model lookup order:** `$SONDR_MODELS`, app bundle `Resources/Models`, `~/Library/Application Support/Sondr/Models`, `<repo>/Models`. A folder counts only when all three files exist.
- Core ML compiles packages on first use and caches the result in `~/Library/Caches/Sondr/CompiledModels`, keyed by version + package mtime.
- **Compute units** (Settings): *GPU and CPU* (default, fastest: 256 emb/s), *All incl. Neural Engine* (211), *CPU only* (140). Applied at next start. The Neural Engine does not help.
- **Conversion patches** that were needed (keep, or find equivalents): bicubic time-axis resize replaced by a fixed matrix; `AdaptiveAvgPool1d(1)` → `mean`; Swin window partition/reverse with rank ≤ 5 reshapes; text attention mask `-1e4` not `finfo.min`. Pin `torch==2.7.0` for `coremltools` 9.0.
- **Audio preprocessing in Swift** (Accelerate, math in Double): mono → 48 kHz → first **10 s** window (model's native window; legacy 7 s was wrong) → zero-pad to ≥ 1 s → peak-normalise to [-1, 1]; then the HF `ClapFeatureExtractor` log-mel: **HTK** mel scale, no norm for `clap-htsat-fused` (`truncation: fusion`; Slaney only for the unfused model; see `docs/DECISIONS.md`), FFT output rounded to float32 before power, `repeatpad` for short clips, 1001 x 64 features. Must match HF with max abs diff 0.0 dB on the 5 mel fixtures. Longer audio is cut to its first 10 s (HF crops randomly; not reproducible).
- **Decoding.** `AVAudioFile` → channel average → `AVAudioConverter` to 48 kHz (Mastering algorithm, max quality). Resampled length = `ceil(n * (48000 / rate))` in that order of operations. MP3: read the LAME/Xing tag and drop exactly `delay` samples at the start and `padding` at the end (Apple's decoder already removes the 529-sample decoder delay); files without a LAME tag are left as decoded. Typed `AudioLoadError` for undecodable files; no files are written.
- **Tokenizer.** Own byte-level BPE (RoBERTa vocab) from `vocab.json` + `merges.txt` (HF snapshot `8fa0f1c6`, 1.2 MB), ~170 lines, no dependency. Ids identical to HF on all 27 golden queries (empty, whitespace, punctuation, emoji, accents, tabs, 700-word input). Truncation: 510 content tokens + `<s>` + `</s>` = 512. Literal special tokens in input are tokenised as HF does.
- **`Embedder` protocol** (model version, audio batch, text) so tests use a stub.
- **Parity (acceptance).** End to end on 51 audio fixtures, Swift vs PyTorch fp32: min cosine ≥ 0.998, mean ≥ 0.9999; 27 text queries min ≥ 0.9999. Tests that need the models skip with a message when `Models/` is missing.

### 5.2 Index job
- Chunks of 256. Per chunk: decode on all cores (next chunk decodes while the current one embeds) → embed → **one transaction** writes vector, six dims, waveform thumb, spectrogram thumb, cluster + score, `embed_state='done'`. Kill at any point and rerun: nothing redone, nothing half-written; every `done` has a vector and vice versa.
- Unreadable file → `failed` + `embed_error`, no vector. A chunk the model rejects is retried **clip by clip** so one bad clip cannot block the run. A model-level error stops the job and leaves the chunk pending (a missing model must not mark the library failed). *Try Again* (`retryFailed`) puts failed samples back to pending.
- Cancel discards the in-flight chunk, returns `cancelled`, not an error; dim ranges are refreshed on cancel too.
- **Embeddings are stored as Float16** (1 KiB/sample). Text vectors stay Float32 in memory.
- **Model version guard.** `meta.model_version` is compared at start; on a mismatch delete all embeddings, cluster data, maps and set every sample to pending.
- **Reconciliation** (at launch and before each index run): wrong-length vectors deleted; `done` samples lacking vector/dims/thumbnail reset to pending with derived data cleared; vectors of non-`done` samples deleted; unfinished samples lose any cluster. Never deletes samples. Samples finished before the spectrogram existed are *not* reset; the next index run back-fills spectrograms by decoding only (`backfilled` count; undecodable files are retried every run).
- After a run: reload vector index, regroup multisamples, place new samples on the map, message "Indexed N samples, N failed." (+ "Added spectrograms to N.").
- Throughput reference (release, `cpuAndGPU`): ~247 samples/s → 250k in ~17 min.

### 5.3 Six sound dims
Raw per-file values (`dim_*` columns), normalised **at read time**:
| Dim | Definition |
|---|---|
| brightness | log-scaled spectral centroid / log(Nyquist), mean over frames |
| percussiveness | mean positive spectral flux per frame / mean magnitude |
| energy | RMS |
| tonality | 1 − spectral flatness, clipped |
| noisiness | zero-crossing rate |
| duration | min(file's real duration / 8 s, 1). Uses the **file's** duration, not the cropped clip. |
STFT: 1024 FFT, hop 512, symmetric Hann, no centre padding. Matches the legacy values to 2.3e-5 relative on reference decodes; through our own decoder expect up to ~15 % (decoder difference; acceptable).
`dim_stats` holds p5/p95 per dim over all samples with a value (linear interpolation; fewer than 5 values use min/max), recomputed after each index batch. Normalised = clip to [p5, p95], rescale to [0, 1]; a degenerate range gives **0.5**. No full-table rewrite per batch.

### 5.4 Thumbnails
- **Waveform**: 128 bins, each the peak |sample| of an equal slice, scaled so 1.0 = 255 (uint8). Always 128 bytes (empty clip → zeros; clips < 128 samples repeat). Computed from the loader's clip, so peak-normalised and capped at 10 s.
- **Spectrogram**: 64 columns (time) x 32 log-spaced bands (50 Hz–14 kHz), one byte per cell = dB relative to the loudest cell mapped from −70..0 dB; 2 KiB/sample; own 1024-point Float STFT (not the model's mel). Loaded for the one selected sample only, never part of list rows.

### 5.5 Clusters
- Clusters are **data, edited by the user** in Settings → Clusters: name, colour (`#RRGGBB`), description (keywords), add, delete (at least one must remain). `Resources/Clusters/clusters.json` only seeds an empty `clusters` table with the default eight (`kicks, snares, hats/perc, bass, pads, leads, vox chops, fx/risers`; bags for kicks/snares/hats-perc start with "drums"; bass/pads/leads must **not**). Ids are never reused; nothing assumes eight or contiguous ids.
- Centre = CLAP *text* embedding of the description joined by spaces, Float32, cached in `cluster_centres` per model version (other versions deleted). Editing a description or deleting a cluster drops that centre.
- **Applying edits.** Rename/recolour is instant. A changed description, an added or a deleted cluster starts the background `ClusterReassignJob`: one transaction saves the edits and nulls all cluster ids and scores, centres are recomputed for missing ones, then samples are re-sorted from the stored vectors in transactions of 2048 rows (no decoding). Resumable at next launch (`meta.recluster_pending`), cancellable, needs the models. The global `unsortedThreshold` is not part of the editor.
- Assignment: nearest centre by cosine; **always store** cluster id and cosine as `cluster_score`. Assigned in the same transaction as the embedding; missing ones back-filled in chunks of 2048.
- **"Unsorted" is a read-time decision**: score < `unsortedThreshold` (**0.30, provisional**) or no cluster. Changing the threshold needs no re-index. Cluster filter `.cluster(n)` requires score ≥ threshold; `.unsorted` = no cluster or weak score.
- Test: eight clearly labelled fixtures land in the expected cluster above the threshold.
- Open: re-pick the threshold from a score histogram on ~500 real files (needs the owner's go-ahead; see §14).

---

## 6. Browse and search

### 6.1 Filter (all parts ANDed)
tags (all must match) · keyword (every word must occur, case-insensitive, `%`/`_` literal, in display name or path below the location) · min/max duration · cluster choice · location id (core only, no UI) · embed state · **dim ranges** (brushed, normalised 0–1; a range touching 0 or 1 leaves that side open; samples without dims never match a brushed dim; degenerate dim matches all or none) · **sample id set** (area picked on the map; passed as one JSON argument so the statement size is constant) · `includeMissing` (default off; missing samples are hidden).

### 6.2 Paging and queries
- Page size 200; next page loads when one of the last 20 rows appears. The table never holds 250k rows.
- A page is **two SQL statements** whatever its size: rows with tags (correlated `group_concat`) + total count. Test with 5-row and 100-row pages. Tag counts for the sidebar: one query.
- Sort keys: name (case-insensitive), path, duration, added, cluster score, and the five dims. UI exposes name and length.
- Targets at 250k samples: any browse query ≤ 200 ms (measured 70–120 ms); whole-library tag count 413 ms (runs only after scan/index/removal).

### 6.3 Describe (text) search
Query → tokenizer → text tower → top **100** nearest samples by cosine. 400 ms debounce. Warm text embedding < 300 ms. Filters apply: the filter becomes an id set (one SQL query) handed to the vector index. Results keep score order; the Match column shows the cosine. Clear returns to the list. Switching to Describe clears the keyword filter.

### 6.4 Find similar
Context menu (single selection) and detail pane button. Top 100 neighbours of the sample's stored vector, **excluding itself**; error `notIndexed` if it has no vector. Banner "Sounds like <name>". Disabled without models or for non-indexed samples.

### 6.5 Vector index
Actor holding one contiguous Float32 buffer (N x 512) plus a parallel id array; loaded from SQLite at start and after scan/index (0.1 s per 100k). Only `done`, non-missing samples. Top-k = `cblas_sgemv` + sorted insertion buffer. `remove` swaps the last row into the gap (row order not stable; nothing outside may depend on it). Cosine = dot product (stored vectors unit length; queries normalised on entry). Allowed-set filtering during selection. **Target: top-50 over 250k x 512 in < 50 ms (measured 2.8 ms).** ~512 MB RAM at 250k.

### 6.6 Cluster colours
One colour per cluster, stored with the cluster (default: eight clearly different hues; new clusters get a golden-angle hue), shared by sidebar, table and map. Unsorted = grey.

### 6.7 Result vs list semantics
- Any change to filter/sort/library reloads page 1; search results are searched again with the new filter.
- `highlight` set (used by the map): the search results; or all samples the filters let through when ≤ 100,000; nil when nothing is narrowed.
- `pin(id)`: a sample selected on the map may not be on a loaded page; it is loaded on its own so the detail pane and playback work. The table does not scroll to it.

---

## 7. Multisamples

A **multisample** is one instrument sampled at several pitches in one folder (`Piano C2.wav … Piano C6.wav`). The list shows it as **one expandable row**. Grouping is found from file names, then confirmed from file metadata or by sound.

### 7.1 Pitch tokens in names
Parse the file stem (no extension):
- **Note token** (strong): `[A-G][#|b]?-?[0-9]` not adjacent to letters/digits/`#` (`C3`, `F#2`, `Db-1`). If several, the **last** one is used. MIDI = `12*(octave+1) + semitone + accidental`, so C4 = 60; must be 0–127. Octave convention differs between tools; this only shifts a whole group, so **display the note exactly as the file writes it** (`label`), not a computed one.
- **Number token** (weak): a standalone 1–3 digit number 0–127 not adjacent to letters and not followed by `bpm` (`Piano_61`). Last one wins. Number groups are only accepted with metadata (§7.3).
- **Layer tokens** (velocity / round robin): `v\d+`, `vel\d+`, `rr\d+` (case-insensitive) are removed from the key and kept as `layer`.
- After a note token: a 3–4 digit take number (`_0002`) or a `-XXXX` four-char capital/digit pack id (`C#2-ASAU`) is removed from the key and kept as `layer`.
- **Pitch index in the name:** a number in the name that equals one of the file's own note numbers (WAV `smpl` root, `acid` root, `inst` root/low/high; see §7.5) is the pitch's index (`45 Return Home Kawaii C2.wav`, 45 = low note), not part of the instrument name, and is removed from the key. Evaluated only for names with a note token.
- **Key** = name with the pitch token replaced by `{p}`, layers removed, lower-cased, runs of `[ _.-]` collapsed to `_`, trimmed. Candidate groups are files in the **same folder** with the same key and the same kind (note vs number).

### 7.2 Candidate rule
At least **3 distinct pitches** (two files are more likely `Kick 1`, `Kick 2`). A file belongs to at most one group.

### 7.3 Acceptance
Candidates in folders allowed by the location's rules (§7.4) are accepted when:
1. **Metadata backs the names.** Root notes (§7.5) exist for ≥ 3 distinct pitches, are not all the same placeholder (> 1 distinct note), and ≥ 90 % of them differ from the name's pitch by **one and the same whole number of octaves** (offset mod 12 = 0). **Or** the pack skips a number in its names while notes stay consecutive: ≥ 90 % have notes, each pitch has exactly one note, the first file's note equals the name's pitch up to whole octaves, notes strictly rise with the names, and the name-to-note difference only ever shrinks (never rises).
2. **Else, for note groups only, by sound:** if any member is still `pending`, defer ("later"; picked up after indexing); otherwise accept when the mean pairwise cosine of the members' embeddings (≤ 16 evenly spaced members, unit vectors) is ≥ **0.8 (provisional)** and ≥ 3 vectors exist.
3. Number groups without metadata backing are rejected (bare numbers are usually just an index, `Decay 01..08`).
Accepted **number** groups take their pitches from the files' root notes when every member has one.

### 7.4 Per-location rules
`{groupByDefault: Bool (default true), overrides: [{folder, group}]}` stored as JSON on the location. `folder` is relative to the location root, no leading/trailing slash. The **nearest ancestor override wins**; the rule is evaluated for the folder that directly holds the files. UI: switch + list of exceptions ("Group in" / "Don't group in" + folder text + remove) + *Add Folder Exception* (new row defaults to the opposite of the default). Saved at import; editing regroups that location.

### 7.5 Root note (no decoding)
Read from header chunks: WAV `smpl` (MIDIUnityNote), then `acid` (root note, only when the flag bit 0x02 is set), then `inst` (unshifted note); AIFF/AIFC `INST` baseNote. Only 0–127. At most 64 chunks are walked; stop at the first chunk id that is not printable ASCII (damaged files). `pitchNumbers` = all note numbers a WAV mentions (smpl, acid, inst root + low + high).

### 7.6 Storage and list behaviour
- Table `sample_groups(id, location_id, folder, key, name, manual, representative_id)` unique on (location, folder, key). A multisample is a **first-class object**: it has a name (default: the representative's file stem), a member list and a representative. Manual groups use `folder = ''` and `key = 'manual:<uuid>'`. `samples.group_id, pitch (MIDI, C4=60), pitch_label`.
- A regroup run **replaces all automatic groups of one location** and keeps `manual` groups and their members (empty manual groups are deleted); it is repeatable at any time. Any user edit (create, rename, ungroup, add/remove members, set representative) marks the group manual, also an edited automatic one.
- **Editing** happens in the location sheet only (Multisamples… on the location row, Review Multisamples… in Edit mode): rename, ungroup, remove member, add samples from the location's ungrouped samples, make representative, new group from selected samples. A sample moves out of its old group when added elsewhere. It runs after scan, after indexing, after a rules edit, and (for all locations) via `regroup()`.
- **Representative** = first member (path order) at the **median distinct pitch**.
- **Tags and categories of a group are the union over its members** (no stored group cluster). A group shows its distinct member tags and one colour dot per distinct sorted member cluster.
- **Collapsed mode** (toolbar toggle, on by default, persisted): one row per group, the representative, or the first member by pitch that matches the filter when the representative does not. `total` counts those rows. Sorting uses the shown row. A group shows when **any member** matches the active filters, keyword, cluster, axes brush or map area; the cluster filter matches a group if any member matches. Expanded, a group lists **all** its members, matching ones normal and non-matching ones dimmed. With grouping off only matching samples show. Name and name sort use the group name. Groups collapse **only** in plain browse, not in text-search or similar results.
- **Row UI** (group of more than one member): badge `N pitches LOW–HIGH` (e.g. `24 pitches C1–B2`) next to the name; a disclosure triangle expands to the **other** members (the group row is itself a member, so children omit it), in pitch order, each labelled with its note. Expansion state is reset on every first-page reload. `showsGroups` changes together with the rows so toggling never draws old rows in the new mode **(unverified; if it persists, key the Table on `showsGroups`)**.
- Keyboard stepping, scrolling, context menu and drag work over expanded members.
- Members of a group are always fetched whole (`members(groupID)`), whatever the filter.
- **Result on the owner's 54k-file synth library:** clear multisample files in no group fell from 18,595 to 149 after the "pitch index" and "id suffix" rules. Use this as a regression target if the library is available; the repo's test libraries contain no multisamples.

### 7.7 CLI
`sondr-multisamples <folder> [--all] [--series]`: read-only, no database. Prints the groups file names suggest and how metadata compares (`metadata agrees` / `shifted N octaves` / `DISAGREES` / `uninformative` / `no metadata`, outliers named), counts of confirmed groups and ignored numbered series. `--all` lists members; `--series` lists unaccepted numbered series. Uses the same acceptance check as the app.

---

## 8. Playback, detail pane, drag-out

### 8.1 Playback
- `AVAudioPlayer`, one sample at a time, 30 Hz playhead. **Space** toggles play/stop for a single selection; **double-click** (table primary action) toggles. Selection change stops playback unless **play on select** is on (toolbar toggle and Settings; persisted).
- A missing file shows a red message in the footer ("<file> is not at <folder> any more. Rescan the folder."), not a crash.
- **Keyboard.** ↑/↓ move one row; Shift+↑/↓ and Page Up/Down move 10. Read from the **event stream** (a local key monitor), not `onKeyPress`, because `onKeyPress` delivers only the first press of a held key; key repeats must keep moving **(unverified)**. Command/Option/Control keep their meaning. Clicking in the table takes keyboard focus even from the search field. Programmatic selection scrolls the table to the row (SwiftUI `Table` does not).

### 8.2 Detail pane
Single selection:
1. Title (display name, selectable).
2. **Sound tile**: one rounded tile with the waveform (46 pt) over the spectrogram (96 pt) and a time axis (0 s / half / full, capped to 1–10 s), **one playhead across both**; frequency axis labels 100 / 1k / 10k Hz positioned to scale. Spectrogram = system accent colour with opacity following the level (gamma 0.85), so silence is the tile and it follows accent and dark mode. Played part of the waveform in the accent colour. Placeholder "No spectrogram yet. Press Index."
3. **Play/Stop** and **Find Similar** buttons.
4. Warnings: "The file is gone from disk." (missing), the failure reason (failed).
5. Facts: Length, Format (`WAV, 48000 Hz, mono|N ch`), Cluster (`name (NN%)`, or `Unsorted (closest: name, NN%)`), State.
6. **Tags**: removable chips + "Add a tag" field (Return adds).
7. **Sound**: six bars for the normalised dims.
8. **Location(s)**: all paths; heading "Found in N places" when > 1; each with a *Show in Finder* button.
9. **File metadata**: read from the file **on demand, never stored**. Main list of 21 named fields: Codec, Bit depth, Approx. duration, File size, Modified, Root note (smpl), Fine tune (smpl), Loops, First loop, Root note (inst), Fine tune (inst), Gain, Key range, Velocity range, Originator, Originator reference, Origination date, Origination time, Time reference, Cue points, Marker labels. Everything else (including opaque vendor chunks) goes under a collapsed **More metadata (N)**. Sources: encoding details, file attributes, AVFoundation tags (ID3, iTunes atoms), and WAV header chunks `smpl, inst, bext, cue/adtl, LIST/INFO`.
Multi-selection: "N samples selected", the union of their tags as chips (removing one removes it from all selected), and an "Add a tag to N samples" field. No selection: empty-state "Select a sample to see its details."

### 8.3 Drag-out
Drag one or many rows as real file URLs (`NSItemProvider(object: url as NSURL)` with `suggestedName` = the file name; not `contentsOf:`, which makes receivers get a renamed cache copy) of the canonical, existing path; works for group rows and expanded members. A missing file yields no provider (nothing is dragged). Never offers a move. **Needs a person to verify** in Finder and the owner's DAW (checklist in §13.2).

### 8.4 Context menu
Single selection: Play, Find Similar (disabled without models). Any selection: Show in Finder.

---

## 9. Explore panel (toolbar toggle, above the table)

Header: segmented **Axes | Map**. Height 160–700 pt, default 380, dragged by a bottom handle (resize cursor); height and tab are persisted. Both views narrow the list; the filters combine with tags, keyword and each other.

### 9.1 Axes (parallel coordinates)
- Six vertical axes (brightness, percussiveness, energy, tonality, noisiness, duration) with one line per sample, normalised 0–1.
- **Drag on an axis** to keep only samples in that range (brush; commits on drag end = one query). **Click** an axis (< 3 pt movement) clears its brush. The nearest axis within 16 pt is the target. Live brush drawn while dragging.
- Draws a **bounded, repeatable pseudo-random sample**: 1,500 lines of the unbrushed result as grey context, plus 1,500 of the brushed result highlighted in accent when any brush is active. The table filter always acts on the full set. Draw in batches of 50 lines per path (one huge path is minutes in the software renderer).
- Caption "N samples with sound data". Banner "Sound axes: <names>" with ✕ in the list.
- Test on the query layer: two brushes narrow the table to exactly the matching samples (including constant dim, full ranges, empty intersections, unindexed samples).

### 9.2 Map
A 2D map of the library: **one dot per sample**, coloured by cluster (grey if unsorted), drawn into one bitmap (premultiplied RGBA, tiny squares composited), not as SwiftUI shapes. 250k dots draw in ~5 ms (15 ms with a highlight set); hit-testing is a plain loop (0.08 ms). Needs ≥ **50** indexed samples ("The map needs at least 50 indexed samples."). No map yet → "There is no map yet." + **Build the map…**.

Interaction (needs AppKit event handling; SwiftUI gestures cannot do scroll/magnify/hover):
- Hover: file name next to the cursor after a moment.
- Click a dot: select it (ring drawn; detail pane shows it; plays if play-on-select is on). Click empty space: clears selection.
- Drag a rectangle (dashed, translucent accent): on release the list narrows to samples inside; banner "Area on the map: N samples" with ✕; Esc clears the area filter and the selection.
- Two-finger scroll pans; pinch zooms; ⌘ or ⌥ + scroll zooms around the cursor; double-click or *Show all* resets. Fit ignores the outer 1 % of points; zoom keeps the point under the cursor; scale limited.
- Search results (describe/similar, or any narrowing filter ≤ 100k) stay bright, the rest fades.
- Footer: "N samples", a "Library has grown. Rebuild?" hint when the library has grown > 20 % since the map was built (measured against `built_count`, not the placed share), *Show all* when zoomed.
- Selection rings drawn for up to 60 selected dots (≤ 200 selected).

**Layout card** (button *Layout*, opens beside the map, 290 pt, never on top of it):
- Sliders: Sample size (1,000–50,000 step 1,000), Neighbourhood size (perplexity 5–100), Cluster tightness (early exaggeration 4–30), Refinement steps (100–1,000 step 50); buttons *New random sample* (new seed), *Reset*.
- **Any change starts a preview after 0.4 s** and cancels the one in flight. The preview is **not saved**; chip "Preview, not saved" / "Computing preview…". The map shows the layout forming (positions stream in during the fit).
- *Keep* (Return) saves, closes the card and makes the draft the new default. *Discard* drops it at once. *Show current* (toggle) or **holding ⌥** flips to the current map without changing the viewport; chip "Current map". *Restore previous map* swaps with the older map and can itself be undone by pressing it again. "More settings…" opens Settings → Map.
- A preview never starts while an index job runs (card shows "Indexing is running."). Cancelling stops a preview between loading, preparing and fitting batches (~25 steps each); preparing (PCA, neighbours) cannot be interrupted (1–2 s at 50k).
- Status text: "Preview of N samples, x.x s, matched to the current map" when aligned.

### 9.3 Map computation
- **Algorithm: t-SNE** via vendored MetalTSNE (UMAP was evaluated and rejected by the owner; `docs/RESEARCH_UMAP.md`). Deployment target macOS 15 comes from this library.
- **Vendoring requirement.** Upstream could not rebuild a model from stored data, so new samples could not be placed after a restart. The vendored copy adds: `TSNEModelState`, `TSNEModel.state`, `TSNE.restoreModel(_:parameters:)`, and makes `TSNE.context` non-private. A restored model must place points **exactly** like the original (`project` and `transform`, with and without PCA). Keep its 51 upstream tests plus the state tests; list every change in `ThirdParty/MetalTSNE/VENDORED.md`.
- **Service (actor).**
  - `preview`: fit a random **seeded partial shuffle** sample of all indexed ids (same seed → same sample); saves nothing.
  - `keep`: place all other indexed samples with `project` (no refit) and save the map in one transaction; skip samples removed since the preview.
  - `placeNewSamples`: project samples without a point, also after a restart (model rebuilt from stored state). **Nothing already on the map moves.**
  - `restorePrevious`: swap current and previous.
  - Samples without a readable vector are skipped, not errors.
- **Alignment.** A new fit is aligned to the current map by orthogonal Procrustes (rotation, flip, scale, shift) over the shared samples, when a current map from the same embedding model exists and ≥ 3 samples are shared; the result says whether it was aligned. Aligned positions are written into the model state so `project` works in the aligned space (relies on `project` being invariant to a similarity transform; tested: samples placed onto an aligned map land among their own cluster). Alignment fixes spin only, not a different arrangement of groups.
- **Reproducibility is not available:** two fits with the same seed differ (GPU arithmetic). "Keep" therefore stores the previewed map itself and never refits it. Settings help text must say so ("Building the map again can arrange the same groups differently").
- **Storage.** `maps` (settings JSON, fitted/input/work dims, reference embedding+work blobs, PCA mean/components, `built_count`, model version) and `map_points(map_id, sample_id, x, y, fitted)` cascade-deleted with the sample. `meta` holds current and previous map ids. **At most two maps**; saving a third drops the oldest in one savepoint. A changed embedding model deletes all maps with the vectors.
- **Parameters** (JSON; missing fields → defaults; explicit `null` PCA = off; `clamped()` enforces ranges): sampleSize 30,000 (range 50–50,000), perplexity 30, earlyExaggeration 12, iterations 300, pcaDimensions 50 (range 10–100 or off), neighborCount (nil → 3 x perplexity), earlyExaggerationIterations 150, learningRate (nil → from sample size), initialMomentum 0.5, finalMomentum 0.8, initialization pca | random, backend auto | exact | fast (auto = exact ≤ 10,000 points, field optimiser + approximate KNN above), seed 42. Adapt to small samples: perplexity < a third of the points, neighbours < point count, PCA ≤ vector size.
- **Targets.** 50k fit 3.8 s (kill criterion was 10 s); `project` of 200k points ≈ 3.5 s; full 250k build ≈ 8 s (30k fit + 220k placed, one transaction).

### 9.4 Settings → Map
Sections: **Current map** (built date, "N (layout from N, the rest placed)", settings summary, rebuild hint; *Rebuild with a preview…* opens the Layout card in the main window; *Restore previous map*), **Layout** (sample size, random sample, neighbourhood size, cluster tightness, refinement steps, "Reduce the vectors first" + "Reduce to N numbers"), **Advanced** disclosure (neighbours kept, steps with tightness applied, learning rate, momentum at first/later, start layout, calculation, seed, *Reset all map settings*), **Reading the map** (t-SNE caveat: distances between groups, group size and empty space carry no meaning). **Every setting has a plain-language explanation caption.** Settings here apply to the next map build.

---

## 10. Tag management

- **Add / remove** on one or many selected samples (detail pane). Bulk add to 1,000 samples is a handful of statements in one transaction (chunks of 500 ids). Names are trimmed and lower-cased.
- **Manage Tags… sheet** (460 x 460): filter field; table Tag | Samples (all tags, most used first); buttons **Rename…**, **Merge Into…**, **Delete…** (confirmation "Delete “x” from all samples?"), **Done**. Note under the table: renaming or merging an auto tag does not change future scans.
- **Rename** = merge into a new name; renaming onto an existing name fails with `nameTaken` and a message telling the user to merge.
- **Merge** never leaves a sample with the target twice; a manual use stays manual; a target tag the user removed from a sample earlier is not brought back by an auto tag from the source.
- **Sticky removals:** removing, merging away or deleting an **auto** tag writes `removed_auto_tags` for each affected sample. A tag row is deleted only when no sample uses it **and** no removal refers to it.
- Known limit (shown in the UI): a new file whose path contains the old word gets the old tag again after rename/merge. Fixing it needs a user-level alias table (not built).
- Tests: merge (no duplicate rows), rename conflict, delete cascade, bulk add in one transaction.

---

## 11. Settings → General

- **Library:** database path (selectable, *Show in Finder*); models path ("Not found. Build them with tools/convert_clap/convert.py." in secondary colour when missing).
- **Search model:** *Run on* picker (GPU and CPU / All incl. Neural Engine / CPU only), note "Takes effect the next time Sondr starts…".
- **Playback:** "Play samples as soon as they are selected".
- Preferences (`UserDefaults`, bundle id `com.sebastianmika.sondr`): `computeUnits`, `autoAudition`, `settingsTab`, `showSoundMap`, `groupMultisamples`, `explorerTab`, `explorerHeight`, map settings.

---

## 12. Data model

One SQLite file. Illustrative, derived from the current schema (v1–v6 squashed is fine; **no migrations needed**).

```
locations(id, path UNIQUE, type_filter, max_length, added_at,
          extra_tags JSON, tag_rules JSON, group_rules JSON)
samples(id, content_hash UNIQUE, canonical_path, filename, name, rel_path,
        duration, sample_rate, channels, format,
        missing, embed_state CHECK(pending|done|failed), embed_error,
        cluster_id→clusters SET NULL, cluster_score,
        dim_brightness, dim_percussiveness, dim_energy, dim_tonality, dim_noisiness, dim_duration,  -- raw
        wave_thumb BLOB(128), spectrogram_thumb BLOB(2048),
        group_id→sample_groups SET NULL, pitch, pitch_label,
        file_size, file_mtime, scanned_at)
sample_paths(id, sample_id→samples CASCADE, path UNIQUE, location_id→locations SET NULL, file_size, file_mtime)
sample_groups(id, location_id→locations CASCADE, folder, key, name, manual, representative_id→samples SET NULL,
              UNIQUE(location_id, folder, key))
embeddings(sample_id PK→samples CASCADE, vector BLOB Float16 x512)
tags(id, name UNIQUE)
sample_tags(sample_id, tag_id, source CHECK(auto|manual), PK(sample_id, tag_id))
removed_auto_tags(sample_id, tag_id, PK)            -- sticky user removals
clusters(id, name, color '#RRGGBB', keywords)
cluster_centres(cluster_id, model_version, vector BLOB Float32, PK(cluster_id, model_version))
dim_stats(dim PK, p5, p95)
maps(...), map_points(map_id, sample_id, x, y, fitted, PK) WITHOUT ROWID
meta(key, value)   -- model_version, tag_rules (global), retag_pending, current/previous map
```
Indexes: `samples(name)`, `samples(embed_state)`, `samples(cluster_id)`, `samples(group_id)`, `sample_paths(sample_id)`, `sample_tags(tag_id)`, `map_points(sample_id)`.
Deleting a sample cascades to paths, embeddings, tags, map points. Foreign-key violations must raise.
Not yet indexed for large sorts: `ORDER BY filename` over 250k rows has no supporting index (measured fine; add only if it becomes slow).

---

## 13. Non-functional requirements and verification

### 13.1 Performance targets (250k samples unless noted)
| Operation | Target | Measured before |
|---|---|---|
| Page of 200 rows + count | ≤ 200 ms | 70–120 ms |
| Vector top-50 | < 50 ms | 2.8 ms |
| Text embedding, warm | < 300 ms | 24–124 ms |
| Index throughput | ~250 samples/s | 247/s |
| Scan, 100k tiny files | – | 30 s first, 0.76 s unchanged rescan |
| Map build | – | 8.1 s |
| Retag 250k | – | 62 s (background job) |
| Tag preview, 100k files | few seconds | 2.9 s |
| Raster 250k dots | smooth zoom/pan | 5 ms |
Benchmarks print numbers into `docs/BENCHMARKS.md`; they are opt-in (`SONDR_BENCH=1`) and not pass/fail.

### 13.2 Manual checks (cannot be automated)
Drag-out into Finder and the DAW (one row, many rows, missing file, originals unchanged afterwards); table feel with 100k rows; first run with no models; playback of a deleted file; the whole map interaction list (hover, click, area drag, search fade, zoom/pan, layout card, compare, keep/discard/restore, new samples appear without rebuild, rebuild hint, indexing blocks preview, size at 50k); locations flows (empty state → add sheet in two clicks, preview, ignore, import, edit + retag count, global rules, two locations sharing a file, quit during retag and resume); **multisamples (unverified): expand/collapse, badge text, keyboard stepping across expanded members, collapse toggle, folder exceptions, group cluster in sidebar/filter**.

### 13.3 Automated tests (≈350 in the old repo, 60 s)
- Swift Testing/XCTest, `swift test`; opt-in release-mode benchmarks.
- **Golden fixtures** (generated by `tools/golden`, deterministic, checksummed, no copyrighted audio): 51 synthetic audio files (drums, tones, pads, noise, loops; edge cases: silence, DC, clipping, < 1 s, > 10 s; rates 22.05k–96k; mono/stereo; wav/aif/flac/mp3/caf/m4a; lossy ones with a −60 dB noise floor), 3 corrupt files, reference embeddings (7 s legacy and 10 s native), log-mel for 5 files, decoded audio for 13 files, 20 text queries + 27 tokenizer cases, 200 tagger paths.
- Parity: embeddings per §5.1; tagger **200/200** exact; dims per §5.3; tokenizer ids exact.
- Scanner: duplicates, nested folders, corrupt file, moved file, unchanged files not rehashed, originals untouched, concurrency lock.
- Index job: stub embedder; kill/rerun; corrupt file → failed without vector; second start rejected.
- Query layer: table-driven filter combinations; constant statement count; groups (`SampleQueryGroups`); dim brushing against a reference filter.
- App models (`AppModel`, `BrowseModel`) with a fake embedder.
- Multisamples: names, grouper, rules, root note, scan stores rules and rescan keeps them, `updateMultisampleRules` stores and regroups.
- Map: alignment, raster, store, service, selection; MetalTSNE's own suite.
- Test-library generator: `TestLibraryGenerator` writes 8-bit mono 8 kHz WAVs of 444 bytes by hand, unique noise each, realistic folder/names (`Pack 007/Drums/Kicks/Kick_Hard_00042.wav`); output depends only on count and seed (1k in normal tests, 100k opt-in).

### 13.4 Development aids (keep, they are how UI is checked without screen capture)
Env vars: `SONDR_DB`, `SONDR_MODELS`, `SONDR_SNAPSHOT=<file>.png` (writes a PNG of the window after 4 s, `SONDR_SNAPSHOT_DELAY` to change, then quits), `SONDR_SELECT_FIRST`, `SONDR_OPEN_SETTINGS` + `SONDR_SETTINGS_TAB`, `SONDR_SHOW_EDITOR` (location editor in the main window), `SONDR_SHOW_LAYOUT` + `SONDR_PREVIEW_PERPLEXITY`, `SONDR_BENCH`, `SONDR_BENCH_DB`. They do nothing unless set.
CLI: `sondr-testlib <count> <folder> [seed] [--db <file>] [--fake] [--clustered] [--map]` builds a scanned (and with `--db`, indexed; `--fake` = random embeddings, `--clustered` = 8 clusters, `--map` = also build the map) library. `sondr-multisamples` per §7.7.

### 13.5 Process
Break the work into small steps; a step is done when its tests and the whole suite pass; commit per step with what and why and reviewer hints. Failing test first for every behaviour in this file. Record non-obvious decisions with evidence in `docs/DECISIONS.md`. Do not scan or index the owner's real library without asking. Ground truth for ML behaviour is HF/PyTorch and the golden fixtures.

---

## 14. Known limits, open questions, provisional values

1. **Unsorted threshold 0.30 is provisional** (synthetic fixtures only). To tune: index ~500 real files into a temp DB, histogram `cluster_score`, inspect around candidates, record in DECISIONS. Needs the owner's go-ahead. It is also used by group clusters, so groups depend on it.
2. **Multisample similarity threshold 0.8 is provisional**; tune on a real library.
3. **Tagger hyphen quirk** is kept for parity (`90bpm-chop-bright` stays one tag). Fixing it changes ~25 % of the golden paths; if wanted, keep a hyphenated token only when it is an alias key/value *and* also split it, then re-baseline the golden test.
4. **Map on real CLAP vectors is untried** (only synthetic clusters). Unsorted dots may be mostly grey at threshold 0.30. Same-seed fits are not reproducible. A side-by-side compare view was left out on purpose. Sample size above 50,000 is not offered.
5. The table does not scroll to a sample selected on the map.
6. Rename/merge of auto tags is overwritten by new scans (no user alias table).
7. A SwiftUI `Table` scroller shows the loaded rows, not the total, until all are loaded; fallback is a windowed `NSTableView`.
8. Core ML text model is fp32 (478 MB); 8-bit quantisation could halve the app size (untried).
9. First walk of a large folder on a cold disk or network volume will be slower than measured. All timings are synthetic.
10. Multisample UI and the collapse toggle were built but not tried in the running app (**unverified**); sample libraries on the dev machine had no multisamples until the 54k synth library.

## 15. Out of scope
Playlists/collections, cloud sync, AU/VST plugin, audio editing, tempo/key detection, App Store distribution and notarisation, localisation, 3D map, UMAP, WebAudio fallback, web UI/API, Qdrant or any vector DB, data migration from the Python prototype, `.ogg`, per-location extension/max-length UI, changing the folder of an existing location (remove and re-add), editing stopwords or aliases, a user-level tag alias table.

## 16. Suggested order for the rebuild
Highest risk first: (1) fixtures + Core ML conversion + mel/tokenizer parity (kill the project here if text search cannot reach parity); (2) DB, scanner, tagger, dims, thumbnails; (3) index job, clusters, reconciliation; (4) vector index + queries; (5) shell, table, playback, detail, drag-out; (6) tags UI, locations in Settings with preview/retag; (7) axes; (8) multisamples (names → grouper → rules → list UI); (9) map (vendored t-SNE + model state, service, store, raster, interaction, layout card, settings); (10) polish, packaging, docs. Cheapest things to cut if scope shrinks: the map (largest, least tied to search), then axes, then cluster "unsorted" handling.

## 17. Reuse code
You can check code from ../sondr/ and reuse it where that does not impact quality of the new code base (esp. isolated sub-elements of Sondr like the MetalTSNE and the CLAP handling - but note that we use a different HF model here).

Otherwise follow the ponytail idea: less code is better