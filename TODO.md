# TODO

## Check the multisample grouper (`MultisampleNames` / `MultisampleGrouper`)

Found while prototyping UMAP/PaCMAP layouts (2026-10-29): after grouping, 4,916 of 12,696 ungrouped
samples still form thin "strands" in the map. Causes, biggest first:

1. **Missed pitched multisamples, ~1,500 samples.** Sets of about 48-52 files per folder named
   `<number> <instrument> <note name>`, e.g. `02. Orchestral/Violin/61 Violin Mirage C#3.wav`,
   `03. Bass/Fuzz Bass/24 Fuzz Bass Mirage C0.wav`, `Instruments/UBC3 SineTape A#1.wav`. The leading
   number looks like a MIDI note number. Find out why these candidates are rejected or never proposed
   (numeric prefix before the note name? metadata check? similarity threshold `minimumSimilarity` 0.8?).
2. **Tempo series of loops/breaks**, e.g. `Breaks/075 Service Vinyl Breaks.wav` .. `200 ...` (number = BPM).
   Decide whether these should be groups at all.
3. **Effect-processed copies of one source across folders** (`...Vinyl`, `...-Tube`, `...-Clean`).
   Probably not multisamples; decide if a different grouping is wanted.

Also: `samples.pitch_label` is empty for every ungrouped sample.
