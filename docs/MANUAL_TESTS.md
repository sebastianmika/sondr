# Manual checks (nothing here has been seen working by a person yet)

Use a temp library, not the real one, for the first pass.

- **Sidebar**: Library, Clusters (colour dots, counts) and Tags render. The headless snapshot draws it black.
- **Drag-out**: one row, many rows, a missing file, from an expanded multisample member; drop into Finder and the DAW; originals unchanged afterwards.
- **Keys**: hold ↑/↓ (repeat keeps moving), Shift+↑/↓ and Page Up/Down move 10, Space plays, double-click plays; table feel with 100k rows.
- **Playback**: a deleted file shows the red footer message; playhead across waveform and spectrogram.
- **First run without models**: banner, Index disabled with tooltip, keyword browsing still works.
- **Search**: Describe ("warm analog pad") and Find Similar with the real models.
- **Locations**: empty state → Add in two clicks, tag preview, Ignore, import, edit with retag count, global rules, two locations sharing a file, quit during retag and resume. Invalid regex rejected; remove confirmation text.
- **Tag manager**: rename conflict alert, merge, delete confirmation.
- **Multisamples** (unverified): expand/collapse, badge text, keyboard stepping over expanded members, collapse toggle, folder exceptions, group cluster in sidebar and filter; toggling must not draw stale rows (else key the Table on `showsGroups`).
- **Axes**: brush, click-to-clear, panel resize, tab and height persist across relaunch, banner with ✕.
- **Map**: hover, click select/clear, area drag + banner, Esc, pan/pinch/⌘⌥ zoom, double-click reset, search fade, layout card (preview, Keep with Return, Discard, ⌥ flip, Show current, Restore previous), rebuild hint, indexing blocks preview, new samples appear without rebuild, speed at 50k and 250k.
- **Cluster threshold**: with the fused model 4 of 8 labelled fixtures miss at 0.30 (see `ClusterModelTests`). Re-tune on ~500 real files with the owner's go-ahead.
