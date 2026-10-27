# Sondr design: "Signal Grid"

Status: implemented on branch `theme/signal-grid` (see PLAN.md). Where the build differs from the first proposal it is noted below. Visual references: the Sondr Identity canvas (Identity, App dark, App light boards for direction A).

## Concept
Elektron-leaning hardware panel. The icon is a 5×5 field of step keys with thirteen lit, tracing an S: the library is the grid, the sample you found is the lit path. The UI is dense and quiet; one signal colour marks what is selected, playing or lit, and nothing else.

## Principles
1. Orange means selected, playing or lit. It is never decoration.
2. Labels in caps, mono, wide-tracked. Every number in mono.
3. Hairlines (1 px) instead of shadows or cards. Corners 2 px, never fully round.
4. Colour carries information (clusters), chrome stays neutral.
5. Native behaviour stays: Table sorting, drag-out, keyboard, Settings. Theme the surface, do not rebuild the controls.

## Colour tokens
Each token has a dark and a light value. Code names are proposals.

| Token | Use | Dark | Light |
|---|---|---|---|
| `window` | main window, map ground | #0E0E0F | #F2F0EB |
| `panel` | sidebar, detail pane, toolbar | #131314 | #E9E6DF |
| `surface` | raised field, search box | #171718 | #FAF9F6 |
| `hairline` | all dividers and borders | #2B2B2D | #D3CFC6 |
| `text` | primary text | #E8E6E1 | #16161A |
| `textDim` | secondary text, labels | #8F8F8A | #5F5D58 |
| `textMid` | tertiary body text | #B4B2AC | #4A4843 |
| `signal` | fills: playing, selected ring, progress, waveform played part | #FF5A1F | #E9440E (the brand orange is 2.7:1 on the light ground) |
| `signalText` | signal-coloured text and thin strokes | #FF5A1F | #C63A06 |
| `onSignal` | text/icons on a signal fill | #0E0E0F | #16161A |

Contrast targets: body text 4.5:1, labels at 11 px and below 4.5:1, graphics and rings 3:1. `ThemeTokensTests` checks every pair; the light `signal` and `signalText` values come from that test. The Table selection and `AccentColor` asset use the same two oranges.

The accent is fixed. Sondr ignores the macOS system accent colour, because orange carries the meaning.

### Cluster colours
Stored per cluster as `#RRGGBB` and editable in Settings → Clusters. Two rules:
- The seed set (new libraries only) is the LED set, none of it the signal orange: kicks #FF4D6D, snares #FFB02E, hats/perc #AEE03A, bass #3DDC97, pads #35B6FF, leads #8E7CFF, vox chops #E066FF, fx/risers #7FD1D1; unsorted stays grey #8E8E93. `MapRasterTests` requires seed colours to be 70 apart. Existing libraries keep what they have (no migration).
- Display colour is derived per scheme: if the stored colour has less than 3:1 contrast against `window` in the current scheme, its lightness is lowered (light) or raised (dark) until it does, hue kept. The stored value never changes. Used in sidebar, table, map, and the map raster table.

## Typography
| Role | Font | Notes |
|---|---|---|
| Labels, numbers, durations, paths, readouts | IBM Plex Mono (400/500/600) | bundled, OFL licence |
| Sample and cluster names, body | system (SF Pro) | decided: no Inter Tight |
| Section labels | Plex Mono 10.5 pt, caps, +0.16 em | e.g. LIBRARY, CLUSTERS |

## Shape and spacing
- Radius 2 pt for fields and chips, 0 for panels, window radius is the system's.
- Base unit 4 pt; list row 40 pt (comfortable) as today, no density option in scope.
- Cluster marker: 8 pt square (replaces the 9 pt circle). In the map the dots stay dots.
- Selected row: 1 px signal inset ring on `surface` background (needs a spike, see PLAN).

## Components
- **Sidebar**: caps mono section labels, counts in mono, selected item on a neutral raised background with a signal square, tag chips with hairline border.
- **Sample table**: names in body font, length / root / match in mono, cluster as marker + dim caps label, per-row mini waveform in `textDim`, signal when selected or playing.
- **Detail pane**: probe label in `signalText`, waveform and spectrogram in `signal`, transport button a 2 pt-radius `signal` square with `onSignal` glyph, metadata as a hairline grid of mono cells, "closest in sound" with segmented LED meters.
- **Jobs bar**: caps label, segmented LED progress, mono counts.
- **Map**: ground = `window`, dots in cluster colours, selection ring in `text`, drag rectangle in `signal`, hover label on `surface`.
- **Settings**: stays a native grouped Form; picks up tint, fonts and the Appearance control.

## Appearance (light / dark / system)
- New preference `appearance` = system | light | dark, default system. Control: Settings → General → Appearance (segmented).
- Applied through `NSApp.appearance` (nil = follow system). That covers the main window, Settings, sheets and AppKit-backed views such as the Table, which `preferredColorScheme` does not always reach.
- Every token is a dynamic colour that resolves from the effective appearance, so views never branch on the scheme themselves. Places that bake colour into pixels (map raster, spectrogram) re-render on appearance change.

## App icon
- Source: `tools/make_icon.swift` draws the icon with Core Graphics into the `AppIcon` set (`make icon`); there is no SVG master. (`rsvg-convert` was not installed and the script avoids a new dev tool.)
- Dark graphite tile with dim and lit dots. One icon for both schemes.
- At 32 px and below the 5×5 field cannot be resolved, so a 3×5 pixel S replaces it (whole-pixel cells, one pixel gap).

## Out of scope
Custom replacement of Table / NavigationSplitView / Form; density settings; user-editable themes; Icon Composer light/tinted icon variants; marketing assets.
