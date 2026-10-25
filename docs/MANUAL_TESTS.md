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
- **Cluster threshold**: with the fused model 4 of 8 labelled fixtures miss at 0.30 (see `ClusterModelTests`). Re-tune on ~500 real files with the owner's go-ahead.
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