# Manual checks (nothing here has been seen working by a person yet)

Use a temp library, not the real one, for the first pass.

- **Sidebar**: Library, Clusters (colour dots, counts) and Tags render. The headless snapshot draws it black.
--> Works
- **Drag-out**: one row, many rows, a missing file, from an expanded multisample member; drop into Finder and the DAW; originals unchanged afterwards.
--> Move (Cmd) is rejected - good
--> Finder copy works, but target file name is "Waveform audio" - it should be the original filename
--> DAW drag and drop: sample lands in DAW
--> BUT: the path is wrong, it starts with '/Users/sebastian/Library/Caches/com.apple.SwiftUI.Drag-43EB826F-B669-45BB-B6BD-599BB13DFE4E/...' instead of the original path that it must start with
- **Keys**: hold ↑/↓ (repeat keeps moving), Shift+↑/↓ and Page Up/Down move 10, Space plays, double-click plays; table feel with 100k rows.
--> Works
- **Playback**: a deleted file shows the red footer message; playhead across waveform and spectrogram.
--> Works
- **First run without models**: banner, Index disabled with tooltip, keyword browsing still works.
--> Works
- **Search**: Describe ("warm analog pad") and Find Similar with the real models.
--> Works
- **Locations**: empty state → Add in two clicks, tag preview, Ignore, import, edit with retag count, global rules, two locations sharing a file, quit during retag and resume. Invalid regex rejected; remove confirmation text.
--> Not yet tested
- **Tag manager**: rename conflict alert, merge, delete confirmation.
--> Not yet tested
- **Multisamples** (unverified): expand/collapse, badge text, keyboard stepping over expanded members, collapse toggle, folder exceptions, group cluster in sidebar and filter; toggling must not draw stale rows (else key the Table on `showsGroups`).
--> See below
- **Axes**: brush, click-to-clear, panel resize, tab and height persist across relaunch, banner with ✕.
--> Not yet tested
- **Map**: hover, click select/clear, area drag + banner, Esc, pan/pinch/⌘⌥ zoom, double-click reset, search fade, layout card (preview, Keep with Return, Discard, ⌥ flip, Show current, Restore previous), rebuild hint, indexing blocks preview, new samples appear without rebuild, speed at 50k and 250k.
--> Not yet tested
- **Cluster threshold**: threshold 0.22 was tuned on the full real library (31,403 samples, 90.6% sorted); 1 of 8 labelled fixtures still misses (see `ClusterModelTests`).
--> See below

## Missing Features:
* No default tag filters for numbers (dd, dd.), number pairs (e.g. dd - dd) and note names (f#, C-3)
* User cannot manually create, edit, delete multisample groups when adding a location
* Cluster definitions not configurable (or not exposed in UI): user can add, delete clusters, change their name, their "description" used for the embedding, change the color.

## Bugs
The handling of multisamples is odd. Example: I select an area on the map that include 80 of 100 multisamples. They are shown as group. I disable the grouping, the samples are shown individually. I enable the grouping again: only a single (!) sample is shown.

Desired behaviour: if grouping is selected, multisamples where any included sample matches active filters/searches/etc show up with ALL included samples - those samples not matching filters vs. those matching highlighted). Grouping disables: only samples matching current filters etc. show. 

## Suggestion Multisamples
Multisamples become be first class objects. They hold a name (default = file stem of one sample) and a list of samples they contain. Categories and tags are the union over the included samples. The representative is just one specific sample of the collection, default=median pitch

## Re-test after the change round
- **Drag-out**: Finder copy keeps the original file name; DAW path is the original path (not `~/Library/Caches/com.apple.SwiftUI.Drag-…`); many rows; Cmd-move still rejected.
- **Grouping bug**: map area → grouping off → on shows one row per group; expand a group: all members listed, non-matching dimmed.
- **Group editor**: Locations → Multisamples… : create, rename, add samples, remove member, make representative, ungroup; manual group survives Rescan and Index.
- **Tag defaults**: Settings → Locations → Ignored tags (all locations) lists the default rules on a fresh library (edit/delete one, Apply, relaunch: stays changed); the location preview crosses out `01`, `f#`, `c-3` as "Ignored for all"; `808`, `909`, `am` stay. Note: `90bpm` loses the bare `90`.
- **Clusters tab**: change colour (instant, sidebar/table/map recolour); change a description or add a cluster and Apply (progress row "Sorting into clusters", Cancel, quit and relaunch resumes); delete a cluster; last cluster cannot be deleted.

## Theme (Signal Grid, light / dark / system)
Run each item once in Light and once in Dark (Settings → General → Appearance), with a temp library that has clusters (`sondr-testlib ... --fake --clustered --map`).
- **Switch live**: changing the picker restyles main window, Settings and sheets without a restart; System follows the macOS appearance, also when macOS switches while Sondr runs.
- **Selection and playing**: selected row is orange with readable text; the playing row's icon is orange; the playhead crosses waveform and spectrogram; the spectrogram is orange, not blue, also with a fixed macOS accent colour (Table selection may then follow the system accent, see RESEARCH.md).
- **Sidebar**: flat panel ground (not translucent), caps labels, square cluster markers, selected item readable; jobs bar shows segmented progress while indexing.
- **Map**: ground matches the window; every cluster colour is visible (light: yellow, lime, teal darkened but same hue); selection ring, drag rectangle and hover label; flipping the scheme redraws the map.
- **Axes**: lines visible on both grounds; brushed ranges orange.
- **Settings**: all four tabs; Clusters colour wells show the stored colour (the app may show a darker or lighter shade in light/dark, by design).
- **Sheets**: multisample editor, tag manager, failures sheet (not yet seen in either scheme).
- **Icon**: Finder and Dock show the dot field; Finder list view (16 px) shows the pixel S; check on a light and a dark desktop.

