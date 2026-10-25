# Sondr

Desktop app (macOS 15+, Apple Silicon) to manage and search 50k–250k audio samples. Requirements: `REQUIREMENTS.md`. Decisions with evidence: `docs/DECISIONS.md`. Manual checks: `docs/MANUAL_TESTS.md`.

## Build and run
```sh
make debug            # xcodegen + xcodebuild; make release for real libraries (about 7x faster indexing)
make run-release
make reset            # forget the library DB and preferences (keeps Models/)
SONDR_MODELS=$PWD/Models swift test    # model tests skip with a message when Models/ is missing
```

## Models (not in git, ~536 MB)
```sh
cd tools/convert_clap && uv sync && uv run python convert.py   # writes ../../Models
uv run python validate.py --units CPU_AND_GPU                   # parity against the golden fixtures
```
Model: `laion/clap-htsat-fused` (see DECISIONS: no fusion branch, 1-channel audio input, HTK mel).
Golden fixtures: `cd tools/golden && uv sync && uv run python generate.py` (needs ffmpeg and the legacy repo at `~/repos/sample_vault`).

## Test libraries
`swift run sondr-testlib <count> <folder> [seed] [--db <file> --fake [--clustered] [--map]]`. Never point the app or tests at a real library without meaning to.

## Dev env vars
`SONDR_DB`, `SONDR_MODELS`, `SONDR_SNAPSHOT=<png>` (+`SONDR_SNAPSHOT_DELAY`), `SONDR_SELECT_FIRST`, `SONDR_OPEN_SETTINGS`, `SONDR_SETTINGS_TAB`, `SONDR_SHOW_EDITOR`, `SONDR_SHOW_LAYOUT`, `SONDR_PREVIEW_PERPLEXITY`, `SONDR_BENCH`. Launch the app with `open -n -W --env KEY=VALUE …`; running the binary directly shows no window.
