# TODO

## Check the multisample grouper (`MultisampleNames` / `MultisampleGrouper`)

Open: group by effect-processed copies of one source across folders (`...Vinyl`, `...-Tube`, `...-Clean`).
Probably not multisamples; decide if a different grouping is wanted.

Also: `samples.pitch_label` is empty for every ungrouped sample.

Decided: BPM-numbered tempo series (`Breaks/075 Service Vinyl Breaks.wav` .. `200`) are not groups; they are
rejected without matching root notes (test `tempoSeriesWithoutRootNotesAreNotMultisamples`).
