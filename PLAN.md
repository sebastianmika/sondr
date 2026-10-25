# Plan: Signal Grid theme, light/dark/system, app icon

Design: `docs/DESIGN.md`. Findings: `RESEARCH.md`. Status: approved 2026-10-25, in progress. Step 0 done.

## Approach
Theme the native surfaces, do not rebuild controls. One token table (pure data, tested) in `SondrCore`, wrapped into dynamic colours in the app. Appearance is a preference applied through `NSApp.appearance`. Each step below builds, passes `swift test` and a snapshot check in both appearances, then gets its own commit.

Biggest risk: native `Table` selection cannot be drawn like the mockup. Step 0 tests that before anything else is built.

## Steps

0. **Spike: orange selection in the Table** (S) — DONE
   - Throwaway branch/stash. Set `.tint(orange)` at the root, snapshot the sample list selected, dark and light (`SONDR_APPEARANCE` stub or `defaults` + system switch).
   - Verify: a screenshot pair. Decision gate with you: accept system selection, or invest in an `NSTableView` row view (adds roughly one M step to step 5).
   - **Result:** `.tint` alone does not reach the Table (selection stayed system blue, spectrogram too). An `AccentColor` asset (`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`) does: selection is orange in dark and light, white text on it. No custom row view needed. Caveat: macOS only honours the asset while the user's system accent is Multicolor (the default); with a fixed system accent the Table selection follows the system, tinted views stay orange. Snapshot sidebar renders black (translucent material is not captured), so the sidebar is unverified by snapshot.

1. **Tokens and contrast logic in SondrCore** (S) — DONE
   - `Sources/SondrCore/Theme/ThemeTokens.swift`: the colour table from `DESIGN.md` as RGB pairs (dark, light). `ClusterPalette.RGB`: `contrast(against:)` and `legible(on:minimum:)` (lightness shift, hue kept).
   - Tests: every token pair meets its target (text 4.5, graphics 3); `legible` leaves good colours alone, fixes yellow on light, is idempotent. Adjust token values until green.
   - Verify: `swift test`.

2. **Appearance setting and accent** (S) — DONE
   - `Preferences.appearance` (`system|light|dark`), picker in Settings → General, applied to `NSApp.appearance` at launch and on change. `App/Theme/Theme.swift`: dynamic `Color`s from the tokens. Root `.tint(Theme.signal)` on window and Settings.
   - Dev aid: `SONDR_APPEARANCE=light|dark` so snapshots need no system switch.
   - Verify: snapshot of main window and Settings, both values; switch while running, no restart needed.

3. **Fonts** (S) — DONE
   - Bundle IBM Plex Mono 400/500/600 + OFL text under `App/Fonts/`, register at launch, `Font.sondrMono(size:weight:)`, caps-label modifier.
   - Verify: snapshot shows Plex (not the fallback); check the font name resolves in a unit-free launch log.

4. **Sidebar and jobs bar** (M) — DONE
   - Panel ground, hairlines, caps section labels, square cluster markers with scheme-derived colour, tag chips, segmented LED progress. Remove `clusterColor` duplication by routing through `Theme`.
   - Verify: snapshots both schemes, compare to the mockup boards.

5. **Sample table and toolbar** (M) — DONE
   - Mono columns for length/root/match, dim caps cluster label, banners and toolbar toggles using `signalText` / `signal`, playing indicator.
   - Verify: snapshots both schemes with a selection, a playing row, and a group row (multisample disclosure still works).

6. **Detail pane** (M)
   - Waveform and spectrogram use `signal` (replace `accentRGB(for:)`), re-render on appearance change. Transport button, hairline metadata grid, "closest in sound" with LED meters.
   - Verify: snapshots; flip appearance with a sample open, spectrogram updates.

7. **Map and explorer** (M)
   - Ground = `window` token, selection ring `text`, drag rectangle `signal`, hover label. Feed `denseTable` through the per-scheme legibility rule; re-render raster on appearance change. Parallel coordinates and Explore panel get the same tokens.
   - Verify: snapshots with a test library (`sondr-testlib ... --fake --clustered --map`) in both schemes; dim clusters stay visible on the light ground.

8. **Settings, sheets, editors** (S)
   - Tint, fonts, Clusters colour well shows both-scheme preview of the chosen colour. Multisample editor, tag manager, failures sheet checked.
   - Verify: snapshot every Settings tab (`SONDR_SETTINGS_TAB`) in both schemes.

9. **Seed colours and app icon** (M)
   - `clusters.json` seed colours switch to the LED set (no migration, existing libraries untouched). `design/icon.svg` master, `make icon` renders the `AppIcon` set (needs a rasteriser; see questions), `project.yml` gets the catalog and `ASSETCATALOG_COMPILER_APPICON_NAME`.
   - Verify: built app shows the icon in Finder/Dock; look at 16, 32, 128 px; if the dim dots vanish at 16/32 px, add a simplified small-size variant.

10. **Docs and manual checks** (S)
    - `docs/MANUAL_TESTS.md`: visual checklist per scheme (selection, playing, map, Settings). `docs/DECISIONS.md`: entry for the accent override, `NSApp.appearance`, derived cluster colours. README: `make icon`.
    - Verify: you run the checklist; items I cannot check (real Finder drag, system appearance switching at runtime) are marked unverified.

## Sizing
S = hours, M = a day-ish. Total roughly a week of focused work, mostly steps 4–7.

## Cut, if time is short
- Step 8's colour-well preview (keep tint and fonts only).
- Mono-font bundling (step 3): fall back to SF Mono, lose some Elektron character.
- Simplified small-size icon unless the 16 px check fails.

## Not in scope
Replacing Table/NavigationSplitView/Form, density options, user themes, Icon Composer light/tinted variants, any model, schema or indexing change. No governance artifacts are triggered (no production model change).

## Open questions (my default in bold)
1. Names/body font: **system SF Pro**, or bundle Inter Tight as in the mockup?
2. If the spike says the Table cannot show the ring: **accept system selection (orange fill, dark text if possible)**, or build a custom NSTableView row view?
3. Accent: **always orange, ignoring the macOS accent colour setting**, or follow the system accent and use orange only for brand surfaces?
4. Icon: **one dark icon for both schemes**, or also a light-tile variant?
5. Icon rasteriser for `make icon`: **`rsvg-convert` via Homebrew** (one new dev tool) or a small Swift script drawing with Core Graphics (no tool, icon defined twice)?
6. Commits: **one commit per step on a branch `theme/signal-grid`**, no push, no PR until you ask. OK?
